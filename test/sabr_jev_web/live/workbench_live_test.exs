defmodule SabrJevWeb.WorkbenchLiveTest do
  use SabrJevWeb.ConnCase, async: true

  test "loads real cards with latch, full probabilities and a labeled oracle", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("[data-card-id='batter:judgeaa01:2024']")
    |> render_click()

    assert has_element?(view, "[data-season-card='batter:judgeaa01:2024']", "Aaron Judge")
    assert has_element?(view, "[data-headline='ops_plus']")
    assert has_element?(view, "[data-latch='review']")
    assert render(view) =~ "provisional thresholds"
    assert has_element?(view, "[data-probabilities='full']", "breakout")

    assert has_element?(
             view,
             "[data-oracle='present']",
             "never sent to Jev"
           )
  end

  test "review lane shows full probabilities with no bold single recommendation", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("[data-card-id='batter:judgeaa01:2024']")
    |> render_click()

    assert has_element?(view, "[data-probabilities='full']")
    refute has_element?(view, "section.judgment strong")
  end

  test "escalated card keeps full probabilities and the oracle pane", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("button[phx-value-role='pitcher']")
    |> render_click()

    view
    |> element("[data-card-id='pitcher:skenepa01:2024']")
    |> render_click()

    assert has_element?(view, "[data-latch='escalate']")
    assert has_element?(view, "[data-probabilities='full']")
    assert has_element?(view, "[data-oracle='present']", "retrospective")
  end

  test "cards without recordings stay honest and skip Noul explicitly", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("[data-card-id='batter:troutmi01:2024']")
    |> render_click()

    assert has_element?(view, "[data-no-recording]")
    assert has_element?(view, "[data-noul-skip]", "no T+1 season")
    assert has_element?(view, "[data-oracle='missing']")
  end

  test "recorded 2025 cards latch without a Noul question", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("[data-card-id='batter:sotoju01:2025']")
    |> render_click()

    assert has_element?(view, "[data-season-card='batter:sotoju01:2025']")
    assert has_element?(view, "[data-latch='escalate']")
    assert has_element?(view, "[data-probabilities='full']")
    assert has_element?(view, "[data-oracle='missing']")
    refute has_element?(view, "[data-no-recording]")
  end

  test "verdict framing states the plain-language call", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("[data-card-id='batter:judgeaa01:2024']")
    |> render_click()

    assert has_element?(
             view,
             "[data-verdict='review']",
             "full probabilities below are the verdict"
           )
  end

  test "audit trail shows its work", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("[data-card-id='batter:judgeaa01:2024']")
    |> render_click()

    assert has_element?(view, "[data-audit]", "jev-1.13.0")
    assert has_element?(view, "[data-audit]", "sha256:")
    assert has_element?(view, "[data-audit]", "priv/data/cards.json")
  end

  test "breakout lens filters to recorded breakout reads only", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("[data-lens='breakout']")
    |> render_click()

    assert has_element?(view, "[data-card-id='batter:judgeaa01:2024']")
    assert has_element?(view, "[data-card-id='batter:sotoju01:2024']")
    refute has_element?(view, "[data-card-id='batter:arozara01:2024']")
    refute has_element?(view, "[data-card-id='batter:troutmi01:2024']")
    assert has_element?(view, "[data-lens-note]", "4 of 6")
  end

  test "regression-risk lens surfaces the watch list", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("button[phx-value-role='pitcher']")
    |> render_click()

    view
    |> element("[data-lens='regression_risk']")
    |> render_click()

    assert has_element?(view, "[data-card-id='pitcher:wheelza01:2024']")
    refute has_element?(view, "[data-card-id='pitcher:skenepa01:2024']")
    assert has_element?(view, "[data-lens-note]", "1 of 6")
  end

  test "underqualified cards get no verdict", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("[data-card-id='batter:troutmi01:2024']")
    |> render_click()

    assert has_element?(view, "[data-verdict='none']", "can never act")
  end

  test "role toggle switches the picker", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    refute has_element?(view, "[data-card-id='pitcher:skenepa01:2024']")

    view
    |> element("button[phx-value-role='pitcher']")
    |> render_click()

    assert has_element?(view, "[data-card-id='pitcher:skenepa01:2024']")
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
