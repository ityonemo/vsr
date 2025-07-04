defmodule VsrTest do
  use ExUnit.Case

  setup do
    # Start replicas without global names to avoid conflicts
    {:ok, replica1} = start_replica(1)
    {:ok, replica2} = start_replica(2)
    {:ok, replica3} = start_replica(3)

    # Connect replicas to form a cluster
    :ok = Vsr.connect(replica1, replica2)
    :ok = Vsr.connect(replica1, replica3)
    :ok = Vsr.connect(replica2, replica1)
    :ok = Vsr.connect(replica2, replica3)
    :ok = Vsr.connect(replica3, replica1)
    :ok = Vsr.connect(replica3, replica2)

    {:ok, replicas: [replica1, replica2, replica3]}
  end

  defp start_replica(_id) do
    # Use empty list as initial log (list log implementation)
    # Start VSR replica directly without global registration
    {:ok, pid} =
      GenServer.start_link(Vsr,
        log: [],
        state_machine: VsrKv,
        cluster_size: 3
      )

    {:ok, pid}
  end

  test "basic put and get operations", %{replicas: [replica1, _, _]} do
    # Test basic KV operations
    assert :ok = VsrKv.put(replica1, "key1", "value1")
    assert "value1" = VsrKv.get(replica1, "key1")
    assert {:ok, "value1"} = VsrKv.fetch(replica1, "key1")
  end

  test "operations are replicated across cluster", %{replicas: [replica1, replica2, replica3]} do
    # Put on one replica
    assert :ok = VsrKv.put(replica1, "replicated_key", "replicated_value")

    # Small delay to allow replication
    Process.sleep(100)

    # Should be available on all replicas
    assert "replicated_value" = VsrKv.get(replica1, "replicated_key")
    assert "replicated_value" = VsrKv.get(replica2, "replicated_key")
    assert "replicated_value" = VsrKv.get(replica3, "replicated_key")
  end

  test "delete operations", %{replicas: [replica1, _, _]} do
    # Put then delete
    assert :ok = VsrKv.put(replica1, "temp_key", "temp_value")
    assert "temp_value" = VsrKv.get(replica1, "temp_key")

    assert :ok = VsrKv.delete(replica1, "temp_key")
    assert :error = VsrKv.fetch(replica1, "temp_key")
    assert VsrKv.get(replica1, "temp_key") == nil
  end

  test "fetch! raises on missing key", %{replicas: [replica1, _, _]} do
    assert_raise KeyError, fn ->
      VsrKv.fetch!(replica1, "nonexistent_key")
    end
  end

  test "get with default value", %{replicas: [replica1, _, _]} do
    assert "default" = VsrKv.get(replica1, "missing_key", "default")
    assert VsrKv.get(replica1, "missing_key") == nil
  end

  test "concurrent operations maintain consistency", %{replicas: [replica1, replica2, replica3]} do
    # Perform concurrent operations
    tasks =
      for i <- 1..10 do
        Task.async(fn ->
          VsrKv.put(replica1, "concurrent_#{i}", "value_#{i}")
        end)
      end

    # Wait for all operations to complete
    Enum.each(tasks, &Task.await/1)

    # Small delay for replication
    Process.sleep(200)

    # Verify all values are present on all replicas
    for i <- 1..10 do
      key = "concurrent_#{i}"
      expected = "value_#{i}"

      assert ^expected = VsrKv.get(replica1, key)
      assert ^expected = VsrKv.get(replica2, key)
      assert ^expected = VsrKv.get(replica3, key)
    end
  end

  test "view number starts at 0", %{replicas: [replica1, _, _]} do
    state = Vsr.dump(replica1)
    assert state.view_number == 0
  end

  test "operation number increments", %{replicas: [replica1, _, _]} do
    initial_state = Vsr.dump(replica1)
    initial_op = initial_state.op_number

    VsrKv.put(replica1, "test", "value")
    Process.sleep(50)

    new_state = Vsr.dump(replica1)
    assert new_state.op_number > initial_op
  end

  test "log entries are maintained", %{replicas: [replica1, _, _]} do
    VsrKv.put(replica1, "log_test", "log_value")
    Process.sleep(50)

    state = Vsr.dump(replica1)
    log_entries = state.log

    # Should have at least one entry
    assert length(log_entries) > 0

    # Most recent entry should contain our operation
    [latest_entry | _] = log_entries
    assert latest_entry.operation == {:put, "log_test", "log_value"}
  end

  test "diagnostic: check quorum and primary", %{replicas: [replica1, replica2, replica3]} do
    # Check quorum status on each replica
    state1 = Vsr.dump(replica1)
    state2 = Vsr.dump(replica2)
    state3 = Vsr.dump(replica3)

    "Replica 1 - Connected: #{MapSet.size(state1.replicas)}, Cluster Size: #{state1.cluster_size}"

    "Replica 2 - Connected: #{MapSet.size(state2.replicas)}, Cluster Size: #{state2.cluster_size}"

    "Replica 3 - Connected: #{MapSet.size(state3.replicas)}, Cluster Size: #{state3.cluster_size}"

    # Check which replica thinks it's primary

    # Basic assertions
    assert state1.cluster_size == 3
    assert state2.cluster_size == 3
    assert state3.cluster_size == 3
  end

  test "diagnostic: manual client request", %{replicas: [replica1, _, _]} do
    initial_state = Vsr.dump(replica1)

    "Before operation - Op number: #{initial_state.op_number}, Log length: #{length(initial_state.log)}"

    # Try a manual client request
    _result = VsrKv.put(replica1, "debug_key", "debug_value")

    Process.sleep(100)

    final_state = Vsr.dump(replica1)

    "After operation - Op number: #{final_state.op_number}, Log length: #{length(final_state.log)}"

    # Check if operation was logged
    if length(final_state.log) > 0 do
      [_latest_entry | _] = final_state.log
    end
  end

  test "replicas maintain connected state", %{replicas: [replica1, replica2, replica3]} do
    state1 = Vsr.dump(replica1)
    state2 = Vsr.dump(replica2)
    state3 = Vsr.dump(replica3)

    # Each replica should be connected to the other two
    assert MapSet.size(state1.replicas) == 2
    assert MapSet.size(state2.replicas) == 2
    assert MapSet.size(state3.replicas) == 2

    # Verify cross-connections
    assert replica2 in state1.replicas
    assert replica3 in state1.replicas
    assert replica1 in state2.replicas
    assert replica3 in state2.replicas
    assert replica1 in state3.replicas
    assert replica2 in state3.replicas
  end
end
