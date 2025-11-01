defmodule VsrTest do
  use ExUnit.Case, async: true

  alias TelemetryHelper

  setup do
    test_id = :erlang.unique_integer([:positive])
    node1_id = :"replica1_#{test_id}"
    node2_id = :"replica2_#{test_id}"
    node3_id = :"replica3_#{test_id}"

    # Configure as a 3-node cluster with proper communication
    replica1 =
      start_supervised!(
        {Vsr.ListKv,
         [
           node_id: node1_id,
           cluster_size: 3,
           replicas: [node2_id, node3_id],
           name: node1_id
         ]},
        id: :"replica1_#{test_id}"
      )

    replica2 =
      start_supervised!(
        {Vsr.ListKv,
         [
           node_id: node2_id,
           cluster_size: 3,
           replicas: [node1_id, node3_id],
           name: node2_id
         ]},
        id: :"replica2_#{test_id}"
      )

    replica3 =
      start_supervised!(
        {Vsr.ListKv,
         [
           node_id: node3_id,
           cluster_size: 3,
           replicas: [node1_id, node2_id],
           name: node3_id
         ]},
        id: :"replica3_#{test_id}"
      )

    {:ok, replicas: [replica1, replica2, replica3]}
  end

  test "basic put and get operations", %{replicas: [replica1 | _]} do
    # Test basic KV operations
    assert :ok = Vsr.ListKv.write(replica1, "key1", "value1")
    assert {:ok, "value1"} = Vsr.ListKv.read(replica1, "key1")
  end

  test "fetch on a missing value", %{replicas: [replica1 | _]} do
    # Fetching a non-existent key should return :error
    assert {:ok, nil} = Vsr.ListKv.read(replica1, "missing_key")
  end

  test "operations are replicated across cluster", %{replicas: [replica1, replica2, replica3]} do
    # Put on one replica
    telemetry_ref = TelemetryHelper.expect([:state, :commit_advance])
    assert :ok = Vsr.ListKv.write(replica1, "replicated_key", "replicated_value")
    TelemetryHelper.wait_for(telemetry_ref)

    # Should be available on all replicas
    assert {:ok, "replicated_value"} = Vsr.ListKv.read(replica1, "replicated_key")
    assert {:ok, "replicated_value"} = Vsr.ListKv.read(replica2, "replicated_key")
    assert {:ok, "replicated_value"} = Vsr.ListKv.read(replica3, "replicated_key")

    TelemetryHelper.detach(telemetry_ref)
  end

  test "delete operations", %{replicas: [replica1 | _]} do
    # Put then delete
    assert :ok = Vsr.ListKv.write(replica1, "temp_key", "temp_value")
    assert {:ok, "temp_value"} = Vsr.ListKv.read(replica1, "temp_key")

    assert :ok = Vsr.ListKv.delete(replica1, "temp_key")
    assert {:ok, nil} = Vsr.ListKv.read(replica1, "temp_key")
  end

  test "concurrent operations maintain consistency", %{replicas: [replica1, replica2, replica3]} do
    # Set up expectation BEFORE performing operations to avoid race
    telemetry_ref = TelemetryHelper.expect([:state, :commit_advance])

    # Perform concurrent operations
    tasks =
      for i <- 1..10 do
        Task.async(fn ->
          Vsr.ListKv.write(replica1, "concurrent_#{i}", "value_#{i}")
        end)
      end

    # Wait for all operations to complete
    Enum.each(tasks, &Task.await/1)

    # Wait for last operation to be committed (they're sequential through the primary)
    TelemetryHelper.wait_for(telemetry_ref, &(&1.new_commit_number >= 10), 500)

    # Verify all values are present on all replicas
    for i <- 1..10 do
      key = "concurrent_#{i}"
      expected = "value_#{i}"

      assert {:ok, ^expected} = Vsr.ListKv.read(replica1, key)
      assert {:ok, ^expected} = Vsr.ListKv.read(replica2, key)
      assert {:ok, ^expected} = Vsr.ListKv.read(replica3, key)
    end

    TelemetryHelper.detach(telemetry_ref)
  end

  test "view number starts at 0", %{replicas: [replica1 | _]} do
    state = VsrServer.dump(replica1)
    assert state.view_number == 0
  end

  test "operation number increments", %{replicas: [replica1 | _]} do
    initial_state = VsrServer.dump(replica1)
    initial_op = initial_state.op_number

    telemetry_ref = TelemetryHelper.expect([:state, :commit_advance])
    Vsr.ListKv.write(replica1, "test", "value")
    TelemetryHelper.wait_for(telemetry_ref)

    new_state = VsrServer.dump(replica1)
    assert new_state.op_number > initial_op

    TelemetryHelper.detach(telemetry_ref)
  end

  test "log entries are maintained", %{replicas: [replica1 | _]} do
    telemetry_ref = TelemetryHelper.expect([:state, :commit_advance])
    Vsr.ListKv.write(replica1, "log_test", "log_value")
    TelemetryHelper.wait_for(telemetry_ref)

    state = VsrServer.dump(replica1)
    log_entries = state.log

    # Should have at least one entry
    assert length(log_entries) > 0

    # Most recent entry should contain our operation
    [latest_entry | _] = log_entries
    assert latest_entry.operation == {:write, "log_test", "log_value"}

    TelemetryHelper.detach(telemetry_ref)
  end

  test "diagnostic: check quorum and primary", %{replicas: [replica1, replica2, replica3]} do
    # Check quorum status on each replica
    state1 = VsrServer.dump(replica1)
    state2 = VsrServer.dump(replica2)
    state3 = VsrServer.dump(replica3)

    "Replica 1 - Connected: #{MapSet.size(state1.replicas)}, Cluster Size: #{state1.cluster_size}"

    "Replica 2 - Connected: #{MapSet.size(state2.replicas)}, Cluster Size: #{state2.cluster_size}"

    "Replica 3 - Connected: #{MapSet.size(state3.replicas)}, Cluster Size: #{state3.cluster_size}"

    # Check which replica thinks it's primary

    # Basic assertions
    assert state1.cluster_size == 3
    assert state2.cluster_size == 3
    assert state3.cluster_size == 3
  end

  test "diagnostic: manual client request", %{replicas: [replica1 | _]} do
    initial_state = VsrServer.dump(replica1)

    "Before operation - Op number: #{initial_state.op_number}, Log length: #{length(initial_state.log)}"

    # Try a manual client request
    telemetry_ref = TelemetryHelper.expect([:state, :commit_advance])
    _result = Vsr.ListKv.write(replica1, "debug_key", "debug_value")
    TelemetryHelper.wait_for(telemetry_ref)

    final_state = VsrServer.dump(replica1)

    "After operation - Op number: #{final_state.op_number}, Log length: #{length(final_state.log)}"

    # Check if operation was logged
    if length(final_state.log) > 0 do
      [_latest_entry | _] = final_state.log
    end

    TelemetryHelper.detach(telemetry_ref)
  end

  test "replicas maintain connected state", %{replicas: [replica1, replica2, replica3]} do
    state1 = VsrServer.dump(replica1)
    state2 = VsrServer.dump(replica2)
    state3 = VsrServer.dump(replica3)

    # Each replica should be connected to the other two
    assert MapSet.size(state1.replicas) == 2
    assert MapSet.size(state2.replicas) == 2
    assert MapSet.size(state3.replicas) == 2

    # The replicas MapSet contains node_id atoms, not PIDs
    # Get the node IDs from the states to verify connections
    node2_id = state2.node_id
    node3_id = state3.node_id
    node1_id = state1.node_id

    assert node2_id in state1.replicas
    assert node3_id in state1.replicas
    assert node1_id in state2.replicas
    assert node3_id in state2.replicas
    assert node1_id in state3.replicas
    assert node2_id in state3.replicas
  end

  test "state machine operation span emits proper telemetry events", %{replicas: [replica1 | _]} do
    # Manually attach handlers to capture both measurements and metadata
    test_pid = self()
    start_handler_id = make_ref()
    stop_handler_id = make_ref()

    start_handler = fn [:vsr, :state_machine, :operation, :start], measurements, metadata, _ ->
      send(test_pid, {:span_start, measurements, metadata})
    end

    stop_handler = fn [:vsr, :state_machine, :operation, :stop], measurements, metadata, _ ->
      send(test_pid, {:span_stop, measurements, metadata})
    end

    :telemetry.attach(
      "span-start-#{inspect(start_handler_id)}",
      [:vsr, :state_machine, :operation, :start],
      start_handler,
      nil
    )

    :telemetry.attach(
      "span-stop-#{inspect(stop_handler_id)}",
      [:vsr, :state_machine, :operation, :stop],
      stop_handler,
      nil
    )

    # Perform an operation that will trigger the span
    Vsr.ListKv.write(replica1, "span_test", "value")

    # Wait for and verify start event
    assert_receive {:span_start, start_measurements, start_metadata}

    # Verify start event has proper measurements
    assert Map.has_key?(start_measurements, :monotonic_time)
    assert Map.has_key?(start_measurements, :system_time)

    # Verify start event has span context
    assert Map.has_key?(start_metadata, :telemetry_span_context)
    assert is_reference(start_metadata.telemetry_span_context)

    # Verify common metadata is present in start event
    assert Map.has_key?(start_metadata, :node_id)
    assert Map.has_key?(start_metadata, :view_number)

    # Wait for and verify stop event
    assert_receive {:span_stop, stop_measurements, stop_metadata}

    # Verify stop event has proper measurements
    assert Map.has_key?(stop_measurements, :monotonic_time)
    assert Map.has_key?(stop_measurements, :duration)

    # Verify stop event has span context
    assert Map.has_key?(stop_metadata, :telemetry_span_context)
    assert is_reference(stop_metadata.telemetry_span_context)

    :telemetry.detach("span-start-#{inspect(start_handler_id)}")
    :telemetry.detach("span-stop-#{inspect(stop_handler_id)}")
  end
end
