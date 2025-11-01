defmodule SetClusterTest do
  use ExUnit.Case, async: true

  alias TelemetryHelper

  test "set_cluster updates cluster configuration" do
    unique_id = System.unique_integer([:positive])
    node_id = :"test_node_#{unique_id}"

    # Start VSR with minimal cluster configuration
    {:ok, pid} =
      start_supervised(
        {Vsr.ListKv,
         [
           node_id: node_id,
           # Start with single node
           cluster_size: 1,
           # No replicas initially
           replicas: [],
           name: node_id
         ]},
        id: :"test_node_#{unique_id}"
      )

    # Verify initial state
    initial_state = VsrServer.dump(pid)
    assert initial_state.cluster_size == 1
    assert MapSet.size(initial_state.replicas) == 0

    # Update cluster configuration
    node2_id = :"test_node2_#{unique_id}"
    node3_id = :"test_node3_#{unique_id}"

    assert :ok = VsrServer.set_cluster(pid, node_id, [node2_id, node3_id])

    # Verify updated state
    updated_state = VsrServer.dump(pid)
    assert updated_state.cluster_size == 3
    assert MapSet.size(updated_state.replicas) == 2
    assert node2_id in updated_state.replicas
    assert node3_id in updated_state.replicas
  end

  test "set_cluster can update partial configuration" do
    unique_id = System.unique_integer([:positive])
    node_id = :"partial_node_#{unique_id}"

    # Start VSR with initial configuration
    {:ok, pid} =
      start_supervised(
        {Vsr.ListKv,
         [
           node_id: node_id,
           cluster_size: 2,
           replicas: [:other_node],
           name: node_id
         ]},
        id: :"partial_node_#{unique_id}"
      )

    # Update cluster with new replica
    new_replica = :"new_replica_#{unique_id}"
    assert :ok = VsrServer.set_cluster(pid, node_id, [:other_node, new_replica])

    # Verify cluster_size changed to 3 (1 current + 2 replicas), replicas updated
    updated_state = VsrServer.dump(pid)
    assert updated_state.cluster_size == 3
    assert :other_node in updated_state.replicas
    assert new_replica in updated_state.replicas
  end

  test "set_cluster updates cluster configuration asynchronously" do
    unique_id = System.unique_integer([:positive])
    node_id = :"async_node_#{unique_id}"

    # Start VSR with minimal cluster configuration
    {:ok, pid} =
      start_supervised(
        {Vsr.ListKv,
         [
           node_id: node_id,
           cluster_size: 1,
           replicas: [],
           name: node_id
         ]},
        id: :"async_node_#{unique_id}"
      )

    # Verify initial state
    initial_state = VsrServer.dump(pid)
    assert initial_state.cluster_size == 1
    assert MapSet.size(initial_state.replicas) == 0

    # Update cluster configuration
    node2_id = :"async_node2_#{unique_id}"
    node3_id = :"async_node3_#{unique_id}"

    # set_cluster is async (cast), so we can't wait for a specific event
    # Just give it a small moment to process
    assert :ok = VsrServer.set_cluster(pid, node_id, [node2_id, node3_id])
    Process.sleep(10)

    # Verify updated state
    updated_state = VsrServer.dump(pid)
    assert updated_state.cluster_size == 3
    assert MapSet.size(updated_state.replicas) == 2
    assert node2_id in updated_state.replicas
    assert node3_id in updated_state.replicas
  end
end
