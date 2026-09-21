defmodule SabrJevWeb.WorkbenchLive do
  use SabrJevWeb, :live_view

  alias SabrJev.Catalog

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
         |> assign(:filter, Map.put(@empty_filter, "position", "batter"))
         |> assign(:route_map, route_map(catalog))
         |> assign_card(default_card_id(catalog, "batter"))}

      {:error, reason} ->
        {:ok,
         socket
         |> assign(:catalog, nil)
         |> assign(:load_error, inspect(reason))
         |> assign(:filter, @empty_filter)
         |> assign(:route_map, %{})
         |> assign(:card, nil)
         |> assign(:judgment, nil)
         |> assign(:judgment_error, nil)}
    end
  end

  @impl true
  def handle_params(%{"card" => id}, _uri, socket) do
    {:noreply,
     case socket.assigns.catalog && Catalog.get(socket.assigns.catalog, id) do
       {:ok, card} ->
         socket
         |> assign(:filter, Map.put(@empty_filter, "position", card["role"]))
         |> assign_card(id)

       _ ->
         socket
     end}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("filter", %{"filter" => params}, socket) when is_map(params) do
    filter =
      @empty_filter
      |> Map.merge(Map.take(socket.assigns.filter, Map.keys(@empty_filter)))
      |> Map.merge(sanitize_filter(params, socket.assigns.catalog))
      |> coerce_empties(socket.assigns.catalog, socket.assigns.route_map)

    socket = assign(socket, :filter, filter)
    current = socket.assigns.card && socket.assigns.card["id"]
    visible = Enum.map(filter_cards(socket.assigns), & &1["id"])

    {:noreply,
     if Enum.member?(visible, current) do
       socket
     else
       assign_card(socket, List.first(visible))
     end}
  end

  def handle_event("select-card", %{"id" => id}, socket) do
    if socket.assigns.catalog && match?({:ok, _}, Catalog.get(socket.assigns.catalog, id)) do
      {:noreply, push_navigate(socket, to: ~p"/?card=#{id}")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="workbench">
      <header>
        <p class="eyebrow">Season workbench</p>
        <h1>Sabr-Jev</h1>
        <p>
          Season stats lie by omission. The verdict below says <strong>act</strong>, <strong>review</strong>, or
          <strong>set aside</strong>
          —
          with full probabilities, never hype.
        </p>
        <nav aria-label="Workbench">
          <a href={~p"/"} aria-current="page">Workbench</a>
          {" | "}
          <a href={~p"/storylines"}>Storylines</a>
          {" | "}
          <a href={~p"/backtest"}>Backtest</a>
          {" | "}
          <a href={~p"/about"}>About &amp; formulas</a>
        </nav>
      </header>

      <section
        :if={@load_error}
        id="catalog-error"
        class="empty-state"
        aria-labelledby="error-heading"
      >
        <h2 id="error-heading">Season data unavailable</h2>
        <p>The frozen card catalog failed to load. No judgments have been requested.</p>
        <p><code>{@load_error}</code></p>
      </section>

      <section :if={!@load_error && @catalog} aria-label="Card selection">
        <form
          phx-change="filter"
          id="card-filters"
          class="filters"
          data-filters="true"
          aria-label="Filter cards"
        >
          <label>
            Position
            <select name="filter[position]" data-facet="position">
              <option value="all" selected={@filter["position"] == "all"}>
                All ({filter_count(@catalog, @route_map, @filter, :position, "all")})
              </option>
              <option
                :for={position <- position_options()}
                value={position}
                selected={@filter["position"] == position}
                disabled={filter_count(@catalog, @route_map, @filter, :position, position) == 0}
              >
                {String.capitalize(position)} ({filter_count(
                  @catalog,
                  @route_map,
                  @filter,
                  :position,
                  position
                )})
              </option>
            </select>
          </label>
          <label>
            Season
            <select name="filter[season]" data-facet="season">
              <option value="all" selected={@filter["season"] == "all"}>
                All ({filter_count(@catalog, @route_map, @filter, :season, "all")})
              </option>
              <option
                :for={season <- season_options(@catalog)}
                value={season}
                selected={@filter["season"] == season}
                disabled={filter_count(@catalog, @route_map, @filter, :season, season) == 0}
              >
                {season} ({filter_count(@catalog, @route_map, @filter, :season, season)})
              </option>
            </select>
          </label>
          <label>
            Verdict
            <select name="filter[verdict]" data-facet="verdict">
              <option value="all" selected={@filter["verdict"] == "all"}>
                All ({filter_count(@catalog, @route_map, @filter, :verdict, "all")})
              </option>
              <option
                :for={verdict <- verdict_options()}
                value={verdict}
                selected={@filter["verdict"] == verdict}
                disabled={filter_count(@catalog, @route_map, @filter, :verdict, verdict) == 0}
              >
                {verdict_label(verdict)} ({filter_count(
                  @catalog,
                  @route_map,
                  @filter,
                  :verdict,
                  verdict
                )})
              </option>
            </select>
          </label>
        </form>
        <p class="lens-note" data-filter-note="true">
          Showing {length(filter_cards(assigns))} of {length(Catalog.cards(@catalog))} —
          empty combinations are not offered.
        </p>
        <ul aria-label="Player seasons" class="card-picker">
          <li :for={card <- filter_cards(assigns)}>
            <.link
              class="picker-link"
              navigate={~p"/?card=#{card["id"]}"}
              data-card-id={card["id"]}
              aria-pressed={@card && @card["id"] == card["id"]}
            >
              {card["player_name"]} · {card["year"]}
            </.link>
          </li>
        </ul>
      </section>

      <section
        :if={@card}
        id="season-card"
        data-season-card={@card["id"]}
        class="season-card"
        aria-labelledby="card-heading"
      >
        <h2 id="card-heading">
          {@card["player_name"]} · {@card["year"]} · {@card["role"]}
        </h2>
        <.headlines card={@card} />
        <.shape card={@card} />
        <.sample card={@card} />
        <.warnings card={@card} />
        <.judgment card={@card} judgment={@judgment} judgment_error={@judgment_error} />
        <.oracle card={@card} />
      </section>

      <section
        :if={!@load_error && @catalog && is_nil(@card)}
        id="empty-workbench"
        class="empty-state"
      >
        <h2>No season cards loaded</h2>
        <p>The workbench has no season data yet. No judgments have been requested.</p>
      </section>

      <section aria-labelledby="eval-heading" class="evaluation-status">
        <h2 id="eval-heading">Evaluation status</h2>
        <p>Prospective evaluation: accuracy pending. No accuracy claim is made.</p>
        <p>
          2024 → 2025 joins are retrospective plumbing only. The local ledger is
          hash chained but cannot prove external capture time.
        </p>
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

  defp default_card_id(nil, _role), do: nil

  defp default_card_id(catalog, role) do
    case Catalog.for_role(catalog, role) do
      [first | _] -> first["id"]
      [] -> nil
    end
  end

  defp position_options, do: @positions
  defp verdict_options, do: @verdicts

  # Precomputed latch route per recorded card; unrecorded cards map to nil and
  # never match a specific verdict facet.
  defp route_map(nil), do: %{}

  defp route_map(catalog) do
    Map.new(Catalog.cards(catalog), fn card ->
      route =
        case Catalog.judgment(card) do
          {:ok, %{decision: %{route: route}}} -> Atom.to_string(route)
          _ -> nil
        end

      {card["id"], route}
    end)
  end

  defp season_options(catalog) do
    catalog |> Catalog.cards() |> Enum.map(&to_string(&1["year"])) |> Enum.uniq() |> Enum.sort()
  end

  defp filter_cards(%{catalog: nil}), do: []

  defp filter_cards(%{catalog: catalog, filter: filter, route_map: route_map}) do
    Enum.filter(Catalog.cards(catalog), fn card ->
      (filter["position"] == "all" or card["role"] == filter["position"]) and
        (filter["season"] == "all" or to_string(card["year"]) == filter["season"]) and
        (filter["verdict"] == "all" or route_map[card["id"]] == filter["verdict"])
    end)
  end

  # Facet counts ignore the facet being counted so every offered option is
  # non-empty by construction; zeros render disabled.
  defp filter_count(catalog, route_map, filter, facet, value) do
    others = Map.delete(filter, Atom.to_string(facet))

    Enum.count(Catalog.cards(catalog), fn card ->
      Enum.all?(others, fn
        {"position", "all"} -> true
        {"position", position} -> card["role"] == position
        {"season", "all"} -> true
        {"season", season} -> to_string(card["year"]) == season
        {"verdict", "all"} -> true
        {"verdict", verdict} -> route_map[card["id"]] == verdict
      end) and facet_match?(facet, value, card, route_map)
    end)
  end

  defp facet_match?(_facet, "all", _card, _route_map), do: true
  defp facet_match?(:position, position, card, _), do: card["role"] == position
  defp facet_match?(:season, season, card, _), do: to_string(card["year"]) == season
  defp facet_match?(:verdict, verdict, card, route_map), do: route_map[card["id"]] == verdict

  defp sanitize_filter(params, nil), do: Map.take(params, ["position", "season", "verdict"])

  defp sanitize_filter(params, catalog) do
    seasons = season_options(catalog)

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

  # A selected value left empty by the other facets falls back to "all" so the
  # picker can never strand on an empty combination.
  defp coerce_empties(filter, nil, _route_map), do: filter

  defp coerce_empties(filter, catalog, route_map) do
    Map.new(filter, fn {key, value} ->
      facet = String.to_existing_atom(key)

      if value != "all" and filter_count(catalog, route_map, filter, facet, value) == 0 do
        {key, "all"}
      else
        {key, value}
      end
    end)
  end

  defp verdict_label("escalate"), do: "Set aside"
  defp verdict_label("all"), do: "All verdicts"
  defp verdict_label(verdict), do: String.capitalize(verdict)

  defp assign_card(socket, nil) do
    socket
    |> assign(:card, nil)
    |> assign(:judgment, nil)
    |> assign(:judgment_error, nil)
  end

  defp assign_card(socket, id) do
    case Catalog.get(socket.assigns.catalog, id) do
      {:ok, card} ->
        case Catalog.judgment(card) do
          {:ok, judgment} ->
            socket
            |> assign(:card, card)
            |> assign(:judgment, judgment)
            |> assign(:judgment_error, nil)

          {:error, :no_recording} ->
            socket
            |> assign(:card, card)
            |> assign(:judgment, nil)
            |> assign(:judgment_error, :no_recording)

          {:error, reason} ->
            socket
            |> assign(:card, card)
            |> assign(:judgment, nil)
            |> assign(:judgment_error, reason)
        end

      {:error, _} ->
        socket
    end
  end

  defp headlines(%{card: %{"role" => "batter"}} = assigns) do
    ~H"""
    <dl class="headlines" aria-label="Headline metrics">
      <div>
        <dt>OPS+ (Sabr-Jev)</dt>
        <dd data-headline="ops_plus">{fmt(@card["metrics"]["ops_plus"])}</dd>
      </div>
      <div>
        <dt>wOBA</dt>
        <dd data-headline="woba">{fmt(@card["metrics"]["woba"])}</dd>
      </div>
    </dl>
    """
  end

  defp headlines(%{card: %{"role" => "pitcher"}} = assigns) do
    ~H"""
    <dl class="headlines" aria-label="Headline metrics">
      <div>
        <dt>FIP</dt>
        <dd data-headline="fip">{fmt(@card["metrics"]["fip"])}</dd>
      </div>
      <div>
        <dt>ERA</dt>
        <dd data-headline="era">{fmt(@card["metrics"]["era"])}</dd>
      </div>
      <div>
        <dt>K-BB%</dt>
        <dd data-headline="k_bb_pct">{fmt(@card["metrics"]["k_bb_pct"])}</dd>
      </div>
    </dl>
    """
  end

  defp shape(%{card: %{"role" => "batter"}} = assigns) do
    ~H"""
    <table class="shape" aria-label="Batter shape">
      <tbody>
        <tr>
          <th scope="row">PA</th><td>{fmt(@card["metrics"]["pa"])}</td>
        </tr>
        <tr>
          <th scope="row">ISO</th><td>{fmt(@card["metrics"]["iso"])}</td>
        </tr>
        <tr>
          <th scope="row">BB%</th><td>{fmt(@card["metrics"]["bb_pct"])}</td>
        </tr>
        <tr>
          <th scope="row">K%</th><td>{fmt(@card["metrics"]["k_pct"])}</td>
        </tr>
        <tr>
          <th scope="row">BABIP</th><td>{fmt(@card["metrics"]["babip"])}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp shape(%{card: %{"role" => "pitcher"}} = assigns) do
    ~H"""
    <table class="shape" aria-label="Pitcher shape">
      <tbody>
        <tr>
          <th scope="row">IP</th><td>{fmt(@card["metrics"]["ip"])}</td>
        </tr>
        <tr>
          <th scope="row">HR/9</th><td>{fmt(@card["metrics"]["hr_per_9"])}</td>
        </tr>
        <tr>
          <th scope="row">BB/9</th><td>{fmt(@card["metrics"]["bb_per_9"])}</td>
        </tr>
        <tr>
          <th scope="row">K/9</th><td>{fmt(@card["metrics"]["k_per_9"])}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp sample(assigns) do
    ~H"""
    <p class="sample" data-sample="true">
      Sample: {fmt(@card["sample"]["value"])} {@card["sample"]["unit"]} (minimum {@card["sample"][
        "minimum"
      ]}) · <span :if={@card["sample"]["qualified"]}>qualified</span>
      <span :if={!@card["sample"]["qualified"]}>below minimum — cannot act</span>
    </p>
    """
  end

  defp warnings(%{card: %{"warnings" => []}} = assigns) do
    ~H"""
    <p class="warnings" data-warnings="none">No data warnings.</p>
    """
  end

  defp warnings(assigns) do
    ~H"""
    <ul class="warnings" aria-label="Data warnings">
      <li :for={warning <- @card["warnings"]}>{warning}</li>
    </ul>
    """
  end

  defp judgment(%{judgment_error: :no_recording} = assigns) do
    ~H"""
    <section aria-labelledby="judgment-heading" class="judgment judgment-missing">
      <h3 id="judgment-heading">Judgment</h3>
      <p data-no-recording="true">
        No judgment recorded for this card. No judgments have been requested for it.
      </p>
      <p :if={!@card["sample"]["qualified"]} data-verdict="none">
        No verdict — below minimum sample, so this card can never act.
      </p>
      <p :if={is_nil(@card["oracle"])} data-noul-skip="true">
        Noul skipped: no T+1 season in the frozen source.
      </p>
    </section>
    """
  end

  defp judgment(%{judgment: nil} = assigns) do
    ~H"""
    <section aria-labelledby="judgment-heading" class="judgment judgment-missing">
      <h3 id="judgment-heading">Judgment</h3>
      <p data-judgment-error="true">
        Judgment unavailable: {@judgment_error |> inspect()}
      </p>
    </section>
    """
  end

  defp judgment(assigns) do
    ~H"""
    <section aria-labelledby="judgment-heading" class="judgment" data-latch={@judgment.decision.route}>
      <h3 id="judgment-heading">
        The verdict: {@judgment.decision.route}
        <span class="provisional">provisional thresholds</span>
      </h3>
      <p class="verdict-line" data-verdict={@judgment.decision.route}>
        {verdict_line(@judgment.decision.route)}
      </p>
      <details class="audit" data-audit="true">
        <summary>Shows its work — audit trail</summary>
        <dl>
          <div>
            <dt>Model</dt><dd>{@judgment.record["model"]}</dd>
          </div>
          <div>
            <dt>Recorded</dt><dd>{@judgment.record["recorded_at"]}</dd>
          </div>
          <div>
            <dt>State hash</dt><dd><code>{short(@judgment.record["state_hash"])}</code></dd>
          </div>
          <div>
            <dt>Questions hash</dt><dd><code>{short(@judgment.record["questions_hash"])}</code></dd>
          </div>
          <div>
            <dt>Card artifact</dt><dd>
              <code>{@judgment.record["source_lineage"]["card_artifact"]}</code>
            </dd>
          </div>
        </dl>
      </details>
      <ul class="answer-routes" aria-label="Per-answer routes">
        <li :for={{id, route} <- @judgment.decision.answer_routes}>
          {id}: {route}
        </li>
      </ul>
      <p :if={@judgment.decision.reasons != []} class="latch-reasons">
        Reasons: {Enum.map_join(@judgment.decision.reasons, ", ", &to_string/1)}
      </p>
      <.answers
        answers={@judgment.record["answers"]}
        route={@judgment.decision.route}
        card={@card}
      />
    </section>
    """
  end

  defp answers(%{route: :act} = assigns) do
    ~H"""
    <div class="answers answers-act" data-probabilities="summary">
      <p><strong>Recommended read: {act_label(@answers)}</strong></p>
      <ul>
        <li :for={{id, answer} <- @answers}>
          {id}: {answer_label(answer)} ({pct(answer["confidence"])} confidence)
        </li>
      </ul>
    </div>
    """
  end

  defp answers(assigns) do
    ~H"""
    <div class="answers answers-review" data-probabilities="full">
      <p class="no-bold-note">
        Under {if @route == :escalate, do: "escalation", else: "review"}: full probabilities
        below, no single bold recommendation.
      </p>
      <div :for={{id, answer} <- @answers} class="answer-block">
        <h4>{id}</h4>
        <.probabilities answer={answer} />
      </div>
    </div>
    """
  end

  defp probabilities(%{answer: %{"type" => "noul"}} = assigns) do
    ~H"""
    <table class="probabilities" aria-label="Noul probabilities">
      <tbody>
        <tr>
          <th scope="row">P(true)</th><td>{pct(@answer["noul"])}</td>
        </tr>
        <tr>
          <th scope="row">Confidence max(p, 1-p)</th><td>{pct(@answer["confidence"])}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp probabilities(%{answer: %{"type" => "choice"}} = assigns) do
    ~H"""
    <table class="probabilities" aria-label="Choice probabilities">
      <tbody>
        <tr :for={option <- @answer["options"]}>
          <th scope="row">{option["option"]}</th>
          <td>{pct(option["probability"])}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp probabilities(%{answer: %{"type" => "score"}} = assigns) do
    ~H"""
    <table class="probabilities" aria-label="Score probabilities">
      <tbody>
        <tr :for={level <- @answer["levels"]}>
          <th scope="row">{level["label"]}</th>
          <td>{pct(level["probability"])}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp oracle(%{card: %{"oracle" => nil}} = assigns) do
    ~H"""
    <section aria-labelledby="oracle-heading" class="oracle oracle-missing" data-oracle="missing">
      <h3 id="oracle-heading">Oracle</h3>
      <p>No oracle — next season unavailable in the frozen source.</p>
    </section>
    """
  end

  defp oracle(assigns) do
    ~H"""
    <section
      aria-labelledby="oracle-heading"
      class="oracle oracle-present"
      data-oracle="present"
    >
      <h3 id="oracle-heading">Oracle — retrospective eval-only pane, never sent to Jev</h3>
      <dl>
        <div>
          <dt>Season</dt><dd>{@card["oracle"]["year"]}</dd>
        </div>
        <div>
          <dt>Metric</dt><dd>{@card["oracle"]["metric"]}</dd>
        </div>
        <div>
          <dt>Next-season value</dt><dd>{fmt(@card["oracle"]["value"])}</dd>
        </div>
        <div>
          <dt>Label</dt><dd>{to_string(@card["oracle"]["label"])}</dd>
        </div>
        <div>
          <dt>Target</dt><dd>{@card["oracle"]["target"]}</dd>
        </div>
      </dl>
    </section>
    """
  end

  defp act_label(%{"season_read" => %{"choice" => choice}}), do: choice
  defp act_label(_), do: "act"

  defp answer_label(%{"type" => "choice", "choice" => choice}), do: choice
  defp answer_label(%{"type" => "score", "label" => label}), do: label
  defp answer_label(%{"type" => "noul", "noul" => p}), do: "P(true) #{pct(p)}"
  defp answer_label(_), do: "answer"

  defp fmt(nil), do: "unavailable"
  defp fmt(value) when is_integer(value), do: Integer.to_string(value)

  defp fmt(value) when is_float(value) do
    :erlang.float_to_binary(value, decimals: 3)
  end

  defp fmt(value), do: to_string(value)

  defp pct(nil), do: "unavailable"
  defp pct(value) when is_number(value), do: "#{Float.round(value * 100.0, 1)}%"

  defp verdict_line(:act), do: "Confidence clears the bar collectively — act on this read."
  defp verdict_line("act"), do: verdict_line(:act)

  defp verdict_line(:review),
    do: "Confidence is mixed — the full probabilities below are the verdict, not a single call."

  defp verdict_line("review"), do: verdict_line(:review)

  defp verdict_line(_),
    do: "The signal isn't there — one or more answers fell short, so set this read aside."

  defp short("sha256:" <> rest), do: "sha256:" <> String.slice(rest, 0, 12) <> "…"
  defp short(value) when is_binary(value), do: String.slice(value, 0, 19) <> "…"
  defp short(_), do: "unavailable"
end
