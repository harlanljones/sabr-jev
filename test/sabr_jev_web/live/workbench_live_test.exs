defmodule SabrJevWeb.WorkbenchLiveTest do
  use SabrJevWeb.ConnCase, async: true

  # Card selection is a real navigation now, so tests open cards by deep link;
  # one test covers the click-to-navigate behavior itself.
  defp open_card(conn, id) do
    {:ok, view, _html} = live(conn, "/?card=#{id}")
    view
  end

  test "loads real cards with latch, full probabilities and a labeled oracle", %{conn: conn} do
    view = open_card(conn, "batter:judgeaa01:2024")

    assert has_element?(view, "[data-season-card='batter:judgeaa01:2024']", "Aaron Judge")
    assert has_element?(view, "[data-headline='ops_plus']")
    assert has_element?(view, "[data-latch='review']")
    assert render(view) =~ "provisional thresholds"
    assert has_element?(view, "[data-probabilities='full']", "breakout")
    assert has_element?(view, "[data-oracle='present']", "never sent to Jev")
  end

  test "review lane shows full probabilities with no bold single recommendation", %{conn: conn} do
    view = open_card(conn, "batter:judgeaa01:2024")

    assert has_element?(view, "[data-probabilities='full']")
    refute has_element?(view, "section.judgment strong")
  end

  test "escalated card keeps full probabilities and the oracle pane", %{conn: conn} do
    view = open_card(conn, "pitcher:skenepa01:2024")

    assert has_element?(view, "[data-latch='escalate']")
    assert has_element?(view, "[data-probabilities='full']")
    assert has_element?(view, "[data-oracle='present']", "retrospective")
  end

  test "cards without recordings stay honest and skip Noul explicitly", %{conn: conn} do
    view = open_card(conn, "batter:troutmi01:2024")

    assert has_element?(view, "[data-no-recording]")
    assert has_element?(view, "[data-noul-skip]", "no T+1 season")
    assert has_element?(view, "[data-oracle='missing']")
  end

  test "recorded 2025 cards latch without a Noul question", %{conn: conn} do
    view = open_card(conn, "batter:sotoju01:2025")

    assert has_element?(view, "[data-season-card='batter:sotoju01:2025']")
    assert has_element?(view, "[data-latch='review']")
    assert has_element?(view, "[data-probabilities='full']")
    assert has_element?(view, "[data-oracle='missing']")
    refute has_element?(view, "[data-no-recording]")
  end

  test "verdict framing states the plain-language call", %{conn: conn} do
    view = open_card(conn, "batter:judgeaa01:2024")

    assert has_element?(
             view,
             "[data-verdict='review']",
             "full probabilities below are the verdict"
           )
  end

  test "audit trail shows its work", %{conn: conn} do
    view = open_card(conn, "batter:judgeaa01:2024")

    assert has_element?(view, "[data-audit]", "jev-1.13.0")
    assert has_element?(view, "[data-audit]", "sha256:")
    assert has_element?(view, "[data-audit]", "priv/data/cards.json")
  end

  test "verdict facet filters and empty verdicts are disabled, never offered", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("form[data-filters]")
    |> render_change(%{filter: %{verdict: "review"}})

    assert has_element?(view, "[data-card-id='batter:judgeaa01:2024']")
    refute has_element?(view, "[data-card-id='batter:sotoju01:2024']")
    assert has_element?(view, "[data-filter-note]", "Showing 10 of 37")

    view
    |> element("form[data-filters]")
    |> render_change(%{filter: %{position: "pitcher"}})

    assert has_element?(view, "select[data-facet='verdict'] option[value='act'][disabled]")
  end

  test "act verdicts exist and filter cleanly", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("form[data-filters]")
    |> render_change(%{filter: %{verdict: "act"}})

    assert has_element?(view, "[data-card-id='batter:guerrvl02:2021']")
    assert has_element?(view, "[data-filter-note]", "Showing 4 of 37")
  end

  test "season facet filters to that season only", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("form[data-filters]")
    |> render_change(%{filter: %{position: "all"}})

    view
    |> element("form[data-filters]")
    |> render_change(%{filter: %{season: "2021"}})

    assert has_element?(view, "[data-card-id='pitcher:burneco01:2021']")
    refute has_element?(view, "[data-card-id='batter:judgeaa01:2024']")
    assert has_element?(view, "[data-filter-note]", "Showing 4 of 37")
  end

  test "position facet switches the picker", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    refute has_element?(view, "[data-card-id='pitcher:skenepa01:2024']")

    view
    |> element("form[data-filters]")
    |> render_change(%{filter: %{position: "pitcher"}})

    assert has_element?(view, "[data-card-id='pitcher:skenepa01:2024']")
    refute has_element?(view, "[data-card-id='batter:judgeaa01:2024']")
  end

  test "clicking a card navigates to its shareable URL", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    assert {:error, {:live_redirect, %{to: "/?card=batter%3Aarozara01%3A2024"}}} =
             view |> element("[data-card-id='batter:arozara01:2024']") |> render_click()
  end

  test "underqualified cards get no verdict", %{conn: conn} do
    view = open_card(conn, "batter:troutmi01:2024")

    assert has_element?(view, "[data-verdict='none']", "can never act")
  end

  test "single filter element offers position, season and verdict together", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "data-filters"
    assert html =~ "data-facet=\"position\""
    assert html =~ "data-facet=\"season\""
    assert html =~ "data-facet=\"verdict\""
    refute html =~ "data-lens="
  end

  test "footer cites Lahman with no Fangraphs scrape", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "Lahman"
    assert html =~ "no Fangraphs scrape in v1"
    assert html =~ "Evaluation status"
  end

  test "about page documents formulas, provenance and pending evaluation", %{conn: conn} do
    conn = get(conn, "/about")
    html = html_response(conn, 200)
    assert html =~ "OPS+ (Sabr-Jev)"
    assert html =~ "woba_weights.csv"
    assert html =~ "FIP"
    assert html =~ "provisional"
    assert html =~ "accuracy pending"
    assert html =~ "Lahman"
    assert html =~ "no Fangraphs scrape in v1"

    {:ok, _view, live_html} = live(conn)
    assert live_html =~ "Teams.BPF"
  end
end
