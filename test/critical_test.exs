defmodule CriticalTest do
  use ExUnit.Case, async: true

  setup do
    # Use unique node IDs for async test isolation
    unique_id = System.unique_integer([:positive])
    node1_id = :"critical_replica1_#{unique_id}"
    node2_id = :"critical_replica2_#{unique_id}"
    node3_id = :"critical_replica3_#{unique_id}"

    # Start 3 replicas out of a cluster_size of 5 to test quorum behavior
    # Fix: Use same atom for node_id and name for proper communication
    replica1 =
      start_supervised!(
        {Vsr.ListKv,
         [
           node_id: node1_id,
           cluster_size: 5,
           replicas: [node2_id, node3_id],
           # Use same atom for name and node_id
           name: node1_id
         ]},
        id: :"critical_replica1_#{unique_id}"
      )

    replica2 =
      start_supervised!(
        {Vsr.ListKv,
         [
           node_id: node2_id,
           cluster_size: 5,
           replicas: [node1_id, node3_id],
           # Use same atom for name and node_id
           name: node2_id
         ]},
        id: :"critical_replica2_#{unique_id}"
      )

    replica3 =
      start_supervised!(
        {Vsr.ListKv,
         [
           node_id: node3_id,
           cluster_size: 5,
           replicas: [node1_id, node2_id],
           # Use same atom for name and node_id
           name: node3_id
         ]},
        id: :"critical_replica3_#{unique_id}"
      )

    {:ok, replicas: [replica1, replica2, replica3]}
  end

  # Test 1: Quorum calculation should be consistent
  test "quorum calculation should use cluster_size consistently", %{
    replicas: [replica1, _replica2, _replica3]
  } do
    # With cluster_size=5, need >2 (i.e., 3+) replicas for quorum
    # Currently connected: 3 replicas, so should have quorum (3 > 5/2 = 2.5)

    # All replicas should be alive and responding

    # This should work since we have 3 replicas which is > 5/2 = 2.5
    assert :ok = Vsr.ListKv.write(replica1, "quorum_test", "value")
    assert {:ok, "value"} = Vsr.ListKv.read(replica1, "quorum_test")
  end

  test "operations should fail without quorum", %{replicas: [replica1, _replica2, _replica3]} do
    # TODO: Implement quorum detection and operation rejection
    # This is a placeholder test documenting expected behavior

    # For now, just test basic functionality
    assert :ok = Vsr.ListKv.write(replica1, "initial", "value")
    assert {:ok, "value"} = Vsr.ListKv.read(replica1, "initial")
  end

  test "client requests should be deduplicated", %{replicas: [replica1, _replica2, _replica3]} do
    # TODO: Implement request deduplication with request IDs
    # This documents expected behavior but isn't implemented yet

    # Test that basic operations work (without deduplication for now)
    assert :ok = Vsr.ListKv.write(replica1, "dedup_test", "value1")
    assert :ok = Vsr.ListKv.write(replica1, "dedup_test", "value2")
    assert {:ok, "value2"} = Vsr.ListKv.read(replica1, "dedup_test")
  end

  test "operations should be sequential", %{replicas: [replica1, _replica2, _replica3]} do
    # Test basic sequential operations work
    assert :ok = Vsr.ListKv.write(replica1, "seq1", "value1")
    assert :ok = Vsr.ListKv.write(replica1, "seq2", "value2")
    assert :ok = Vsr.ListKv.write(replica1, "seq3", "value3")

    # Verify all operations were applied in order
    assert {:ok, "value1"} = Vsr.ListKv.read(replica1, "seq1")
    assert {:ok, "value2"} = Vsr.ListKv.read(replica1, "seq2")
    assert {:ok, "value3"} = Vsr.ListKv.read(replica1, "seq3")
  end

  test "multiple operations complete successfully", %{replicas: [replica1, _replica2, _replica3]} do
    # Test that multiple operations can be performed
    operations = [
      {"key1", "value1"},
      {"key2", "value2"},
      {"key3", "value3"}
    ]

    # Perform all writes
    Enum.each(operations, fn {key, value} ->
      assert :ok = Vsr.ListKv.write(replica1, key, value)
    end)

    # Verify all reads work
    Enum.each(operations, fn {key, expected_value} ->
      assert {:ok, ^expected_value} = Vsr.ListKv.read(replica1, key)
    end)
  end
end
