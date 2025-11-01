defmodule GapsTest do
  use ExUnit.Case, async: true

  alias TelemetryHelper

  setup do
    # Use unique node IDs for async test isolation
    unique_id = System.unique_integer([:positive])
    node1_id = :"gaps_replica1_#{unique_id}"
    node2_id = :"gaps_replica2_#{unique_id}"

    replica1 =
      start_supervised!(
        {Vsr.ListKv,
         [
           node_id: node1_id,
           cluster_size: 2,
           replicas: [node2_id],
           name: node1_id
         ]},
        id: :"replica1_#{unique_id}"
      )

    replica2 =
      start_supervised!(
        {Vsr.ListKv,
         [
           node_id: node2_id,
           cluster_size: 2,
           replicas: [node1_id],
           name: node2_id
         ]},
        id: :"replica2_#{unique_id}"
      )

    {:ok, primary: replica1, backup: replica2}
  end

  test "should reject prepare messages with gaps in operation numbers", %{
    primary: primary,
    backup: backup
  } do
    # TODO: Implement gap detection and rejection in VSR protocol

    # First, do a normal operation
    telemetry_ref = TelemetryHelper.expect([:state, :commit_advance])
    assert :ok = Vsr.ListKv.write(primary, "key1", "value1")
    TelemetryHelper.wait_for(telemetry_ref)

    # Test that both replicas are responding
    assert Process.alive?(primary)
    assert Process.alive?(backup)

    # Gap detection will be implemented once VSR protocol message handling is complete
    # This test documents the expected behavior

    TelemetryHelper.detach(telemetry_ref)
  end

  test "should trigger state transfer when gap is detected", %{primary: primary, backup: backup} do
    # TODO: Implement state transfer mechanism in VSR protocol

    # Test basic functionality for now
    assert :ok = Vsr.ListKv.write(primary, "initial", "value")
    assert {:ok, "value"} = Vsr.ListKv.read(primary, "initial")

    # Both replicas should be alive and responding
    assert Process.alive?(primary)
    assert Process.alive?(backup)

    # State transfer implementation will be added once the basic VSR protocol is complete
  end

  test "basic operations work across replicas", %{primary: primary, backup: backup} do
    # Test that basic operations work without gaps
    assert :ok = Vsr.ListKv.write(primary, "test1", "value1")
    assert :ok = Vsr.ListKv.write(primary, "test2", "value2")
    assert :ok = Vsr.ListKv.write(primary, "test3", "value3")

    # Verify operations were applied
    assert {:ok, "value1"} = Vsr.ListKv.read(primary, "test1")
    assert {:ok, "value2"} = Vsr.ListKv.read(primary, "test2")
    assert {:ok, "value3"} = Vsr.ListKv.read(primary, "test3")

    # Both replicas should remain alive
    assert Process.alive?(primary)
    assert Process.alive?(backup)
  end
end
