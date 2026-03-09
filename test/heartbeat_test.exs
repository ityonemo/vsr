defmodule HeartbeatTest do
  use ExUnit.Case, async: true

  alias TelemetryHelper

  setup do
    # Use unique node IDs for async test isolation
    unique_id = System.unique_integer([:positive])
    node1_id = :"heartbeat_replica1_#{unique_id}"
    node2_id = :"heartbeat_replica2_#{unique_id}"
    node3_id = :"heartbeat_replica3_#{unique_id}"

    replica1 =
      start_supervised!(
        {Vsr.ListKv,
         [
           node_id: node1_id,
           cluster_size: 3,
           replicas: [node2_id, node3_id],
           # Fast heartbeat for testing
           heartbeat_interval: 100,
           # Fast timeout for testing
           primary_inactivity_timeout: 300,
           # Use same atom for name and node_id
           name: node1_id
         ]},
        id: :"heartbeat_replica1_#{unique_id}"
      )

    replica2 =
      start_supervised!(
        {Vsr.ListKv,
         [
           node_id: node2_id,
           cluster_size: 3,
           replicas: [node1_id, node3_id],
           heartbeat_interval: 100,
           primary_inactivity_timeout: 300,
           # Use same atom for name and node_id
           name: node2_id
         ]},
        id: :"heartbeat_replica2_#{unique_id}"
      )

    replica3 =
      start_supervised!(
        {Vsr.ListKv,
         [
           node_id: node3_id,
           cluster_size: 3,
           replicas: [node1_id, node2_id],
           heartbeat_interval: 100,
           primary_inactivity_timeout: 300,
           # Use same atom for name and node_id
           name: node3_id
         ]},
        id: :"heartbeat_replica3_#{unique_id}"
      )

    {:ok, replicas: [replica1, replica2, replica3]}
  end

  test "primary should send heartbeats to replicas", %{replicas: replicas} do
    # For now, just test that heartbeat mechanism exists in code
    # The actual heartbeat sending requires timer implementation

    # All replicas should be alive and responding
    Enum.each(replicas, fn replica ->
      assert Process.alive?(replica), "Replica should be alive"
    end)

    # This test documents that heartbeat implementation is needed
    # Currently heartbeat_impl/2 exists but doesn't send heartbeats
    # TODO: Implement actual heartbeat timer and verify heartbeat sending
  end

  test "backup should detect primary failure and trigger view change", %{
    replicas: [replica1, _replica2, _replica3]
  } do
    # This test documents view change behavior but is currently simplified
    # TODO: Implement proper view change testing once view change is fully implemented

    # For now, just verify the replica is alive and can handle messages
    assert Process.alive?(replica1), "Replica should be alive"

    # View change implementation will be tested once the protocol is complete
    # This test serves as a placeholder for the expected behavior
  end

  test "heartbeat should reset primary inactivity timer", %{
    replicas: [_replica1, replica2, _replica3]
  } do
    # This test documents what should happen but won't work until timers implemented

    # Simulate receiving heartbeat
    telemetry_ref = TelemetryHelper.expect([:timer, :heartbeat_received])
    heartbeat = %Vsr.Message.Heartbeat{}
    VsrServer.vsr_send(replica2, heartbeat)

    # Wait for heartbeat to be processed
    TelemetryHelper.wait_for(telemetry_ref)

    # Replica should still be alive and responding
    assert Process.alive?(replica2), "Replica should handle heartbeat without crashing"

    TelemetryHelper.detach(telemetry_ref)
  end

  test "primary sends heartbeats and backup detects primary failure" do
    # Use predictable names: a < b < c in term_to_binary sort order
    # For view 0: rem(0, 3) = 0 → first in sorted order is primary
    unique_id = System.unique_integer([:positive])
    node_a = :"hbt_a_#{unique_id}"
    node_b = :"hbt_b_#{unique_id}"
    node_c = :"hbt_c_#{unique_id}"

    primary =
      start_supervised!(
        {Vsr.ListKv,
         [
           node_id: node_a,
           cluster_size: 3,
           replicas: [node_b, node_c],
           heartbeat_interval: 50,
           primary_inactivity_timeout: 200,
           name: node_a
         ]},
        id: :"hbt_a_#{unique_id}"
      )

    _backup1 =
      start_supervised!(
        {Vsr.ListKv,
         [
           node_id: node_b,
           cluster_size: 3,
           replicas: [node_a, node_c],
           heartbeat_interval: 50,
           primary_inactivity_timeout: 200,
           name: node_b
         ]},
        id: :"hbt_b_#{unique_id}"
      )

    _backup2 =
      start_supervised!(
        {Vsr.ListKv,
         [
           node_id: node_c,
           cluster_size: 3,
           replicas: [node_a, node_b],
           heartbeat_interval: 50,
           primary_inactivity_timeout: 200,
           name: node_c
         ]},
        id: :"hbt_c_#{unique_id}"
      )

    # Let heartbeats run — primary should send heartbeats
    telemetry_ref = TelemetryHelper.expect([:timer, :heartbeat_received])
    TelemetryHelper.wait_for(telemetry_ref, fn _ -> true end, 300)

    # Attach timeout listener BEFORE stopping primary so we can't miss the event
    telemetry_ref2 = TelemetryHelper.expect([:timer, :primary_timeout])

    # Stop the actual primary to simulate failure
    GenServer.stop(primary, :shutdown)

    # Register a dummy process under the dead primary's name so that
    # the backups' broadcast in start_manual_view_change doesn't crash
    # on send/2 to an unregistered atom.
    dummy = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(dummy, node_a)
    on_exit(fn -> Process.exit(dummy, :kill) end)

    # Wait for primary inactivity timeout to trigger on a backup
    TelemetryHelper.wait_for(telemetry_ref2, fn _ -> true end, 800)

    TelemetryHelper.detach(telemetry_ref)
    TelemetryHelper.detach(telemetry_ref2)
  end
end
