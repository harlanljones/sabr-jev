defmodule SabrJevWeb.StorylinesLive do
  use SabrJevWeb, :live_view

  alias SabrJev.{Catalog, Storylines}

  @lenses ["all", "breakout", "regression_risk"]

  @impl true
  def mount(_params, _session, socket) do
    case Catalog.load() do
      {:ok, catalog} ->
        {:ok,
         socket
         |> assign(:catalog, catalog)
         |> assign(:load_error, nil)
         |> assign(:lens, "all")
         |> assign(:rows, build_rows(catalog))}

      {:error, reason} ->
        {:ok,
         socket
         |> assign(:catalog, nil)
         |> assign(:load_error, inspect(reason))
         |> assign(:lens, "all")
         |> assign(:rows, [])}
    end
  end

  @impl true
  def handle_event("select-lens", %{"lens" => lens}, socket) when lens in @lenses do
    {:noreply, assign(socket, :lens, lens)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="storylines">
      <header>
        <p class="eyebrow">Storylines</p>
        <h1>What would the model have said?</h1>
        <p>
          Twenty famous recent seasons, each graded the way Sabr-Jev grades
          everything: precomputed numbers in, a typed verdict out. Pick a season
          you remember. See whether the numbers deserved your memory.
        </p>
        <nav aria-label="Storylines">
          <a href={~p"/"}>Workbench</a>
          {" | "}
          <a href={~p"/storylines"} aria-current="page">Storylines</a>
          {" | "}
          <a href={~p"/about"}>About &amp; formulas</a>
        </nav>
      </header>

      <section :if={@load_error} class="empty-state">
        <h2>Season data unavailable</h2>
        <p>The frozen card catalog failed to load.</p>
        <p><code>{@load_error}</code></p>
      </section>

      <section :if={!@load_error} aria-label="Storyline selection">
        <div role="group" aria-label="Lens">
          <button
            :for={lens <- lens_options()}
            type="button"
            phx-click="select-lens"
            phx-value-lens={lens}
            data-lens={lens}
            aria-pressed={@lens == lens}
            class={if(@lens == lens, do: "role-active", else: "role-idle")}
          >
            {lens_label(lens)}
          </button>
        </div>
        <p class="lens-note" data-lens-note="true">
          Showing {length(visible_rows(@rows, @lens))} of {length(@rows)} —
          verdicts are recorded judgments, never guesses.
        </p>
        <div id="storyline-list">
          <a
            :for={row <- visible_rows(@rows, @lens)}
            class="storyline"
            data-storyline={row.card["id"]}
            href={~p"/?#{%{card: row.card["id"]}}"}
          >
            <span class="season-tag">{row.card["year"]} · {row.team}</span>
            <span>
              <span class="who">{row.card["player_name"]}</span>
              <p class="hook">{row.hook}</p>
              <p class="nums">{headlines(row.card)}</p>
            </span>
            <span class="verdict {row.route}" data-verdict={row.route}>{verdict_label(row.route)}</span>
          </a>
        </div>
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

  defp build_rows(catalog) do
    cards = Map.new(Catalog.cards(catalog), &{&1["id"], &1})

    for entry <- Storylines.list(),
        {:ok, card} <- [Catalog.get(catalog, entry.card_id)],
        {:ok, %{decision: decision, record: record}} <- [Catalog.judgment(card)] do
      %{
        card: cards[entry.card_id],
        team: entry.team,
        hook: entry.hook,
        route: decision.route,
        read: get_in(record, ["answers", "season_read", "choice"])
      }
    end
  end

  defp visible_rows(rows, "all"), do: rows
  defp visible_rows(rows, lens), do: Enum.filter(rows, &(&1.read == lens))
  defp lens_label("all"), do: "All twenty"
  defp lens_label("breakout"), do: "Breakout check"
  defp lens_label("regression_risk"), do: "Regression watch"

  defp lens_options, do: @lenses

  defp verdict_label(:act), do: "act"
  defp verdict_label(:review), do: "review"
  defp verdict_label(:escalate), do: "set aside"

  defp headlines(%{"role" => "batter", "metrics" => m}) do
    "OPS+ (Sabr-Jev) #{fmt(m["ops_plus"])} · wOBA #{fmt(m["woba"])} · #{fmt(m["pa"])} PA"
  end

  defp headlines(%{"role" => "pitcher", "metrics" => m}) do
    "ERA #{fmt(m["era"])} · FIP #{fmt(m["fip"])} · #{fmt(m["ip"])} IP"
  end

  defp fmt(nil), do: "unavailable"
  defp fmt(value) when is_integer(value), do: Integer.to_string(value)
  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp fmt(value), do: to_string(value)
end
