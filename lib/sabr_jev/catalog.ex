defmodule SabrJev.Catalog do
  @moduledoc """
  Trusted card boundary between the frozen ETL artifact and any judgment use.

  Every card exposed here has passed the exact outer contract before any
  caller may hand it to `SabrJev.Questions`, `SabrJev.Judgments`, or
  `SabrJev.Latch`:

  - exact outer keys, no unknown keys at any level;
  - `id` is exactly `"<role>:<player_id>:<year>"`;
  - outer `metrics` equal `judgment_state.metrics` for every shared field;
  - batter `pa` / pitcher `ip` equals `sample.value`;
  - oracle/state/sample consistency via `SabrJev.Questions.for_card/1`.

  Callers must use only the cards returned by `load/1`. Never construct a
  card by hand and never bypass this loader.
  """

  alias SabrJev.{Judgments, Latch, Questions}

  @schema_version 1
  @outer_keys ~w(id role player_id player_name year metrics sample warnings judgment_state oracle)
  @provenance_keys ~w(manifest_sha256 sources weights latest_season license license_url
    notice_url formula_version scope purpose oracle_policy)
  # Frozen-contract mirroring: these tables intentionally duplicate the
  # allowlists in SabrJev.Questions so each boundary validates independently.
  # If either copy changes, both must change together.
  @batter_metric_keys ~w(pa obp slg ops iso babip bb_pct k_pct woba ops_plus
    league_obp league_slg park_adjustment)
  @pitcher_metric_keys ~w(ip era fip k_bb_pct hr_per_9 bb_per_9 k_per_9 league_cfip)
  @minimums %{"batter" => 200, "pitcher" => 50}
  @units %{"batter" => "PA", "pitcher" => "IP"}
  @count_keys %{"batter" => "pa", "pitcher" => "ip"}

  @spec default_path() :: Path.t()
  def default_path, do: "priv/data/cards.json"

  @spec recordings_dir() :: Path.t()
  def recordings_dir, do: "priv/jev/recordings"

  @spec recording_path(String.t()) :: Path.t()
  def recording_path(card_id) when is_binary(card_id) do
    Path.join(recordings_dir(), String.replace(card_id, ":", "--") <> ".json")
  end

  @spec load(Path.t()) :: {:ok, map()} | {:error, term()}
  def load(path \\ default_path()) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      validate_catalog(decoded)
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:invalid_json, Exception.message(error)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec load!(Path.t()) :: map()
  def load!(path \\ default_path()) do
    case load(path) do
      {:ok, catalog} -> catalog
      {:error, reason} -> raise "invalid catalog #{path}: #{inspect(reason)}"
    end
  end

  @spec cards(map()) :: [map()]
  def cards(%{"cards" => cards}), do: cards

  @spec get(map(), String.t()) :: {:ok, map()} | {:error, :unknown_card}
  def get(%{"cards" => cards}, id) when is_binary(id) do
    case Enum.find(cards, &(&1["id"] == id)) do
      nil -> {:error, :unknown_card}
      card -> {:ok, card}
    end
  end

  def get(_, _), do: {:error, :unknown_card}

  @spec roles(map()) :: [String.t()]
  def roles(%{"cards" => cards}) do
    cards |> Enum.map(& &1["role"]) |> Enum.uniq() |> Enum.sort()
  end

  @spec for_role(map(), String.t()) :: [map()]
  def for_role(%{"cards" => cards}, role) when is_binary(role) do
    Enum.filter(cards, &(&1["role"] == role))
  end

  @doc """
  Loads the immutable recording for a catalog card and validates it against
  that exact card. Returns `{:error, :no_recording}` when no file exists so
  callers render an honest empty judgment instead of inventing one.
  """
  @spec load_recording(map()) :: {:ok, map()} | {:error, term()}
  def load_recording(%{"id" => _id} = card) do
    with :ok <- validate_card(card) do
      path = recording_path(card["id"])

      case File.read(path) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, record} ->
              Judgments.validate_record(record, card)

            {:error, %Jason.DecodeError{} = error} ->
              {:error, {:invalid_json, Exception.message(error)}}

            {:error, reason} ->
              {:error, reason}
          end

        {:error, :enoent} ->
          {:error, :no_recording}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def load_recording(_), do: {:error, {:invalid_card, "card must be a map"}}

  @doc """
  Fail-closed judgment bundle for a catalog card: the validated recording
  plus its latch routing. `{:error, :no_recording}` is not a failure of the
  card, only the absence of a judgment.
  """
  @spec judgment(map()) :: {:ok, map()} | {:error, term()}
  def judgment(%{} = card) do
    with {:ok, record} <- load_recording(card),
         {:ok, decision} <- Latch.route(record["answers"], card) do
      {:ok, %{record: record, decision: decision}}
    end
  end

  defp validate_catalog(%{"schema_version" => @schema_version} = catalog) do
    with :ok <- exact_keys(catalog, ["cards", "provenance", "schema_version"], "catalog"),
         :ok <- validate_provenance(catalog["provenance"]),
         :ok <- validate_card_list(catalog["cards"]) do
      {:ok, catalog}
    end
  end

  defp validate_catalog(%{"schema_version" => other}),
    do: {:error, {:schema_version_mismatch, other}}

  defp validate_catalog(_), do: {:error, :invalid_catalog}

  defp validate_provenance(provenance) when is_map(provenance) do
    exact_keys(provenance, @provenance_keys, "provenance")
  end

  defp validate_provenance(_), do: {:error, :invalid_provenance}

  defp validate_card_list(cards) when is_list(cards) and length(cards) > 0 do
    with :ok <- validate_each(cards),
         :ok <- validate_ids_unique(cards),
         :ok <- validate_sorted(cards) do
      :ok
    end
  end

  defp validate_card_list(_), do: {:error, :invalid_card_list}

  defp validate_each(cards) do
    Enum.reduce_while(cards, :ok, fn card, :ok ->
      case validate_card(card) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_ids_unique(cards) do
    ids = Enum.map(cards, &if(is_map(&1), do: &1["id"], else: nil))

    if length(Enum.uniq(ids)) == length(ids),
      do: :ok,
      else: {:error, :duplicate_card_ids}
  end

  defp validate_sorted(cards) do
    ids = Enum.map(cards, & &1["id"])

    if ids == Enum.sort(ids),
      do: :ok,
      else: {:error, :cards_not_sorted}
  end

  @spec validate_card(map()) :: :ok | {:error, term()}
  def validate_card(card) when is_map(card) do
    with :ok <- exact_keys(card, @outer_keys, "card"),
         {:ok, role} <- validate_identity(card),
         :ok <- validate_metrics(card["metrics"], role),
         :ok <- validate_sample(card["sample"], role),
         :ok <- validate_warnings(card["warnings"]),
         :ok <- validate_metric_state_equality(card, role),
         :ok <- validate_count_sample_equality(card, role),
         {:ok, _questions} <- Questions.for_card(card) do
      :ok
    end
  end

  def validate_card(_), do: {:error, {:invalid_card, "card must be a map"}}

  defp validate_identity(card) do
    role = card["role"]
    player_id = card["player_id"]
    year = card["year"]

    with true <- role in ["batter", "pitcher"] || {:error, {:invalid_card, "invalid card role"}},
         true <-
           (is_binary(player_id) and byte_size(player_id) > 0 and
              not String.contains?(player_id, ":")) ||
             {:error, {:invalid_card, "invalid player_id"}},
         true <-
           (is_binary(card["player_name"]) and byte_size(card["player_name"]) > 0) ||
             {:error, {:invalid_card, "invalid player_name"}},
         true <- is_integer(year) || {:error, {:invalid_card, "year must be an integer"}},
         true <-
           card["id"] == "#{role}:#{player_id}:#{year}" ||
             {:error, {:invalid_card, "id must be role:player_id:year"}} do
      {:ok, role}
    end
  end

  defp validate_metrics(metrics, role) when is_map(metrics) do
    expected = if role == "batter", do: @batter_metric_keys, else: @pitcher_metric_keys

    with :ok <- exact_keys(metrics, expected, "metrics") do
      Enum.reduce_while(metrics, :ok, fn
        {key, value}, :ok when is_binary(key) ->
          if is_nil(value) or finite_number?(value),
            do: {:cont, :ok},
            else:
              {:halt, {:error, {:invalid_card, "metric #{inspect(key)} must be finite or null"}}}

        {key, _}, :ok ->
          {:halt, {:error, {:invalid_card, "metric key #{inspect(key)} must be a string"}}}
      end)
    end
  end

  defp validate_metrics(_, _), do: {:error, {:invalid_card, "metrics must be a map"}}

  defp validate_sample(sample, role) when is_map(sample) do
    with :ok <- exact_keys(sample, ~w(qualified minimum value unit), "sample"),
         true <-
           sample["minimum"] == @minimums[role] ||
             {:error, {:invalid_card, "wrong sample minimum"}},
         true <- sample["unit"] == @units[role] || {:error, {:invalid_card, "wrong sample unit"}},
         true <-
           (is_nil(sample["value"]) or (finite_number?(sample["value"]) and sample["value"] >= 0)) ||
             {:error, {:invalid_card, "sample value must be finite, nonnegative, or null"}},
         true <-
           is_boolean(sample["qualified"]) ||
             {:error, {:invalid_card, "qualified must be boolean"}},
         true <-
           sample["qualified"] ==
             (not is_nil(sample["value"]) and sample["value"] >= @minimums[role]) ||
             {:error, {:invalid_card, "qualified disagrees with sample value"}} do
      :ok
    end
  end

  defp validate_sample(_, _), do: {:error, {:invalid_card, "sample must be a map"}}

  defp validate_warnings(warnings) when is_list(warnings) do
    if Enum.all?(warnings, &is_binary/1),
      do: :ok,
      else: {:error, {:invalid_card, "warnings must be strings"}}
  end

  defp validate_warnings(_), do: {:error, {:invalid_card, "warnings must be a list"}}

  # The outer card and the allowlisted judgment state must carry the same
  # numbers: Judgments receives only the state, so any drift between the two
  # would let the UI show numbers Jev never saw.
  defp validate_metric_state_equality(%{"metrics" => outer, "judgment_state" => state}, _role)
       when is_map(outer) and is_map(state) do
    if is_map(state["metrics"]) and outer == state["metrics"],
      do: :ok,
      else: {:error, {:invalid_card, "outer and judgment-state metrics disagree"}}
  end

  defp validate_metric_state_equality(_, _),
    do: {:error, {:invalid_card, "outer and judgment-state metrics disagree"}}

  # Batter PA / pitcher IP is the sample value: the deterministic minimum gate
  # in code reads the sample, so the count it gates on must be the same number.
  defp validate_count_sample_equality(
         %{"metrics" => metrics, "sample" => sample},
         role
       )
       when is_map(metrics) and is_map(sample) do
    count_key = @count_keys[role]

    if metrics[count_key] == sample["value"],
      do: :ok,
      else: {:error, {:invalid_card, "#{count_key} disagrees with sample value"}}
  end

  defp validate_count_sample_equality(_, _),
    do: {:error, {:invalid_card, "count disagrees with sample value"}}

  defp exact_keys(map, expected, label) when is_map(map) do
    if Enum.sort(Map.keys(map)) == Enum.sort(expected),
      do: :ok,
      else: {:error, {:invalid_card, "#{label} keys do not match the frozen contract"}}
  end

  defp finite_number?(value) when is_integer(value), do: true

  defp finite_number?(value) when is_float(value) do
    <<_sign::1, exponent::11, _fraction::52>> = <<value::float>>
    exponent != 2047
  end

  defp finite_number?(_), do: false
end
