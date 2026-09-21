defmodule Mix.Tasks.Sabr.Capture do
  use Mix.Task

  @shortdoc "Captures prospective Jev judgments before the outcome season"
  @requirements ["app.start"]
  @default_recordings "priv/jev/recordings"

  @impl Mix.Task
  def run(args, runtime_opts \\ []) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          catalog: :string,
          ledger: :string,
          baseline: :string,
          card: :keep,
          captured_at: :string
        ]
      )

    if rest != [] or invalid != [] do
      Mix.raise(
        "invalid arguments; use --catalog PATH --ledger PATH --baseline JSON [--captured-at ISO8601]"
      )
    end

    catalog_path = Keyword.fetch!(opts, :catalog)
    ledger_path = Keyword.fetch!(opts, :ledger)
    baseline = opts |> Keyword.fetch!(:baseline) |> Jason.decode!()
    requested = Keyword.get_values(opts, :card)
    at = captured_at!(opts, runtime_opts)
    catalog_reader = Keyword.get(runtime_opts, :catalog_reader, &default_catalog/1)

    record_reader =
      Keyword.get(runtime_opts, :record_reader, fn card ->
        read_record(card, Keyword.get(runtime_opts, :records_dir, @default_recordings))
      end)

    {:ok, cards} = catalog_reader.(catalog_path)
    selected = select(cards, requested)
    reject_duplicate_requests!(requested)
    now = normalize_time(at)
    cohort = SabrJev.Prospective.enroll(selected, baseline: baseline)
    existing = read_ledger(ledger_path)

    {ledger, lines} =
      Enum.reduce(selected, {existing, []}, fn card, {current, acc} ->
        record = record_for!(record_reader, card)

        case SabrJev.Prospective.capture(cohort, card, record, captured_at: now, ledger: current) do
          {:ok, updated, line} -> {updated, acc ++ [line]}
          {:error, reason} -> Mix.raise("cannot capture #{card["id"]}: #{inspect(reason)}")
        end
      end)

    case SabrJev.Prospective.verify(ledger) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("refusing to write ledger: #{inspect(reason)}")
    end

    if lines != [], do: write_ledger(ledger_path, ledger)

    for line <- lines do
      Mix.shell().info("captured #{Jason.decode!(line)["card_id"]}")
    end

    Mix.shell().info("ledger is local hash-chained only; it cannot prove external capture time")
  end

  defp write_ledger(path, ledger) do
    File.write!(path, Enum.map_join(ledger, "\n", & &1) <> "\n")
  end

  defp record_for!(reader, card) do
    case reader.(card) do
      {:ok, record} when is_map(record) -> record
      {:error, reason} -> Mix.raise("cannot read recording for #{card["id"]}: #{inspect(reason)}")
      other -> Mix.raise("record reader returned #{inspect(other)} for #{card["id"]}")
    end
  end

  defp select(cards, []), do: cards

  defp select(cards, ids) do
    by_id = Map.new(cards, &{&1["id"], &1})
    missing = Enum.reject(ids, &Map.has_key?(by_id, &1))
    if missing != [], do: Mix.raise("unknown card ids: #{Enum.join(missing, ", ")}")
    Enum.map(ids, &by_id[&1])
  end

  defp reject_duplicate_requests!(ids) do
    duplicates = ids -- Enum.uniq(ids)

    if duplicates != [] do
      Mix.raise("duplicate card ids: #{Enum.join(Enum.uniq(duplicates), ", ")}")
    end
  end

  defp captured_at!(opts, runtime_opts) do
    case {Keyword.get(opts, :captured_at), Keyword.get(runtime_opts, :captured_at)} do
      {nil, nil} ->
        Mix.raise("capture time is required; pass --captured-at ISO8601")

      {flag, nil} ->
        flag

      {nil, injected} ->
        injected

      {_flag, _injected} ->
        Mix.raise("pass capture time once, not both --captured-at and harness injection")
    end
  end

  defp normalize_time(%DateTime{} = at), do: at

  defp normalize_time(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, 0} -> dt
      _ -> Mix.raise("invalid captured_at")
    end
  end

  defp default_catalog(path) do
    case File.read(path) do
      {:ok, bytes} ->
        case Jason.decode(bytes) do
          {:ok, %{"cards" => cards}} -> {:ok, cards}
          _ -> Mix.raise("catalog #{path} does not match schema version 1")
        end

      {:error, reason} ->
        Mix.raise("cannot read catalog #{path}: #{inspect(reason)}")
    end
  end

  # The real record source is the immutable Jev recording written by
  # `mix sabr.record`. A capture without a recorded judgment would be an
  # invented prediction, so a missing recording is a hard error naming the
  # exact path the operator must produce first.
  @doc false
  @spec read_record(map(), Path.t()) :: {:ok, map()}
  def read_record(card, dir \\ @default_recordings) do
    path = recording_path(card, dir)

    case File.read(path) do
      {:ok, bytes} ->
        with {:ok, record} <- decode_record(bytes, path),
             {:ok, probability} <- recorded_probability(record, card, path) do
          {:ok, Map.put(record, "probability", probability)}
        end

      {:error, :enoent} ->
        Mix.raise(
          "no recorded Jev judgment for #{card["id"]} at #{path}; " <>
            "record the judgment with `mix sabr.record --card #{card["id"]}` before capturing"
        )

      {:error, reason} ->
        Mix.raise("cannot read recording #{path}: #{inspect(reason)}")
    end
  end

  defp recording_path(card, dir) do
    role = card["role"] || "batter"
    "#{role}--#{card["player_id"]}--#{card["year"]}.json" |> then(&Path.join(dir, &1))
  end

  defp decode_record(bytes, path) do
    case Jason.decode(bytes) do
      {:ok, record} when is_map(record) -> {:ok, record}
      _ -> Mix.raise("recording #{path} is not a JSON object")
    end
  end

  # The Noul probability is read from the recorded typed answer. This is the
  # only number capture stores, and it is never recomputed here.
  # noul_id is resolved centrally so the spelling can never drift between
  # the capture task, the ledger, and the evaluator.
  defp recorded_probability(record, card, path) do
    noul_id = SabrJev.Questions.noul_id(card["role"] || "batter")

    case get_in(record, ["answers", noul_id]) do
      %{"noul" => probability} when is_number(probability) ->
        {:ok, probability}

      _ ->
        Mix.raise("recording #{path} has no #{noul_id} Noul answer")
    end
  end

  defp read_ledger(path) do
    case File.read(path) do
      {:ok, bytes} ->
        lines = String.split(String.trim(bytes), "\n", trim: true)

        case SabrJev.Prospective.verify(lines) do
          :ok -> lines
          {:error, reason} -> Mix.raise("ledger #{path} fails verification: #{inspect(reason)}")
        end

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Mix.raise("cannot read ledger #{path}: #{inspect(reason)}")
    end
  end
end
