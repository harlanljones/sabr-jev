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

    assert view |> render() |> then(fn h -> length(Regex.scan(~r/data-storyline=/, h)) end) == 20
  end

  test "breakout lens filters without inventing", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/storylines")

    view
    |> element("[data-lens='breakout']")
    |> render_click()

    assert has_element?(view, "[data-storyline='batter:judgeaa01:2022']")
    refute has_element?(view, "[data-storyline='pitcher:wheelza01:2024']")
    assert render(view) =~ "verdicts are recorded judgments, never guesses"
  end

  test "storyline links open the card in the workbench", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/storylines")

    assert {:error, {:redirect, %{to: "/?card=" <> _}}} =
             view |> element("[data-storyline='batter:acunaro01:2023']") |> render_click()

    {:ok, workbench, _html} = live(conn, "/?card=batter:acunaro01:2023")
    assert has_element?(workbench, "[data-season-card='batter:acunaro01:2023']")
  end

  test "workbench links to storylines", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "/storylines"
  end
end
