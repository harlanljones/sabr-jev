defmodule SabrJev.LatchTest do
  use ExUnit.Case, async: true

  alias SabrJev.Latch

  @batter_card %{
    "id" => "batter:example:2024",
    "role" => "batter",
    "year" => 2024,
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

  test "routes only exact frozen serialized answer contracts" do
    answers = batter_answers()
    assert {:ok, %{route: :act}} = Latch.route(answers, @batter_card)

    nonmax_choice =
      answers
      |> put_in(["season_read", "choice"], "breakout")
      |> put_in(
        ["season_read", "description"],
        "The supplied metrics jointly support an unusually strong positive season read."
      )

    inconsistent_score_level =
      answers
      |> put_in(["confidence_in_signal", "level"], 1)
      |> put_in(["confidence_in_signal", "label"], "moderate")
      |> put_in(
        ["confidence_in_signal", "description"],
        "The metrics provide a meaningful but not decisive signal."
      )

    mutations = [
      put_in(answers, ["season_read", "choice"], "invented"),
      nonmax_choice,
      put_in(answers, ["season_read", "probabilities"], %{"stable" => 1.0}),
      put_in(answers, ["season_read", "options", Access.at(0), "probability"], 0.5),
      Map.put(answers["season_read"], "extra", true)
      |> then(&Map.put(answers, "season_read", &1)),
      put_in(answers, ["profile", "choice"], "strikeout"),
      put_in(answers, ["confidence_in_signal", "label"], "weak"),
      inconsistent_score_level,
      put_in(answers, ["confidence_in_signal", "score"], 1.0),
      put_in(answers, ["confidence_in_signal", "score"], 3.0),
      put_in(answers, ["confidence_in_signal", "legend", "0", "label"], "invented"),
      put_in(answers, ["confidence_in_signal", "probabilities", "0"], :nan)
    ]

    for changed <- mutations do
      assert {:error, _} = Latch.route(changed, @batter_card)
    end
  end

  test "uses role-specific IDs and profile choices even without a Noul" do
    pitcher = pitcher_card()
    answers = pitcher_answers()

    assert {:ok, %{route: :act}} = Latch.route(answers, pitcher)
    assert {:error, _} = Latch.route(batter_answers(), pitcher)
    assert {:error, _} = Latch.route(put_in(answers, ["profile", "choice"], "power"), pitcher)

    wrong_noul = Map.put(answers, "ops_plus_drop_ge_10_next", noul_answer(0.1))
    assert {:error, _} = Latch.route(wrong_noul, pitcher)
  end

  test "Noul uses max probability confidence and can review but never escalate" do
    card =
      put_in(@batter_card, ["oracle"], %{
        "year" => 2025,
        "metric" => "ops_plus",
        "value" => 110.0,
        "label" => true,
        "target" => "ops_plus_drop_ge_10_next"
      })

    act_answers = Map.put(batter_answers(), "ops_plus_drop_ge_10_next", noul_answer(0.15))
    assert {:ok, act} = Latch.route(act_answers, card)
    assert act.route == :act
    assert act.answer_routes["ops_plus_drop_ge_10_next"] == :act

    review_answers = Map.put(batter_answers(), "ops_plus_drop_ge_10_next", noul_answer(0.5))
    assert {:ok, review} = Latch.route(review_answers, card)
    assert review.route == :review
    assert review.answer_routes["ops_plus_drop_ge_10_next"] == :review

    assert {:error, _} =
             Latch.route(
               put_in(act_answers, ["ops_plus_drop_ge_10_next", "confidence"], 0.15),
               card
             )
  end

  test "validates full role sample contract and state consistency before routing" do
    answers = batter_answers()

    invalid_cards = [
      put_in(@batter_card, ["sample", "qualified"], false),
      put_in(@batter_card, ["sample", "minimum"], 50),
      put_in(@batter_card, ["sample", "unit"], "IP"),
      put_in(@batter_card, ["sample", "value"], nil),
      put_in(@batter_card, ["sample", "value"], -1),
      put_in(@batter_card, ["sample", "value"], :nan),
      put_in(@batter_card, ["sample", "extra"], true),
      put_in(@batter_card, ["judgment_state", "sample", "value"], 399)
    ]

    for card <- invalid_cards do
      assert {:error, _} = Latch.route(answers, card)
    end

    underqualified =
      @batter_card
      |> put_in(["sample"], %{
        "qualified" => false,
        "minimum" => 200,
        "value" => 199,
        "unit" => "PA"
      })
      |> put_in(["judgment_state", "sample", "value"], 199)

    assert {:ok, decision} = Latch.route(answers, underqualified)
    assert decision.route == :review
    assert decision.reasons == [:underqualified_sample]
  end

  test "all thirty immutable real recordings validate and route with their full cards" do
    catalog = Jason.decode!(File.read!("priv/data/cards.json"))
    cards = Map.new(catalog["cards"], &{&1["id"], &1})
    paths = Path.wildcard("priv/jev/recordings/*.json")
    assert length(paths) == 30

    for path <- paths do
      record = Jason.decode!(File.read!(path))
      card = cards[record["card_id"]]
      assert {:ok, _decision} = Latch.route(record["answers"], card)
    end
  end

  defp batter_answers do
    %{
      "season_read" => choice_answer("stable", season_options(), 1.0),
      "confidence_in_signal" => score_answer(1.0),
      "profile" => choice_answer("balanced", batter_profile_options(), 1.0)
    }
  end

  defp pitcher_answers do
    %{
      "season_read" => choice_answer("stable", season_options(), 1.0),
      "confidence_in_signal" => score_answer(1.0),
      "profile" => choice_answer("balanced", pitcher_profile_options(), 1.0)
    }
  end

  defp choice_answer(choice, options, confidence) do
    probabilities =
      Map.new(options, fn {option, _description} ->
        {option, if(option == choice, do: 1.0, else: 0.0)}
      end)

    descriptions = Map.new(options)

    %{
      "type" => "choice",
      "choice" => choice,
      "description" => descriptions[choice],
      "confidence" => confidence,
      "probabilities" => probabilities,
      "options" =>
        Enum.map(options, fn {option, _} ->
          %{"option" => option, "probability" => probabilities[option]}
        end)
    }
  end

  defp score_answer(confidence) do
    levels = [
      {"weak", "The metrics provide weak or conflicting interpretive evidence."},
      {"moderate", "The metrics provide a meaningful but not decisive signal."},
      {"strong", "The metrics provide a strong and coherent signal."}
    ]

    probabilities = %{"0" => 0.0, "1" => 0.0, "2" => 1.0}

    %{
      "type" => "score",
      "score" => 2.0,
      "level" => 2,
      "label" => "strong",
      "description" => elem(Enum.at(levels, 2), 1),
      "confidence" => confidence,
      "probabilities" => probabilities,
      "levels" =>
        Enum.with_index(levels, fn {label, _}, index ->
          %{"label" => label, "probability" => probabilities[to_string(index)]}
        end),
      "legend" =>
        Enum.with_index(levels)
        |> Map.new(fn {{label, description}, index} ->
          {to_string(index), %{"label" => label, "description" => description}}
        end)
    }
  end

  defp noul_answer(probability) do
    %{
      "type" => "noul",
      "noul" => probability,
      "confidence" => max(probability, 1.0 - probability)
    }
  end

  defp season_options do
    [
      {"breakout",
       "The supplied metrics jointly support an unusually strong positive season read."},
      {"stable", "The supplied metrics support a sustainable, broadly stable season read."},
      {"regression_risk", "The supplied metrics contain a meaningful regression-risk signal."},
      {"small_sample", "The supplied sample is too small for a firm season read."},
      {"other", "None of the listed readings is supported."}
    ]
  end

  defp batter_profile_options do
    [
      {"power", "Power production is the clearest feature."},
      {"discipline", "Plate discipline is the clearest feature."},
      {"contact", "Contact quality or contact frequency is the clearest feature."},
      {"balanced", "No single tool dominates; the profile is balanced."},
      {"other", "None of the listed profiles is supported."}
    ]
  end

  defp pitcher_profile_options do
    [
      {"strikeout", "Strikeout ability is the clearest feature."},
      {"command", "Walk suppression or command is the clearest feature."},
      {"contact_management", "Home-run or contact management is the clearest feature."},
      {"balanced", "No single skill dominates; the profile is balanced."},
      {"other", "None of the listed profiles is supported."}
    ]
  end

  defp pitcher_card do
    @batter_card
    |> put_in(["id"], "pitcher:example:2024")
    |> put_in(["role"], "pitcher")
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
  end
end
