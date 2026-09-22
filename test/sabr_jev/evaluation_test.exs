defmodule SabrJev.EvaluationTest do
  use ExUnit.Case, async: true

  alias SabrJev.{Evaluation, Prospective}

  # Entries describe the enrollable cohort: a judged season whose T+1 is not yet
  # in the pins. The capture time is explicit so nothing here reads the clock.
  @outcome_year 2026
  @inside_window "2025-06-01T00:00:00Z"

  defp entry(card_id, noul_id, probability) do
    %{
      "card_id" => card_id,
      "noul_id" => noul_id,
      "probability" => probability,
      "mode" => "prospective",
      "captured_at" => @inside_window
    }
  end

  defp realized(label, overrides \\ %{}) do
    Map.merge(
      %{
        "year" => @outcome_year,
        "label" => label,
        "target" => "ops_plus_drop_ge_10_next",
        "provenance" => %{"card_artifact" => "priv/data/cards.json"}
      },
      overrides
    )
  end

  defp card(id \\ "batter:retro:2024") do
    %{
      "id" => id,
      "role" => "batter",
      "year" => 2024,
      "judgment_state" => %{
        "role" => "batter",
        "metrics" => %{"pa" => 400},
        "sample" => %{"minimum" => 200, "value" => 400}
      }
    }
  end

  defp record do
    %{
      "card_id" => "batter:retro:2024",
      "state_hash" => SabrJev.Questions.state_hash(card()["judgment_state"]),
      "questions_hash" => "sha256:test",
      "model" => "jev-test",
      "mode" => "prospective",
      "probability" => 0.2
    }
  end

  test "missing outcomes remain pending and excluded, never negative labels" do
    report =
      Evaluation.score(
        [entry("batter:a:2025", "ops_plus_drop_ge_10_next", 0.2)],
        %{},
        baseline: %{"batter" => 0.4}
      )

    assert report.pending == ["batter:a:2025"]
    assert report.scored == []
    assert report.coverage == %{scored: 0, pending: 1}
  end

  test "a line without a prospective mode is never scored" do
    # A retrospective line would score a judgment taken with the outcome already
    # known, so the mode gate sits ahead of every other scoring check.
    for mode <- [nil, "retrospective", "sometimes"] do
      entry = entry("batter:a:2025", "ops_plus_drop_ge_10_next", 0.2)
      entry = if is_nil(mode), do: Map.delete(entry, "mode"), else: Map.put(entry, "mode", mode)

      assert {:error, :not_prospective_ledger_line} =
               Evaluation.score([entry], %{"batter:a:2025" => realized(false)},
                 baseline: %{"batter" => 0.4}
               )
    end
  end

  test "outcome year and provenance must match before scoring" do
    entries = [entry("batter:a:2025", "ops_plus_drop_ge_10_next", 0.2)]

    # T+1 for a 2025 card is 2026, never 2028.
    assert {:error, :outcome_year_mismatch} =
             Evaluation.score(
               entries,
               %{"batter:a:2025" => realized(true, %{"year" => 2028})},
               baseline: %{"batter" => 0.4}
             )

    assert {:error, :outcome_provenance_mismatch} =
             Evaluation.score(
               entries,
               %{"batter:a:2025" => realized(true, %{"provenance" => %{}})},
               baseline: %{"batter" => 0.4}
             )
  end

  test "reports Brier by role with baseline, buckets, coverage and missingness" do
    entries = [
      entry("batter:a:2025", "ops_plus_drop_ge_10_next", 0.2),
      entry("batter:b:2025", "ops_plus_drop_ge_10_next", 0.8),
      entry("pitcher:c:2025", "fip_rise_ge_0_50_next", 0.5)
    ]

    realized_map = %{
      "batter:a:2025" => realized(false),
      "batter:b:2025" => realized(true)
    }

    report =
      Evaluation.score(entries, realized_map, baseline: %{"batter" => 0.5, "pitcher" => 0.5})

    assert report.coverage == %{scored: 2, pending: 1}

    assert report.missingness == %{
             pending: ["pitcher:c:2025"],
             pending_rate: 1 / 3
           }

    assert_in_delta report.by_role["batter"].brier, 0.04, 1.0e-9
    assert_in_delta report.by_role["batter"].baseline_brier, 0.25, 1.0e-9
    assert report.by_role["batter"].n == 2
    assert is_list(report.by_role["batter"].buckets)
    refute Map.has_key?(report.by_role, "pitcher")
  end

  test "outcome target must match the captured Noul before scoring" do
    entries = [entry("batter:a:2025", "ops_plus_drop_ge_10_next", 0.2)]

    assert {:error, :outcome_target_mismatch} =
             Evaluation.score(
               entries,
               %{"batter:a:2025" => realized(true, %{"target" => "fip_rise_ge_0_50_next"})},
               baseline: %{"batter" => 0.4}
             )
  end

  test "a frozen baseline is required for every scored role" do
    entries = [entry("batter:a:2025", "ops_plus_drop_ge_10_next", 0.2)]

    assert_raise ArgumentError, ~r/baseline for role/, fn ->
      Evaluation.score(entries, %{"batter:a:2025" => realized(false)},
        baseline: %{"pitcher" => 0.5}
      )
    end
  end

  test "baselines must be frozen before predictions, never fit on outcomes" do
    entries = [entry("batter:a:2025", "ops_plus_drop_ge_10_next", 0.2)]

    assert {:error, :baseline_required} = Evaluation.score(entries, %{}, [])
  end

  test "the enrollable window is derived from the committed frozen pin" do
    catalog = Jason.decode!(File.read!("priv/data/cards.json"))
    manifest = Jason.decode!(File.read!("data/sources.json"))
    latest = SabrJev.Prospective.latest_frozen_season()

    # The window is only as trustworthy as the frozen source it claims to follow.
    assert latest == catalog["provenance"]["latest_season"]
    assert latest == manifest["latest_season"]

    # The cohort is the newest season in the pins, not the season after it: a
    # cohort of latest + 1 would ask for a card from a season that has no source,
    # so no capture could ever succeed.
    assert SabrJev.Prospective.enrollable_year() == latest
    assert SabrJev.Prospective.outcome_year() == latest + 1
    assert SabrJev.Prospective.cutoff_iso() == "2026-01-01T00:00:00Z"

    # Cutoffs are derived per cohort year, so a later cohort gets a later cutoff
    # instead of silently reusing a stale constant.
    assert DateTime.compare(
             SabrJev.Prospective.cutoff_for(2026),
             SabrJev.Prospective.cutoff_for(2025)
           ) == :gt
  end

  test "the cohort window is a pure function of an as-of instant" do
    assert SabrJev.Prospective.window_open?(~U[2025-06-01 00:00:00Z])
    assert SabrJev.Prospective.window_open?(~U[2025-12-31 23:59:59Z])
    refute SabrJev.Prospective.window_open?(SabrJev.Prospective.cutoff())
    refute SabrJev.Prospective.window_open?(~U[2026-09-22 00:00:00Z])
  end

  test "the enrollable cohort is the one season that is not retrospective" do
    catalog = Jason.decode!(File.read!("priv/data/cards.json"))
    latest = SabrJev.Prospective.latest_frozen_season()

    # A join is retrospective only when both seasons are in the pins, so the
    # newest pinned season is not: it is the cohort itself.
    assert Enum.all?(catalog["cards"], fn card ->
             Prospective.retrospective?(card["id"]) == card["year"] + 1 <= latest
           end)

    assert Enum.any?(catalog["cards"], &Prospective.retrospective?(&1["id"]))

    refute Enum.any?(
             catalog["cards"],
             &(&1["year"] == latest and Prospective.retrospective?(&1["id"]))
           )
  end

  test "an already-resolved or unrecorded season can never enroll" do
    # A season whose T+1 is already in the pins is historical, whether it is the
    # most recent judged season (2024) or one with no card at all (2026).
    for id <- ["batter:retro:2024", "batter:example:2026"] do
      entry = Map.put(card(id), "year", String.to_integer(String.slice(id, -4, 4)))

      assert {:error, :historical_cohort} =
               Prospective.capture(
                 Prospective.enroll([entry], baseline: %{"batter" => 0.4}),
                 entry,
                 Map.put(record(), "card_id", id),
                 captured_at: ~U[2025-06-01 00:00:00Z]
               )
    end

    # A caller cannot backdate enrollment by supplying an older capture time
    # either: the cohort year gate fires before the capture time is read.
    assert {:error, :historical_cohort} =
             Prospective.capture(
               Prospective.enroll([card()], baseline: %{"batter" => 0.4}),
               card(),
               record(),
               captured_at: Prospective.cutoff_for(2024)
             )

    # And the enrollable season itself is refused once its window has closed.
    enrollable = Map.put(card("batter:example:2025"), "year", 2025)

    assert {:error, :window_closed} =
             Prospective.capture(
               Prospective.enroll([enrollable], baseline: %{"batter" => 0.4}),
               enrollable,
               Map.put(record(), "card_id", "batter:example:2025"),
               captured_at: SabrJev.Prospective.cutoff()
             )
  end

  test "prospective plumbing uses only historical retrospective labels" do
    assert Prospective.retrospective?("batter:judgeaa01:2024")
    assert Prospective.retrospective?("pitcher:skenepa01:2024")
    refute Prospective.retrospective?("pitcher:skenepa01:2025")
    refute Prospective.retrospective?("batter:example:2026")
  end
end
