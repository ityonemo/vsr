defmodule VsrTest do
  use ExUnit.Case

  setup do
    # Initialize VSR replicas with list log and VsrKv state machine
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

    # Create VsrKv instances
    kv1 = VsrKv.new(replica1, [])
    kv2 = VsrKv.new(replica2, [])
    kv3 = VsrKv.new(replica3, [])

    {:ok,
     %{
       replicas: [replica1, replica2, replica3],
       kvs: [kv1, kv2, kv3],
       kv1: kv1,
       kv2: kv2,
       kv3: kv3
     }}
  end

  defp start_replica(id) do
    # Use empty list as initial log (list log implementation)
    start_supervised({
      Vsr,
      [
        log: [],
        state_machine: VsrKv.new(self(), []),
        cluster_size: 3,
        name: :"replica_#{id}"
      ]
    })
  end

  test "basic put and get operations", %{kv1: kv1} do
    # Test basic KV operations
    assert :ok = VsrKv.put(kv1, "key1", "value1")
    assert "value1" = VsrKv.get(kv1, "key1")
    assert {:ok, "value1"} = VsrKv.fetch(kv1, "key1")
  end

  test "operations are replicated across cluster", %{kv1: kv1, kv2: kv2, kv3: kv3} do
    # Put on one replica
    assert :ok = VsrKv.put(kv1, "replicated_key", "replicated_value")

    # Small delay to allow replication
    Process.sleep(100)

    # Should be available on all replicas
    assert "replicated_value" = VsrKv.get(kv1, "replicated_key")
    assert "replicated_value" = VsrKv.get(kv2, "replicated_key")
    assert "replicated_value" = VsrKv.get(kv3, "replicated_key")
  end

  test "delete operations", %{kv1: kv1} do
    # Put then delete
    assert :ok = VsrKv.put(kv1, "temp_key", "temp_value")
    assert "temp_value" = VsrKv.get(kv1, "temp_key")

    assert :ok = VsrKv.delete(kv1, "temp_key")
    assert :error = VsrKv.fetch(kv1, "temp_key")
    assert VsrKv.get(kv1, "temp_key") == nil
  end

  test "fetch! raises on missing key", %{kv1: kv1} do
    assert_raise KeyError, fn ->
      VsrKv.fetch!(kv1, "nonexistent_key")
    end
  end

  test "get with default value", %{kv1: kv1} do
    assert "default" = VsrKv.get(kv1, "missing_key", "default")
    assert VsrKv.get(kv1, "missing_key") == nil
  end

  test "concurrent operations maintain consistency", %{kv1: kv1, kv2: kv2, kv3: kv3} do
    # Perform concurrent operations
    tasks =
      for i <- 1..10 do
        Task.async(fn ->
          VsrKv.put(kv1, "concurrent_#{i}", "value_#{i}")
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

      assert ^expected = VsrKv.get(kv1, key)
      assert ^expected = VsrKv.get(kv2, key)
      assert ^expected = VsrKv.get(kv3, key)
    end
  end

  test "view number starts at 0", %{replicas: [replica1, _, _]} do
    state = Vsr.dump(replica1)
    assert state.view_number == 0
  end

  test "operation number increments", %{kv1: kv1, replicas: [replica1, _, _]} do
    initial_state = Vsr.dump(replica1)
    initial_op = initial_state.op_number

    VsrKv.put(kv1, "test", "value")
    Process.sleep(50)

    new_state = Vsr.dump(replica1)
    assert new_state.op_number > initial_op
  end

  test "log entries are maintained", %{kv1: kv1, replicas: [replica1, _, _]} do
    VsrKv.put(kv1, "log_test", "log_value")
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

    IO.puts(
      "Replica 1 - Connected: #{MapSet.size(state1.replicas)}, Cluster Size: #{state1.cluster_size}"
    )

    IO.puts(
      "Replica 2 - Connected: #{MapSet.size(state2.replicas)}, Cluster Size: #{state2.cluster_size}"
    )

    IO.puts(
      "Replica 3 - Connected: #{MapSet.size(state3.replicas)}, Cluster Size: #{state3.cluster_size}"
    )

    # Check which replica thinks it's primary
    IO.puts("Replica 1 PID: #{inspect(replica1)}, View: #{state1.view_number}")
    IO.puts("Replica 2 PID: #{inspect(replica2)}, View: #{state2.view_number}")
    IO.puts("Replica 3 PID: #{inspect(replica3)}, View: #{state3.view_number}")

    # Basic assertions
    assert state1.cluster_size == 3
    assert state2.cluster_size == 3
    assert state3.cluster_size == 3
  end

  test "diagnostic: manual client request", %{kv1: kv1, replicas: [replica1, _, _]} do
    initial_state = Vsr.dump(replica1)

    IO.puts(
      "Before operation - Op number: #{initial_state.op_number}, Log length: #{length(initial_state.log)}"
    )

    # Try a manual client request
    result = VsrKv.put(kv1, "debug_key", "debug_value")
    IO.puts("Put result: #{inspect(result)}")

    Process.sleep(100)

    final_state = Vsr.dump(replica1)

    IO.puts(
      "After operation - Op number: #{final_state.op_number}, Log length: #{length(final_state.log)}"
    )

    # Check if operation was logged
    if length(final_state.log) > 0 do
      [latest_entry | _] = final_state.log
      IO.puts("Latest log entry: #{inspect(latest_entry)}")
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
