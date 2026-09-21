defmodule SabrJev.EvaluationTest do
  use ExUnit.Case, async: true

  alias SabrJev.{Evaluation, Prospective}

  defp entry(card_id, noul_id, probability) do
    %{
      "card_id" => card_id,
      "noul_id" => noul_id,
      "probability" => probability,
      "captured_at" => "2026-06-01T00:00:00Z"
    }
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
      "probability" => 0.2
    }
  end

  test "missing outcomes remain pending and excluded, never negative labels" do
    report =
      Evaluation.score(
        [entry("batter:a:2026", "ops_plus_drop_ge_10_next", 0.2)],
        %{},
        baseline: %{"batter" => 0.4}
      )

    assert report.pending == ["batter:a:2026"]
    assert report.scored == []
    assert report.coverage == %{scored: 0, pending: 1}
  end

  test "outcome year and provenance must match before scoring" do
    entries = [entry("batter:a:2026", "ops_plus_drop_ge_10_next", 0.2)]

    realized = %{
      "batter:a:2026" => %{
        "year" => 2028,
        "label" => true,
        "target" => "ops_plus_drop_ge_10_next",
        "provenance" => %{"card_artifact" => "priv/data/cards.json"}
      }
    }

    assert {:error, :outcome_year_mismatch} =
             Evaluation.score(entries, realized, baseline: %{"batter" => 0.4})

    bad_provenance = %{
      "batter:a:2026" => %{
        "year" => 2027,
        "label" => true,
        "target" => "ops_plus_drop_ge_10_next",
        "provenance" => %{}
      }
    }

    assert {:error, :outcome_provenance_mismatch} =
             Evaluation.score(entries, bad_provenance, baseline: %{"batter" => 0.4})
  end

  test "reports Brier by role with baseline, buckets, coverage and missingness" do
    entries = [
      entry("batter:a:2026", "ops_plus_drop_ge_10_next", 0.2),
      entry("batter:b:2026", "ops_plus_drop_ge_10_next", 0.8),
      entry("pitcher:c:2026", "fip_rise_ge_0_50_next", 0.5)
    ]

    realized = %{
      "batter:a:2026" => %{
        "year" => 2027,
        "label" => false,
        "target" => "ops_plus_drop_ge_10_next",
        "provenance" => %{"card_artifact" => "priv/data/cards.json"}
      },
      "batter:b:2026" => %{
        "year" => 2027,
        "label" => true,
        "target" => "ops_plus_drop_ge_10_next",
        "provenance" => %{"card_artifact" => "priv/data/cards.json"}
      }
    }

    report =
      Evaluation.score(entries, realized, baseline: %{"batter" => 0.5, "pitcher" => 0.5})

    assert report.coverage == %{scored: 2, pending: 1}

    assert report.missingness == %{
             pending: ["pitcher:c:2026"],
             pending_rate: 1 / 3
           }

    assert_in_delta report.by_role["batter"].brier, 0.04, 1.0e-9
    assert_in_delta report.by_role["batter"].baseline_brier, 0.25, 1.0e-9
    assert report.by_role["batter"].n == 2
    assert is_list(report.by_role["batter"].buckets)
    refute Map.has_key?(report.by_role, "pitcher")
  end

  test "outcome target must match the captured Noul before scoring" do
    entries = [entry("batter:a:2026", "ops_plus_drop_ge_10_next", 0.2)]

    wrong_target = %{
      "batter:a:2026" => %{
        "year" => 2027,
        "label" => true,
        "target" => "fip_rise_ge_0_50_next",
        "provenance" => %{"card_artifact" => "priv/data/cards.json"}
      }
    }

    assert {:error, :outcome_target_mismatch} =
             Evaluation.score(entries, wrong_target, baseline: %{"batter" => 0.4})
  end

  test "a frozen baseline is required for every scored role" do
    entries = [entry("batter:a:2026", "ops_plus_drop_ge_10_next", 0.2)]

    realized = %{
      "batter:a:2026" => %{
        "year" => 2027,
        "label" => false,
        "target" => "ops_plus_drop_ge_10_next",
        "provenance" => %{"card_artifact" => "priv/data/cards.json"}
      }
    }

    assert_raise ArgumentError, ~r/baseline for role/, fn ->
      Evaluation.score(entries, realized, baseline: %{"pitcher" => 0.5})
    end
  end

  test "baselines must be frozen before predictions, never fit on outcomes" do
    entries = [entry("batter:a:2026", "ops_plus_drop_ge_10_next", 0.2)]

    assert {:error, :baseline_required} = Evaluation.score(entries, %{}, [])
  end

  test "the enrollable window is derived from the committed frozen pin" do
    catalog = Jason.decode!(File.read!("priv/data/cards.json"))
    manifest = Jason.decode!(File.read!("data/sources.json"))

    # The window is only as trustworthy as the frozen source it claims to follow.
    assert SabrJev.Prospective.latest_frozen_season() == catalog["provenance"]["latest_season"]
    assert SabrJev.Prospective.latest_frozen_season() == manifest["latest_season"]
    assert SabrJev.Prospective.enrollable_year() == catalog["provenance"]["latest_season"] + 1
    assert SabrJev.Prospective.cutoff_iso() == "2027-01-01T00:00:00Z"

    # Cutoffs are derived per cohort year, so a later cohort gets a later cutoff
    # instead of silently reusing a stale constant.
    assert DateTime.compare(
             SabrJev.Prospective.cutoff_for(2027),
             SabrJev.Prospective.cutoff_for(2026)
           ) == :gt
  end

  test "an already-starting outcome season can never enroll" do
    # Any cohort whose outcome season has begun fails on the derived cutoff, so
    # a caller cannot backdate enrollment by supplying an older capture time.
    past = Prospective.cutoff_for(2024)

    assert {:error, :historical_cohort} =
             Prospective.capture(
               Prospective.enroll([card()], baseline: %{"batter" => 0.4}),
               card(),
               record(),
               captured_at: past
             )
  end

  test "retrospective plumbing is rejected for prospective capture" do
    catalog = Jason.decode!(File.read!("priv/data/cards.json"))

    # Every card in the frozen demonstration catalog resolves inside the pinned
    # seasons, so all of them are retrospective plumbing, not prospective.
    refute Enum.any?(catalog["cards"], &(not Prospective.retrospective?(&1["id"])))

    entry = %{
      "id" => "batter:example:2026",
      "role" => "batter",
      "year" => 2026,
      "judgment_state" => %{
        "role" => "batter",
        "metrics" => %{},
        "sample" => %{"minimum" => 200, "value" => 400}
      }
    }

    cohort = Prospective.enroll([entry], baseline: %{"batter" => 0.4})

    assert {:error, :historical_cohort} =
             Prospective.capture(cohort, Map.put(entry, "year", 2025), entry,
               captured_at: ~U[2026-06-01 00:00:00Z]
             )
  end

  test "prospective plumbing uses only historical retrospective labels" do
    assert Prospective.retrospective?("batter:judgeaa01:2024")
    assert Prospective.retrospective?("pitcher:skenepa01:2025")
    refute Prospective.retrospective?("batter:example:2026")
  end
end
