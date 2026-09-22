defmodule SabrJev.EvaluateTaskTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Sabr.Evaluate

  # The enrollable cohort is the newest season in the pins, so its window closed
  # on January 1 of the outcome season and every capture timestamp here sits
  # inside it. The offline suite never reads the wall clock.
  @inside_window ~U[2025-06-01 00:00:00Z]

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
      "year" => 2025,
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
      "mode" => "prospective",
      "probability" => probability
    }

    cohort = SabrJev.Prospective.enroll([card], baseline: %{"batter" => 0.5})

    {:ok, _ledger, line} =
      SabrJev.Prospective.capture(cohort, card, record, captured_at: @inside_window)

    ledger = Path.join(root, "ledger.jsonl")
    File.write!(ledger, line <> "\n")
    ledger
  end

  defp outcome(year) do
    %{
      "year" => year,
      "label" => false,
      "target" => "ops_plus_drop_ge_10_next",
      "provenance" => %{"card_artifact" => "priv/data/cards.json"}
    }
  end

  defp run(ledger, outcomes, report_path, baseline \\ %{"batter" => 0.5}) do
    Evaluate.run([
      "--ledger",
      ledger,
      "--outcomes",
      outcomes,
      "--report",
      report_path,
      "--baseline",
      Jason.encode!(baseline)
    ])
  end

  test "scores realized outcomes and leaves missing outcomes pending", %{root: root} do
    ledger = ledger_entry(root, "batter:a:2025", 0.2)
    outcomes = Path.join(root, "outcomes.json")
    report_path = Path.join(root, "report.json")

    File.write!(outcomes, Jason.encode!(%{"batter:a:2025" => outcome(2026)}))

    run(ledger, outcomes, report_path)

    report = report_path |> File.read!() |> Jason.decode!()
    assert report["coverage"] == %{"scored" => 1, "pending" => 0}
    assert report["by_role"]["batter"]["n"] == 1
  end

  test "evaluation refuses a tampered ledger and a re-fitted baseline", %{root: root} do
    ledger = ledger_entry(root, "batter:a:2025", 0.2)
    outcomes = Path.join(root, "outcomes.json")
    report_path = Path.join(root, "report.json")

    File.write!(outcomes, Jason.encode!(%{}))

    # A baseline that disagrees with the frozen ledger cohort is refused.
    assert_raise Mix.Error, ~r/ledger baseline does not match/, fn ->
      run(ledger, outcomes, report_path, %{"batter" => 0.9})
    end

    # Any post-capture edit invalidates the hash chain, so tampering is refused.
    File.write!(ledger, File.read!(ledger) <> "tampered\n")

    assert_raise Mix.Error, ~r/refusing to score ledger/, fn ->
      run(ledger, outcomes, report_path)
    end
  end

  test "missing outcomes stay pending, never negative", %{root: root} do
    ledger = ledger_entry(root, "batter:a:2025", 0.2)
    outcomes = Path.join(root, "outcomes.json")
    report_path = Path.join(root, "report.json")

    File.write!(outcomes, Jason.encode!(%{}))

    run(ledger, outcomes, report_path)

    report = report_path |> File.read!() |> Jason.decode!()
    assert report["pending"] == ["batter:a:2025"]
    assert report["coverage"] == %{"scored" => 0, "pending" => 1}
  end

  test "the report carries machine-readable pending labels and cohort markers", %{root: root} do
    ledger = ledger_entry(root, "batter:a:2025", 0.2)
    outcomes = Path.join(root, "outcomes.json")
    report_path = Path.join(root, "report.json")

    frozen_cutoff =
      ledger |> File.read!() |> String.trim() |> Jason.decode!() |> Map.fetch!("cutoff")

    File.write!(outcomes, Jason.encode!(%{"batter:a:2025" => outcome(2026)}))

    run(ledger, outcomes, report_path)

    report = report_path |> File.read!() |> Jason.decode!()
    assert report["status"] == "prospective, accuracy pending"
    assert report["mode"] == "prospective"

    # The header must report the cutoff frozen into the ledger, not whatever
    # cohort the module currently considers enrollable: after the pins next move,
    # an old ledger scored here would otherwise be labelled with a cutoff its
    # lines never carried.
    assert report["cutoff"] == frozen_cutoff
    assert frozen_cutoff == "2026-01-01T00:00:00Z"

    assert report["baseline"] == %{"batter" => 0.5}
    assert report["ledger_limit"] == SabrJev.Prospective.ledger_limit()
    assert report["missingness"]["pending_rate"] == 0.0
  end

  test "an outcome for a different season is refused rather than scored", %{root: root} do
    ledger = ledger_entry(root, "batter:a:2025", 0.2)
    outcomes = Path.join(root, "outcomes.json")
    report_path = Path.join(root, "report.json")

    # T+1 for a 2025 card is 2026, never 2027.
    File.write!(outcomes, Jason.encode!(%{"batter:a:2025" => outcome(2027)}))

    assert_raise Mix.Error, ~r/outcome_year_mismatch/, fn ->
      run(ledger, outcomes, report_path)
    end
  end

  test "a ledger line that is not prospective is refused by the scorer", %{root: root} do
    ledger = ledger_entry(root, "batter:a:2025", 0.2)
    outcomes = Path.join(root, "outcomes.json")
    report_path = Path.join(root, "report.json")

    File.write!(outcomes, Jason.encode!(%{}))

    # A retrospective line for the same card is the shape the old capture path
    # could have written; it must never be scored as a prospective prediction.
    line = ledger |> File.read!() |> String.trim() |> Jason.decode!()

    assert {:error, :not_prospective_ledger_line} =
             SabrJev.Evaluation.score(
               [Map.delete(line, "mode")],
               %{},
               baseline: %{"batter" => 0.5}
             )

    assert {:error, :not_prospective_ledger_line} =
             SabrJev.Evaluation.score(
               [Map.put(line, "mode", "retrospective")],
               %{},
               baseline: %{"batter" => 0.5}
             )

    # A published report cannot be written from such a ledger either. The chain
    # guard fires first when the line is edited, so a non-prospective line is
    # refused before the parse-time mode check is even reached.
    File.write!(ledger, Jason.encode!(Map.delete(line, "mode")) <> "\n")

    assert_raise Mix.Error, ~r/refusing to score ledger/, fn ->
      run(ledger, outcomes, report_path)
    end

    refute File.exists?(report_path)
  end

  test "a ledger mixing cohort cutoffs is refused", %{root: root} do
    ledger = ledger_entry(root, "batter:a:2025", 0.2)
    outcomes = Path.join(root, "outcomes.json")

    File.write!(outcomes, Jason.encode!(%{}))

    # Hash-valid line from a different cohort window: verify/1 passes, so the
    # cutoff guard is what refuses it.
    forged =
      Jason.encode!(%{
        "card_id" => "batter:b:2025",
        "noul_id" => "ops_plus_drop_ge_10_next",
        "probability" => 0.4,
        "mode" => "prospective",
        "cutoff" => "2031-01-01T00:00:00Z",
        "captured_at" => "2025-06-01T00:00:00Z",
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
    ledger = ledger_entry(root, "batter:a:2025", 0.2)
    outcomes = Path.join(root, "outcomes.json")
    report_path = Path.join(root, "report.json")

    File.write!(outcomes, Jason.encode!([1, 2, 3]))

    assert_raise Mix.Error, ~r/outcomes file must decode to a JSON object/, fn ->
      run(ledger, outcomes, report_path)
    end
  end
end
