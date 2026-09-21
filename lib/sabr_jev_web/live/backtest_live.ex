defmodule SabrJevWeb.BacktestLive do
  use SabrJevWeb, :live_view

  alias SabrJev.Backtest
  alias SabrJev.Catalog

  @impl true
  def mount(_params, _session, socket) do
    load =
      case Catalog.load() do
        {:ok, catalog} -> Backtest.run(catalog)
        {:error, reason} -> {:error, reason}
      end

    case load do
      {:ok, report} ->
        {:ok,
         assign(socket,
           load_error: nil,
           report: report,
           summary_rows: summary_rows(report),
           bucket_rows: bucket_rows(report),
           note: note(report)
         )}

      {:error, reason} ->
        {:ok,
         assign(socket,
           load_error: inspect(reason),
           report: nil,
           summary_rows: [],
           bucket_rows: [],
           note: nil
         )}
    end
  end

  defp summary_rows(%{by_role: by_role, all: all}) do
    rows = Enum.map(by_role, fn {role, s} -> %{"role" => role, "s" => s} end)
    rows ++ [%{"role" => "all", "s" => all}]
  end

  defp bucket_rows(%{by_role: by_role}) do
    for {role, s} <- by_role, b <- s["buckets"], do: %{role: role, bucket: b}
  end

  defp note(%{coverage: coverage}) do
    "Coverage: #{coverage["scored"]} of #{coverage["cards"]} cards scored, " <>
      "#{coverage["excluded"]} excluded (no recording, no oracle, or no recorded Noul). " <>
      "Lower Brier is better; edge is baseline minus model."
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="backtest">
      <header>
        <p class="eyebrow">Backtest</p>
        <h1>Projected vs actual</h1>
        <p>
          Every recorded next-season prediction, scored against the realized
          outcome from the frozen source. Retrospective plumbing, not
          prospective validation: treat calibration as pending until the
          2026→2027 capture completes.
        </p>
        <nav aria-label="Backtest">
          <a href={~p"/"}>Workbench</a>
          {" | "}
          <a href={~p"/storylines"}>Storylines</a>
          {" | "}
          <a href={~p"/backtest"} aria-current="page">Backtest</a>
          {" | "}
          <a href={~p"/about"}>About &amp; formulas</a>
        </nav>
      </header>

      <section :if={@load_error} class="empty-state">
        <h2>Season data unavailable</h2>
        <p><code>{@load_error}</code></p>
      </section>

      <section :if={@report} aria-labelledby="summary-h">
        <h2 id="summary-h">Score summary</h2>
        <table class="probabilities" aria-label="Brier summary">
          <thead>
            <tr>
              <th scope="col">Role</th>
              <th scope="col">N</th>
              <th scope="col">Model Brier (lower is better)</th>
              <th scope="col">Baseline Brier (0.5)</th>
              <th scope="col">Edge</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @summary_rows}>
              <th scope="row">{row["role"]}</th>
              <td>{row["s"]["n"]}</td>
              <td>{num(row["s"]["brier"])}</td>
              <td>{num(row["s"]["baseline_brier"])}</td>
              <td>
                {edge(row["s"])}
                <span :if={no_edge?(row["s"])} class="provisional">
                  no edge claimed
                </span>
              </td>
            </tr>
          </tbody>
        </table>
        <p class="lens-note">
          {@note}
        </p>
      </section>

      <section :if={@report} aria-labelledby="bucket-h">
        <h2 id="bucket-h">Reliability buckets</h2>
        <table class="probabilities" aria-label="Reliability buckets">
          <thead>
            <tr>
              <th scope="col">Role</th>
              <th scope="col">P bucket</th>
              <th scope="col">N</th>
              <th scope="col">Mean P</th>
              <th scope="col">Actual rate</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @bucket_rows}>
              <th scope="row">{row.role}</th>
              <td>{row.bucket["range"]}</td>
              <td>{row.bucket["n"]}</td>
              <td>{num(row.bucket["mean_p"])}</td>
              <td>{num(row.bucket["rate"])}</td>
            </tr>
          </tbody>
        </table>
      </section>

      <section :if={@report} aria-labelledby="pair-h">
        <h2 id="pair-h">Every scored prediction</h2>
        <table class="probabilities" aria-label="Scored predictions">
          <thead>
            <tr>
              <th scope="col">Card</th>
              <th scope="col">Projected</th>
              <th scope="col">Actual</th>
              <th scope="col">Loss</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={pair <- @report.pairs}>
              <th scope="row"><.link navigate={~p"/?card=#{pair.card_id}"}>{pair.card_id}</.link></th>
              <td>{num(pair.probability)}</td>
              <td>{actual(pair.label)}</td>
              <td>{num(loss(pair))}</td>
            </tr>
          </tbody>
        </table>
      </section>

      <footer>
        <p>
          Data source: <a href="https://sabr.org/lahman-database/">Lahman Baseball Database</a>.
          no Fangraphs scrape in v1. No Retrosheet data in v1.
        </p>
      </footer>
    </main>
    """
  end

  defp actual(true), do: "happened"
  defp actual(false), do: "didn't"

  defp loss(%{probability: p, label: true}), do: (1.0 - p) * (1.0 - p)
  defp loss(%{probability: p, label: false}), do: p * p

  defp edge(s) when is_map(s) do
    case {s["brier"], s["baseline_brier"]} do
      {b, bb} when is_number(b) and is_number(bb) -> num(bb - b)
      _ -> "—"
    end
  end

  defp no_edge?(s) when is_map(s) do
    case s["brier"] do
      b when is_number(b) -> b >= s["baseline_brier"]
      _ -> true
    end
  end

  defp num(nil), do: "unavailable"
  defp num(v) when is_number(v), do: :erlang.float_to_binary(v * 1.0, decimals: 3)
end
