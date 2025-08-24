defmodule Maelstrom.KvServerTest do
  @moduledoc """
  Tests for Maelstrom Node KV message handling.

  NOTE: KV operations (read/write) are not yet implemented in Maelstrom.Message.
  These tests verify message parsing and basic node behavior.
  """

  use ExUnit.Case, async: true
  alias VsrServer

  setup t do
    # Use temporary directory for DETS files
    temp_dir = System.tmp_dir!()
    unique_id = System.unique_integer([:positive])
    node_id = "n1"
    dets_file = Path.join(temp_dir, "kv_test_#{unique_id}_log.dets")

    pid =
      start_supervised!({MaelstromKv, name: :"#{t.test}-node", dets_root: temp_dir})

    # Set cluster configuration (single-node cluster for unit tests)
    VsrServer.set_cluster(pid, node_id, [], 1)

    # Set up DETS log
    table_name = String.to_atom("kv_test_log_#{unique_id}")
    {:ok, log} = :dets.open_file(table_name, file: String.to_charlist(dets_file))
    VsrServer.set_log(pid, log)

    # Clean up DETS file on test completion
    on_exit(fn ->
      File.rm(dets_file)
    end)

    {:ok, pid: pid}
  end

  @tag :maelstrom
  test "kv server responds with init_ok and handles KV messages", %{pid: pid} do
    # Test read operation for non-existent key
    assert {:error, :not_found} = MaelstromKv.read(pid, "test_key", "c1", 10)

    # Test write operation
    assert :ok = MaelstromKv.write(pid, "test_key", "test_value", "c1", 20)

    # Test read operation after write
    assert {:ok, "test_value"} = MaelstromKv.read(pid, "test_key", "c1", 30)

    # Verify node is still alive and responsive after processing KV messages
    assert Process.alive?(pid)
  end

  @tag :maelstrom
  test "kv server responds with init_ok and handles CAS messages", %{pid: pid} do
    # Test CAS that should fail (key doesn't exist, so value is nil, not "old_value")
    assert {:error, :precondition_failed} =
             MaelstromKv.cas(pid, "cas_key", "old_value", "new_value", "c1", 10)

    # Test CAS that should succeed (key doesn't exist, so value is nil, CAS from nil)
    assert :ok = MaelstromKv.cas(pid, "cas_key2", nil, "initial_value", "c1", 20)

    # Verify the CAS worked by reading the value
    assert {:ok, "initial_value"} = MaelstromKv.read(pid, "cas_key2", "c1", 30)

    # Verify node is still alive after processing CAS messages
    assert Process.alive?(pid)
  end
end
