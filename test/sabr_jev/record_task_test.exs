defmodule Mix.Tasks.Sabr.RecordTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Sabr.Record

  setup do
    root = Path.join(System.tmp_dir!(), "sabr-record-task-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "rejects unsafe catalog ids before creating destinations", %{root: root} do
    unsafe_ids = [
      "../../escape",
      "batter/foo/2024",
      "batter\\foo\\2024",
      "/absolute",
      "C:\\absolute",
      ".",
      "..",
      "batter:..:2024",
      "",
      "batter:weird id:2024",
      "batter:\u0000:2024"
    ]

    for id <- unsafe_ids do
      assert {:error, {:unsafe_card_id, ^id}} =
               Record.prepare_destinations(Path.join(root, "output"), [%{"id" => id}])
    end

    refute File.exists?(Path.join(root, "output"))
  end

  test "preserves all six frozen filenames and verifies strict output containment", %{root: root} do
    output = Path.join(root, "recordings")
    catalog = Jason.decode!(File.read!("priv/data/cards.json"))
    cards = Enum.filter(catalog["cards"], &is_map(&1["oracle"]))

    assert {:ok, destinations} = Record.prepare_destinations(output, cards)

    assert destinations |> Enum.map(&Path.basename(&1.path)) |> Enum.sort() == [
             "batter--arozara01--2024.json",
             "batter--judgeaa01--2024.json",
             "batter--sotoju01--2024.json",
             "pitcher--skenepa01--2024.json",
             "pitcher--sotogr01--2024.json",
             "pitcher--wheelza01--2024.json"
           ]

    expanded_output = Path.expand(output)

    assert Enum.all?(destinations, fn destination ->
             expanded = Path.expand(destination.path)
             Path.dirname(expanded) == expanded_output and expanded != expanded_output
           end)
  end

  test "rejects encoded filename collisions", %{root: root} do
    cards = [%{"id" => "batter:example:2024"}, %{"id" => "batter--example--2024"}]

    assert {:error, {:destination_collision, "batter--example--2024.json"}} =
             Record.prepare_destinations(root, cards)
  end

  test "duplicate card selections fail before credentials, API calls, or writes", %{root: root} do
    {record, card} = real_record_and_card()
    catalog_path = Path.join(root, "cards.json")
    output = Path.join(root, "output")

    catalog = %{
      "schema_version" => 1,
      "provenance" => record["source_lineage"]["provenance"],
      "cards" => [card]
    }

    File.write!(catalog_path, Jason.encode!(catalog))

    notify = fn phase -> fn _ -> send(self(), phase) end end

    assert_raise Mix.Error, ~r/duplicate card ids/, fn ->
      Record.run(
        [
          "--catalog",
          catalog_path,
          "--output",
          output,
          "--card",
          card["id"],
          "--card",
          card["id"]
        ],
        client_factory: notify.(:client_created),
        evaluator: fn _, _, _ -> send(self(), :api_called) end,
        batch_writer: notify.(:write_called)
      )
    end

    refute_received :client_created
    refute_received :api_called
    refute_received :write_called
    refute File.exists?(output)
  end

  test "stage collision preserves the pre-existing file and retries with a new name", %{
    root: root
  } do
    {record, card} = real_record_and_card()
    [entry | _] = batch_entries(root, record, card)
    collision = Path.join(root, ".collision.stage")
    retry_path = Path.join(root, ".retry.stage")
    File.write!(collision, "sentinel")

    test_pid = self()

    stage_path = fn _path, attempt ->
      send(test_pid, {:stage_attempt, attempt})
      if attempt == 1, do: collision, else: retry_path
    end

    assert :ok = Record.write_batch([entry], stage_path: stage_path)
    assert_received {:stage_attempt, 1}
    assert_received {:stage_attempt, 2}
    assert File.read!(collision) == "sentinel"
    assert File.exists?(entry.path)
    refute File.exists?(retry_path)
  end

  test "later staging failure removes every owned staging file", %{root: root} do
    {record, card} = real_record_and_card()
    entries = batch_entries(root, record, card)

    assert {:error,
            {:stage_failed, _path, :injected_failure,
             %{failures: [], conflicts: [], leftovers: []}}} =
             Record.write_batch(entries, fail_at: {:stage, 2})

    assert File.ls!(root) == []
  end

  test "stage replacement is preserved and reported as a rollback ownership conflict", %{
    root: root
  } do
    {record, card} = real_record_and_card()
    entries = batch_entries(root, record, card)
    sentinel = Path.join(root, "sentinel")
    File.write!(sentinel, "replacement")

    event_hook = fn
      {:stage_created, %{index: 1, path: stage_path}} ->
        File.rm!(stage_path)
        File.ln_s!(sentinel, stage_path)

      _event ->
        :ok
    end

    assert {:error,
            {:stage_failed, _path, :injected_failure,
             %{failures: [], conflicts: [conflict], leftovers: [leftover]}}} =
             Record.write_batch(entries, fail_at: {:stage, 2}, event_hook: event_hook)

    assert conflict == %{path: leftover, reason: :ownership_mismatch}
    assert File.lstat!(leftover).type == :symlink
    assert File.read!(leftover) == "replacement"
    assert File.read!(sentinel) == "replacement"
  end

  test "later publish failure rolls back invocation-created finals and staging", %{root: root} do
    {record, card} = real_record_and_card()
    entries = batch_entries(root, record, card)

    assert {:error,
            {:publish_failed, _path, :injected_failure,
             %{failures: [], conflicts: [], leftovers: []}}} =
             Record.write_batch(entries, fail_at: {:publish, 2})

    assert File.ls!(root) == []
  end

  test "published final replacement survives later failure and is reported", %{root: root} do
    {record, card} = real_record_and_card()
    [first | _] = entries = batch_entries(root, record, card)

    event_hook = fn
      {:published, %{index: 1, path: path}} ->
        File.rm!(path)
        File.write!(path, "replacement")

      _event ->
        :ok
    end

    assert {:error,
            {:publish_failed, _path, :injected_failure,
             %{failures: [], conflicts: [conflict], leftovers: [leftover]}}} =
             Record.write_batch(entries, fail_at: {:publish, 2}, event_hook: event_hook)

    assert conflict == %{path: first.path, reason: :ownership_mismatch}
    assert leftover == first.path
    assert File.read!(first.path) == "replacement"
    refute File.exists?(Enum.at(entries, 1).path)
  end

  test "rollback removal failures are surfaced with leftover paths", %{root: root} do
    {record, card} = real_record_and_card()
    entries = batch_entries(root, record, card)
    remove = fn _path -> {:error, :eacces} end

    assert {:error,
            {:stage_failed, _path, :injected_failure,
             %{failures: [failure], conflicts: [], leftovers: [leftover]}}} =
             Record.write_batch(entries, fail_at: {:stage, 2}, remove: remove)

    assert failure == %{path: leftover, reason: :eacces}
    assert File.exists?(leftover)
    refute leftover in Enum.map(entries, & &1.path)
  end

  test "successful publication still surfaces stage cleanup failures", %{root: root} do
    {record, card} = real_record_and_card()
    [entry | _] = batch_entries(root, record, card)
    remove = fn _path -> {:error, :eacces} end

    assert {:error,
            {:cleanup_failed, %{failures: [failure], conflicts: [], leftovers: [leftover]}}} =
             Record.write_batch([entry], remove: remove)

    assert failure == %{path: leftover, reason: :eacces}
    assert File.exists?(entry.path)
    assert File.exists?(leftover)
  end

  test "task renders original and rollback failures without credential leakage", %{root: root} do
    {record, card} = real_record_and_card()
    previous_key = System.get_env("TYPESAFE_API_KEY")
    System.put_env("TYPESAFE_API_KEY", "super-secret-test-key")

    on_exit(fn ->
      if previous_key,
        do: System.put_env("TYPESAFE_API_KEY", previous_key),
        else: System.delete_env("TYPESAFE_API_KEY")
    end)

    failed_path = Path.join(root, "output/#{card["id"]}.json")
    leftover = Path.join(root, "output/.owned.stage")

    batch_writer = fn _entries ->
      {:error,
       {:publish_failed, failed_path, :eio,
        %{
          failures: [%{path: leftover, reason: :eacces}],
          conflicts: [],
          leftovers: [leftover]
        }}}
    end

    error =
      assert_raise Mix.Error, fn ->
        Record.run(
          ["--card", card["id"], "--output", Path.join(root, "output")],
          client_factory: fn _opts -> :client end,
          evaluator: fn :client, ^card, _opts -> {:ok, record} end,
          batch_writer: batch_writer
        )
      end

    assert error.message =~ "cannot publish #{failed_path}:"
    assert error.message =~ ~r/I\/O error/i
    assert error.message =~ "rollback incomplete"
    assert error.message =~ "removal failed for #{leftover}: permission denied"
    assert error.message =~ "leftovers: #{leftover}"
    refute error.message =~ "super-secret-test-key"
  end

  test "pre-existing destinations remain untouched and prevent all staging", %{root: root} do
    {record, card} = real_record_and_card()
    [first, second] = entries = batch_entries(root, record, card)
    File.write!(first.path, "sentinel")

    assert {:error, {:already_exists, [existing]}} = Record.write_batch(entries)
    assert existing == first.path
    assert File.read!(first.path) == "sentinel"
    refute File.exists?(second.path)
    assert File.ls!(root) == [Path.basename(first.path)]
  end

  test "all records validate before any staging begins", %{root: root} do
    {record, card} = real_record_and_card()
    [first, second] = batch_entries(root, record, card)
    invalid = %{second | record: %{"schema_version" => 1}}
    invalid_path = second.path

    assert {:error, {:invalid_record, ^invalid_path, _reason}} =
             Record.write_batch([first, invalid])

    assert File.ls!(root) == []
  end

  test "successful immutable batch writes complete valid JSON", %{root: root} do
    {record, card} = real_record_and_card()
    entries = batch_entries(root, record, card)

    assert :ok = Record.write_batch(entries)

    for entry <- entries do
      decoded = entry.path |> File.read!() |> Jason.decode!()
      assert decoded == record
      assert {:ok, ^decoded} = SabrJev.Judgments.validate_record(decoded, card)
    end

    assert Enum.sort(File.ls!(root)) ==
             entries |> Enum.map(&Path.basename(&1.path)) |> Enum.sort()
  end

  defp batch_entries(root, record, card) do
    for suffix <- ["one", "two"] do
      %{path: Path.join(root, "#{suffix}.json"), record: record, card: card}
    end
  end

  defp real_record_and_card do
    catalog = Jason.decode!(File.read!("priv/data/cards.json"))
    cards = Map.new(catalog["cards"], &{&1["id"], &1})
    path = "priv/jev/recordings/batter--judgeaa01--2024.json"
    record = Jason.decode!(File.read!(path))
    {record, cards[record["card_id"]]}
  end
end
