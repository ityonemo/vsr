defmodule DeduplicationTest do
  use ExUnit.Case, async: true

  setup do
    # Use unique node IDs for async test isolation
    unique_id = System.unique_integer([:positive])
    node1_id = :"dedup_replica1_#{unique_id}"
    node2_id = :"dedup_replica2_#{unique_id}"

    replica1 =
      start_supervised!(
        {Vsr.ListKv,
         [
           node_id: node1_id,
           cluster_size: 2,
           replicas: [node2_id],
           # Use same atom for name and node_id
           name: node1_id
         ]},
        id: :"dedup_replica1_#{unique_id}"
      )

    replica2 =
      start_supervised!(
        {Vsr.ListKv,
         [
           node_id: node2_id,
           cluster_size: 2,
           replicas: [node1_id],
           # Use same atom for name and node_id
           name: node2_id
         ]},
        id: :"dedup_replica2_#{unique_id}"
      )

    {:ok, primary: replica1, backup: replica2}
  end

  test "duplicate client requests should be deduplicated", %{
    primary: primary
  } do
    # TODO: Implement request deduplication in VSR protocol
    # This is a placeholder test that documents the expected behavior

    # Test basic write operations work
    assert :ok = Vsr.ListKv.write(primary, "test_key", "value1")
    assert {:ok, "value1"} = Vsr.ListKv.read(primary, "test_key")

    # Deduplication will be implemented later with proper request ID tracking
  end

  test "basic operations work without deduplication", %{primary: primary} do
    # Test that basic KV operations work in the new architecture
    assert :ok = Vsr.ListKv.write(primary, "key1", "value1")
    # Overwrite
    assert :ok = Vsr.ListKv.write(primary, "key1", "value2")

    assert {:ok, "value2"} = Vsr.ListKv.read(primary, "key1")
    assert {:ok, nil} = Vsr.ListKv.read(primary, "nonexistent")
  end

  test "replica servers start successfully", %{primary: primary, backup: _backup} do
    # Basic test that both replicas are alive and responding

    # Test that primary can handle basic operations
    assert :ok = Vsr.ListKv.write(primary, "test", "value")
    assert {:ok, "value"} = Vsr.ListKv.read(primary, "test")
  end
end
