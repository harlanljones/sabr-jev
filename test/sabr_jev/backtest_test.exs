defmodule SabrJev.BacktestTest do
  use ExUnit.Case, async: true

  alias SabrJev.{Backtest, Catalog}

  test "scores every recorded oracle card and labels itself honestly" do
    {:ok, catalog} = Catalog.load()
    {:ok, report} = Backtest.run(catalog)

    assert report.status =~ "retrospective"
    assert report.status =~ "not prospective validation"

    assert report.by_role["batter"]["n"] > 0
    assert report.by_role["pitcher"]["n"] > 0
    assert report.all["n"] == report.by_role["batter"]["n"] + report.by_role["pitcher"]["n"]

    for role <- ["batter", "pitcher"] do
      brier = report.by_role[role]["brier"]
      assert is_number(brier) and brier >= 0.0 and brier <= 1.0
      assert report.by_role[role]["baseline_brier"] >= 0.0
    end
  end

  test "pairs match oracle labels exactly" do
    {:ok, catalog} = Catalog.load()
    {:ok, report} = Backtest.run(catalog)

    for pair <- report.pairs do
      assert {:ok, card} = Catalog.get(catalog, pair.card_id)
      assert pair.label == card["oracle"]["label"]
      assert is_number(pair.probability) and pair.probability >= 0 and pair.probability <= 1
    end
  end

  test "bucket counts sum to scored n" do
    {:ok, catalog} = Catalog.load()
    {:ok, report} = Backtest.run(catalog)

    for role <- ["batter", "pitcher"] do
      assert Enum.sum(Enum.map(report.by_role[role]["buckets"], & &1["n"])) ==
               report.by_role[role]["n"]
    end
  end

  test "excluded cards are the ones without recordings or without oracles" do
    {:ok, catalog} = Catalog.load()
    {:ok, report} = Backtest.run(catalog)

    assert report.coverage["cards"] == 50
    assert report.coverage["scored"] + report.coverage["excluded"] == 50
    assert report.coverage["scored"] > 40
  end

  test "invalid catalog is refused" do
    assert {:error, :invalid_catalog} = Backtest.run("not a map")
  end
end
