defmodule SabrJev.JudgmentsTest do
  use ExUnit.Case, async: true

  alias SabrJev.{Judgments, Questions}
  alias TypeSafeAPI.Answer.{Choice, Noul, Score}

  @card %{
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

  setup context do
    TypeSafeAPI.Test.typesafe_stubs(context)
  end

  test "batches every applicable typed question in one request and preserves distributions" do
    client =
      TypeSafeAPI.Test.client()
      |> TypeSafeAPI.Test.stub(
        season_read: {:choice, :stable, 0.82},
        confidence_in_signal: {:score, 2, 0.75},
        profile: {:choice, :balanced, 0.72},
        ops_plus_drop_ge_10_next: {:noul, 0.2}
      )

    assert {:ok, record} = Judgments.evaluate(client, @card, recorded_at: "2026-09-18T12:00:00Z")
    assert record["card_id"] == @card["id"]
    assert record["recorded_at"] == "2026-09-18T12:00:00Z"
    assert record["model"] == "jev-latest"
    assert map_size(record["answers"]) == 4
    assert map_size(record["answers"]["season_read"]["probabilities"]) == 5
    assert length(record["answers"]["confidence_in_signal"]["levels"]) == 3
    assert record["answers"]["ops_plus_drop_ge_10_next"]["confidence"] == 0.8
  end

  test "passes the exact judgment_state and no other card fields" do
    parent = self()
    name = {__MODULE__, make_ref()}

    Req.Test.stub(name, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      send(parent, {:sent_state, decoded["state"], map_size(decoded["questions"])})

      TypeSafeAPI.Test.json(conn, 200, %{
        "model" => "jev-test",
        "answers" => synthetic_wire_answers(decoded["questions"]),
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      })
    end)

    client = TypeSafeAPI.Test.client(name: name)
    assert {:ok, _record} = Judgments.evaluate(client, @card)
    assert_receive {:sent_state, state, 4}
    assert state == @card["judgment_state"]
    refute Map.has_key?(state, "id")
  end

  test "from_answers requires an exact raw response and returns only a validated record" do
    assert {:ok, questions} = Questions.for_card(@card)
    answers = valid_answers()
    response = valid_raw_response()
    opts = [response: response, recorded_at: "2026-09-18T12:00:00Z"]

    for bad <- [
          Map.delete(answers, :profile),
          put_in(answers, [:season_read, Access.key!(:confidence)], 2.0),
          put_in(answers, [:season_read, Access.key!(:probabilities)], %{stable: 1.0}),
          put_in(answers, [:confidence_in_signal, Access.key!(:score)], :nan),
          put_in(answers, [:ops_plus_drop_ge_10_next, Access.key!(:noul)], -0.1)
        ] do
      assert {:error, {:invalid_answers, _}} =
               Judgments.from_answers(@card, questions, "jev-test", bad, opts)
    end

    assert {:error, _} = Judgments.from_answers(@card, questions, "jev-test", answers)

    assert {:error, _} =
             Judgments.from_answers(@card, questions, "jev-test", answers,
               response: put_in(response, ["model"], "other-model"),
               recorded_at: "2026-09-18T12:00:00Z"
             )

    assert {:error, _} =
             Judgments.from_answers(@card, questions, "jev-test", answers,
               response: put_in(response, ["answers", "season_read", "choice"], "breakout"),
               recorded_at: "2026-09-18T12:00:00Z"
             )

    assert {:ok, record} = Judgments.from_answers(@card, questions, "jev-test", answers, opts)
    assert {:ok, ^record} = Judgments.validate_record(record, @card)
  end

  test "recording writes only validated immutable JSON and refuses replacement" do
    path = Path.join(System.tmp_dir!(), "sabr-record-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)

    assert {:ok, questions} = Questions.for_card(@card)

    assert {:ok, record} =
             Judgments.from_answers(@card, questions, "jev-test", valid_answers(),
               response: valid_raw_response(),
               recorded_at: "2026-09-18T12:00:00Z"
             )

    assert {:error, _} =
             Mix.Tasks.Sabr.Record.write_immutable(path, %{"schema_version" => 1}, @card)

    refute File.exists?(path)
    assert :ok = Mix.Tasks.Sabr.Record.write_immutable(path, record, @card)

    assert {:error, :already_exists} =
             Mix.Tasks.Sabr.Record.write_immutable(path, record, @card)

    assert Jason.decode!(File.read!(path)) == record
  end

  test "rejects unexpected answer types and options" do
    assert {:ok, questions} = Questions.for_card(@card)
    answers = valid_answers()

    assert {:error, {:invalid_answers, _}} =
             Judgments.from_answers(@card, questions, "jev-test", %{
               answers
               | season_read: answers.profile
             })

    bad_choice = %{answers.season_read | choice: :invented}

    assert {:error, {:invalid_answers, _}} =
             Judgments.from_answers(@card, questions, "jev-test", %{
               answers
               | season_read: bad_choice
             })
  end

  test "all immutable real recordings validate against their cards" do
    catalog = Jason.decode!(File.read!("priv/data/cards.json"))
    cards = Map.new(catalog["cards"], &{&1["id"], &1})
    paths = Path.wildcard("priv/jev/recordings/*.json")
    assert length(paths) == 10

    for path <- paths do
      record = Jason.decode!(File.read!(path))
      assert {:ok, ^record} = Judgments.validate_record(record, cards[record["card_id"]])
    end
  end

  test "record validation enforces exact serialized and raw contracts and agreement" do
    {record, card} = real_record_and_card()
    assert {:ok, ^record} = Judgments.validate_record(record, card)

    mutations = [
      Map.put(record, "extra", true),
      put_in(record, ["answers", "season_read", "extra"], true),
      put_in(record, ["answers", "season_read", "description"], "invented"),
      put_in(record, ["answers", "season_read", "probabilities"], nil),
      put_in(record, ["answers", "season_read", "options", Access.at(0), "option"], "stable"),
      put_in(record, ["answers", "confidence_in_signal", "label"], "weak"),
      put_in(
        record,
        ["answers", "confidence_in_signal", "levels", Access.at(0), "label"],
        "wrong"
      ),
      put_in(record, ["answers", "confidence_in_signal", "legend", "0", "label"], "wrong"),
      put_in(record, ["response", "extra"], true),
      put_in(record, ["response", "usage", "input_tokens"], -1),
      put_in(record, ["response", "answers", "season_read", "extra"], true),
      put_in(record, ["response", "answers", "season_read", "probabilities", "stable"], 2.0),
      put_in(record, ["response", "answers", "ops_plus_drop_ge_10_next", "noul"], "yes"),
      put_in(record, ["answers", "season_read", "choice"], "stable")
    ]

    for changed <- mutations do
      assert {:error, _} = Judgments.validate_record(changed, card)
    end
  end

  defp valid_answers do
    %{
      season_read: %Choice{
        id: :season_read,
        choice: :stable,
        description: "The supplied metrics support a sustainable, broadly stable season read.",
        probabilities: %{
          breakout: 0.05,
          stable: 0.8,
          regression_risk: 0.05,
          small_sample: 0.05,
          other: 0.05
        },
        options: [
          breakout: 0.05,
          stable: 0.8,
          regression_risk: 0.05,
          small_sample: 0.05,
          other: 0.05
        ],
        confidence: 0.8
      },
      confidence_in_signal: %Score{
        id: :confidence_in_signal,
        score: 1.7,
        level: 2,
        label: "strong",
        description: "The metrics provide a strong and coherent signal.",
        probabilities: %{0 => 0.05, 1 => 0.2, 2 => 0.75},
        levels: [{"weak", 0.05}, {"moderate", 0.2}, {"strong", 0.75}],
        legend: %{
          0 => %{
            "label" => "weak",
            "description" => "The metrics provide weak or conflicting interpretive evidence."
          },
          1 => %{
            "label" => "moderate",
            "description" => "The metrics provide a meaningful but not decisive signal."
          },
          2 => %{
            "label" => "strong",
            "description" => "The metrics provide a strong and coherent signal."
          }
        },
        confidence: 0.75
      },
      profile: %Choice{
        id: :profile,
        choice: :balanced,
        description: "No single tool dominates; the profile is balanced.",
        probabilities: %{power: 0.05, discipline: 0.05, contact: 0.05, balanced: 0.8, other: 0.05},
        options: [power: 0.05, discipline: 0.05, contact: 0.05, balanced: 0.8, other: 0.05],
        confidence: 0.8
      },
      ops_plus_drop_ge_10_next: %Noul{id: :ops_plus_drop_ge_10_next, noul: 0.2, confidence: 0.8}
    }
  end

  defp valid_raw_response do
    %{
      "model" => "jev-test",
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1},
      "answers" => %{
        "season_read" => %{
          "type" => "choice",
          "choice" => "stable",
          "confidence" => 0.8,
          "probabilities" => %{
            "breakout" => 0.05,
            "stable" => 0.8,
            "regression_risk" => 0.05,
            "small_sample" => 0.05,
            "other" => 0.05
          }
        },
        "confidence_in_signal" => %{
          "type" => "score",
          "score" => 1.7,
          "confidence" => 0.75,
          "probabilities" => %{"0" => 0.05, "1" => 0.2, "2" => 0.75},
          "legend" => %{
            "0" => %{
              "label" => "weak",
              "description" => "The metrics provide weak or conflicting interpretive evidence."
            },
            "1" => %{
              "label" => "moderate",
              "description" => "The metrics provide a meaningful but not decisive signal."
            },
            "2" => %{
              "label" => "strong",
              "description" => "The metrics provide a strong and coherent signal."
            }
          }
        },
        "profile" => %{
          "type" => "choice",
          "choice" => "balanced",
          "confidence" => 0.8,
          "probabilities" => %{
            "power" => 0.05,
            "discipline" => 0.05,
            "contact" => 0.05,
            "balanced" => 0.8,
            "other" => 0.05
          }
        },
        "ops_plus_drop_ge_10_next" => %{"type" => "noul", "noul" => 0.2}
      }
    }
  end

  defp synthetic_wire_answers(questions) do
    Map.new(questions, fn
      {id, %{"type" => "choice", "criteria" => criteria}} ->
        option = criteria |> Map.keys() |> hd()
        probs = Map.new(criteria, fn {key, _} -> {key, if(key == option, do: 1.0, else: 0.0)} end)

        {id,
         %{"type" => "choice", "choice" => option, "probabilities" => probs, "confidence" => 1.0}}

      {id, %{"type" => "score", "criteria" => levels}} ->
        probs =
          levels
          |> Enum.with_index()
          |> Map.new(fn {_level, index} ->
            {to_string(index), if(index == 0, do: 1.0, else: 0.0)}
          end)

        legend =
          levels
          |> Enum.with_index()
          |> Map.new(fn {level, index} -> {to_string(index), level} end)

        {id,
         %{
           "type" => "score",
           "score" => 0.0,
           "probabilities" => probs,
           "legend" => legend,
           "confidence" => 1.0
         }}

      {id, %{"type" => "noul"}} ->
        {id, %{"type" => "noul", "noul" => 0.1}}
    end)
  end

  defp real_record_and_card do
    catalog = Jason.decode!(File.read!("priv/data/cards.json"))
    card = Enum.find(catalog["cards"], &(&1["id"] == "batter:sotoju01:2024"))
    record = Jason.decode!(File.read!("priv/jev/recordings/batter--sotoju01--2024.json"))
    {record, card}
  end
end
