defmodule SabrJev.Prospective do
  @moduledoc """
  Prospective enrollment and capture before an outcome season.

  Cohort and baseline freeze before capture. Enrollment is limited to the single
  cycle that follows the latest season in the frozen source pins, and capture
  must strictly precede that outcome season under a conservative January 1
  cutoff. The local ledger is append-only and hash chained, but it cannot prove
  external capture time: a local writer controls both the file and its clock.

  Caller contract: pass an already-verified ledger. `capture/4` verifies the
  supplied ledger itself and fails closed, so a corrupt input is never extended.

  The record handed to `capture/4` must carry exactly one accepted shape: a
  top-level `"probability"` in 0..1 (injected by the capture task from the
  recorded Noul answer), plus non-empty `"card_id"`, `"state_hash"`,
  `"questions_hash"`, and `"model"`. `capture/4` accepts no alternate spelling
  and never derives a missing field.
  """

  # Mirrors data/sources.json and priv/data/cards.json provenance.latest_season.
  # A test cross-checks this against the committed artifact so the window cannot
  # silently drift; advancing it is a deliberate frozen-source update.
  @latest_frozen_season 2025
  @ledger_limit "Local hash chain only; cannot prove external capture time."

  @spec latest_frozen_season() :: pos_integer()
  def latest_frozen_season, do: @latest_frozen_season

  @spec enrollable_year() :: pos_integer()
  def enrollable_year, do: @latest_frozen_season + 1

  @spec ledger_limit() :: String.t()
  def ledger_limit, do: @ledger_limit

  # Capture must precede the outcome season, so the cutoff is January 1 of the
  # season after the cohort year: stricter than opening day and never inferred
  # from the wall clock.
  @spec cutoff_for(pos_integer()) :: DateTime.t()
  def cutoff_for(year) when is_integer(year),
    do: DateTime.new!(Date.new!(year + 1, 1, 1), ~T[00:00:00], "Etc/UTC")

  @spec cutoff() :: DateTime.t()
  def cutoff, do: cutoff_for(enrollable_year())

  @spec cutoff_iso() :: String.t()
  def cutoff_iso, do: cutoff() |> DateTime.to_iso8601()

  @spec enroll([map()], keyword()) :: map()
  def enroll(cards, opts) when is_list(cards) and is_list(opts) do
    %{
      cohort: Enum.map(cards, & &1["id"]),
      baseline: Keyword.fetch!(opts, :baseline),
      year: enrollable_year(),
      cutoff: cutoff(),
      cutoff_iso: cutoff_iso(),
      note: "Historical 2024 -> 2025 joins are retrospective plumbing only."
    }
  end

  @spec capture(map(), map(), map(), keyword()) ::
          {:ok, [String.t()], String.t()} | {:error, term()}
  def capture(cohort, card, record, opts \\ []) when is_list(opts) do
    ledger = Keyword.get(opts, :ledger, [])

    with :ok <- verify(ledger),
         {:ok, at} <- parse_capture_time(opts),
         :ok <- check_enrolled(cohort, card),
         :ok <- check_prospective_year(card),
         :ok <- check_capture_time(card, at),
         :ok <- check_unclaimed(ledger, card),
         {:ok, entry} <- record_entry(card, record) do
      append(ledger, cohort, entry, at)
    end
  end

  # Detects any edit, duplication, or reordering *within* a ledger. It cannot
  # detect a replaced or truncated ledger, because a local writer can always
  # rewrite a shorter valid chain.
  @spec verify([String.t()]) :: :ok | {:error, term()}
  def verify([]), do: :ok

  def verify([first | _] = ledger) do
    with {:ok, entry} <- decode_line(first),
         :ok <- check_genesis(entry),
         :ok <- check_chain(ledger) do
      :ok
    end
  end

  @spec retrospective?(String.t()) :: boolean()
  def retrospective?(id) when is_binary(id) do
    # Any card from a season whose next season already exists in the frozen pins
    # is retrospective plumbing, never prospective validation.
    case card_year(id) do
      year when is_integer(year) -> year <= @latest_frozen_season
      _ -> false
    end
  end

  defp parse_capture_time(opts) do
    case Keyword.fetch(opts, :captured_at) do
      {:ok, %DateTime{} = at} -> {:ok, at}
      {:ok, at} when is_binary(at) -> parse_time(at)
      _ -> {:error, :capture_time_required}
    end
  end

  defp parse_time(v) do
    case DateTime.from_iso8601(v) do
      {:ok, dt, 0} -> {:ok, dt}
      _ -> {:error, :invalid_capture_time}
    end
  end

  defp check_enrolled(%{cohort: c}, %{"id" => id}) do
    if id in c, do: :ok, else: {:error, :unknown_cohort_card}
  end

  defp check_enrolled(_, _), do: {:error, :unknown_cohort_card}

  defp check_prospective_year(%{"year" => year}) do
    if year == enrollable_year(), do: :ok, else: {:error, :historical_cohort}
  end

  defp check_prospective_year(_), do: {:error, :historical_cohort}

  defp check_capture_time(%{"year" => year}, at) do
    if DateTime.compare(at, cutoff_for(year)) == :lt,
      do: :ok,
      else: {:error, :capture_after_cutoff}
  end

  defp check_capture_time(_, _), do: {:error, :historical_cohort}

  defp check_unclaimed(ledger, %{"id" => id}) do
    existing =
      Enum.flat_map(ledger, fn line ->
        case Jason.decode(line) do
          {:ok, %{"card_id" => captured}} -> [captured]
          _ -> []
        end
      end)

    if id in existing, do: {:error, :duplicate_capture}, else: :ok
  end

  # A capture line is only useful if it can be joined to the exact judged state
  # and re-read later, so every field is required rather than defaulted.
  defp record_entry(card, record) when is_map(record) do
    with {:ok, id} <- card_id(record),
         :ok <- same_card?(card, id),
         {:ok, state_hash} <- non_empty(record, "state_hash"),
         {:ok, questions_hash} <- non_empty(record, "questions_hash"),
         {:ok, model} <- non_empty(record, "model"),
         {:ok, probability} <- probability(record),
         :ok <- check_state_hash(card, state_hash) do
      {:ok,
       %{
         "card_id" => card["id"],
         "noul_id" => noul_id(card),
         "probability" => probability,
         "state_hash" => state_hash,
         "questions_hash" => questions_hash,
         "model" => model
       }}
    end
  end

  defp record_entry(_card, _record), do: {:error, :record_card_mismatch}

  defp card_id(%{"card_id" => id}) when is_binary(id), do: {:ok, id}
  defp card_id(_), do: {:error, :record_card_mismatch}

  defp same_card?(%{"id" => id}, id), do: :ok
  defp same_card?(_, _), do: {:error, :record_card_mismatch}

  defp non_empty(record, key) do
    case record[key] do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, {:record_field_required, key}}
    end
  end

  defp probability(%{"probability" => value}), do: unit(value)
  defp probability(_), do: {:error, {:record_field_required, "probability"}}

  defp unit(value) when is_number(value) and value >= 0 and value <= 1, do: {:ok, value}
  defp unit(_), do: {:error, :probability_out_of_range}

  defp check_state_hash(%{"judgment_state" => state}, hash) when is_map(state) do
    if hash == SabrJev.Questions.state_hash(state), do: :ok, else: {:error, :state_hash_mismatch}
  end

  defp check_state_hash(_, _), do: {:error, :state_hash_mismatch}

  defp noul_id(%{"role" => role}), do: SabrJev.Questions.noul_id(role)
  defp noul_id(_), do: SabrJev.Questions.noul_id("batter")

  defp append(ledger, cohort, entry, at) do
    prev = prev_hash(ledger)

    body =
      entry
      |> Map.merge(%{
        "captured_at" => DateTime.to_iso8601(at),
        "cutoff" => cohort.cutoff_iso,
        "baseline" => cohort.baseline,
        "previous_hash" => prev,
        "ledger_limit" => @ledger_limit
      })

    line = Jason.encode!(Map.put(body, "line_hash", h(prev, body)))
    {:ok, ledger ++ [line], line}
  end

  defp card_year(id) do
    case Regex.run(~r/:(\d{4})$/, id) do
      [_, year] -> String.to_integer(year)
      _ -> nil
    end
  end

  defp prev_hash([]), do: "genesis"

  defp prev_hash(ledger) do
    case ledger |> List.last() |> Jason.decode!() |> Map.fetch("line_hash") do
      {:ok, hash} -> hash
      :error -> "genesis"
    end
  end

  defp h(prev, body) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, prev <> Jason.encode!(body)), case: :lower)
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, e} when is_map(e) -> {:ok, e}
      _ -> {:error, :corrupt_ledger_line}
    end
  end

  defp check_genesis(%{"previous_hash" => "genesis"} = e), do: check_hash("genesis", e)
  defp check_genesis(_), do: {:error, :ledger_missing_genesis}

  defp check_chain([one]) do
    with {:ok, entry} <- decode_line(one),
         :ok <- check_genesis(entry) do
      :ok
    end
  end

  defp check_chain(ledger) do
    with :ok <- decode_all(ledger) do
      ledger
      |> Enum.map(&Jason.decode!/1)
      |> Enum.reduce_while({:ok, "genesis"}, fn e, {:ok, prev} ->
        with :ok <- check_link(e, prev), :ok <- check_hash(prev, e) do
          {:cont, {:ok, e["line_hash"]}}
        else
          err -> {:halt, err}
        end
      end)
      |> case do
        {:ok, _} -> :ok
        err -> err
      end
    end
  end

  defp decode_all(ledger) do
    Enum.reduce_while(ledger, :ok, fn line, :ok ->
      case Jason.decode(line) do
        {:ok, decoded} when is_map(decoded) -> {:cont, :ok}
        _ -> {:halt, {:error, :corrupt_ledger_line}}
      end
    end)
  end

  defp check_link(%{"previous_hash" => p}, p), do: :ok
  defp check_link(_, _), do: {:error, :ledger_tampered}

  defp check_hash(prev, entry) do
    case Map.pop(entry, "line_hash") do
      {hash, body} when is_binary(hash) ->
        if hash == h(prev, body), do: :ok, else: {:error, :ledger_tampered}

      _ ->
        {:error, :ledger_tampered}
    end
  end
end
