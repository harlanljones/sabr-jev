defmodule SabrJevWeb.BacktestLiveTest do
  use SabrJevWeb.ConnCase, async: true

  test "renders summary, buckets and per-pair results", %{conn: conn} do
    {:ok, view, html} = live(conn, "/backtest")

    assert html =~ "Projected vs actual"
    assert html =~ "Retrospective plumbing, not"
    assert has_element?(view, "table", "Model Brier")
    assert has_element?(view, "[aria-label='Reliability buckets']", "Actual rate")
    assert has_element?(view, "[aria-label='Scored predictions']", "Actual")
    assert has_element?(view, "[aria-label='Brier summary']", "Edge")

    html = render(view)
    assert html =~ "43 of 50 cards scored"
    assert html =~ "no edge claimed" or html =~ "0."
  end

  test "per-pair rows deep link into the workbench", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/backtest")

    assert has_element?(view, "a[data-phx-link], a", "batter:judgeaa01:2022")

    {:ok, workbench, _html} = live(conn, "/?card=batter:judgeaa01:2022")
    assert has_element?(workbench, "[data-season-card='batter:judgeaa01:2022']")
  end

  test "backtest is linked from the workbench nav", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "/backtest"
  end
end
