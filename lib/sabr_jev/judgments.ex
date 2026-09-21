defmodule SabrJev.Judgments do
  @moduledoc "Fail-closed adapter between frozen card state and typed Jev answers."

  alias SabrJev.Questions
  alias TypeSafeAPI.Answer.{Choice, Noul, Score}

  @schema_version 1
  @tolerance 1.0e-9
  # Wire probabilities and Score values are independently rounded to two decimals.
  @score_tolerance 0.011
  @record_keys ~w(schema_version card_id state_hash questions_hash model recorded_at response answers source_lineage)

  @spec evaluate(TypeSafeAPI.Client.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def evaluate(client, card, opts \\ []) do
    with {:ok, questions} <- Questions.for_card(card),
         {:ok, result} <- TypeSafeAPI.evaluate(client, card["judgment_state"], questions),
         :ok <- validate_raw_response(result.raw, questions) do
      from_answers(card, questions, result.model, result.answers,
        response: result.raw,
        recorded_at: Keyword.get(opts, :recorded_at),
        source_lineage: Keyword.get(opts, :source_lineage)
      )
    end
  end

  @spec from_answers(map(), keyword(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def from_answers(card, questions, model, answers, opts \\ []) do
    with :ok <- validate_model(model),
         :ok <- validate_answers(answers, questions),
         {:ok, response} <- required_response(opts),
         :ok <- validate_raw_response(response, questions),
         {:ok, recorded_at} <- recorded_at(Keyword.get(opts, :recorded_at)),
         {:ok, lineage} <- source_lineage(Keyword.get(opts, :source_lineage)),
         record = %{
           "schema_version" => @schema_version,
           "card_id" => card["id"],
           "state_hash" => Questions.state_hash(card["judgment_state"]),
           "questions_hash" => Questions.hash(questions),
           "model" => model,
           "recorded_at" => recorded_at,
           "response" => response,
           "answers" =>
             Map.new(answers, fn {id, answer} -> {to_string(id), serialize(answer)} end),
           "source_lineage" => lineage
         },
         {:ok, validated} <- validate_record(record, card) do
      {:ok, validated}
    end
  end

  defp required_response(opts) do
    case Keyword.fetch(opts, :response) do
      {:ok, response} -> {:ok, response}
      :error -> {:error, {:invalid_record, "response is required"}}
    end
  end

  @spec validate_record(map(), map()) :: {:ok, map()} | {:error, term()}
  def validate_record(record, card) when is_map(record) and is_map(card) do
    with {:ok, questions} <- Questions.for_card(card),
         :ok <- exact_record_keys(record, @record_keys, "record"),
         true <- record["schema_version"] == @schema_version || {:error, :schema_version_mismatch},
         true <- record["card_id"] == card["id"] || {:error, :card_id_mismatch},
         true <-
           record["state_hash"] == Questions.state_hash(card["judgment_state"]) ||
             {:error, :state_hash_mismatch},
         true <-
           record["questions_hash"] == Questions.hash(questions) ||
             {:error, :questions_hash_mismatch},
         :ok <- validate_model(record["model"]),
         {:ok, _timestamp} <- recorded_at(record["recorded_at"]),
         {:ok, _lineage} <- source_lineage(record["source_lineage"]),
         :ok <- validate_serialized_answers(record["answers"], questions),
         :ok <- validate_raw_response(record["response"], questions),
         :ok <- validate_response_metadata(record),
         :ok <-
           validate_answer_agreement(record["answers"], record["response"]["answers"], questions) do
      {:ok, record}
    end
  end

  def validate_record(_, _), do: {:error, {:invalid_record, "record and card must be maps"}}

  @spec load(Path.t(), map()) :: {:ok, map()} | {:error, term()}
  def load(path, card) do
    with {:ok, body} <- File.read(path),
         {:ok, record} <- Jason.decode(body) do
      validate_record(record, card)
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:invalid_json, Exception.message(error)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_answers(answers, questions) when is_map(answers) do
    expected_ids = Enum.map(questions, &elem(&1, 0))

    if Map.keys(answers) |> Enum.sort() != Enum.sort(expected_ids) do
      {:error, {:invalid_answers, "answer ids must exactly match question ids"}}
    else
      Enum.reduce_while(questions, :ok, fn {id, question}, :ok ->
        case validate_answer(answers[id], question, id) do
          :ok -> {:cont, :ok}
          {:error, message} -> {:halt, {:error, {:invalid_answers, message}}}
        end
      end)
    end
  end

  defp validate_answers(_, _), do: {:error, {:invalid_answers, "answers must be a map"}}

  defp validate_answer(%Choice{} = answer, %TypeSafeAPI.Question.Choice{criteria: criteria}, id) do
    options = Enum.map(criteria, &elem(&1, 0))

    with true <- answer.id == id || {:error, "choice id mismatch for #{id}"},
         true <- answer.choice in options || {:error, "unexpected option for #{id}"},
         :ok <- unit(answer.confidence, "choice confidence for #{id}"),
         :ok <- distribution(answer.probabilities, options, "choice probabilities for #{id}"),
         true <-
           Enum.map(answer.options, &elem(&1, 0)) == options ||
             {:error, "incomplete ordered options for #{id}"} do
      :ok
    end
  end

  defp validate_answer(%Score{} = answer, %TypeSafeAPI.Question.Score{levels: levels}, id) do
    indexes = Enum.to_list(0..(length(levels) - 1))
    labels = Enum.map(levels, &TypeSafeAPI.Question.Score.label/1)

    with true <- answer.id == id || {:error, "score id mismatch for #{id}"},
         true <- answer.level in indexes || {:error, "unexpected score level for #{id}"},
         true <-
           answer.label == Enum.at(labels, answer.level) ||
             {:error, "score label mismatch for #{id}"},
         :ok <- bounded(answer.score, 0.0, length(levels) - 1, "score for #{id}"),
         :ok <- unit(answer.confidence, "score confidence for #{id}"),
         :ok <- distribution(answer.probabilities, indexes, "score probabilities for #{id}"),
         true <-
           Enum.map(answer.levels, &elem(&1, 0)) == labels ||
             {:error, "incomplete score levels for #{id}"} do
      :ok
    end
  end

  defp validate_answer(%Noul{} = answer, %TypeSafeAPI.Question.Noul{}, id) do
    with true <- answer.id == id || {:error, "Noul id mismatch for #{id}"},
         :ok <- unit(answer.noul, "Noul probability for #{id}"),
         :ok <- unit(answer.confidence, "Noul confidence for #{id}"),
         true <-
           abs(answer.confidence - max(answer.noul, 1.0 - answer.noul)) <= @tolerance ||
             {:error, "Noul confidence mismatch for #{id}"} do
      :ok
    end
  end

  defp validate_answer(_answer, _question, id), do: {:error, "unexpected answer type for #{id}"}

  defp distribution(values, expected_keys, label) when is_map(values) do
    with true <-
           Enum.sort(Map.keys(values)) == Enum.sort(expected_keys) ||
             {:error, "#{label} are incomplete"},
         true <-
           Enum.all?(values, fn {_key, value} -> unit?(value) end) ||
             {:error, "#{label} contain an invalid value"},
         true <-
           abs(Enum.sum(Map.values(values)) - 1.0) <= @tolerance ||
             {:error, "#{label} do not sum to one"} do
      :ok
    end
  end

  defp distribution(_, _, label), do: {:error, "#{label} must be a map"}

  defp validate_raw_response(response, questions) when is_map(response) do
    with :ok <- exact_answer_keys(response, ~w(answers model usage), "response"),
         :ok <- validate_model(response["model"]),
         :ok <- validate_usage(response["usage"]),
         raw when is_map(raw) <- response["answers"],
         expected_ids = questions |> Keyword.keys() |> Enum.map(&to_string/1) |> Enum.sort(),
         true <-
           Enum.sort(Map.keys(raw)) == expected_ids ||
             {:error, {:invalid_answers, "raw answer ids must exactly match question ids"}},
         :ok <- validate_raw_answers(raw, questions) do
      :ok
    else
      {:error, _} = error ->
        error

      nil ->
        {:error, {:invalid_answers, "response has no answers map"}}

      value when not is_map(value) ->
        {:error, {:invalid_answers, "response answers must be a map"}}
    end
  end

  defp validate_raw_response(_, _),
    do: {:error, {:invalid_answers, "response has no answers map"}}

  defp validate_raw_answers(raw, questions) do
    Enum.reduce_while(questions, :ok, fn {id, question}, :ok ->
      answer = raw[to_string(id)]

      result =
        case {answer, question} do
          {%{
             "type" => "choice",
             "choice" => choice,
             "confidence" => confidence,
             "probabilities" => probabilities
           } = raw_answer, %TypeSafeAPI.Question.Choice{criteria: criteria}} ->
            options = Enum.map(criteria, fn {key, _} -> to_string(key) end)

            with :ok <-
                   exact_answer_keys(
                     raw_answer,
                     ~w(type choice confidence probabilities),
                     "raw choice #{id}"
                   ),
                 true <-
                   choice in options ||
                     {:error, {:invalid_answers, "unexpected raw choice for #{id}"}},
                 :ok <- unit(confidence, "raw choice confidence for #{id}"),
                 :ok <- distribution(probabilities, options, "raw choice probabilities for #{id}") do
              :ok
            end

          {%{
             "type" => "score",
             "score" => score,
             "confidence" => confidence,
             "probabilities" => probabilities,
             "legend" => legend
           } = raw_answer, %TypeSafeAPI.Question.Score{levels: levels}} ->
            indexes = Enum.map(0..(length(levels) - 1), &to_string/1)

            with :ok <-
                   exact_answer_keys(
                     raw_answer,
                     ~w(type score confidence probabilities legend),
                     "raw score #{id}"
                   ),
                 :ok <- bounded(score, 0.0, length(levels) - 1, "raw score for #{id}"),
                 :ok <- unit(confidence, "raw score confidence for #{id}"),
                 :ok <- distribution(probabilities, indexes, "raw score probabilities for #{id}"),
                 true <-
                   legend == expected_legend(levels) ||
                     {:error, {:invalid_answers, "raw score legend mismatch for #{id}"}} do
              :ok
            end

          {%{"type" => "noul", "noul" => noul} = raw_answer, %TypeSafeAPI.Question.Noul{}} ->
            with :ok <- exact_answer_keys(raw_answer, ~w(type noul), "raw Noul #{id}"),
                 :ok <- unit(noul, "raw Noul probability for #{id}"),
                 do: :ok

          _ ->
            {:error, {:invalid_answers, "missing or mismatched raw answer for #{id}"}}
        end

      case result do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp serialize(%Choice{} = answer) do
    %{
      "type" => "choice",
      "choice" => to_string(answer.choice),
      "description" => answer.description,
      "confidence" => answer.confidence,
      "probabilities" =>
        Map.new(answer.probabilities, fn {key, value} -> {to_string(key), value} end),
      "options" =>
        Enum.map(answer.options, fn {key, value} ->
          %{"option" => to_string(key), "probability" => value}
        end)
    }
  end

  defp serialize(%Score{} = answer) do
    %{
      "type" => "score",
      "score" => answer.score,
      "level" => answer.level,
      "label" => answer.label,
      "description" => answer.description,
      "confidence" => answer.confidence,
      "probabilities" =>
        Map.new(answer.probabilities, fn {key, value} -> {to_string(key), value} end),
      "levels" =>
        Enum.map(answer.levels, fn {label, value} ->
          %{"label" => label, "probability" => value}
        end),
      "legend" => Map.new(answer.legend, fn {key, value} -> {to_string(key), value} end)
    }
  end

  defp serialize(%Noul{} = answer) do
    %{"type" => "noul", "noul" => answer.noul, "confidence" => answer.confidence}
  end

  @doc "Validates stored answer JSON against the exact frozen questions."
  @spec validate_serialized_answers(map(), keyword()) :: :ok | {:error, term()}
  def validate_serialized_answers(answers, questions) when is_map(answers) do
    expected = questions |> Keyword.keys() |> Enum.map(&to_string/1) |> Enum.sort()

    if Enum.sort(Map.keys(answers)) != expected do
      {:error, {:invalid_record, "serialized answer ids do not match questions"}}
    else
      Enum.reduce_while(questions, :ok, fn {id, question}, :ok ->
        case validate_serialized_answer(answers[to_string(id)], question, id) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  def validate_serialized_answers(_, _), do: {:error, {:invalid_record, "answers must be a map"}}

  defp validate_serialized_answer(
         %{"type" => "choice"} = answer,
         %TypeSafeAPI.Question.Choice{criteria: criteria},
         id
       ) do
    options = Enum.map(criteria, fn {key, _} -> to_string(key) end)
    probabilities = answer["probabilities"]
    expected_options = Enum.map(options, &%{"option" => &1, "probability" => probabilities[&1]})
    descriptions = Map.new(criteria, fn {key, description} -> {to_string(key), description} end)

    with :ok <-
           exact_record_keys(
             answer,
             ~w(type choice description confidence probabilities options),
             "choice #{id}"
           ),
         true <-
           answer["choice"] in options ||
             {:error, {:invalid_record, "unexpected choice for #{id}"}},
         true <-
           answer["description"] == descriptions[answer["choice"]] ||
             {:error, {:invalid_record, "choice description mismatch for #{id}"}},
         :ok <- unit(answer["confidence"], "choice confidence for #{id}"),
         :ok <- distribution(probabilities, options, "choice probabilities for #{id}"),
         true <-
           selected_max?(probabilities, answer["choice"]) ||
             {:error, {:invalid_record, "choice disagrees with probabilities for #{id}"}} do
      if answer["options"] == expected_options,
        do: :ok,
        else: {:error, {:invalid_record, "ordered choice options mismatch for #{id}"}}
    end
  end

  defp validate_serialized_answer(
         %{"type" => "score"} = answer,
         %TypeSafeAPI.Question.Score{levels: levels},
         id
       ) do
    indexes = Enum.map(0..(length(levels) - 1), &to_string/1)
    labels = Enum.map(levels, &TypeSafeAPI.Question.Score.label/1)
    descriptions = Enum.map(levels, &elem(&1, 1))
    probabilities = answer["probabilities"]

    expected_levels =
      Enum.with_index(labels)
      |> Enum.map(fn {label, index} ->
        %{"label" => label, "probability" => probabilities[to_string(index)]}
      end)

    with :ok <-
           exact_record_keys(
             answer,
             ~w(type score level label description confidence probabilities levels legend),
             "score #{id}"
           ),
         true <-
           (is_integer(answer["level"]) and answer["level"] >= 0 and
              answer["level"] < length(levels)) ||
             {:error, {:invalid_record, "unexpected score level for #{id}"}},
         true <-
           answer["label"] == Enum.at(labels, answer["level"]) ||
             {:error, {:invalid_record, "score label mismatch for #{id}"}},
         true <-
           answer["description"] == Enum.at(descriptions, answer["level"]) ||
             {:error, {:invalid_record, "score description mismatch for #{id}"}},
         :ok <- bounded(answer["score"], 0.0, length(levels) - 1, "score for #{id}"),
         :ok <- unit(answer["confidence"], "score confidence for #{id}"),
         :ok <- distribution(probabilities, indexes, "score probabilities for #{id}"),
         true <-
           abs(answer["score"] - expected_score(probabilities)) <= @score_tolerance ||
             {:error, {:invalid_record, "score disagrees with probabilities for #{id}"}},
         true <-
           selected_max?(probabilities, to_string(answer["level"])) ||
             {:error, {:invalid_record, "score level disagrees with probabilities for #{id}"}},
         true <-
           answer["levels"] == expected_levels ||
             {:error, {:invalid_record, "ordered score levels mismatch for #{id}"}},
         true <-
           answer["legend"] == expected_legend(levels) ||
             {:error, {:invalid_record, "score legend mismatch for #{id}"}} do
      :ok
    end
  end

  defp validate_serialized_answer(
         %{"type" => "noul", "noul" => noul, "confidence" => confidence} = answer,
         %TypeSafeAPI.Question.Noul{},
         id
       ) do
    with :ok <- exact_record_keys(answer, ~w(type noul confidence), "Noul #{id}"),
         :ok <- unit(noul, "Noul probability for #{id}"),
         :ok <- unit(confidence, "Noul confidence for #{id}"),
         true <-
           abs(confidence - max(noul, 1.0 - noul)) <= @tolerance ||
             {:error, {:invalid_record, "Noul confidence mismatch for #{id}"}} do
      :ok
    end
  end

  defp validate_serialized_answer(_, _, id),
    do: {:error, {:invalid_record, "unexpected answer type for #{id}"}}

  defp validate_response_metadata(record) do
    if record["response"]["model"] == record["model"],
      do: :ok,
      else: {:error, {:invalid_record, "response model does not match record model"}}
  end

  defp validate_answer_agreement(serialized, raw, questions) do
    Enum.reduce_while(questions, :ok, fn {id, question}, :ok ->
      key = to_string(id)
      stored = serialized[key]
      wire = raw[key]

      fields =
        case question do
          %TypeSafeAPI.Question.Choice{} -> ~w(type choice confidence probabilities)
          %TypeSafeAPI.Question.Score{} -> ~w(type score confidence probabilities legend)
          %TypeSafeAPI.Question.Noul{} -> ~w(type noul)
        end

      if Enum.all?(fields, &equivalent?(stored[&1], wire[&1])) do
        {:cont, :ok}
      else
        {:halt,
         {:error, {:invalid_record, "serialized answer disagrees with raw response for #{id}"}}}
      end
    end)
  end

  defp equivalent?(left, right) when is_number(left) and is_number(right),
    do: abs(left - right) <= @tolerance

  defp equivalent?(left, right), do: left == right

  defp selected_max?(probabilities, selected) do
    selected_value = probabilities[selected]

    is_number(selected_value) and
      selected_value >= Enum.max(Map.values(probabilities)) - @tolerance
  end

  defp expected_score(probabilities) do
    Enum.reduce(probabilities, 0.0, fn {index, probability}, total ->
      total + String.to_integer(index) * probability
    end)
  end

  defp expected_legend(levels) do
    levels
    |> Enum.with_index()
    |> Map.new(fn {{label, description}, index} ->
      {to_string(index), %{"label" => label, "description" => description}}
    end)
  end

  defp validate_usage(usage) when is_map(usage) do
    with :ok <- exact_answer_keys(usage, ~w(input_tokens output_tokens), "response usage"),
         true <-
           Enum.all?(Map.values(usage), &(is_integer(&1) and &1 >= 0)) ||
             {:error, {:invalid_answers, "response usage values must be nonnegative integers"}} do
      :ok
    end
  end

  defp validate_usage(_), do: {:error, {:invalid_answers, "response usage must be a map"}}

  defp exact_record_keys(map, expected, label) when is_map(map) do
    if Enum.sort(Map.keys(map)) == Enum.sort(expected),
      do: :ok,
      else: {:error, {:invalid_record, "#{label} keys do not match the frozen contract"}}
  end

  defp exact_answer_keys(map, expected, label) when is_map(map) do
    if Enum.sort(Map.keys(map)) == Enum.sort(expected),
      do: :ok,
      else: {:error, {:invalid_answers, "#{label} keys do not match the frozen contract"}}
  end

  defp validate_model(model) when is_binary(model) and byte_size(model) > 0, do: :ok
  defp validate_model(_), do: {:error, {:invalid_record, "model must be a non-empty string"}}

  defp recorded_at(nil),
    do: {:ok, DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()}

  defp recorded_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, 0} -> {:ok, value}
      _ -> {:error, {:invalid_record, "recorded_at must be an ISO 8601 UTC timestamp"}}
    end
  end

  defp recorded_at(_), do: {:error, {:invalid_record, "recorded_at must be a UTC timestamp"}}

  defp source_lineage(nil), do: {:ok, %{"card_artifact" => "priv/data/cards.json"}}
  defp source_lineage(lineage) when is_map(lineage) and map_size(lineage) > 0, do: {:ok, lineage}

  defp source_lineage(_),
    do: {:error, {:invalid_record, "source_lineage must be a non-empty map"}}

  defp unit(value, label), do: bounded(value, 0.0, 1.0, label)
  defp unit?(value), do: finite_number?(value) and value >= 0 and value <= 1

  defp bounded(value, low, high, _label)
       when is_number(value) and value >= low and value <= high do
    if finite_number?(value), do: :ok, else: {:error, "value must be finite"}
  end

  defp bounded(_value, _low, _high, label), do: {:error, "#{label} is outside its allowed range"}

  defp finite_number?(value) when is_integer(value), do: true

  defp finite_number?(value) when is_float(value) do
    <<_sign::1, exponent::11, _fraction::52>> = <<value::float>>
    exponent != 2047
  end

  defp finite_number?(_), do: false
end
