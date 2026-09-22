defmodule SabrJev.ProspectiveTest do
  use ExUnit.Case, async: true

  alias SabrJev.Prospective

  # The cohort is the newest season in the frozen pins, so its window closed on
  # January 1 of the following season. Every capture time below is therefore in
  # the past, which the library accepts: it never consults the wall clock.
  @cutoff ~U[2026-01-01 00:00:00Z]
  @inside_window ~U[2025-06-01 00:00:00Z]
  @after_cutoff ~U[2026-06-01 00:00:00Z]

  defp card(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "batter:example:2025",
        "role" => "batter",
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
        "sample" => %{
          "qualified" => true,
          "minimum" => 200,
          "value" => 400,
          "unit" => "PA"
        },
        "oracle" => nil
      },
      overrides
    )
  end

  defp record(overrides \\ %{}) do
    state_hash = SabrJev.Questions.state_hash(card()["judgment_state"])

    Map.merge(
      %{
        "schema_version" => 1,
        "card_id" => "batter:example:2025",
        "state_hash" => state_hash,
        "questions_hash" => "sha256:def",
        "model" => "jev-latest",
        "mode" => "prospective",
        "recorded_at" => "2025-05-18T12:00:00Z",
        "response" => %{"model" => "jev-latest"},
        "answers" => %{"season_read" => %{"type" => "choice"}},
        "source_lineage" => %{"card_artifact" => "priv/data/cards.json"}
      },
      overrides
    )
  end

  defp entry_record(id, probability \\ 0.2) do
    entry_card = card(%{"id" => id})

    record(%{
      "card_id" => id,
      "state_hash" => SabrJev.Questions.state_hash(entry_card["judgment_state"]),
      "probability" => probability
    })
  end

  test "the enrollable cohort is the newest season in the frozen pins" do
    # Regression: the cohort used to be latest_frozen_season + 1, a season that
    # cannot have a card until the ETL pins the source that makes it historical.
    assert Prospective.enrollable_year() == Prospective.latest_frozen_season()
    assert Prospective.outcome_year() == Prospective.latest_frozen_season() + 1
    assert Prospective.cutoff() == @cutoff
    assert Prospective.cutoff_iso() == "2026-01-01T00:00:00Z"
  end

  test "enrollment freezes cohort and baseline before capture" do
    cohort = Prospective.enroll([card()], baseline: %{"batter" => 0.4})

    assert cohort.cohort == ["batter:example:2025"]
    assert cohort.baseline == %{"batter" => 0.4}
    assert cohort.year == 2025
    assert cohort.cutoff == @cutoff
    assert cohort.note =~ "2024"
    assert cohort.note =~ "2026-01-01T00:00:00Z"
  end

  test "window_open?/1 is derived from the cohort cutoff, not the clock" do
    assert Prospective.window_open?(@inside_window)
    refute Prospective.window_open?(@cutoff)
    refute Prospective.window_open?(@after_cutoff)
  end

  test "retrospective?/1 is true only when the T+1 season is in the pins" do
    assert Prospective.retrospective?("batter:judgeaa01:2024")
    refute Prospective.retrospective?("batter:judgeaa01:2025")
    refute Prospective.retrospective?("batter:example:2026")
    refute Prospective.retrospective?("not-a-card-id")
  end

  test "capture refuses cards from any other season as historical" do
    for year <- [2024, 2026] do
      historical = card(%{"id" => "batter:example:#{year}", "year" => year})
      cohort = Prospective.enroll([historical], baseline: %{"batter" => 0.4})

      assert {:error, :historical_cohort} =
               Prospective.capture(cohort, historical, entry_record(historical["id"]),
                 captured_at: @inside_window
               )
    end
  end

  test "capture refuses a closed cohort window" do
    cohort = Prospective.enroll([card()], baseline: %{"batter" => 0.4})
    entry = entry_record("batter:example:2025")

    for at <- [@cutoff, @after_cutoff] do
      assert {:error, :window_closed} =
               Prospective.capture(cohort, card(), entry, captured_at: at)
    end
  end

  test "capture refuses a recording that is not explicitly prospective" do
    cohort = Prospective.enroll([card()], baseline: %{"batter" => 0.4})

    # A missing mode is treated as retrospective and fails closed, so a
    # retrospective recording can never be captured as a prospective prediction.
    assert {:error, {:record_field_required, "mode"}} =
             Prospective.capture(cohort, card(), Map.delete(record(), "mode"),
               captured_at: @inside_window
             )

    for mode <- ["retrospective", "prospective-ish", nil, 1] do
      assert {:error, :not_prospective_recording} =
               Prospective.capture(cohort, card(), Map.put(record(), "mode", mode),
                 captured_at: @inside_window
               )
    end
  end

  test "capture rejects duplicates and mismatched state without clock override" do
    entry_card = card()
    cohort = Prospective.enroll([entry_card], baseline: %{"batter" => 0.4})
    entry = entry_record("batter:example:2025")

    assert {:ok, ledger, line} =
             Prospective.capture(cohort, entry_card, entry, captured_at: @inside_window)

    assert Jason.decode!(line)["mode"] == "prospective"

    assert {:error, :duplicate_capture} =
             Prospective.capture(cohort, entry_card, entry,
               captured_at: @inside_window,
               ledger: ledger
             )

    # A ledger that fails verification is never extended, so tampering cannot be
    # laundered into a longer valid chain.
    assert {:error, :ledger_tampered} =
             Prospective.capture(cohort, entry_card, entry,
               captured_at: @inside_window,
               ledger: ledger ++ [List.last(ledger)]
             )

    tampered = put_in(entry_card, ["judgment_state", "metrics", "ops_plus"], 1.0)

    assert {:error, :state_hash_mismatch} =
             Prospective.capture(cohort, tampered, entry, captured_at: @inside_window)

    assert {:error, :capture_time_required} = Prospective.capture(cohort, entry_card, entry, [])
  end

  test "capture requires a complete record rather than inventing fields" do
    entry_card = card()
    cohort = Prospective.enroll([entry_card], baseline: %{"batter" => 0.4})
    entry = entry_record("batter:example:2025")
    at = @inside_window

    for field <- ["state_hash", "questions_hash", "model", "probability"] do
      assert {:error, {:record_field_required, ^field}} =
               Prospective.capture(cohort, entry_card, Map.delete(entry, field), captured_at: at)
    end

    assert {:error, :probability_out_of_range} =
             Prospective.capture(cohort, entry_card, Map.put(entry, "probability", 7.5),
               captured_at: at
             )

    assert {:error, :record_card_mismatch} =
             Prospective.capture(
               cohort,
               entry_card,
               Map.put(entry, "card_id", "batter:other:2025"),
               captured_at: at
             )
  end

  test "ledger is append-only and hash verified" do
    first = card(%{"id" => "batter:first:2025"})
    second = card(%{"id" => "batter:second:2025"})

    cohort = Prospective.enroll([first, second], baseline: %{"batter" => 0.4})

    assert {:ok, ledger, _first_line} =
             Prospective.capture(cohort, first, entry_record("batter:first:2025"),
               captured_at: @inside_window
             )

    assert {:ok, ledger, _second_line} =
             Prospective.capture(
               cohort,
               second,
               entry_record("batter:second:2025"),
               captured_at: @inside_window,
               ledger: ledger
             )

    assert :ok = Prospective.verify(ledger)
    assert {:error, _} = Prospective.verify(tl(ledger))
    assert {:error, _} = Prospective.verify([Jason.encode!(%{"tampered" => true})])
  end
end
