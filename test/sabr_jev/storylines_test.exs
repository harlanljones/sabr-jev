defmodule SabrJev.StorylinesTest do
  use ExUnit.Case, async: true

  alias SabrJev.{Catalog, Storylines}

  test "every storyline resolves to a recorded catalog card with a hook" do
    assert {:ok, catalog} = Catalog.load()
    entries = Storylines.list()
    assert length(entries) == 24
    assert length(Storylines.ids()) == length(Enum.uniq(Storylines.ids()))

    for entry <- entries do
      assert is_binary(entry.hook) and byte_size(entry.hook) > 0
      assert {:ok, card} = Catalog.get(catalog, entry.card_id)
      assert {:ok, %{decision: decision}} = Catalog.judgment(card)
      assert decision.route in [:act, :review, :escalate]
    end
  end

  test "storyline seasons stay inside the modern window" do
    for id <- Storylines.ids() do
      year = id |> String.split(":") |> List.last() |> String.to_integer()
      assert year >= 2020 and year <= 2025
    end
  end
end
