defmodule Vsr.ReplicaTest do
  use ExUnit.Case, async: false
  alias Vsr.Replica
  alias Vsr.Messages

  describe "replica initialization" do
    test "starts with correct initial state" do
      {:ok, pid} = Replica.start_link(configuration: [], name: nil)

      state = Replica.dump(pid)

      assert state.view_number == 0
      assert state.status == :normal
      assert state.op_number == 0
      assert state.commit_number == 0
      assert state.configuration == []
      assert length(state.log) == 0
    end

    test "starts in blocking mode when configured" do
      {:ok, pid} =
        Replica.start_link(
          configuration: [],
          blocking: true,
          name: nil
        )

      state = Replica.dump(pid)
      assert state.blocking == true
    end

    test "determines primary correctly in initial view" do
      {:ok, pid1} = Replica.start_link(configuration: [], name: nil)
      {:ok, pid2} = Replica.start_link(configuration: [], name: nil)
      {:ok, pid3} = Replica.start_link(configuration: [], name: nil)

      configuration = [pid1, pid2, pid3]
      {:ok, replica} = Replica.start_link(configuration: configuration, name: nil)

      state = Replica.dump(replica)
      # view 0, first replica in configuration
      expected_primary = Enum.at(configuration, rem(0, 3))
      assert state.primary == expected_primary
    end
  end

  describe "normal operation - primary" do
    setup do
      {:ok, primary} = Replica.start_link(configuration: [], name: nil)
      {:ok, backup1} = Replica.start_link(configuration: [], name: nil)
      {:ok, backup2} = Replica.start_link(configuration: [], name: nil)

      # Update each replica's configuration to know about all replicas
      configuration = [primary, backup1, backup2]
      GenServer.call(primary, {:update_configuration, configuration})
      GenServer.call(backup1, {:update_configuration, configuration})
      GenServer.call(backup2, {:update_configuration, configuration})

      # Connect replicas to each other
      Replica.connect(primary, backup1)
      Replica.connect(primary, backup2)
      Replica.connect(backup1, backup2)

      %{replica1: primary, replica2: backup1, replica3: backup2}
    end

    test "backup starts view change on timeout", %{replica2: replica2} do
      # Simulate primary failure by triggering view change
      Replica.start_view_change(replica2)

      state = Replica.dump(replica2)
      assert state.status == :view_change
      assert state.view_number == 1
    end

    test "replica becomes new primary after successful view change", %{
      replica1: replica1,
      replica2: replica2,
      replica3: replica3
    } do
      # Start view change from replica2
      Replica.start_view_change(replica2)

      # Send start-view-change messages using new struct format
      start_view_change_msg = %Messages.StartViewChange{
        view: 1,
        sender: replica2
      }

      send(replica1, start_view_change_msg)
      send(replica3, start_view_change_msg)

      # Allow view change to complete
      Process.sleep(100)

      # Check that view change completed and new primary is determined
      replica2_state = Replica.dump(replica2)
      configuration = [replica1, replica2, replica3]
      expected_new_primary = Enum.at(configuration, rem(1, 3))
      assert replica2_state.view_number == 1
      assert replica2_state.primary == expected_new_primary
    end
  end

  describe "key-value operations" do
    setup do
      {:ok, replica} = Replica.start_link(configuration: [], name: nil)
      %{replica: replica}
    end

    test "put and get operations", %{replica: replica} do
      assert Replica.put(replica, "key1", "value1") == :ok
      assert Replica.get(replica, "key1") == {:ok, "value1"}
      assert Replica.get(replica, "nonexistent") == {:error, :not_found}
    end

    test "delete operation", %{replica: replica} do
      Replica.put(replica, "key1", "value1")
      assert Replica.delete(replica, "key1") == :ok
      assert Replica.get(replica, "key1") == {:error, :not_found}
    end

    test "operations are logged correctly", %{replica: replica} do
      Replica.put(replica, "key1", "value1")
      Replica.put(replica, "key2", "value2")
      Replica.delete(replica, "key1")

      state = Replica.dump(replica)
      assert length(state.log) == 3
      assert state.op_number == 3
    end
  end

  describe "blocking behavior" do
    test "replica blocks when configured with blocking option" do
      {:ok, replica} =
        Replica.start_link(configuration: [], blocking: true, name: nil)

      # Start async operation that should block
      task =
        Task.async(fn ->
          Replica.put(replica, "key1", "value1")
        end)

      # Operation should not complete immediately
      refute Task.yield(task, 50)

      # Unblock the replica using new struct format
      unblock_msg = %Messages.Unblock{id: 1}
      send(replica, unblock_msg)

      # Now operation should complete
      assert Task.await(task, 100) == :ok
    end
  end

  describe "state transfer" do
    test "lagging replica requests and receives state" do
      # Create two independent replicas (no connections)
      {:ok, replica1} = Replica.start_link(configuration: [], name: nil)
      {:ok, replica2} = Replica.start_link(configuration: [], name: nil)

      # Add some operations to replica1 (as a single replica)
      Replica.put(replica1, "key1", "value1")
      Replica.put(replica1, "key2", "value2")

      # Simulate replica2 falling behind and requesting state using new struct format
      get_state_msg = %Messages.GetState{
        view: 0,
        op_number: 0,
        sender: replica2
      }

      send(replica1, get_state_msg)

      Process.sleep(500)

      # Check that replica2 caught up
      replica2_state = Replica.dump(replica2)
      assert replica2_state.op_number >= 2
      assert Replica.get(replica2, "key1") == {:ok, "value1"}
      assert Replica.get(replica2, "key2") == {:ok, "value2"}
    end
  end
end
