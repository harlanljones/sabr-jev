defmodule SabrJev.QuestionsTest do
  use ExUnit.Case, async: true

  alias SabrJev.Questions
  alias TypeSafeAPI.Question.{Choice, Noul, Score}

  @batter %{
    "id" => "batter:example:2024",
    "role" => "batter",
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
    "oracle" => %{
      "year" => 2025,
      "metric" => "ops_plus",
      "value" => 110.0,
      "label" => true,
      "target" => "ops_plus_drop_ge_10_next"
    },
    "year" => 2024
  }

  test "freezes exact shared question types and options" do
    assert {:ok, questions} = Questions.for_card(@batter)

    assert %Choice{criteria: season_options} = questions[:season_read]

    assert Enum.map(season_options, &elem(&1, 0)) ==
             [:breakout, :stable, :regression_risk, :small_sample, :other]

    assert %Score{levels: levels} = questions[:confidence_in_signal]
    assert Enum.map(levels, &TypeSafeAPI.Question.Score.label/1) == ["weak", "moderate", "strong"]

    assert %Choice{criteria: profile_options} = questions[:profile]

    assert Enum.map(profile_options, &elem(&1, 0)) ==
             [:power, :discipline, :contact, :balanced, :other]

    assert %Noul{} = questions[:ops_plus_drop_ge_10_next]
  end

  test "uses pitcher profile and Noul while omitting Noul when T+1 does not exist" do
    pitcher = put_in(@batter, ["role"], "pitcher")
    pitcher = put_in(pitcher, ["judgment_state", "role"], "pitcher")

    pitcher =
      put_in(pitcher, ["judgment_state", "metrics"], %{
        "ip" => 180.0,
        "era" => 3.0,
        "fip" => 3.2,
        "k_bb_pct" => 0.2,
        "hr_per_9" => 0.8,
        "bb_per_9" => 2.0,
        "k_per_9" => 10.0,
        "league_cfip" => 4.1
      })

    pitcher = put_in(pitcher, ["judgment_state", "sample", "minimum"], 50)
    pitcher = put_in(pitcher, ["judgment_state", "sample", "value"], 180.0)

    pitcher =
      put_in(pitcher, ["sample"], %{
        "qualified" => true,
        "minimum" => 50,
        "value" => 180.0,
        "unit" => "IP"
      })

    pitcher =
      put_in(pitcher, ["oracle"], %{
        "year" => 2025,
        "metric" => "fip",
        "value" => 4.0,
        "label" => true,
        "target" => "fip_rise_ge_0_50_next"
      })

    assert {:ok, with_oracle} = Questions.for_card(pitcher)

    assert Enum.map(with_oracle[:profile].criteria, &elem(&1, 0)) ==
             [:strikeout, :command, :contact_management, :balanced, :other]

    assert %Noul{} = with_oracle[:fip_rise_ge_0_50_next]

    assert {:ok, without_oracle} = Questions.for_card(%{pitcher | "oracle" => nil})
    refute Keyword.has_key?(without_oracle, :fip_rise_ge_0_50_next)
  end

  test "question and state hashes are deterministic and domain separated" do
    assert {:ok, questions} = Questions.for_card(@batter)
    assert Questions.hash(questions) == Questions.hash(questions)
    assert Questions.hash(questions) =~ ~r/^sha256:[0-9a-f]{64}$/
    assert Questions.state_hash(@batter["judgment_state"]) =~ ~r/^sha256:[0-9a-f]{64}$/
    refute Questions.hash(questions) == Questions.state_hash(@batter["judgment_state"])
  end

  test "rejects role mismatch and any identity, free text, outcome, or nonfinite state" do
    assert {:error, {:invalid_state, _}} =
             Questions.for_card(put_in(@batter, ["judgment_state", "player_name"], "Example"))

    assert {:error, {:invalid_state, _}} =
             Questions.for_card(put_in(@batter, ["judgment_state", "metrics", "ops_plus"], :nan))

    assert {:error, {:role_mismatch, _}} =
             Questions.for_card(put_in(@batter, ["judgment_state", "role"], "pitcher"))
  end

  test "validates the exact role-correct T+1 oracle contract" do
    invalid_oracles = [
      Map.put(@batter["oracle"], "extra", true),
      Map.delete(@batter["oracle"], "label"),
      Map.put(@batter["oracle"], "year", 2026),
      Map.put(@batter["oracle"], "metric", "fip"),
      Map.put(@batter["oracle"], "target", "fip_rise_ge_0_50_next"),
      Map.put(@batter["oracle"], "value", nil),
      Map.put(@batter["oracle"], "value", :nan),
      Map.put(@batter["oracle"], "label", 1)
    ]

    for oracle <- invalid_oracles do
      assert {:error, _} = Questions.for_card(%{@batter | "oracle" => oracle})
    end

    assert {:ok, questions} = Questions.for_card(%{@batter | "oracle" => nil})
    refute Keyword.has_key?(questions, :ops_plus_drop_ge_10_next)
  end

  test "oracle label is derived from the current metric and exact role formula" do
    assert {:error, {:invalid_oracle_marker, _}} =
             Questions.for_card(put_in(@batter, ["oracle", "label"], false))

    unavailable = put_in(@batter, ["judgment_state", "metrics", "ops_plus"], nil)
    assert {:error, {:invalid_oracle_marker, _}} = Questions.for_card(unavailable)

    pitcher =
      @batter
      |> put_in(["role"], "pitcher")
      |> put_in(["judgment_state", "role"], "pitcher")
      |> put_in(["judgment_state", "metrics"], %{
        "ip" => 180.0,
        "era" => 3.0,
        "fip" => 3.6,
        "k_bb_pct" => 0.2,
        "hr_per_9" => 0.8,
        "bb_per_9" => 2.0,
        "k_per_9" => 10.0,
        "league_cfip" => 4.1
      })
      |> put_in(["judgment_state", "sample"], %{"minimum" => 50, "value" => 180.0})
      |> put_in(["sample"], %{
        "qualified" => true,
        "minimum" => 50,
        "value" => 180.0,
        "unit" => "IP"
      })
      |> put_in(["oracle"], %{
        "year" => 2025,
        "metric" => "fip",
        "value" => 4.0,
        "label" => true,
        "target" => "fip_rise_ge_0_50_next"
      })

    assert {:error, {:invalid_oracle_marker, _}} = Questions.for_card(pitcher)
  end

  test "Noul requires a qualified current sample consistent with role and judgment state" do
    invalid_cards = [
      put_in(@batter, ["sample", "qualified"], false),
      put_in(@batter, ["sample", "minimum"], 50),
      put_in(@batter, ["sample", "unit"], "IP"),
      put_in(@batter, ["sample", "value"], 199),
      put_in(@batter, ["judgment_state", "sample", "value"], 399)
    ]

    for card <- invalid_cards do
      assert {:error, _} = Questions.for_card(card)
    end
  end

  # T+1 qualification is guaranteed by pinned ETL oracle creation; the exact oracle
  # card deliberately has no next-season sample field to reconstruct here.
  test "accepts the frozen oracle without inventing a T+1 sample field" do
    assert {:ok, questions} = Questions.for_card(@batter)
    assert Keyword.has_key?(questions, :ops_plus_drop_ge_10_next)
  end

  test "accepts documented unavailable metric and sample nulls without a Noul" do
    card =
      @batter
      |> put_in(["judgment_state", "metrics", "woba"], nil)
      |> put_in(["judgment_state", "metrics", "ops_plus"], nil)
      |> put_in(["judgment_state", "sample", "value"], nil)
      |> put_in(["sample"], %{
        "qualified" => false,
        "minimum" => 200,
        "value" => nil,
        "unit" => "PA"
      })
      |> put_in(["oracle"], nil)

    assert {:ok, questions} = Questions.for_card(card)
    assert Keyword.keys(questions) == [:season_read, :confidence_in_signal, :profile]
  end

  test "noul_id and role_for_noul_id are the single frozen resolution per role" do
    assert Questions.noul_id("batter") == "ops_plus_drop_ge_10_next"
    assert Questions.noul_id("pitcher") == "fip_rise_ge_0_50_next"
    assert Questions.noul_id("unknown") == "ops_plus_drop_ge_10_next"

    assert Questions.role_for_noul_id("ops_plus_drop_ge_10_next") == "batter"
    assert Questions.role_for_noul_id("fip_rise_ge_0_50_next") == "pitcher"
    assert Questions.role_for_noul_id("unknown") == "batter"

    # Round-trip consistency so the capture task, ledger, and scorer can never
    # disagree on which role owns a given Noul target.
    for role <- ["batter", "pitcher"] do
      assert Questions.role_for_noul_id(Questions.noul_id(role)) == role
    end
  end

  test "requires the exact role-specific frozen metric allowlist" do
    assert {:error, {:invalid_state, _}} =
             Questions.for_card(put_in(@batter, ["judgment_state", "metrics", "year"], 2024))

    assert {:error, {:invalid_state, _}} =
             Questions.for_card(
               update_in(@batter, ["judgment_state", "metrics"], &Map.delete(&1, "woba"))
             )

    pitcher =
      @batter
      |> put_in(["role"], "pitcher")
      |> put_in(["year"], 2024)
      |> put_in(["judgment_state", "role"], "pitcher")
      |> put_in(["judgment_state", "metrics"], %{
        "ip" => 180.0,
        "era" => 3.0,
        "fip" => 3.2,
        "k_bb_pct" => 0.2,
        "hr_per_9" => 0.8,
        "bb_per_9" => 2.0,
        "k_per_9" => 10.0,
        "league_cfip" => 4.1
      })
      |> put_in(["judgment_state", "sample"], %{"minimum" => 50, "value" => 180.0})
      |> put_in(["sample"], %{
        "qualified" => true,
        "minimum" => 50,
        "value" => 180.0,
        "unit" => "IP"
      })
      |> put_in(["oracle"], nil)

    assert {:ok, _} = Questions.for_card(pitcher)

    assert {:error, {:invalid_state, _}} =
             Questions.for_card(put_in(pitcher, ["judgment_state", "metrics", "ops_plus"], 100))
  end

  test "prospective mode asks the frozen Noul without a realized T+1" do
    card =
      @batter
      |> put_in(["year"], 2025)
      |> put_in(["id"], "batter:example:2025")
      |> put_in(["oracle"], nil)

    assert {:ok, retrospective} = Questions.for_card(card)
    refute Keyword.has_key?(retrospective, :ops_plus_drop_ge_10_next)

    assert {:ok, prospective} = Questions.for_card(card, mode: :prospective)

    assert Keyword.keys(prospective) ==
             [:season_read, :confidence_in_signal, :profile, :ops_plus_drop_ge_10_next]

    assert %Noul{} = prospective[:ops_plus_drop_ge_10_next]

    # Same judged state, different question set: a prospective prediction must
    # not hash like a retrospective recording of the same card.
    refute Questions.hash(prospective) == Questions.hash(retrospective)

    assert Questions.state_hash(card["judgment_state"]) ==
             Questions.state_hash(@batter["judgment_state"])
  end

  test "prospective mode refuses a card whose T+1 outcome is already realized" do
    assert {:error, {:invalid_prospective_marker, _}} =
             Questions.for_card(@batter, mode: :prospective)
  end

  test "prospective mode still requires an available qualified current signal" do
    card = put_in(@batter, ["oracle"], nil)

    unavailable = put_in(card, ["judgment_state", "metrics", "ops_plus"], nil)

    assert {:error, {:invalid_prospective_marker, _}} =
             Questions.for_card(unavailable, mode: :prospective)

    unqualified =
      card
      |> put_in(["judgment_state", "sample", "value"], nil)
      |> put_in(["sample"], %{
        "qualified" => false,
        "minimum" => 200,
        "value" => nil,
        "unit" => "PA"
      })

    assert {:error, {:invalid_prospective_marker, _}} =
             Questions.for_card(unqualified, mode: :prospective)
  end

  test "an unknown question mode is refused" do
    assert {:error, {:invalid_mode, :prospective_ish}} =
             Questions.for_card(@batter, mode: :prospective_ish)

    assert {:error, {:invalid_card, _}} = Questions.for_card(:not_a_card, mode: :prospective)
  end
end
