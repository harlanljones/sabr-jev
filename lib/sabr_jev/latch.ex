defmodule SabrJev.Latch do
  @moduledoc """
  Provisional confidence latch for validated typed judgments.

  v3 routing: the card route comes from the mean Choice/Score confidence.
  Min-based routing (v1/v2) was doubly unreachable in practice — max
  season_read confidence 0.68 across 48 recordings, and pitchers never
  cleared a conjunctive bar at all — so act now asks whether the judgment
  package collectively clears 0.65 rather than requiring every answer to.
  A single weak answer can be carried by strong companions; the full
  per-answer probabilities stay visible in the UI. The Noul judges a
  different question (next season) and keeps its own act/review at max(p,
  1-p) >= 0.85, never demoting the season read. Bars stay provisional until
  prospective outcomes arrive; nothing here claims calibration.
  """

  alias SabrJev.{Judgments, Questions}

  @choice_score_act 0.65
  @choice_score_review 0.45
  @noul_act 0.85

  @spec thresholds() :: map()
  def thresholds do
    %{
      "status" => "provisional",
      "choice_score" => %{"act" => @choice_score_act, "review" => @choice_score_review},
      "noul" => %{"act" => @noul_act, "review" => 0.5}
    }
  end

  @spec route(map(), map()) :: {:ok, map()} | {:error, term()}
  def route(answers, card) when is_map(answers) and is_map(card) do
    with {:ok, questions} <- Questions.for_card(card),
         :ok <- Judgments.validate_serialized_answers(answers, questions),
         {:ok, answer_routes} <- route_answers(answers) do
      cs_confidences =
        for {_id, answer} <- answers, answer["type"] in ["choice", "score"] do
          answer["confidence"]
        end

      route = mean_route(cs_confidences)
      {route, reasons} = enforce_sample(route, card["sample"])

      {:ok,
       %{
         route: route,
         answer_routes: answer_routes,
         reasons: reasons,
         thresholds: thresholds()
       }}
    end
  end

  def route(_answers, _card), do: {:error, :invalid_card_or_answers}

  defp route_answers(answers) do
    Enum.reduce_while(answers, {:ok, %{}}, fn {id, answer}, {:ok, acc} ->
      case answer_route(answer) do
        route when route in [:act, :review, :escalate] -> {:cont, {:ok, Map.put(acc, id, route)}}
        {:error, reason} -> {:halt, {:error, {:invalid_answer, id, reason}}}
      end
    end)
  end

  defp answer_route(%{"type" => "choice", "choice" => "other", "confidence" => _}),
    do: :escalate

  defp answer_route(%{"type" => "choice", "confidence" => confidence}),
    do: choice_score_route(confidence)

  defp answer_route(%{"type" => "score", "confidence" => confidence}),
    do: choice_score_route(confidence)

  defp answer_route(%{"type" => "noul", "noul" => probability}) do
    if max(probability, 1.0 - probability) >= @noul_act, do: :act, else: :review
  end

  defp answer_route(_), do: {:error, :unexpected_answer_shape}

  defp choice_score_route(confidence) do
    cond do
      confidence >= @choice_score_act -> :act
      confidence >= @choice_score_review -> :review
      true -> :escalate
    end
  end

  defp mean_route([]), do: :escalate

  defp mean_route(confidences) do
    mean = Enum.sum(confidences) / length(confidences)

    cond do
      mean >= @choice_score_act -> :act
      mean >= @choice_score_review -> :review
      true -> :escalate
    end
  end

  defp enforce_sample(:act, %{"value" => nil}), do: {:review, [:unavailable_sample]}
  defp enforce_sample(:act, %{"qualified" => false}), do: {:review, [:underqualified_sample]}
  defp enforce_sample(route, _sample), do: {route, []}
end
