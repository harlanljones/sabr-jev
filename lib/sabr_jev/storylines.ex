defmodule SabrJev.Storylines do
  @moduledoc """
  Editorial index for the storyline surface: famous 2020-2025 seasons with a
  one-line hook each. Every entry must resolve to a catalog card with a real
  immutable recording; the LiveView renders real verdicts, never the hooks as
  judgments. Teams are single-stint, verified against the pinned source.
  """

  @entries [
    %{card_id: "batter:judgeaa01:2022", team: "NYY", hook: "62 home runs. The AL record falls."},
    %{card_id: "batter:ohtansh01:2024", team: "LAD", hook: "50/50: the first ever."},
    %{
      card_id: "batter:acunaro01:2023",
      team: "ATL",
      hook: "40/70, then the knee gave out. Did the 2023 numbers already whisper 2024?"
    },
    %{
      card_id: "batter:wittbo02:2024",
      team: "KC",
      hook: "From top prospect to MVP runner-up in one summer."
    },
    %{card_id: "batter:hendegu01:2024", team: "BAL", hook: "The sophomore leap, all fields."},
    %{
      card_id: "batter:bellico01:2023",
      team: "CHC",
      hook: "Non-tendered, then reborn in Chicago."
    },
    %{
      card_id: "batter:bettsmo01:2023",
      team: "LAD",
      hook: "MVP-caliber while learning shortstop mid-season."
    },
    %{
      card_id: "batter:schwaky01:2022",
      team: "PHI",
      hook: "A .218 average with 46 homers. What even is a season?"
    },
    %{card_id: "batter:ramirjo01:2022", team: "CLE", hook: "The quiet superstar, loud numbers."},
    %{card_id: "batter:freemfr01:2023", team: "LAD", hook: "59 doubles, sprayed to all fields."},
    %{card_id: "pitcher:burneco01:2021", team: "MIL", hook: "A 1.59 FIP. Absurd, then and now."},
    %{card_id: "pitcher:colege01:2023", team: "NYY", hook: "The unanimous 2023 Cy Young."},
    %{
      card_id: "pitcher:snellbl01:2023",
      team: "SD",
      hook: "A 2.25 ERA and a 3.44 FIP won the Cy Young. Which number was lying?"
    },
    %{card_id: "pitcher:alcansa01:2022", team: "MIA", hook: "228 innings in a bullpen era."},
    %{
      card_id: "pitcher:stridsp01:2023",
      team: "ATL",
      hook: "281 strikeouts, then seven outs in 2024."
    },
    %{
      card_id: "pitcher:skubata01:2024",
      team: "DET",
      hook: "The breakout that won Detroit a Cy Young."
    },
    %{card_id: "pitcher:salech01:2024", team: "ATL", hook: "The comeback Cy Young."},
    %{
      card_id: "pitcher:degroja01:2021",
      team: "NYM",
      hook: "A 1.08 ERA and 1.19 FIP over 92 innings. Greatness, interrupted."
    },
    %{
      card_id: "pitcher:rayro02:2021",
      team: "TOR",
      hook: "A strikeout crown on a walk tightrope."
    },
    %{
      card_id: "pitcher:ohtansh01:2022",
      team: "LAA",
      hook: "The other half of the two-way season."
    },
    %{
      card_id: "batter:guerrvl02:2021",
      team: "TOR",
      hook: "A Triple Crown chase that came up one AVG point short."
    },
    %{
      card_id: "batter:alvaryo01:2022",
      team: "HOU",
      hook: "A swing rebuilt into 37 homers and a .413 OBP."
    },
    %{
      card_id: "batter:goldspa01:2022",
      team: "STL",
      hook: "MVP at 34, on a Triple Crown pace into August."
    },
    %{
      card_id: "pitcher:verlaju01:2022",
      team: "HOU",
      hook: "A no-hitter and a Cy Young, one year before the elbow."
    }
  ]

  @spec list() :: [map()]
  def list, do: @entries

  @spec ids() :: [String.t()]
  def ids, do: Enum.map(@entries, & &1.card_id)
end
