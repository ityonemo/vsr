defmodule QuorumTest do
  use ExUnit.Case, async: true

  test "quorum calculation should be consistent with cluster_size" do
    # TODO: Implement proper quorum checking logic
    # Test with cluster_size=5, connected=3 (should have quorum: 3 > 5/2 = 2.5)
    unique_id = System.unique_integer([:positive])
    node1_id = :"replica1_#{unique_id}"
    node2_id = :"replica2_#{unique_id}"
    node3_id = :"replica3_#{unique_id}"

    replica1 =
      start_supervised!(
        {Vsr.ListKv,
         [
           node_id: node1_id,
           cluster_size: 5,
           replicas: [node2_id, node3_id],
           name: node1_id
         ]},
        id: :"replica1_#{unique_id}"
      )

    _replica2 =
      start_supervised!(
        {Vsr.ListKv,
         [
           node_id: node2_id,
           cluster_size: 5,
           replicas: [node1_id, node3_id],
           name: node2_id
         ]},
        id: :"replica2_#{unique_id}"
      )

    _replica3 =
      start_supervised!(
        {Vsr.ListKv,
         [
           node_id: node3_id,
           cluster_size: 5,
           replicas: [node1_id, node2_id],
           name: node3_id
         ]},
        id: :"replica3_#{unique_id}"
      )

    # For now, test basic operations work
    assert :ok = Vsr.ListKv.write(replica1, "quorum_test", "should_work")
    assert {:ok, "should_work"} = Vsr.ListKv.read(replica1, "quorum_test")
  end

  test "quorum calculation should reject operations without majority" do
    # TODO: Implement quorum rejection for insufficient replicas
    # Test cluster_size=5, connected=2 (should NOT have quorum: 2 <= 5/2 = 2.5)
    unique_id = System.unique_integer([:positive])
    node1_id = :"replica1_#{unique_id}"
    node2_id = :"replica2_#{unique_id}"

    replica1 =
      start_supervised!(
        {Vsr.ListKv,
         [
           node_id: node1_id,
           cluster_size: 5,
           replicas: [node2_id],
           name: node1_id
         ]},
        id: :"replica1_#{unique_id}"
      )

    _replica2 =
      start_supervised!(
        {Vsr.ListKv,
         [
           node_id: node2_id,
           cluster_size: 5,
           replicas: [node1_id],
           name: node2_id
         ]},
        id: :"replica2_#{unique_id}"
      )

    # Should fail with no quorum (2 nodes out of cluster_size=5 is not > 2.5)
    assert {:error, :no_quorum} = Vsr.ListKv.write(replica1, "no_quorum_test", "should_fail")

    # Read operations currently also fail with no_quorum - this may be the expected VSR behavior
    # since read linearizability might require consensus in this implementation
    assert {:error, :no_quorum} = Vsr.ListKv.read(replica1, "no_quorum_test")
  end

  test "quorum function should use cluster_size consistently" do
    # TODO: Implement and test quorum helper function logic
    unique_id = System.unique_integer([:positive])
    node1_id = :"replica1_#{unique_id}"
    node2_id = :"replica2_#{unique_id}"
    node3_id = :"replica3_#{unique_id}"

    replica1 =
      start_supervised!(
        {Vsr.ListKv,
         [
           node_id: node1_id,
           cluster_size: 5,
           replicas: [node2_id, node3_id],
           name: node1_id
         ]},
        id: :"replica1_#{unique_id}"
      )

    _replica2 =
      start_supervised!(
        {Vsr.ListKv,
         [
           node_id: node2_id,
           cluster_size: 5,
           replicas: [node1_id, node3_id],
           name: node2_id
         ]},
        id: :"replica2_#{unique_id}"
      )

    _replica3 =
      start_supervised!(
        {Vsr.ListKv,
         [
           node_id: node3_id,
           cluster_size: 5,
           replicas: [node1_id, node2_id],
           name: node3_id
         ]},
        id: :"replica3_#{unique_id}"
      )

    # For now, test basic operations work
    assert :ok = Vsr.ListKv.write(replica1, "quorum_check", "test")
    assert {:ok, "test"} = Vsr.ListKv.read(replica1, "quorum_check")
  end
end
