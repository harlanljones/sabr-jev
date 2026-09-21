defmodule SabrJev.Latch do
  @moduledoc "Provisional confidence latch for validated typed judgments."

  alias SabrJev.{Judgments, Questions}

  @choice_score_act 0.8
  @choice_score_review 0.5
  @noul_act 0.85
  @rank %{act: 0, review: 1, escalate: 2}

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
      typed = Enum.map(answers, fn {id, answer} -> {id, answer["type"], answer_routes[id]} end)

      choice_score_routes =
        for {_id, type, route} <- typed, type in ["choice", "score"], do: route

      noul_routes = for {_id, "noul", route} <- typed, do: route
      base = worst(choice_score_routes)
      route = if base == :act and :review in noul_routes, do: :review, else: base
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

  defp worst([]), do: :escalate
  defp worst(routes), do: Enum.max_by(routes, &@rank[&1])

  defp enforce_sample(:act, %{"value" => nil}), do: {:review, [:unavailable_sample]}
  defp enforce_sample(:act, %{"qualified" => false}), do: {:review, [:underqualified_sample]}
  defp enforce_sample(route, _sample), do: {route, []}
end
