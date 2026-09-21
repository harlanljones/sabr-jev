defmodule SabrJevWeb.StorylinesLive do
  use SabrJevWeb, :live_view

  alias SabrJev.{Catalog, Storylines}

  @positions ["batter", "pitcher"]
  @verdicts ["act", "review", "escalate"]
  @empty_filter %{"position" => "all", "season" => "all", "verdict" => "all"}

  @impl true
  def mount(_params, _session, socket) do
    case Catalog.load() do
      {:ok, catalog} ->
        {:ok,
         socket
         |> assign(:catalog, catalog)
         |> assign(:load_error, nil)
         |> assign(:filter, @empty_filter)
         |> assign(:rows, build_rows(catalog))}

      {:error, reason} ->
        {:ok,
         socket
         |> assign(:catalog, nil)
         |> assign(:load_error, inspect(reason))
         |> assign(:filter, @empty_filter)
         |> assign(:rows, [])}
    end
  end

  @impl true
  def handle_event("filter", %{"filter" => params}, socket) when is_map(params) do
    filter =
      @empty_filter
      |> Map.merge(Map.take(socket.assigns.filter, Map.keys(@empty_filter)))
      |> Map.merge(sanitize_filter(params, socket.assigns.rows))
      |> coerce_empties(socket.assigns.rows)

    {:noreply, assign(socket, :filter, filter)}
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
        <form phx-change="filter" class="filters" data-filters="true" aria-label="Filter storylines">
          <label>
            Position
            <select name="filter[position]" data-facet="position">
              <option value="all" selected={@filter["position"] == "all"}>
                All ({facet_count(@rows, @filter, :position, "all")})
              </option>
              <option
                :for={position <- position_options()}
                value={position}
                selected={@filter["position"] == position}
                disabled={facet_count(@rows, @filter, :position, position) == 0}
              >
                {String.capitalize(position)} ({facet_count(@rows, @filter, :position, position)})
              </option>
            </select>
          </label>
          <label>
            Season
            <select name="filter[season]" data-facet="season">
              <option value="all" selected={@filter["season"] == "all"}>
                All ({facet_count(@rows, @filter, :season, "all")})
              </option>
              <option
                :for={season <- season_options(@rows)}
                value={season}
                selected={@filter["season"] == season}
                disabled={facet_count(@rows, @filter, :season, season) == 0}
              >
                {season} ({facet_count(@rows, @filter, :season, season)})
              </option>
            </select>
          </label>
          <label>
            Verdict
            <select name="filter[verdict]" data-facet="verdict">
              <option value="all" selected={@filter["verdict"] == "all"}>
                All ({facet_count(@rows, @filter, :verdict, "all")})
              </option>
              <option
                :for={verdict <- verdict_options()}
                value={verdict}
                selected={@filter["verdict"] == verdict}
                disabled={facet_count(@rows, @filter, :verdict, verdict) == 0}
              >
                {verdict_label(verdict)} ({facet_count(@rows, @filter, :verdict, verdict)})
              </option>
            </select>
          </label>
        </form>
        <p class="lens-note" data-filter-note="true">
          Showing {length(visible_rows(@rows, @filter))} of {length(@rows)} —
          verdicts are recorded judgments, never guesses.
        </p>
        <div id="storyline-list">
          <.link
            :for={row <- visible_rows(@rows, @filter)}
            class="storyline"
            data-storyline={row.card["id"]}
            navigate={~p"/?#{%{card: row.card["id"]}}"}
          >
            <span class="season-tag">{row.card["year"]} · {row.team}</span>
            <span>
              <span class="who">{row.card["player_name"]}</span>
              <p class="hook">{row.hook}</p>
              <p class="nums">{headlines(row.card)}</p>
            </span>
            <span class="verdict {row.route}" data-verdict={row.route}>{verdict_label(
              Atom.to_string(row.route)
            )}</span>
          </.link>
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

  defp position_options, do: @positions
  defp verdict_options, do: @verdicts

  defp season_options(rows) do
    rows |> Enum.map(&to_string(&1.card["year"])) |> Enum.uniq() |> Enum.sort()
  end

  defp visible_rows(rows, filter) do
    Enum.filter(rows, fn row ->
      (filter["position"] == "all" or row.card["role"] == filter["position"]) and
        (filter["season"] == "all" or to_string(row.card["year"]) == filter["season"]) and
        (filter["verdict"] == "all" or Atom.to_string(row.route) == filter["verdict"])
    end)
  end

  defp facet_count(rows, filter, facet, value) do
    others = Map.delete(filter, Atom.to_string(facet))

    Enum.count(rows, fn row ->
      Enum.all?(others, fn
        {"position", "all"} -> true
        {"position", position} -> row.card["role"] == position
        {"season", "all"} -> true
        {"season", season} -> to_string(row.card["year"]) == season
        {"verdict", "all"} -> true
        {"verdict", verdict} -> Atom.to_string(row.route) == verdict
      end) and facet_match?(facet, value, row)
    end)
  end

  defp facet_match?(_facet, "all", _row), do: true
  defp facet_match?(:position, position, row), do: row.card["role"] == position
  defp facet_match?(:season, season, row), do: to_string(row.card["year"]) == season
  defp facet_match?(:verdict, verdict, row), do: Atom.to_string(row.route) == verdict

  defp sanitize_filter(params, rows) do
    seasons = season_options(rows)

    %{}
    |> put_valid(params, "position", ["all" | @positions])
    |> put_valid(params, "season", ["all" | seasons])
    |> put_valid(params, "verdict", ["all" | @verdicts])
  end

  defp put_valid(acc, params, key, allowed) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) ->
        if value in allowed, do: Map.put(acc, key, value), else: acc

      _ ->
        acc
    end
  end

  defp coerce_empties(filter, rows) do
    Map.new(filter, fn {key, value} ->
      facet = String.to_existing_atom(key)

      if value != "all" and facet_count(rows, filter, facet, value) == 0 do
        {key, "all"}
      else
        {key, value}
      end
    end)
  end

  defp verdict_label("escalate"), do: "set aside"
  defp verdict_label("all"), do: "All verdicts"
  defp verdict_label("act"), do: "act"
  defp verdict_label("review"), do: "review"

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
