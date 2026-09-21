defmodule SabrJev.EvaluateTaskTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Sabr.Evaluate

  setup do
    root = Path.join(System.tmp_dir!(), "sabr-eval-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp ledger_entry(root, id, probability) do
    card = %{
      "id" => id,
      "role" => "batter",
      "year" => 2026,
      "judgment_state" => %{
        "role" => "batter",
        "metrics" => %{},
        "sample" => %{"minimum" => 200, "value" => 400}
      }
    }

    record = %{
      "card_id" => id,
      "state_hash" => SabrJev.Questions.state_hash(card["judgment_state"]),
      "questions_hash" => "sha256:test",
      "model" => "jev-test",
      "probability" => probability
    }

    cohort = SabrJev.Prospective.enroll([card], baseline: %{"batter" => 0.5})

    {:ok, _ledger, line} =
      SabrJev.Prospective.capture(cohort, card, record, captured_at: ~U[2026-06-01 00:00:00Z])

    ledger = Path.join(root, "ledger.jsonl")
    File.write!(ledger, line <> "\n")
    ledger
  end

  test "scores realized outcomes and leaves missing outcomes pending", %{root: root} do
    ledger = ledger_entry(root, "batter:a:2026", 0.2)
    outcomes = Path.join(root, "outcomes.json")
    report_path = Path.join(root, "report.json")

    File.write!(
      outcomes,
      Jason.encode!(%{
        "batter:a:2026" => %{
          "year" => 2027,
          "label" => false,
          "target" => "ops_plus_drop_ge_10_next",
          "provenance" => %{"card_artifact" => "priv/data/cards.json"}
        }
      })
    )

    Evaluate.run([
      "--ledger",
      ledger,
      "--outcomes",
      outcomes,
      "--report",
      report_path,
      "--baseline",
      Jason.encode!(%{"batter" => 0.5})
    ])

    report = report_path |> File.read!() |> Jason.decode!()
    assert report["coverage"] == %{"scored" => 1, "pending" => 0}
    assert report["by_role"]["batter"]["n"] == 1
  end

  test "evaluation refuses a tampered ledger and a re-fitted baseline", %{root: root} do
    ledger = ledger_entry(root, "batter:a:2026", 0.2)
    outcomes = Path.join(root, "outcomes.json")
    report_path = Path.join(root, "report.json")

    File.write!(outcomes, Jason.encode!(%{}))

    # A baseline that disagrees with the frozen ledger cohort is refused.
    assert_raise Mix.Error, ~r/ledger baseline does not match/, fn ->
      Evaluate.run([
        "--ledger",
        ledger,
        "--outcomes",
        outcomes,
        "--report",
        report_path,
        "--baseline",
        Jason.encode!(%{"batter" => 0.9})
      ])
    end

    # Any post-capture edit invalidates the hash chain, so tampering is refused.
    File.write!(ledger, File.read!(ledger) <> "tampered\n")

    assert_raise Mix.Error, ~r/refusing to score ledger/, fn ->
      Evaluate.run([
        "--ledger",
        ledger,
        "--outcomes",
        outcomes,
        "--report",
        report_path,
        "--baseline",
        Jason.encode!(%{"batter" => 0.5})
      ])
    end
  end

  test "missing outcomes stay pending, never negative", %{root: root} do
    ledger = ledger_entry(root, "batter:a:2026", 0.2)
    outcomes = Path.join(root, "outcomes.json")
    report_path = Path.join(root, "report.json")

    File.write!(outcomes, Jason.encode!(%{}))

    Evaluate.run([
      "--ledger",
      ledger,
      "--outcomes",
      outcomes,
      "--report",
      report_path,
      "--baseline",
      Jason.encode!(%{"batter" => 0.5})
    ])

    report = report_path |> File.read!() |> Jason.decode!()
    assert report["pending"] == ["batter:a:2026"]
    assert report["coverage"] == %{"scored" => 0, "pending" => 1}
  end

  test "the report carries machine-readable pending labels and cohort markers", %{root: root} do
    ledger = ledger_entry(root, "batter:a:2026", 0.2)
    outcomes = Path.join(root, "outcomes.json")
    report_path = Path.join(root, "report.json")

    File.write!(
      outcomes,
      Jason.encode!(%{
        "batter:a:2026" => %{
          "year" => 2027,
          "label" => false,
          "target" => "ops_plus_drop_ge_10_next",
          "provenance" => %{"card_artifact" => "priv/data/cards.json"}
        }
      })
    )

    Evaluate.run([
      "--ledger",
      ledger,
      "--outcomes",
      outcomes,
      "--report",
      report_path,
      "--baseline",
      Jason.encode!(%{"batter" => 0.5})
    ])

    report = report_path |> File.read!() |> Jason.decode!()
    assert report["status"] == "prospective, accuracy pending"
    assert report["mode"] == "prospective"
    assert report["cutoff"] == "2027-01-01T00:00:00Z"
    assert report["baseline"] == %{"batter" => 0.5}
    assert report["ledger_limit"] == SabrJev.Prospective.ledger_limit()
    assert report["missingness"]["pending_rate"] == 0.0
  end

  test "a ledger mixing cohort cutoffs is refused", %{root: root} do
    ledger = ledger_entry(root, "batter:a:2026", 0.2)
    outcomes = Path.join(root, "outcomes.json")

    File.write!(outcomes, Jason.encode!(%{}))

    # Hash-valid line from a different cohort window: verify/1 passes, so the
    # cutoff guard is what refuses it.
    forged =
      Jason.encode!(%{
        "card_id" => "batter:b:2026",
        "noul_id" => "ops_plus_drop_ge_10_next",
        "probability" => 0.4,
        "cutoff" => "2031-01-01T00:00:00Z",
        "captured_at" => "2030-06-01T00:00:00Z",
        "line_hash" => "sha256:forged"
      })

    File.write!(ledger, File.read!(ledger) <> forged <> "\n")
    lines = ledger |> File.read!() |> String.trim() |> String.split("\n")

    # The hash chain is still structurally valid per line, so this exercises the
    # cutoff check rather than verify/1. (verify would refuse the forged hash.)
    assert {:error, :mixed_cohort_cutoffs} =
             SabrJev.Evaluation.score(
               Enum.map(lines, &Jason.decode!/1),
               %{},
               baseline: %{"batter" => 0.5}
             )
  end

  test "a non-object outcomes file is refused", %{root: root} do
    ledger = ledger_entry(root, "batter:a:2026", 0.2)
    outcomes = Path.join(root, "outcomes.json")
    report_path = Path.join(root, "report.json")

    File.write!(outcomes, Jason.encode!([1, 2, 3]))

    assert_raise Mix.Error, ~r/outcomes file must decode to a JSON object/, fn ->
      Evaluate.run([
        "--ledger",
        ledger,
        "--outcomes",
        outcomes,
        "--report",
        report_path,
        "--baseline",
        Jason.encode!(%{"batter" => 0.5})
      ])
    end
  end
end
