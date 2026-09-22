defmodule SabrJev.CaptureTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Sabr.Capture

  @inside_window ~U[2025-06-01 00:00:00Z]
  @after_cutoff ~U[2026-06-01 00:00:00Z]
  @today ~U[2026-09-22 00:00:00Z]

  setup do
    root = Path.join(System.tmp_dir!(), "sabr-capture-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp card(id \\ "batter:example:2025") do
    %{
      "id" => id,
      "role" => "batter",
      "player_id" => String.split(id, ":") |> Enum.at(1, "example"),
      "year" => 2025,
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

  defp record(id \\ "batter:example:2025") do
    %{
      "schema_version" => 1,
      "card_id" => id,
      "state_hash" => SabrJev.Questions.state_hash(card(id)["judgment_state"]),
      "questions_hash" => "sha256:test",
      "model" => "jev-test",
      "mode" => "prospective",
      "recorded_at" => "2025-05-18T00:00:00Z",
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

  # The state hash must come from the card actually being captured, not from the
  # synthetic fixture: the real catalog's judgment states differ per player.
  defp record_for(card) do
    record(card["id"])
    |> Map.put("state_hash", SabrJev.Questions.state_hash(card["judgment_state"]))
  end

  test "appends chained lines across runs and rejects intra-batch duplicates", %{root: root} do
    first = card("batter:first:2025")
    second = card("batter:second:2025")
    path = catalog(root, [first, second])
    ledger = Path.join(root, "ledger.jsonl")
    baseline = Jason.encode!(%{"batter" => 0.4})

    Capture.run(["--catalog", path, "--ledger", ledger, "--baseline", baseline],
      catalog_reader: fn _ -> {:ok, [first, second]} end,
      record_reader: fn card -> {:ok, record(card["id"])} end,
      captured_at: @inside_window
    )

    lines = ledger |> File.read!() |> String.trim() |> String.split("\n")
    assert length(lines) == 2
    assert :ok = SabrJev.Prospective.verify(lines)
    assert Enum.all?(lines, &(Jason.decode!(&1)["mode"] == "prospective"))

    assert_raise Mix.Error, ~r/duplicate/, fn ->
      Capture.run(
        ["--catalog", path, "--ledger", ledger, "--baseline", baseline, "--card", first["id"]],
        catalog_reader: fn _ -> {:ok, [first]} end,
        record_reader: fn _ -> {:ok, record(first["id"])} end,
        captured_at: @inside_window
      )
    end

    assert_raise Mix.Error, ~r/duplicate/, fn ->
      Capture.run(["--catalog", path, "--ledger", ledger, "--baseline", baseline],
        catalog_reader: fn _ -> {:ok, [first, first]} end,
        record_reader: fn _ -> {:ok, record(first["id"])} end,
        captured_at: @inside_window
      )
    end

    assert length(ledger |> File.read!() |> String.trim() |> String.split("\n")) == 2
  end

  test "refuses historical enrollment and a closed cohort window", %{root: root} do
    historic = %{card() | "id" => "batter:old:2024", "year" => 2024}
    path = catalog(root, [historic])
    ledger = Path.join(root, "ledger.jsonl")
    baseline = Jason.encode!(%{"batter" => 0.4})

    assert_raise Mix.Error, ~r/historical/, fn ->
      Capture.run(
        ["--catalog", path, "--ledger", ledger, "--baseline", baseline],
        catalog_reader: fn _ -> {:ok, [historic]} end,
        record_reader: fn _ -> {:ok, record("batter:old:2024")} end,
        captured_at: @inside_window
      )
    end

    # The enrollable season is enrollable only before its own cutoff: a capture
    # after January 1 of the outcome season is refused outright.
    assert_raise Mix.Error, ~r/window_closed/, fn ->
      Capture.run(
        ["--catalog", path, "--ledger", ledger, "--baseline", baseline],
        catalog_reader: fn _ -> {:ok, [card()]} end,
        record_reader: fn _ -> {:ok, record()} end,
        captured_at: @after_cutoff
      )
    end

    refute File.exists?(ledger)
  end

  test "the production reader refuses a retrospective recording for a prospective cohort", %{
    root: root
  } do
    dir = Path.join(root, "prospective")
    File.mkdir_p!(dir)

    File.cp!(
      "priv/jev/recordings/batter--judgeaa01--2024.json",
      Path.join(dir, "batter--judgeaa01--2024.json")
    )

    catalog = Jason.decode!(File.read!("priv/data/cards.json"))
    judged = Enum.find(catalog["cards"], &(&1["id"] == "batter:judgeaa01:2024"))

    assert_raise Mix.Error, ~r/prospective/, fn -> Capture.read_record(judged, dir) end
  end

  test "the production reader takes the probability from a prospective recording", %{root: root} do
    dir = Path.join(root, "prospective")
    File.mkdir_p!(dir)

    # Synthetic prospective artifact, explicitly distinguished from a recorded
    # response: only the Noul probability and the mode matter to the reader.
    # SabrJev.Judgments.validate_record owns deep record validation.
    prospective = %{
      "schema_version" => 1,
      "card_id" => "batter:example:2025",
      "state_hash" => SabrJev.Questions.state_hash(card()["judgment_state"]),
      "questions_hash" => "sha256:synthetic",
      "model" => "jev-test",
      "mode" => "prospective",
      "recorded_at" => "2025-05-18T00:00:00Z",
      "response" => %{"model" => "jev-test"},
      "answers" => %{
        "ops_plus_drop_ge_10_next" => %{"type" => "noul", "noul" => 0.31, "confidence" => 0.9}
      },
      "source_lineage" => %{"card_artifact" => "test"}
    }

    File.write!(Path.join(dir, "batter--example--2025.json"), Jason.encode!(prospective))

    assert {:ok, read} = Capture.read_record(card(), dir)
    assert read["probability"] == 0.31
    assert read["mode"] == "prospective"
  end

  test "the real catalog has no open cohort today, and says so per card", %{root: root} do
    # The offline suite must never depend on the wall clock, so the as-of
    # instant is explicit. Every card in the frozen catalog is either historical
    # (its T+1 is already in the pins) or belongs to a cohort whose window has
    # closed. Reverting the cohort to latest_frozen_season + 1 makes every card
    # historical and this assertion fails.
    catalog = Jason.decode!(File.read!("priv/data/cards.json"))
    cohort = SabrJev.Prospective.enroll(catalog["cards"], baseline: %{"batter" => 0.5})

    closed =
      Enum.filter(catalog["cards"], fn card ->
        SabrJev.Prospective.capture(cohort, card, record_for(card), captured_at: @today) ==
          {:error, :window_closed}
      end)

    assert closed != [], "the enrollable cohort must be a season that has cards"

    assert Enum.map(closed, & &1["year"]) |> Enum.uniq() ==
             [SabrJev.Prospective.enrollable_year()]

    historical = catalog["cards"] -- closed

    assert Enum.all?(historical, fn card ->
             SabrJev.Prospective.capture(cohort, card, record_for(card), captured_at: @today) ==
               {:error, :historical_cohort}
           end)

    # And the same cohort succeeds as-of a timestamp inside its window.
    assert {:ok, _ledger, _line} =
             SabrJev.Prospective.capture(
               cohort,
               hd(closed),
               record_for(hd(closed)),
               captured_at: @inside_window
             )

    _ = root
  end

  test "a missing recording is refused instead of inventing a prediction", %{root: root} do
    empty = Path.join(root, "empty-recordings")
    File.mkdir_p!(empty)

    assert_raise Mix.Error, ~r/no recorded Jev judgment for batter:example:2025/, fn ->
      Capture.read_record(card(), empty)
    end
  end

  test "capture time is required and never defaulted", %{root: root} do
    first = card("batter:first:2025")
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
        "2025-06-01T00:00:00Z"
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
      captured_at: @inside_window
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
        captured_at: @inside_window
      )
    end

    # The corrupt file is left exactly as found, never extended.
    assert File.read!(ledger) == "not json\n"
  end

  test "evaluation refuses a ledger with no capture time or a late capture time" do
    card = %{
      "id" => "batter:a:2025",
      "role" => "batter",
      "year" => 2025,
      "judgment_state" => %{
        "role" => "batter",
        "metrics" => %{},
        "sample" => %{"minimum" => 200, "value" => 400}
      }
    }

    cohort = SabrJev.Prospective.enroll([card], baseline: %{"batter" => 0.4})

    base_record = %{
      "card_id" => "batter:a:2025",
      "state_hash" => SabrJev.Questions.state_hash(card["judgment_state"]),
      "questions_hash" => "sha256:test",
      "model" => "jev-test",
      "mode" => "prospective",
      "probability" => 0.2
    }

    outcomes = %{
      "batter:a:2025" => %{
        "year" => 2026,
        "label" => false,
        "target" => "ops_plus_drop_ge_10_next",
        "provenance" => %{"card_artifact" => "x"}
      }
    }

    # A ledger line that omits captured_at is not scoreable, even though the
    # omitted key was copyable at parse time.
    {:ok, _ledger, line} =
      SabrJev.Prospective.capture(cohort, card, base_record, captured_at: @inside_window)

    entry = line |> Jason.decode!() |> Map.delete("captured_at")
    mode = Map.take(Jason.decode!(line), ["mode"])

    assert {:error, :invalid_capture_time} =
             SabrJev.Evaluation.score([entry], outcomes, baseline: %{"batter" => 0.5})

    # A capture time after the outcome season is refused even though the chain
    # was valid at capture time, so scoring cannot launder a late capture.
    late_entry =
      Map.merge(mode, %{
        "card_id" => "batter:a:2025",
        "noul_id" => "ops_plus_drop_ge_10_next",
        "probability" => 0.2,
        "captured_at" => "2026-06-01T00:00:00Z"
      })

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
      captured_at: @inside_window
    )

    File.write!(ledger, File.read!(ledger) <> "tampered\n")
    lines = ledger |> File.read!() |> String.trim() |> String.split("\n")
    assert {:error, _} = SabrJev.Prospective.verify(lines)
  end
end
