defmodule Mix.Tasks.Sabr.Evaluate do
  use Mix.Task

  @shortdoc "Scores prospective outcomes without inventing missing labels"
  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [ledger: :string, outcomes: :string, report: :string, baseline: :string]
      )

    if rest != [] or invalid != [] do
      Mix.raise("invalid arguments; use --ledger --outcomes --report --baseline")
    end

    lines =
      opts
      |> Keyword.fetch!(:ledger)
      |> File.read!()
      |> String.trim()
      |> String.split("\n", trim: true)

    case SabrJev.Prospective.verify(lines) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("refusing to score ledger: #{inspect(reason)}")
    end

    parsed =
      Enum.map(lines, fn line ->
        case Jason.decode(line) do
          {:ok, %{"card_id" => id, "noul_id" => noul, "probability" => p, "cutoff" => cutoff} = e}
          when is_binary(noul) and is_number(p) and is_binary(cutoff) ->
            if e["mode"] != "prospective" do
              Mix.raise(
                "cannot score ledger line #{id}: not a prospective prediction " <>
                  "(mode: #{inspect(e["mode"])})"
              )
            end

            %{
              "card_id" => id,
              "noul_id" => noul,
              "probability" => p,
              "captured_at" => e["captured_at"],
              "cutoff" => cutoff,
              "mode" => "prospective",
              "baseline" => e["baseline"]
            }

          _ ->
            Mix.raise("cannot read ledger line: #{line}")
        end
      end)

    realized =
      case opts |> Keyword.fetch!(:outcomes) |> File.read!() |> Jason.decode!() do
        realized when is_map(realized) -> realized
        _ -> Mix.raise("outcomes file must decode to a JSON object keyed by card_id")
      end

    baseline = opts |> Keyword.fetch!(:baseline) |> Jason.decode!()
    check_baseline_binding!(parsed, baseline)
    check_cutoff_uniformity!(parsed)
    frozen_cutoff = ledger_cutoff(parsed)

    case SabrJev.Evaluation.score(parsed, realized, baseline: baseline) do
      {:error, reason} ->
        Mix.raise("cannot evaluate: #{inspect(reason)}")

      report ->
        report =
          Map.merge(report, %{
            status: "prospective, accuracy pending",
            mode: "prospective",
            ledger_limit: SabrJev.Prospective.ledger_limit(),
            cutoff: frozen_cutoff,
            baseline: baseline
          })

        File.write!(Keyword.fetch!(opts, :report), Jason.encode!(report, pretty: true))
    end
  end

  # Every line must come from one frozen cohort window, otherwise a ledger built
  # across source updates would silently mix cohorts. The library check in
  # SabrJev.Evaluation catches hash-valid mixed lines; this parse-time check
  # gives a clearer error before scoring even starts.
  defp check_cutoff_uniformity!(entries) do
    cutoffs = entries |> Enum.map(& &1["cutoff"]) |> Enum.uniq()

    if length(cutoffs) > 1 do
      Mix.raise("ledger mixes cohort cutoffs: #{Enum.join(Enum.sort(cutoffs), ", ")}")
    end
  end

  # The report must describe the cohort the ledger actually froze. Reading the
  # module's current cutoff would relabel an older ledger the moment the frozen
  # source pins move to the next season.
  defp ledger_cutoff([]), do: SabrJev.Prospective.cutoff_iso()
  defp ledger_cutoff([%{"cutoff" => cutoff} | _]), do: cutoff

  defp check_baseline_binding!(entries, baseline) do
    mismatched =
      Enum.filter(entries, fn
        %{"baseline" => entry_baseline} -> entry_baseline != baseline
        _ -> false
      end)

    if mismatched != [] do
      ids = mismatched |> Enum.map(& &1["card_id"]) |> Enum.join(", ")
      Mix.raise("ledger baseline does not match --baseline for: #{ids}")
    end
  end
end
