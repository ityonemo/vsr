defmodule Vsr.ReplicaTest do
  use ExUnit.Case, async: true
  alias Vsr.Replica
  alias Vsr.KV

  test "replica can be started" do
    {:ok, replica} = Replica.start_link(configuration: [self()])
    assert is_pid(replica)
  end

  test "replica state can be dumped" do
    {:ok, replica} = Replica.start_link(configuration: [self()])
    state = Replica.dump(replica)
    assert state.view_number == 0
    assert state.op_number == 0
    assert state.commit_number == 0
    assert state.status == :normal
  end

  test "replicas can connect to each other" do
    {:ok, replica1} = Replica.start_link(configuration: [self(), :replica2])
    {:ok, replica2} = Replica.start_link(configuration: [self(), :replica2])

    assert Replica.connect(replica1, replica2) == :ok
    assert Replica.connect(replica2, replica1) == :ok
  end

  test "key-value operations put and get operations" do
    {:ok, replica} = Replica.start_link(configuration: [self()])
    kv = KV.new(replica)

    assert KV.put(kv, "key1", "value1") == :ok
    assert KV.get(kv, "key1") == {:ok, "value1"}
    assert KV.get(kv, "nonexistent") == {:error, :not_found}
  end

  test "key-value operations delete operation" do
    {:ok, replica} = Replica.start_link(configuration: [self()])
    kv = KV.new(replica)

    KV.put(kv, "key1", "value1")
    assert KV.delete(kv, "key1") == :ok
    assert KV.get(kv, "key1") == {:error, :not_found}
  end

  test "key-value operations operations are logged correctly" do
    {:ok, replica} = Replica.start_link(configuration: [self()])
    kv = KV.new(replica)

    KV.put(kv, "key1", "value1")
    KV.put(kv, "key2", "value2")
    KV.delete(kv, "key1")

    state = Replica.dump(replica)
    assert length(state.log) == 3
    assert state.op_number == 3
    assert state.commit_number == 3
  end

  test "view change can be initiated" do
    {:ok, replica1} = Replica.start_link(configuration: [self(), :replica2])
    {:ok, replica2} = Replica.start_link(configuration: [self(), :replica2])

    Replica.connect(replica1, replica2)
    Replica.connect(replica2, replica1)

    Replica.start_view_change(replica1)

    # Give some time for view change to process
    Process.sleep(100)

    state1 = Replica.dump(replica1)
    state2 = Replica.dump(replica2)

    assert state1.view_number > 0 or state2.view_number > 0
  end

  test "state transfer lagging replica requests and receives state" do
    {:ok, replica1} = Replica.start_link(configuration: [self(), :replica2])
    {:ok, replica2} = Replica.start_link(configuration: [self(), :replica2])

    Replica.connect(replica1, replica2)
    Replica.connect(replica2, replica1)

    kv1 = KV.new(replica1)

    # Put some operations on replica1 (primary)
    KV.put(kv1, "key1", "value1")
    KV.put(kv1, "key2", "value2")

    # Give some time for operations to process
    Process.sleep(100)

    # Request state transfer from replica1 to replica2
    Replica.get_state(replica2, replica1)

    # Give some time for state transfer to complete
    Process.sleep(100)

    replica1_state = Replica.dump(replica1)
    replica2_state = Replica.dump(replica2)

    # Both replicas should have the same op_number after state transfer
    assert replica2_state.op_number >= 2
    assert replica1_state.op_number == replica2_state.op_number
  end

  test "multi-replica consensus two replicas reach consensus" do
    {:ok, replica1} = Replica.start_link(configuration: [self(), :replica2])
    {:ok, replica2} = Replica.start_link(configuration: [self(), :replica2])

    Replica.connect(replica1, replica2)
    Replica.connect(replica2, replica1)

    kv1 = KV.new(replica1)

    # Perform operations (replica1 should be primary)
    KV.put(kv1, "consensus_key", "consensus_value")

    # Give time for consensus to complete
    Process.sleep(200)

    state1 = Replica.dump(replica1)
    state2 = Replica.dump(replica2)

    # Both replicas should have committed the operation
    assert state1.commit_number >= 1
    assert state2.commit_number >= 1

    # Both should have the same log
    assert length(state1.log) == length(state2.log)
  end
end
