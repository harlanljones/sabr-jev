defmodule SabrJevWeb.StorylinesLiveTest do
  use SabrJevWeb.ConnCase, async: true

  test "index renders twenty storylines with real verdicts", %{conn: conn} do
    {:ok, view, html} = live(conn, "/storylines")

    assert html =~ "What would the model have said?"
    assert has_element?(view, "[data-storyline='batter:acunaro01:2023']", "knee gave out")

    assert has_element?(
             view,
             "[data-storyline='pitcher:snellbl01:2023']",
             "Which number was lying"
           )

    assert view |> render() |> then(fn h -> length(Regex.scan(~r/data-storyline=/, h)) end) == 24
  end

  test "position facet narrows the index with counts", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/storylines")

    view
    |> element("form[data-filters]")
    |> render_change(%{filter: %{position: "pitcher"}})

    assert has_element?(view, "[data-storyline='pitcher:snellbl01:2023']")
    refute has_element?(view, "[data-storyline='batter:acunaro01:2023']")
    assert has_element?(view, "[data-filter-note]", "Showing 11 of 24")
  end

  test "season and verdict facets combine with no dead ends", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/storylines")

    view
    |> element("form[data-filters]")
    |> render_change(%{filter: %{verdict: "act"}})

    assert has_element?(view, "[data-storyline='batter:judgeaa01:2022']")
    assert has_element?(view, "[data-filter-note]", "Showing 4 of 24")

    view
    |> element("form[data-filters]")
    |> render_change(%{filter: %{verdict: "all", season: "2023"}})

    assert has_element?(view, "[data-storyline='batter:acunaro01:2023']")
    refute has_element?(view, "[data-storyline='batter:judgeaa01:2022']")
    assert has_element?(view, "[data-filter-note]", "Showing 7 of 24")
  end

  test "storyline links navigate to the card in the workbench", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/storylines")

    assert {:error, {:live_redirect, %{to: "/?card=batter%3Aacunaro01%3A2023"}}} =
             view |> element("[data-storyline='batter:acunaro01:2023']") |> render_click()

    {:ok, workbench, _html} = live(conn, "/?card=batter:acunaro01:2023")
    assert has_element?(workbench, "[data-season-card='batter:acunaro01:2023']")
  end

  test "workbench links to storylines", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "/storylines"
  end
end
