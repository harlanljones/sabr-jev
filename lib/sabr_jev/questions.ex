defmodule SabrJev.Questions do
  @moduledoc "Frozen TypeSafe System One questions for season-card judgments."

  @season_read TypeSafeAPI.choice(
                 "Classify the season represented by the supplied precomputed numeric card. Do not calculate or infer any missing statistic.",
                 breakout:
                   "The supplied metrics jointly support an unusually strong positive season read.",
                 stable:
                   "The supplied metrics support a sustainable, broadly stable season read.",
                 regression_risk:
                   "The supplied metrics contain a meaningful regression-risk signal.",
                 small_sample: "The supplied sample is too small for a firm season read.",
                 other: "None of the listed readings is supported."
               )

  @confidence_in_signal TypeSafeAPI.score(
                          "How strong is the interpretive signal in the supplied precomputed metrics? Judge only the presented values; do not recompute sample qualification.",
                          [
                            {"weak",
                             "The metrics provide weak or conflicting interpretive evidence."},
                            {"moderate",
                             "The metrics provide a meaningful but not decisive signal."},
                            {"strong", "The metrics provide a strong and coherent signal."}
                          ]
                        )

  @batter_profile TypeSafeAPI.choice(
                    "Which batter profile is best supported by the supplied precomputed metrics?",
                    power: "Power production is the clearest feature.",
                    discipline: "Plate discipline is the clearest feature.",
                    contact: "Contact quality or contact frequency is the clearest feature.",
                    balanced: "No single tool dominates; the profile is balanced.",
                    other: "None of the listed profiles is supported."
                  )

  @pitcher_profile TypeSafeAPI.choice(
                     "Which pitcher profile is best supported by the supplied precomputed metrics?",
                     strikeout: "Strikeout ability is the clearest feature.",
                     command: "Walk suppression or command is the clearest feature.",
                     contact_management:
                       "Home-run or contact management is the clearest feature.",
                     balanced: "No single skill dominates; the profile is balanced.",
                     other: "None of the listed profiles is supported."
                   )

  @batter_noul TypeSafeAPI.noul(
                 "Based only on this season's supplied precomputed metrics, will OPS+ (Sabr-Jev) drop by at least 10 points in the next season?",
                 true: "A drop of at least 10 OPS+ (Sabr-Jev) points is likely.",
                 false: "A drop of at least 10 OPS+ (Sabr-Jev) points is not likely."
               )

  @pitcher_noul TypeSafeAPI.noul(
                  "Based only on this season's supplied precomputed metrics, will FIP rise by at least 0.50 in the next season?",
                  true: "A rise of at least 0.50 FIP is likely.",
                  false: "A rise of at least 0.50 FIP is not likely."
                )

  @minimums %{"batter" => 200, "pitcher" => 50}
  @sample_units %{"batter" => "PA", "pitcher" => "IP"}
  @metric_keys %{
    "batter" =>
      ~w(pa obp slg ops iso babip bb_pct k_pct woba ops_plus league_obp league_slg park_adjustment),
    "pitcher" => ~w(ip era fip k_bb_pct hr_per_9 bb_per_9 k_per_9 league_cfip)
  }

  # The frozen next-season Noul belongs to exactly one question per role. The
  # prospective ledger, the capture task, and the evaluator all resolve the same
  # two constants here so the spelling can never drift between them.
  @spec noul_id(String.t()) :: String.t()
  def noul_id("pitcher"), do: "fip_rise_ge_0_50_next"
  def noul_id(_role), do: "ops_plus_drop_ge_10_next"

  @spec role_for_noul_id(String.t()) :: String.t()
  def role_for_noul_id("fip_rise_ge_0_50_next"), do: "pitcher"
  def role_for_noul_id(_noul_id), do: "batter"

  @spec for_card(map()) :: {:ok, keyword()} | {:error, term()}
  def for_card(card), do: for_card(card, [])

  # `mode: :prospective` asks the next-season Noul before the outcome season
  # exists, which is the only way the enrollable cohort can carry a prediction.
  # The frozen Noul definition is shared between modes: only the marker check
  # differs, so the ledger's noul_id stays comparable across both.
  @spec for_card(map(), keyword()) :: {:ok, keyword()} | {:error, term()}
  def for_card(card, opts) when is_map(card) and is_list(opts) do
    with {:ok, mode} <- validate_mode(Keyword.get(opts, :mode, :retrospective)),
         {:ok, role, _state} <- validate_card_state(card),
         {:ok, include_noul?} <- noul_for(card, role, mode) do
      questions = [
        season_read: @season_read,
        confidence_in_signal: @confidence_in_signal,
        profile: profile(role)
      ]

      {:ok, if(include_noul?, do: questions ++ [noul(role)], else: questions)}
    end
  end

  def for_card(_, _), do: {:error, {:invalid_card, "card must be a map"}}

  @spec hash(keyword()) :: String.t()
  def hash(questions) when is_list(questions) do
    encoded =
      Enum.map(questions, fn {id, question} ->
        %{"id" => Atom.to_string(id), "question" => question.__struct__.encode(question)}
      end)

    digest("sabr-jev/questions/v1\n", encoded)
  end

  @spec state_hash(map()) :: String.t()
  def state_hash(state) when is_map(state), do: digest("sabr-jev/state/v1\n", state)

  @spec validate_state(map()) :: :ok | {:error, term()}
  def validate_state(state) when is_map(state) do
    with :ok <- exact_keys(state, ["metrics", "role", "sample"], "state"),
         role when role in ["batter", "pitcher"] <- state["role"],
         :ok <- validate_metrics(state["metrics"], role),
         :ok <- validate_sample(state["sample"], role) do
      :ok
    else
      role when is_binary(role) -> {:error, {:invalid_state, "unsupported role #{inspect(role)}"}}
      nil -> {:error, {:invalid_state, "state role is missing"}}
      {:error, _} = error -> error
      other -> {:error, {:invalid_state, "invalid role #{inspect(other)}"}}
    end
  end

  def validate_state(_), do: {:error, {:invalid_state, "judgment_state must be a map"}}

  defp validate_card_state(card) do
    role = card["role"]
    state = card["judgment_state"]

    with true <- role in ["batter", "pitcher"] || {:error, {:invalid_card, "invalid card role"}},
         true <- is_map(state) || {:error, {:invalid_state, "judgment_state must be a map"}},
         true <- state["role"] == role || {:error, {:role_mismatch, {role, state["role"]}}},
         :ok <- validate_state(state),
         :ok <- validate_card_sample(card["sample"], state["sample"], role) do
      {:ok, role, state}
    end
  end

  defp validate_card_sample(sample, state_sample, role) when is_map(sample) do
    minimum = @minimums[role]
    value = sample["value"]

    with :ok <- exact_card_sample_keys(sample),
         true <- sample["minimum"] == minimum || {:error, {:invalid_card, "wrong sample minimum"}},
         true <-
           sample["unit"] == @sample_units[role] || {:error, {:invalid_card, "wrong sample unit"}},
         true <-
           (is_nil(value) or (finite_number?(value) and value >= 0)) ||
             {:error, {:invalid_card, "sample value must be finite, nonnegative, or null"}},
         true <-
           is_boolean(sample["qualified"]) ||
             {:error, {:invalid_card, "qualified must be boolean"}},
         true <-
           sample["qualified"] == (not is_nil(value) and value >= minimum) ||
             {:error, {:invalid_card, "qualified disagrees with sample value"}},
         true <-
           state_sample == %{"minimum" => minimum, "value" => value} ||
             {:error, {:invalid_card, "outer and judgment-state samples disagree"}} do
      :ok
    end
  end

  defp validate_card_sample(_, _, _), do: {:error, {:invalid_card, "sample must be a map"}}

  defp exact_card_sample_keys(sample) do
    expected = ~w(qualified minimum value unit)

    if Enum.sort(Map.keys(sample)) == Enum.sort(expected),
      do: :ok,
      else: {:error, {:invalid_card, "sample keys must be exactly #{inspect(expected)}"}}
  end

  defp validate_mode(:retrospective), do: {:ok, :retrospective}
  defp validate_mode(:prospective), do: {:ok, :prospective}
  defp validate_mode(other), do: {:error, {:invalid_mode, other}}

  defp noul_for(card, role, :retrospective), do: validate_oracle_marker(card, role)
  defp noul_for(card, role, :prospective), do: validate_prospective_marker(card, role)

  # A prospective prediction is asked before the outcome season exists, so the
  # card carries no oracle. Everything else still holds: the signal being
  # predicted must be present and the sample must be qualified, otherwise the
  # question would be unanswerable rather than merely uncertain.
  defp validate_prospective_marker(card, role) do
    metric = if role == "batter", do: "ops_plus", else: "fip"
    current_value = card["judgment_state"]["metrics"][metric]

    with :ok <- no_realized_oracle(card),
         true <-
           card["sample"]["qualified"] ||
             {:error, {:invalid_prospective_marker, "current sample must be qualified"}},
         true <-
           finite_number?(current_value) ||
             {:error, {:invalid_prospective_marker, "current target metric must be available"}} do
      {:ok, true}
    end
  end

  defp no_realized_oracle(%{"oracle" => nil}), do: :ok

  defp no_realized_oracle(_card) do
    {:error,
     {:invalid_prospective_marker, "a prospective prediction cannot carry a realized T+1 oracle"}}
  end

  defp validate_oracle_marker(card, role) do
    expected = role |> noul() |> elem(0) |> Atom.to_string()
    metric = if role == "batter", do: "ops_plus", else: "fip"
    current_value = card["judgment_state"]["metrics"][metric]

    case card["oracle"] do
      nil ->
        {:ok, false}

      oracle when is_map(oracle) ->
        with :ok <- exact_oracle_keys(oracle),
             true <-
               is_integer(card["year"]) ||
                 {:error, {:invalid_oracle_marker, "card year must be an integer"}},
             true <-
               oracle["year"] == card["year"] + 1 ||
                 {:error, {:invalid_oracle_marker, "oracle year must be T+1"}},
             true <-
               oracle["metric"] == metric ||
                 {:error, {:invalid_oracle_marker, "oracle metric does not match role"}},
             true <-
               oracle["target"] == expected ||
                 {:error, {:invalid_oracle_target, oracle["target"]}},
             true <-
               finite_number?(oracle["value"]) ||
                 {:error, {:invalid_oracle_marker, "oracle value must be finite"}},
             true <-
               is_boolean(oracle["label"]) ||
                 {:error, {:invalid_oracle_marker, "oracle label must be boolean"}},
             true <-
               card["sample"]["qualified"] ||
                 {:error, {:invalid_oracle_marker, "current sample must be qualified"}},
             true <-
               finite_number?(current_value) ||
                 {:error, {:invalid_oracle_marker, "current target metric must be available"}},
             true <-
               oracle["label"] == oracle_label(role, current_value, oracle["value"]) ||
                 {:error, {:invalid_oracle_marker, "oracle label disagrees with target formula"}} do
          # The exact oracle card has no T+1 sample field. Pinned ETL establishes
          # next-season qualification before creating this artifact.
          {:ok, true}
        end

      _ ->
        {:error, {:invalid_oracle_marker, "oracle must be nil or carry the frozen target"}}
    end
  end

  defp oracle_label("batter", current, next), do: current - next >= 10
  defp oracle_label("pitcher", current, next), do: next - current >= 0.50

  defp exact_oracle_keys(oracle) do
    expected = ~w(year metric value label target)

    if Enum.sort(Map.keys(oracle)) == Enum.sort(expected),
      do: :ok,
      else: {:error, {:invalid_oracle_marker, "oracle keys must be exactly #{inspect(expected)}"}}
  end

  defp validate_metrics(metrics, role) when is_map(metrics) do
    with :ok <- exact_keys(metrics, @metric_keys[role], "metrics") do
      Enum.reduce_while(metrics, :ok, fn
        {key, value}, :ok when is_binary(key) ->
          if is_nil(value) or finite_number?(value),
            do: {:cont, :ok},
            else:
              {:halt, {:error, {:invalid_state, "metric #{inspect(key)} must be finite or null"}}}

        {key, _value}, :ok ->
          {:halt, {:error, {:invalid_state, "metric key #{inspect(key)} must be a string"}}}
      end)
    end
  end

  defp validate_metrics(_, _),
    do: {:error, {:invalid_state, "metrics must be a non-empty numeric map"}}

  defp validate_sample(sample, role) when is_map(sample) do
    with :ok <- exact_keys(sample, ["minimum", "value"], "sample"),
         true <-
           sample["minimum"] == @minimums[role] ||
             {:error, {:invalid_state, "wrong sample minimum"}},
         true <-
           (is_nil(sample["value"]) or finite_number?(sample["value"])) ||
             {:error, {:invalid_state, "sample value must be finite or null"}},
         true <-
           (is_nil(sample["value"]) or sample["value"] >= 0) ||
             {:error, {:invalid_state, "sample value must be nonnegative"}} do
      :ok
    end
  end

  defp validate_sample(_, _), do: {:error, {:invalid_state, "sample must be a numeric map"}}

  defp exact_keys(map, expected, label) do
    if Enum.sort(Map.keys(map)) == Enum.sort(expected),
      do: :ok,
      else: {:error, {:invalid_state, "#{label} keys must be exactly #{inspect(expected)}"}}
  end

  defp finite_number?(value) when is_integer(value), do: true

  defp finite_number?(value) when is_float(value) do
    <<_sign::1, exponent::11, _fraction::52>> = <<value::float>>
    exponent != 2047
  end

  defp finite_number?(_), do: false

  defp profile("batter"), do: @batter_profile
  defp profile("pitcher"), do: @pitcher_profile

  defp noul("batter"), do: {:ops_plus_drop_ge_10_next, @batter_noul}
  defp noul("pitcher"), do: {:fip_rise_ge_0_50_next, @pitcher_noul}

  defp digest(prefix, value) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, prefix <> canonical(value)), case: :lower)
  end

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {to_string(key), item} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(",", fn {key, item} -> Jason.encode!(key) <> ":" <> canonical(item) end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp canonical(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical/1) <> "]"

  defp canonical(value) when is_atom(value) and value not in [true, false, nil],
    do: Jason.encode!(Atom.to_string(value))

  defp canonical(value), do: Jason.encode!(value)
end
