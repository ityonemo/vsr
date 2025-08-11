defmodule Maelstrom.DetsLogTest do
  use ExUnit.Case
  alias Maelstrom.DetsLog
  alias Vsr.Log.Entry

  @moduletag :maelstrom

  # Clean up test files after each test
  setup do
    test_file = "test_log_#{:rand.uniform(10000)}.dets"

    on_exit(fn ->
      File.rm(test_file)
    end)

    {:ok, dets_file: test_file}
  end

  describe "_new/2" do
    test "creates a new DETS log with default file", %{dets_file: dets_file} do
      log = DetsLog._new("test_node", dets_file: dets_file)

      assert %DetsLog{} = log
      assert log.table_name == :maelstrom_log_test_node
      assert log.dets_file == dets_file
      assert File.exists?(dets_file)
    end

    test "creates unique table names for different nodes" do
      log1 = DetsLog._new("node1", dets_file: "node1_test.dets")
      log2 = DetsLog._new("node2", dets_file: "node2_test.dets")

      assert log1.table_name == :maelstrom_log_node1
      assert log2.table_name == :maelstrom_log_node2
      assert log1.table_name != log2.table_name

      # Cleanup
      File.rm("node1_test.dets")
      File.rm("node2_test.dets")
    end

    test "creates directory if it doesn't exist" do
      test_dir = "tmp_test_#{:rand.uniform(10000)}"
      test_file = "#{test_dir}/test.dets"

      refute File.exists?(test_dir)

      _log = DetsLog._new("test", dets_file: test_file)

      assert File.exists?(test_dir)
      assert File.exists?(test_file)

      # Cleanup
      File.rm_rf!(test_dir)
    end
  end

  describe "Vsr.Log protocol implementation" do
    setup %{dets_file: dets_file} do
      log = DetsLog._new("test_node", dets_file: dets_file)
      {:ok, log: log}
    end

    test "append/2 adds entry to log", %{log: log} do
      entry = %Entry{
        view: 1,
        op_number: 1,
        operation: {:write, "key", "value"},
        sender_id: "client1"
      }

      updated_log = Vsr.Log.append(log, entry)

      # Should return same log instance
      assert updated_log == log
      assert {:ok, ^entry} = Vsr.Log.fetch(log, 1)
    end

    test "fetch/2 retrieves entry by operation number", %{log: log} do
      entry1 = %Entry{
        view: 1,
        op_number: 1,
        operation: {:write, "key1", "val1"},
        sender_id: "client1"
      }

      entry2 = %Entry{
        view: 1,
        op_number: 2,
        operation: {:write, "key2", "val2"},
        sender_id: "client2"
      }

      Vsr.Log.append(log, entry1)
      Vsr.Log.append(log, entry2)

      assert {:ok, ^entry1} = Vsr.Log.fetch(log, 1)
      assert {:ok, ^entry2} = Vsr.Log.fetch(log, 2)
      assert {:error, :not_found} = Vsr.Log.fetch(log, 3)
    end

    test "get_all/1 returns all entries in order", %{log: log} do
      entry1 = %Entry{
        view: 1,
        op_number: 1,
        operation: {:write, "key1", "val1"},
        sender_id: "client1"
      }

      entry2 = %Entry{
        view: 1,
        op_number: 2,
        operation: {:write, "key2", "val2"},
        sender_id: "client2"
      }

      entry3 = %Entry{view: 1, op_number: 3, operation: {:read, "key1"}, sender_id: "client3"}

      # Add out of order
      Vsr.Log.append(log, entry2)
      Vsr.Log.append(log, entry1)
      Vsr.Log.append(log, entry3)

      all_entries = Vsr.Log.get_all(log)

      assert length(all_entries) == 3
      # Should be sorted by op_number
      assert [^entry1, ^entry2, ^entry3] = all_entries
    end

    test "get_from/2 returns entries from specified operation number", %{log: log} do
      entry1 = %Entry{
        view: 1,
        op_number: 1,
        operation: {:write, "key1", "val1"},
        sender_id: "client1"
      }

      entry2 = %Entry{
        view: 1,
        op_number: 2,
        operation: {:write, "key2", "val2"},
        sender_id: "client2"
      }

      entry3 = %Entry{view: 1, op_number: 3, operation: {:read, "key1"}, sender_id: "client3"}

      Vsr.Log.append(log, entry1)
      Vsr.Log.append(log, entry2)
      Vsr.Log.append(log, entry3)

      from_2 = Vsr.Log.get_from(log, 2)
      assert [^entry2, ^entry3] = from_2

      from_1 = Vsr.Log.get_from(log, 1)
      assert [^entry1, ^entry2, ^entry3] = from_1

      from_4 = Vsr.Log.get_from(log, 4)
      assert [] = from_4
    end

    test "length/1 returns number of entries", %{log: log} do
      assert Vsr.Log.length(log) == 0

      entry1 = %Entry{
        view: 1,
        op_number: 1,
        operation: {:write, "key", "val"},
        sender_id: "client1"
      }

      Vsr.Log.append(log, entry1)
      assert Vsr.Log.length(log) == 1

      entry2 = %Entry{view: 1, op_number: 2, operation: {:read, "key"}, sender_id: "client2"}
      Vsr.Log.append(log, entry2)
      assert Vsr.Log.length(log) == 2
    end

    test "replace/2 replaces entire log with new entries", %{log: log} do
      # Add some initial entries
      entry1 = %Entry{
        view: 1,
        op_number: 1,
        operation: {:write, "key1", "val1"},
        sender_id: "client1"
      }

      Vsr.Log.append(log, entry1)
      assert Vsr.Log.length(log) == 1

      # Replace with new entries
      new_entry1 = %Entry{
        view: 2,
        op_number: 1,
        operation: {:write, "newkey1", "newval1"},
        sender_id: "client2"
      }

      new_entry2 = %Entry{
        view: 2,
        op_number: 2,
        operation: {:write, "newkey2", "newval2"},
        sender_id: "client3"
      }

      updated_log = Vsr.Log.replace(log, [new_entry1, new_entry2])

      assert updated_log == log
      assert Vsr.Log.length(log) == 2
      assert {:ok, ^new_entry1} = Vsr.Log.fetch(log, 1)
      assert {:ok, ^new_entry2} = Vsr.Log.fetch(log, 2)
    end

    test "clear/1 removes all entries", %{log: log} do
      # Add some entries
      entry1 = %Entry{
        view: 1,
        op_number: 1,
        operation: {:write, "key1", "val1"},
        sender_id: "client1"
      }

      entry2 = %Entry{
        view: 1,
        op_number: 2,
        operation: {:write, "key2", "val2"},
        sender_id: "client2"
      }

      Vsr.Log.append(log, entry1)
      Vsr.Log.append(log, entry2)
      assert Vsr.Log.length(log) == 2

      # Clear the log
      cleared_log = Vsr.Log.clear(log)

      assert cleared_log == log
      assert Vsr.Log.length(log) == 0
      assert [] = Vsr.Log.get_all(log)
    end

    test "persistence across log instances", %{dets_file: dets_file} do
      # Create first log instance and add data
      log1 = DetsLog._new("test_node", dets_file: dets_file)

      entry = %Entry{
        view: 1,
        op_number: 1,
        operation: {:write, "key", "value"},
        sender_id: "client1"
      }

      Vsr.Log.append(log1, entry)

      # Create second log instance with same file
      log2 = DetsLog._new("test_node", dets_file: dets_file)

      # Should be able to read the persisted data
      assert {:ok, ^entry} = Vsr.Log.fetch(log2, 1)
      assert Vsr.Log.length(log2) == 1
    end

    test "handles empty log operations gracefully", %{log: log} do
      assert [] = Vsr.Log.get_all(log)
      assert [] = Vsr.Log.get_from(log, 1)
      assert Vsr.Log.length(log) == 0
      assert {:error, :not_found} = Vsr.Log.fetch(log, 1)

      # Clear empty log should work
      cleared = Vsr.Log.clear(log)
      assert cleared == log
    end
  end
end
