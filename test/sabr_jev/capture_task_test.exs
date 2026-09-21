defmodule SabrJev.CaptureTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Sabr.Capture

  setup do
    root = Path.join(System.tmp_dir!(), "sabr-capture-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp card(id \\ "batter:example:2026") do
    %{
      "id" => id,
      "role" => "batter",
      "year" => 2026,
      "judgment_state" => %{
        "role" => "batter",
        "metrics" => %{
          "pa" => 400,
          "obp" => 0.4,
          "slg" => 0.5,
          "ops" => 0.9,
          "iso" => 0.2,
          "babip" => 0.3,
          "bb_pct" => 0.1,
          "k_pct" => 0.2,
          "woba" => 0.38,
          "ops_plus" => 123.4,
          "league_obp" => 0.31,
          "league_slg" => 0.4,
          "park_adjustment" => 1.0
        },
        "sample" => %{"minimum" => 200, "value" => 400}
      },
      "sample" => %{"qualified" => true, "minimum" => 200, "value" => 400, "unit" => "PA"},
      "oracle" => nil
    }
  end

  defp record(id \\ "batter:example:2026") do
    %{
      "schema_version" => 1,
      "card_id" => id,
      "state_hash" => SabrJev.Questions.state_hash(card(id)["judgment_state"]),
      "questions_hash" => "sha256:test",
      "model" => "jev-test",
      "recorded_at" => "2026-06-01T00:00:00Z",
      "probability" => 0.2,
      "response" => %{"model" => "jev-test"},
      "answers" => %{},
      "source_lineage" => %{"card_artifact" => "test"}
    }
  end

  defp catalog(root, cards) do
    path = Path.join(root, "cards.json")
    File.write!(path, Jason.encode!(%{"schema_version" => 1, "cards" => cards}))
    path
  end

  test "appends chained lines across runs and rejects intra-batch duplicates", %{root: root} do
    first = card("batter:first:2026")
    second = card("batter:second:2026")
    path = catalog(root, [first, second])
    ledger = Path.join(root, "ledger.jsonl")
    baseline = Jason.encode!(%{"batter" => 0.4})

    Capture.run(["--catalog", path, "--ledger", ledger, "--baseline", baseline],
      catalog_reader: fn _ -> {:ok, [first, second]} end,
      record_reader: fn card -> {:ok, record(card["id"])} end,
      captured_at: ~U[2026-06-01 00:00:00Z]
    )

    lines = ledger |> File.read!() |> String.trim() |> String.split("\n")
    assert length(lines) == 2
    assert :ok = SabrJev.Prospective.verify(lines)

    assert_raise Mix.Error, ~r/duplicate/, fn ->
      Capture.run(
        ["--catalog", path, "--ledger", ledger, "--baseline", baseline, "--card", first["id"]],
        catalog_reader: fn _ -> {:ok, [first]} end,
        record_reader: fn _ -> {:ok, record(first["id"])} end,
        captured_at: ~U[2026-06-02 00:00:00Z]
      )
    end

    assert_raise Mix.Error, ~r/duplicate/, fn ->
      Capture.run(["--catalog", path, "--ledger", ledger, "--baseline", baseline],
        catalog_reader: fn _ -> {:ok, [first, first]} end,
        record_reader: fn _ -> {:ok, record(first["id"])} end,
        captured_at: ~U[2026-06-02 00:00:00Z]
      )
    end

    assert length(ledger |> File.read!() |> String.trim() |> String.split("\n")) == 2
  end

  test "refuses historical enrollment and duplicate capture", %{root: root} do
    historic = %{card() | "id" => "batter:old:2024", "year" => 2024}
    path = catalog(root, [historic])
    ledger = Path.join(root, "ledger.jsonl")

    assert_raise Mix.Error, ~r/historical/, fn ->
      Capture.run(
        ["--catalog", path, "--ledger", ledger, "--baseline", Jason.encode!(%{"batter" => 0.4})],
        catalog_reader: fn _ -> {:ok, [historic]} end,
        record_reader: fn _ -> {:ok, record("batter:old:2024")} end,
        captured_at: ~U[2026-06-01 00:00:00Z]
      )
    end

    refute File.exists?(ledger)
  end

  test "the production record reader reads a real committed recording", %{root: root} do
    catalog = Jason.decode!(File.read!("priv/data/cards.json"))
    card = Enum.find(catalog["cards"], &(&1["id"] == "batter:judgeaa01:2024"))
    path = catalog(root, catalog["cards"])

    # The reader resolves the real recording by role/player/year and takes the
    # probability from the recorded typed Noul answer. 2024 is historical, so
    # capture itself refuses it: the reader and the window are independent.
    dir = Path.join(root, "recordings")
    File.mkdir_p!(dir)

    File.cp!(
      "priv/jev/recordings/batter--judgeaa01--2024.json",
      Path.join(dir, "batter--judgeaa01--2024.json")
    )

    record = read_real_record(card, dir)
    assert is_binary(record["card_id"])
    assert is_number(record["probability"])
    assert record["probability"] >= 0 and record["probability"] <= 1
    assert record["state_hash"] == SabrJev.Questions.state_hash(card["judgment_state"])

    assert_raise Mix.Error, ~r/historical/, fn ->
      Capture.run(
        [
          "--catalog",
          path,
          "--ledger",
          Path.join(root, "ledger.jsonl"),
          "--baseline",
          Jason.encode!(%{"batter" => 0.4}),
          "--captured-at",
          "2026-06-01T00:00:00Z",
          "--card",
          card["id"]
        ],
        records_dir: dir
      )
    end
  end

  test "a missing recording is refused instead of inventing a prediction", %{root: root} do
    empty = Path.join(root, "empty-recordings")
    File.mkdir_p!(empty)

    assert_raise Mix.Error, ~r/no recorded Jev judgment for batter:example:2026/, fn ->
      Capture.read_record(card(), empty)
    end
  end

  defp read_real_record(card, dir) do
    {:ok, record} = Capture.read_record(card, dir)
    record
  end

  test "capture time is required and never defaulted", %{root: root} do
    first = card("batter:first:2026")
    path = catalog(root, [first])
    ledger = Path.join(root, "ledger.jsonl")

    assert_raise Mix.Error, ~r/--captured-at/, fn ->
      Capture.run(
        ["--catalog", path, "--ledger", ledger, "--baseline", Jason.encode!(%{"batter" => 0.4})],
        catalog_reader: fn _ -> {:ok, [first]} end,
        record_reader: fn _ -> {:ok, record(first["id"])} end
      )
    end

    refute File.exists?(ledger)

    # An explicit production flag works without any harness injection.
    Capture.run(
      [
        "--catalog",
        path,
        "--ledger",
        ledger,
        "--baseline",
        Jason.encode!(%{"batter" => 0.4}),
        "--captured-at",
        "2026-06-01T00:00:00Z"
      ],
      catalog_reader: fn _ -> {:ok, [first]} end,
      record_reader: fn _ -> {:ok, record(first["id"])} end
    )

    assert :ok =
             ledger
             |> File.read!()
             |> String.trim()
             |> String.split("\n")
             |> SabrJev.Prospective.verify()

    refute File.exists?(Path.join(root, "unused.jsonl"))

    # An empty cohort creates no ledger file at all.
    empty = Path.join(root, "empty.jsonl")

    Capture.run(
      ["--catalog", path, "--ledger", empty, "--baseline", Jason.encode!(%{"batter" => 0.4})],
      catalog_reader: fn _ -> {:ok, []} end,
      record_reader: fn _ -> {:ok, record(first["id"])} end,
      captured_at: ~U[2026-06-01 00:00:00Z]
    )

    refute File.exists?(empty)
  end

  test "a capture task refuses to extend a corrupt ledger", %{root: root} do
    path = catalog(root, [card()])
    ledger = Path.join(root, "ledger.jsonl")
    File.write!(ledger, "not json\n")

    assert_raise Mix.Error, ~r/fails verification/, fn ->
      Capture.run(
        ["--catalog", path, "--ledger", ledger, "--baseline", Jason.encode!(%{"batter" => 0.4})],
        catalog_reader: fn _ -> {:ok, [card()]} end,
        record_reader: fn _ -> {:ok, record()} end,
        captured_at: ~U[2026-06-01 00:00:00Z]
      )
    end

    # The corrupt file is left exactly as found, never extended.
    assert File.read!(ledger) == "not json\n"
  end

  test "evaluation refuses a ledger with no capture time or a late capture time" do
    card = %{
      "id" => "batter:a:2026",
      "role" => "batter",
      "year" => 2026,
      "judgment_state" => %{
        "role" => "batter",
        "metrics" => %{},
        "sample" => %{"minimum" => 200, "value" => 400}
      }
    }

    cohort = SabrJev.Prospective.enroll([card], baseline: %{"batter" => 0.4})

    base_record = %{
      "card_id" => "batter:a:2026",
      "state_hash" => SabrJev.Questions.state_hash(card["judgment_state"]),
      "questions_hash" => "sha256:test",
      "model" => "jev-test",
      "probability" => 0.2
    }

    outcomes = %{
      "batter:a:2026" => %{
        "year" => 2027,
        "label" => false,
        "target" => "ops_plus_drop_ge_10_next",
        "provenance" => %{"card_artifact" => "x"}
      }
    }

    # A ledger line that omits captured_at is not scoreable, even though the
    # omitted key was copyable at parse time.
    {:ok, _ledger, line} =
      SabrJev.Prospective.capture(cohort, card, base_record,
        captured_at: ~U[2026-06-01 00:00:00Z]
      )

    entry = line |> Jason.decode!() |> Map.delete("captured_at")

    assert {:error, :invalid_capture_time} =
             SabrJev.Evaluation.score([entry], outcomes, baseline: %{"batter" => 0.5})

    # A capture time after the outcome season is refused even though the chain
    # was valid at capture time, so scoring cannot launder a late capture.
    late_entry = %{
      "card_id" => "batter:a:2026",
      "noul_id" => "ops_plus_drop_ge_10_next",
      "probability" => 0.2,
      "captured_at" => "2027-06-01T00:00:00Z"
    }

    assert {:error, :capture_after_cutoff} =
             SabrJev.Evaluation.score([late_entry], outcomes, baseline: %{"batter" => 0.5})

    # An unparseable capture time is refused.
    assert {:error, :invalid_capture_time} =
             SabrJev.Evaluation.score(
               [Map.put(late_entry, "captured_at", "not a time")],
               outcomes,
               baseline: %{"batter" => 0.5}
             )
  end

  test "tampered ledger lines fail verification", %{root: root} do
    path = catalog(root, [card()])
    ledger = Path.join(root, "ledger.jsonl")

    Capture.run(
      ["--catalog", path, "--ledger", ledger, "--baseline", Jason.encode!(%{"batter" => 0.4})],
      catalog_reader: fn _ -> {:ok, [card()]} end,
      record_reader: fn _ -> {:ok, record()} end,
      captured_at: ~U[2026-06-01 00:00:00Z]
    )

    File.write!(ledger, File.read!(ledger) <> "tampered\n")
    lines = ledger |> File.read!() |> String.trim() |> String.split("\n")
    assert {:error, _} = SabrJev.Prospective.verify(lines)
  end
end
