defmodule SabrJev.Backtest do
  @moduledoc """
  Retrospective backtest recorded Noul predictions against oracle outcomes.

  Every scored pair uses an already-validated recording and the card's own
  oracle join, so the numbers here are real. The view is explicitly
  retrospective plumbing: capture always precedes outcomes for prospective
  work, and no claim of calibration or validation follows from this report.
  """

  alias SabrJev.Catalog

  @doc """
  Scores every card that has both a recorded Noul and an oracle outcome.
  Returns :ok tuples wrapped with per-role and overall statistics; cards
  missing either side are excluded and counted as coverage gaps.
  """
  @spec run(map()) :: {:ok, map()} | {:error, term()}
  def run(%{} = catalog) do
    pairs =
      Enum.flat_map(Catalog.cards(catalog), fn card ->
        with {:ok, %{record: %{"answers" => answers}}} <- Catalog.judgment(card),
             %{"type" => "noul", "noul" => probability} when is_number(probability) <-
               find_noul(answers, card["role"]),
             %{"label" => label} when is_boolean(label) <- card["oracle"] do
          [%{card_id: card["id"], role: card["role"], probability: probability, label: label}]
        else
          _ -> []
        end
      end)

    by_role =
      pairs
      |> Enum.group_by(& &1.role)
      |> Map.new(fn {role, items} -> {role, summarize(items)} end)

    {:ok,
     %{
       pairs: pairs,
       by_role: by_role,
       all: summarize(pairs),
       coverage: %{
         "cards" => length(Catalog.cards(catalog)),
         "scored" => length(pairs),
         "excluded" => length(Catalog.cards(catalog)) - length(pairs)
       },
       status: "retrospective backtest; not prospective validation; no calibration claim",
       ledger_limit: "Historical oracle join; capture always precedes this outcome."
     }}
  end

  def run(_), do: {:error, :invalid_catalog}

  defp summarize(items) do
    ps = Enum.map(items, & &1.probability)
    ls = Enum.map(items, &((&1.label && 1.0) || 0.0))
    n = length(items)

    %{
      "n" => n,
      "brier" => divide(sum_sq(ps, ls), n),
      "baseline_brier" => divide(sum_sq(List.duplicate(0.5, n), ls), n),
      "buckets" => buckets(ps, ls)
    }
  end

  defp find_noul(answers, role) do
    id = SabrJev.Questions.noul_id(role)
    answers[id]
  end

  defp sum_sq(ps, ls), do: Enum.sum(Enum.zip_with(ps, ls, fn p, l -> (p - l) * (p - l) end))

  defp divide(_, 0), do: nil
  defp divide(sum, n), do: sum / n

  defp buckets(ps, ls) do
    Enum.zip_with(ps, ls, fn p, l -> {p, l} end)
    |> Enum.group_by(fn {p, _} -> bucket(p) end)
    |> Enum.map(fn {range, pairs} ->
      %{
        "range" => range,
        "n" => length(pairs),
        "mean_p" => divide(Enum.sum(Enum.map(pairs, &elem(&1, 0))), length(pairs)),
        "rate" => divide(Enum.count(pairs, &elem(&1, 1)), length(pairs))
      }
    end)
    |> Enum.sort_by(& &1["range"])
  end

  defp bucket(p) when p < 0.2, do: "0.0-0.2"
  defp bucket(p) when p < 0.4, do: "0.2-0.4"
  defp bucket(p) when p < 0.6, do: "0.4-0.6"
  defp bucket(p) when p < 0.8, do: "0.6-0.8"
  defp bucket(_), do: "0.8-1.0"
end
