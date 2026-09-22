defmodule SabrJev.Evaluation do
  @moduledoc """
  Late-outcome scoring for prospective Noul entries.
  Missing outcomes stay pending and excluded, never negative.
  Baselines are frozen before predictions, never fit on outcomes.
  """

  @spec score([map()], map(), keyword()) :: map() | {:error, term()}
  def score(entries, realized, opts) when is_list(entries) and is_list(opts) do
    case Keyword.fetch(opts, :baseline) do
      {:ok, baseline} when is_map(baseline) -> do_score(entries, realized, baseline)
      _ -> {:error, :baseline_required}
    end
  end

  defp do_score(entries, realized, baseline) do
    with :ok <- check_prospective_mode(entries),
         :ok <- check_realized(entries, realized),
         :ok <- check_cutoff_uniformity(entries) do
      {scored, pending} = Enum.split_with(entries, &Map.has_key?(realized, &1["card_id"]))
      by_role = group_brier(scored, realized, baseline)

      %{
        scored: Enum.map(scored, & &1["card_id"]),
        pending: Enum.map(pending, & &1["card_id"]),
        by_role: by_role,
        coverage: %{scored: length(scored), pending: length(pending)},
        missingness: %{
          pending: Enum.map(pending, & &1["card_id"]),
          pending_rate: length(pending) / max(length(entries), 1)
        }
      }
    end
  end

  # Only prospective lines are scoreable. A line derived from a retrospective
  # recording would score a judgment made with the outcome already known, which
  # is the leakage the capture cutoff exists to prevent in the first place.
  defp check_prospective_mode(entries) do
    if Enum.all?(entries, &(Map.get(&1, "mode") == "prospective")),
      do: :ok,
      else: {:error, :not_prospective_ledger_line}
  end

  # A ledger captured across two different cohort windows must be scored
  # separately; mixing them would silently compare against two frozen baselines.
  defp check_cutoff_uniformity(entries) do
    cutoffs =
      entries
      |> Enum.map(&Map.get(&1, "cutoff"))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if length(cutoffs) > 1,
      do: {:error, :mixed_cohort_cutoffs},
      else: :ok
  end

  defp check_realized(entries, realized) do
    Enum.reduce_while(entries, :ok, fn e, :ok ->
      case Map.get(realized, e["card_id"]) do
        nil ->
          {:cont, :ok}

        %{"year" => y, "label" => l, "target" => t, "provenance" => p}
        when is_boolean(l) and is_binary(t) and is_map(p) and map_size(p) > 0 ->
          with :ok <- provenance_ok?(p),
               :ok <- year_ok?(e, y),
               :ok <- target_ok?(e, t),
               :ok <- capture_precedes_outcome?(e, y) do
            {:cont, :ok}
          else
            err -> {:halt, err}
          end

        _ ->
          {:halt, {:error, :outcome_provenance_mismatch}}
      end
    end)
  end

  defp provenance_ok?(%{"card_artifact" => artifact}) when is_binary(artifact), do: :ok
  defp provenance_ok?(_), do: {:error, :outcome_provenance_mismatch}

  # Scoring must not resurrect the leakage the capture cutoff already forbade.
  # A line without a parseable capture time is never scoreable; there is no
  # retrospective exemption because capture cannot run in the past at all.
  defp capture_precedes_outcome?(%{"captured_at" => captured_at}, year)
       when is_binary(captured_at) do
    case DateTime.from_iso8601(captured_at) do
      {:ok, at, 0} ->
        cutoff = SabrJev.Prospective.cutoff_for(year - 1)
        if DateTime.compare(at, cutoff) == :lt, do: :ok, else: {:error, :capture_after_cutoff}

      _ ->
        {:error, :invalid_capture_time}
    end
  end

  defp capture_precedes_outcome?(_, _), do: {:error, :invalid_capture_time}

  defp target_ok?(%{"noul_id" => noul}, target) when noul == target, do: :ok
  defp target_ok?(_, _), do: {:error, :outcome_target_mismatch}

  defp year_ok?(%{"card_id" => id}, y) do
    case Regex.run(~r/:(\d{4})$/, id) do
      [_, t] ->
        if String.to_integer(t) + 1 == y, do: :ok, else: {:error, :outcome_year_mismatch}

      _ ->
        {:error, :outcome_year_mismatch}
    end
  end

  defp group_brier(scored, realized, baseline) do
    scored
    |> Enum.group_by(fn e -> SabrJev.Questions.role_for_noul_id(e["noul_id"]) end)
    |> Map.new(fn {role, items} ->
      ps = Enum.map(items, & &1["probability"])
      ls = Enum.map(items, fn e -> realized[e["card_id"]]["label"] end)

      b =
        case Map.fetch(baseline, role) do
          {:ok, value} when is_number(value) -> value
          _ -> raise ArgumentError, "baseline for role #{inspect(role)} is required and frozen"
        end

      {role,
       %{
         n: length(items),
         brier: brier(ps, ls),
         baseline_brier: brier(List.duplicate(b, length(items)), ls),
         buckets: buckets(ps, ls)
       }}
    end)
  end

  defp brier(ps, ls) do
    Enum.zip(ps, ls)
    |> Enum.map(fn {p, l} -> :math.pow(p - if(l, do: 1.0, else: 0.0), 2) end)
    |> Enum.sum()
    |> Kernel./(max(length(ps), 1))
  end

  defp buckets(ps, ls) do
    Enum.zip(ps, ls)
    |> Enum.group_by(fn {p, _} -> bucket(p) end)
    |> Enum.map(fn {range, pairs} ->
      %{
        range: range,
        n: length(pairs),
        mean_p: Enum.sum(Enum.map(pairs, &elem(&1, 0))) / length(pairs),
        rate: Enum.count(pairs, &elem(&1, 1)) / length(pairs)
      }
    end)
    |> Enum.sort_by(& &1.range)
  end

  defp bucket(p) when p < 0.2, do: "0.0-0.2"
  defp bucket(p) when p < 0.4, do: "0.2-0.4"
  defp bucket(p) when p < 0.6, do: "0.4-0.6"
  defp bucket(p) when p < 0.8, do: "0.6-0.8"
  defp bucket(_), do: "0.8-1.0"
end
