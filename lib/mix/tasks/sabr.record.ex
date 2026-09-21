defmodule Mix.Tasks.Sabr.Record do
  use Mix.Task

  @shortdoc "Records immutable live Jev judgments for historical demo cards"
  @requirements ["app.start"]
  @default_catalog "priv/data/cards.json"
  @default_output "priv/jev/recordings"
  @credential_path Path.expand("~/.hermes/jev/key")
  @safe_id ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*(?::[A-Za-z0-9][A-Za-z0-9._-]*)*\z/

  @impl Mix.Task
  def run(args, runtime_opts \\ []) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [card: :keep, output: :string, catalog: :string],
        aliases: [c: :card, o: :output]
      )

    if rest != [] or invalid != [],
      do: Mix.raise("invalid arguments; use --card ID and/or --output DIR")

    catalog_path = opts[:catalog] || @default_catalog
    output_dir = opts[:output] || @default_output
    requested_ids = Keyword.get_values(opts, :card)
    reject_duplicate_selections!(requested_ids)

    catalog = read_catalog!(catalog_path)
    cards = select_cards!(catalog["cards"], requested_ids)
    destinations = prepare_destinations!(output_dir, cards)

    existing = destinations |> Enum.map(& &1.path) |> Enum.filter(&File.exists?/1)

    if existing != [],
      do: Mix.raise("refusing to replace immutable recordings: #{Enum.join(existing, ", ")}")

    lineage = %{
      "card_artifact" => catalog_path,
      "card_artifact_schema_version" => catalog["schema_version"],
      "provenance" => catalog["provenance"]
    }

    client_factory = Keyword.get(runtime_opts, :client_factory, &TypeSafeAPI.new/1)
    evaluator = Keyword.get(runtime_opts, :evaluator, &SabrJev.Judgments.evaluate/3)
    batch_writer = Keyword.get(runtime_opts, :batch_writer, &write_batch/1)
    client = client_factory.(api_key: api_key!())

    entries =
      Enum.map(destinations, fn destination ->
        case evaluator.(client, destination.card, source_lineage: lineage) do
          {:ok, record} ->
            Map.put(destination, :record, record)

          {:error, error} ->
            Mix.raise("Jev recording failed for #{destination.card["id"]}: #{safe_error(error)}")
        end
      end)

    case batch_writer.(entries) do
      :ok ->
        Enum.each(entries, fn entry ->
          Mix.shell().info("recorded #{entry.card["id"]} -> #{entry.path}")
        end)

      {:error, {:already_exists, paths}} ->
        Mix.raise("refusing to replace immutable recordings: #{Enum.join(paths, ", ")}")

      {:error, {:invalid_record, path, reason}} ->
        Mix.raise("refusing to write invalid recording #{path}: #{inspect(reason)}")

      {:error, {phase, path, reason, report}}
      when phase in [:stage_failed, :publish_failed] ->
        Mix.raise(
          "cannot #{phase_label(phase)} #{path}: #{format_file_error(reason)}" <>
            format_report(report)
        )

      {:error, {phase, path, reason}} when phase in [:stage_failed, :publish_failed] ->
        Mix.raise("cannot #{phase_label(phase)} #{path}: #{format_file_error(reason)}")

      {:error, {:cleanup_failed, report}} ->
        Mix.raise("cannot clean staging files: rollback incomplete" <> format_report(report))

      {:error, reason} ->
        Mix.raise("cannot write recordings: #{inspect(reason)}")
    end
  end

  @doc false
  @spec prepare_destinations(Path.t(), [map()]) ::
          {:ok, [map()]}
          | {:error, {:unsafe_card_id, term()} | {:destination_collision, String.t()}}
  def prepare_destinations(output_dir, cards) when is_binary(output_dir) and is_list(cards) do
    expanded_output = Path.expand(output_dir)

    with {:ok, destinations} <- build_destinations(output_dir, expanded_output, cards),
         :ok <- reject_destination_collisions(destinations) do
      {:ok, destinations}
    end
  end

  @doc false
  @spec write_batch([map()], keyword()) :: :ok | {:error, term()}
  def write_batch(entries, opts \\ []) when is_list(entries) do
    # Complete files are staged and atomically hard-linked without overwrite.
    # Runtime failures roll back the batch; no multi-file scheme can be atomic
    # across process or power loss without a directory/filesystem transaction.
    with {:ok, prepared} <- validate_and_encode(entries),
         :ok <- one_destination_directory(prepared),
         :ok <- reject_existing(prepared),
         :ok <- create_destination_directory(prepared),
         {:ok, staged} <- stage_all(prepared, opts) do
      publish_all(staged, opts)
    end
  end

  @doc false
  @spec write_immutable(Path.t(), map(), map()) :: :ok | {:error, :already_exists | term()}
  def write_immutable(path, record, card)
      when is_binary(path) and is_map(record) and is_map(card) do
    case write_batch([%{path: path, record: record, card: card}]) do
      :ok -> :ok
      {:error, {:already_exists, [_path]}} -> {:error, :already_exists}
      {:error, {:invalid_record, _path, reason}} -> {:error, reason}
      {:error, {_phase, _path, reason, _report}} -> {:error, reason}
      {:error, {_phase, _path, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reject_duplicate_selections!(ids) do
    duplicates =
      ids
      |> Enum.frequencies()
      |> Enum.filter(fn {_id, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    if duplicates != [], do: Mix.raise("duplicate card ids: #{Enum.join(duplicates, ", ")}")
  end

  defp prepare_destinations!(output_dir, cards) do
    case prepare_destinations(output_dir, cards) do
      {:ok, destinations} ->
        destinations

      {:error, {:unsafe_card_id, id}} ->
        Mix.raise("unsafe card id: #{inspect(id)}")

      {:error, {:destination_collision, filename}} ->
        Mix.raise("card ids collide at recording filename #{filename}")
    end
  end

  defp build_destinations(output_dir, expanded_output, cards) do
    Enum.reduce_while(cards, {:ok, []}, fn card, {:ok, destinations} ->
      id = card["id"]

      with :ok <- validate_id(id),
           filename = encode_filename(id),
           path = Path.join(output_dir, filename),
           :ok <- validate_containment(path, expanded_output) do
        {:cont, {:ok, [%{card: card, path: path, filename: filename} | destinations]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, destinations} -> {:ok, Enum.reverse(destinations)}
      error -> error
    end
  end

  defp validate_id(id) when is_binary(id) do
    segments = String.split(id, ":")

    if Regex.match?(@safe_id, id) and Enum.all?(segments, &(&1 not in [".", ".."])),
      do: :ok,
      else: {:error, {:unsafe_card_id, id}}
  end

  defp validate_id(id), do: {:error, {:unsafe_card_id, id}}

  defp encode_filename(id), do: String.replace(id, ":", "--") <> ".json"

  defp validate_containment(path, expanded_output) do
    expanded_path = Path.expand(path)

    if expanded_path != expanded_output and Path.dirname(expanded_path) == expanded_output,
      do: :ok,
      else: {:error, {:unsafe_card_id, Path.basename(path, ".json")}}
  end

  defp reject_destination_collisions(destinations) do
    case Enum.find(Enum.group_by(destinations, & &1.filename), fn {_filename, group} ->
           length(group) > 1
         end) do
      nil -> :ok
      {filename, _group} -> {:error, {:destination_collision, filename}}
    end
  end

  defp validate_and_encode(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, prepared} ->
      case SabrJev.Judgments.validate_record(entry.record, entry.card) do
        {:ok, validated} ->
          data = [Jason.encode_to_iodata!(validated, pretty: true), "\n"]
          {:cont, {:ok, [Map.put(entry, :data, data) | prepared]}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_record, entry.path, reason}}}
      end
    end)
    |> case do
      {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
      error -> error
    end
  end

  defp one_destination_directory([]), do: :ok

  defp one_destination_directory(entries) do
    directories = entries |> Enum.map(&Path.dirname(&1.path)) |> Enum.uniq()
    if length(directories) == 1, do: :ok, else: {:error, :multiple_destination_directories}
  end

  defp reject_existing(entries) do
    existing = entries |> Enum.map(& &1.path) |> Enum.filter(&File.exists?/1)
    if existing == [], do: :ok, else: {:error, {:already_exists, existing}}
  end

  defp create_destination_directory([]), do: :ok
  defp create_destination_directory([entry | _]), do: File.mkdir_p(Path.dirname(entry.path))

  defp stage_all(entries, opts) do
    entries
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, staged} ->
      case write_stage(entry, index, opts) do
        {:ok, staged_entry} ->
          emit(opts, {:stage_created, %{index: index, path: staged_entry.stage_path}})
          {:cont, {:ok, [staged_entry | staged]}}

        {:error, reason} ->
          report = rollback(owned_refs(staged), opts)
          {:halt, {:error, {:stage_failed, entry.path, normalize_exists(reason), report}}}
      end
    end)
    |> case do
      {:ok, staged} -> {:ok, Enum.reverse(staged)}
      error -> error
    end
  end

  defp publish_all(staged, opts) do
    staged
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, published} ->
      result =
        if Keyword.get(opts, :fail_at) == {:publish, index},
          do: {:error, :injected_failure},
          else: File.ln(entry.stage_path, entry.path)

      case result do
        :ok ->
          published_entry = Map.put(entry, :final_id, file_id(entry.path))
          emit(opts, {:published, %{index: index, path: entry.path}})
          {:cont, {:ok, [published_entry | published]}}

        {:error, reason} ->
          refs = owned_refs(published, :final) ++ owned_refs(staged, :stage)
          report = rollback(refs, opts)
          {:halt, {:error, {:publish_failed, entry.path, normalize_exists(reason), report}}}
      end
    end)
    |> case do
      {:ok, _published} ->
        report = rollback(owned_refs(staged, :stage), opts)

        if report == %{failures: [], conflicts: [], leftovers: []} do
          :ok
        else
          {:error, {:cleanup_failed, report}}
        end

      error ->
        error
    end
  end

  defp write_stage(entry, index, opts) do
    case Keyword.get(opts, :stage_path) do
      nil ->
        write_stage_unique(entry, index, opts)

      stage_fun when is_function(stage_fun, 2) ->
        write_stage_retry(entry, index, opts, stage_fun, 1)
    end
  end

  defp write_stage_unique(entry, index, opts) do
    stage_path = stage_path(entry.path)

    result =
      if Keyword.get(opts, :fail_at) == {:stage, index},
        do: {:error, :injected_failure},
        else: File.write(stage_path, entry.data, [:exclusive, :binary, :sync])

    case result do
      :ok ->
        {:ok,
         entry |> Map.put(:stage_path, stage_path) |> Map.put(:stage_id, file_id(stage_path))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A custom stage path callback may point at an existing file; that stale
  # file belongs to someone else, so it must be preserved and retried with a
  # fresh name instead of being overwritten.
  defp write_stage_retry(entry, index, opts, stage_fun, attempt) when attempt <= 100 do
    stage_path = stage_fun.(entry.path, attempt)

    result =
      if Keyword.get(opts, :fail_at) == {:stage, index},
        do: {:error, :injected_failure},
        else: File.write(stage_path, entry.data, [:exclusive, :binary, :sync])

    case result do
      :ok ->
        {:ok,
         entry |> Map.put(:stage_path, stage_path) |> Map.put(:stage_id, file_id(stage_path))}

      {:error, :eexist} ->
        write_stage_retry(entry, index, opts, stage_fun, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_stage_retry(_entry, _index, _opts, _stage_fun, _attempt), do: {:error, :eexist}

  defp emit(opts, event) do
    case Keyword.get(opts, :event_hook) do
      hook when is_function(hook, 1) -> hook.(event)
      _ -> :ok
    end
  end

  # Ownership-aware rollback: only files this invocation created are removed.
  # Identity is captured at creation time, so a path replaced out from under
  # the batch is reported as a conflict and preserved, while removal failures
  # are surfaced with leftover paths.
  defp owned_refs(entries, kind \\ :stage) do
    Enum.map(entries, fn entry ->
      case kind do
        :stage -> %{path: entry.stage_path, id: entry.stage_id}
        :final -> %{path: entry.path, id: entry.final_id}
      end
    end)
  end

  defp rollback(refs, opts) do
    remove = Keyword.get(opts, :remove, &File.rm/1)

    Enum.reduce(refs, %{failures: [], conflicts: [], leftovers: []}, fn ref, acc ->
      case {file_id(ref.path), ref.id} do
        {nil, _} ->
          acc

        {current, expected} when current == expected ->
          case remove.(ref.path) do
            :ok -> acc
            {:error, :enoent} -> acc
            {:error, reason} -> add_failure(acc, ref.path, reason)
          end

        {_current, _expected} ->
          conflict = %{path: ref.path, reason: :ownership_mismatch}
          %{acc | conflicts: acc.conflicts ++ [conflict], leftovers: acc.leftovers ++ [ref.path]}
      end
    end)
  end

  defp file_id(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, inode: inode, major_device: major, minor_device: minor}} ->
        {major, minor, inode}

      _ ->
        nil
    end
  end

  defp add_failure(acc, path, reason) do
    failure = %{path: path, reason: reason}

    %{
      acc
      | failures: acc.failures ++ [failure],
        leftovers: acc.leftovers ++ [path]
    }
  end

  defp stage_path(path) do
    unique = System.unique_integer([:positive, :monotonic])
    Path.join(Path.dirname(path), ".#{Path.basename(path)}.stage-#{unique}")
  end

  defp normalize_exists(:eexist), do: :already_exists
  defp normalize_exists(reason), do: reason

  defp read_catalog!(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{"schema_version" => 1, "cards" => cards, "provenance" => provenance} = catalog}
         when is_list(cards) and is_map(provenance) <- Jason.decode(bytes) do
      catalog
    else
      {:error, reason} -> Mix.raise("cannot read catalog #{path}: #{inspect(reason)}")
      _ -> Mix.raise("catalog #{path} does not match schema version 1")
    end
  end

  defp select_cards!(cards, []) do
    selected = Enum.filter(cards, &is_map(&1["oracle"]))
    if selected == [], do: Mix.raise("catalog has no historical T+1 demo cards"), else: selected
  end

  defp select_cards!(cards, ids) do
    by_id = Map.new(cards, &{&1["id"], &1})
    missing = Enum.reject(ids, &Map.has_key?(by_id, &1))
    if missing != [], do: Mix.raise("unknown card ids: #{Enum.join(missing, ", ")}")
    Enum.map(ids, &by_id[&1])
  end

  # Credential material is resolved only inside the running task and is never printed.
  defp api_key! do
    case present(System.get_env("TYPESAFE_API_KEY")) do
      nil -> read_local_key!()
      key -> key
    end
  end

  defp read_local_key! do
    case File.read(@credential_path) do
      {:ok, contents} ->
        present(contents) || Mix.raise("TypeSafe API credential file is empty")

      {:error, _reason} ->
        Mix.raise(
          "no TypeSafe API credential available; set TYPESAFE_API_KEY or configure the local Jev key"
        )
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      key -> key
    end
  end

  defp present(_), do: nil

  defp phase_label(:stage_failed), do: "stage"
  defp phase_label(:publish_failed), do: "publish"

  defp format_file_error(reason) when reason in [:injected_failure, :already_exists],
    do: Atom.to_string(reason)

  defp format_file_error(reason), do: :file.format_error(reason)

  defp format_report(%{failures: failures, conflicts: conflicts, leftovers: leftovers}) do
    parts = []

    parts =
      if failures == [] and conflicts == [] and leftovers == [] do
        parts
      else
        parts ++ ["; rollback incomplete"]
      end

    parts =
      Enum.reduce(failures, parts, fn %{path: path, reason: reason}, acc ->
        acc ++ ["; removal failed for #{path}: #{:file.format_error(reason)}"]
      end)

    parts =
      Enum.reduce(conflicts, parts, fn %{path: path, reason: reason}, acc ->
        acc ++ ["; ownership conflict at #{path}: #{reason} (preserved)"]
      end)

    parts =
      if leftovers == [] do
        parts
      else
        parts ++ ["; leftovers: #{Enum.join(leftovers, ", ")}"]
      end

    Enum.join(parts)
  end

  defp format_report(_), do: ""

  defp safe_error(%TypeSafeAPI.Error{type: type, status: status}),
    do: "#{type}#{if status, do: " (HTTP #{status})", else: ""}"

  defp safe_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_error(_reason), do: "unexpected failure"
end
