defmodule SabrJev.CatalogTest do
  use ExUnit.Case, async: true

  alias SabrJev.Catalog

  test "loads the frozen catalog with twelve trusted cards" do
    assert {:ok, catalog} = Catalog.load()
    assert catalog["schema_version"] == 1
    assert length(catalog["cards"]) == 12
    assert Catalog.roles(catalog) == ["batter", "pitcher"]
    assert length(Catalog.for_role(catalog, "batter")) == 6
    assert length(Catalog.for_role(catalog, "pitcher")) == 6

    for card <- catalog["cards"] do
      assert :ok = Catalog.validate_card(card)
    end
  end

  test "get/2 resolves known ids and refuses unknown ids" do
    assert {:ok, catalog} = Catalog.load()
    assert {:ok, card} = Catalog.get(catalog, "batter:judgeaa01:2024")
    assert card["player_name"] == "Aaron Judge"
    assert {:error, :unknown_card} = Catalog.get(catalog, "batter:nobody01:2024")
  end

  test "rejects unknown outer keys and id/role/year drift" do
    assert {:ok, catalog} = Catalog.load()
    {:ok, card} = Catalog.get(catalog, "batter:judgeaa01:2024")

    assert {:error, _} = Catalog.validate_card(Map.put(card, "extra", true))
    assert {:error, _} = Catalog.validate_card(Map.put(card, "id", "batter:judgeaa01:2025"))
    assert {:error, _} = Catalog.validate_card(Map.put(card, "role", "pitcher"))
    assert {:error, _} = Catalog.validate_card(Map.put(card, "year", 2025))
    assert {:error, _} = Catalog.validate_card(Map.put(card, "player_id", "other01"))
  end

  test "rejects outer/state metric drift and count/sample drift before judgments" do
    assert {:ok, catalog} = Catalog.load()
    {:ok, card} = Catalog.get(catalog, "batter:judgeaa01:2024")

    drifted_metrics = put_in(card, ["metrics", "ops_plus"], 1.0)
    assert {:error, _} = Catalog.validate_card(drifted_metrics)

    drifted_state = put_in(card, ["judgment_state", "metrics", "ops_plus"], 1.0)
    assert {:error, _} = Catalog.validate_card(drifted_state)

    drifted_pa = put_in(card, ["metrics", "pa"], 1)
    assert {:error, _} = Catalog.validate_card(drifted_pa)

    drifted_sample = put_in(card, ["sample", "value"], 1)
    assert {:error, _} = Catalog.validate_card(drifted_sample)

    {:ok, pitcher} = Catalog.get(catalog, "pitcher:skenepa01:2024")
    drifted_ip = put_in(pitcher, ["metrics", "ip"], 1.0)
    assert {:error, _} = Catalog.validate_card(drifted_ip)
  end

  test "rejects duplicate ids, unsorted cards, and bad schema version" do
    assert {:ok, catalog} = Catalog.load()
    [first | _] = catalog["cards"]

    duplicated = %{catalog | "cards" => [first, first]}
    assert {:error, :duplicate_card_ids} = load_catalog(duplicated)

    unsorted = %{catalog | "cards" => Enum.reverse(catalog["cards"])}
    assert {:error, :cards_not_sorted} = load_catalog(unsorted)

    bad_schema = %{catalog | "schema_version" => 2}
    assert {:error, {:schema_version_mismatch, 2}} = load_catalog(bad_schema)
  end

  test "recordings validate against trusted cards; missing recordings stay explicit" do
    assert {:ok, catalog} = Catalog.load()
    {:ok, card} = Catalog.get(catalog, "batter:judgeaa01:2024")
    assert {:ok, record} = Catalog.load_recording(card)
    assert record["card_id"] == card["id"]

    assert {:ok, %{record: _, decision: decision}} = Catalog.judgment(card)
    assert decision.route == :review

    {:ok, unrecorded} = Catalog.get(catalog, "batter:troutmi01:2024")
    assert {:error, :no_recording} = Catalog.load_recording(unrecorded)
    assert {:error, :no_recording} = Catalog.judgment(unrecorded)
  end

  test "mutated cards never reach judgments or latch" do
    assert {:ok, catalog} = Catalog.load()
    {:ok, card} = Catalog.get(catalog, "batter:arozara01:2024")
    {:ok, _record} = Catalog.load_recording(card)

    mutated = put_in(card, ["metrics", "ops_plus"], 0.0)

    assert {:error, _} = Catalog.validate_card(mutated)
    # The trusted loader re-validates the card before any recording use, so
    # outer/state drift cannot be laundered past the boundary even though the
    # state hash alone still matches.
    assert {:error, _} = Catalog.load_recording(mutated)
    assert {:error, _} = Catalog.judgment(mutated)
  end

  defp load_catalog(catalog) do
    path = Path.join(System.tmp_dir!(), "sabr-catalog-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(catalog))
    on_exit(fn -> File.rm(path) end)
    Catalog.load(path)
  end
end
