defmodule SabrJev.ProspectiveTest do
  use ExUnit.Case, async: true

  alias SabrJev.Prospective

  @cutoff ~U[2027-01-01 00:00:00Z]

  defp card(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "batter:example:2024",
        "role" => "batter",
        "year" => 2024,
        "judgment_state" => %{
          "role" => "batter",
          "metrics" => %{
            "pa" => 400,
            "obp" => 0.4,
            "slg" => 0.5,
            "ops" => 0.9,
            "iso" => 0.2,
            "babip" => 0.3,
            "bb_pct" => 0.1,
            "k_pct" => 0.2,
            "woba" => 0.38,
            "ops_plus" => 123.4,
            "league_obp" => 0.31,
            "league_slg" => 0.4,
            "park_adjustment" => 1.0
          },
          "sample" => %{"minimum" => 200, "value" => 400}
        },
        "sample" => %{
          "qualified" => true,
          "minimum" => 200,
          "value" => 400,
          "unit" => "PA"
        },
        "oracle" => nil
      },
      overrides
    )
  end

  defp record(overrides \\ %{}) do
    state_hash = SabrJev.Questions.state_hash(card()["judgment_state"])

    Map.merge(
      %{
        "schema_version" => 1,
        "card_id" => "batter:example:2024",
        "state_hash" => state_hash,
        "questions_hash" => "sha256:def",
        "model" => "jev-latest",
        "recorded_at" => "2026-09-18T12:00:00Z",
        "response" => %{"model" => "jev-latest"},
        "answers" => %{"season_read" => %{"type" => "choice"}},
        "source_lineage" => %{"card_artifact" => "priv/data/cards.json"}
      },
      overrides
    )
  end

  defp entry_record(id, probability \\ 0.2) do
    entry_card = card(%{"id" => id, "year" => 2026})

    record(%{
      "card_id" => id,
      "state_hash" => SabrJev.Questions.state_hash(entry_card["judgment_state"]),
      "probability" => probability
    })
  end

  test "enrollment freezes cohort and baseline before capture" do
    cohort = Prospective.enroll([card()], baseline: %{"batter" => 0.4})

    assert cohort.cohort == ["batter:example:2024"]
    assert cohort.baseline == %{"batter" => 0.4}
    assert cohort.cutoff == @cutoff
  end

  test "capture refuses historical cohort years whose outcome season already started" do
    cohort = Prospective.enroll([card()], baseline: %{"batter" => 0.4})

    assert {:error, :historical_cohort} =
             Prospective.capture(cohort, card(), record(), captured_at: @cutoff)
  end

  test "capture requires capture before the conservative cutoff" do
    cohort =
      Prospective.enroll([card(%{"id" => "batter:example:2026", "year" => 2026})],
        baseline: %{"batter" => 0.4}
      )

    assert {:error, :capture_after_cutoff} =
             Prospective.capture(
               cohort,
               card(%{"id" => "batter:example:2026", "year" => 2026}),
               entry_record("batter:example:2026"),
               captured_at: @cutoff
             )
  end

  test "capture rejects duplicates and mismatched state without clock override" do
    entry_card = card(%{"id" => "batter:example:2026", "year" => 2026})

    cohort =
      Prospective.enroll([entry_card],
        baseline: %{"batter" => 0.4},
        captured_at: ~U[2026-06-01 00:00:00Z]
      )

    entry = entry_record("batter:example:2026")

    assert {:ok, ledger, _line} =
             Prospective.capture(cohort, entry_card, entry, captured_at: ~U[2026-06-01 00:00:00Z])

    assert {:error, :duplicate_capture} =
             Prospective.capture(cohort, entry_card, entry,
               captured_at: ~U[2026-06-01 00:00:00Z],
               ledger: ledger
             )

    # A ledger that fails verification is never extended, so tampering cannot be
    # laundered into a longer valid chain.
    assert {:error, :ledger_tampered} =
             Prospective.capture(cohort, entry_card, entry,
               captured_at: ~U[2026-06-01 00:00:00Z],
               ledger: ledger ++ [List.last(ledger)]
             )

    tampered = put_in(entry_card, ["judgment_state", "metrics", "ops_plus"], 1.0)

    assert {:error, :state_hash_mismatch} =
             Prospective.capture(cohort, tampered, entry, captured_at: ~U[2026-06-01 00:00:00Z])

    assert {:error, :capture_time_required} = Prospective.capture(cohort, entry_card, entry, [])
  end

  test "capture requires a complete record rather than inventing fields" do
    entry_card = card(%{"id" => "batter:example:2026", "year" => 2026})
    cohort = Prospective.enroll([entry_card], baseline: %{"batter" => 0.4})
    entry = entry_record("batter:example:2026")
    at = ~U[2026-06-01 00:00:00Z]

    for field <- ["state_hash", "questions_hash", "model", "probability"] do
      assert {:error, {:record_field_required, ^field}} =
               Prospective.capture(cohort, entry_card, Map.delete(entry, field), captured_at: at)
    end

    assert {:error, :probability_out_of_range} =
             Prospective.capture(cohort, entry_card, Map.put(entry, "probability", 7.5),
               captured_at: at
             )

    assert {:error, :record_card_mismatch} =
             Prospective.capture(
               cohort,
               entry_card,
               Map.put(entry, "card_id", "batter:other:2026"),
               captured_at: at
             )
  end

  test "ledger is append-only and hash verified" do
    first = card(%{"id" => "batter:first:2026", "year" => 2026})
    second = card(%{"id" => "batter:second:2026", "year" => 2026})

    cohort = Prospective.enroll([first, second], baseline: %{"batter" => 0.4})

    assert {:ok, ledger, _first_line} =
             Prospective.capture(cohort, first, entry_record("batter:first:2026"),
               captured_at: ~U[2026-06-01 00:00:00Z]
             )

    assert {:ok, ledger, _second_line} =
             Prospective.capture(
               cohort,
               second,
               entry_record("batter:second:2026"),
               captured_at: ~U[2026-06-02 00:00:00Z],
               ledger: ledger
             )

    assert :ok = Prospective.verify(ledger)
    assert {:error, _} = Prospective.verify(tl(ledger))
    assert {:error, _} = Prospective.verify([Jason.encode!(%{"tampered" => true})])
  end
end
