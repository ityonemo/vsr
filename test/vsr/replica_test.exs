defmodule Vsr.ReplicaTest do
  use ExUnit.Case, async: false
  alias Vsr.Replica

  describe "replica initialization" do
    test "starts with correct initial state" do
      {:ok, pid} = Replica.start_link(replica_id: 1, configuration: [1, 2, 3])

      state = Replica.dump(pid)

      assert state.replica_id == 1
      assert state.view_number == 0
      assert state.status == :normal
      assert state.op_number == 0
      assert state.commit_number == 0
      assert state.configuration == [1, 2, 3]
      assert length(state.log) == 0
    end

    test "starts in blocking mode when configured" do
      {:ok, pid} = Replica.start_link(replica_id: 1, configuration: [1, 2, 3], blocking: true)

      state = Replica.dump(pid)
      assert state.blocking == true
    end

    test "determines primary correctly in initial view" do
      {:ok, pid} = Replica.start_link(replica_id: 1, configuration: [1, 2, 3])

      state = Replica.dump(pid)
      # view 0, first replica
      expected_primary = rem(0, 3) + 1
      assert state.primary == expected_primary
    end
  end

  describe "normal operation - primary" do
    setup do
      {:ok, primary} = Replica.start_link(replica_id: 1, configuration: [1, 2, 3])
      {:ok, backup1} = Replica.start_link(replica_id: 2, configuration: [1, 2, 3])
      {:ok, backup2} = Replica.start_link(replica_id: 3, configuration: [1, 2, 3])

      # Connect replicas to each other
      Replica.connect(primary, backup1)
      Replica.connect(primary, backup2)
      Replica.connect(backup1, primary)
      Replica.connect(backup1, backup2)
      Replica.connect(backup2, primary)
      Replica.connect(backup2, backup1)

      %{primary: primary, backup1: backup1, backup2: backup2}
    end

    test "handles client request and coordinates replication", %{
      primary: primary,
      backup1: backup1,
      backup2: backup2
    } do
      # Send client request to primary
      Replica.client_request(primary, {:put, "key1", "value1"}, "client1", 1)

      # Check that operation was added to primary's log
      state = Replica.dump(primary)
      assert length(state.log) == 1
      assert state.op_number == 1

      # Check that prepare messages were sent to backups
      # Allow message processing
      Process.sleep(10)

      backup1_state = Replica.dump(backup1)
      backup2_state = Replica.dump(backup2)

      assert length(backup1_state.log) == 1
      assert length(backup2_state.log) == 1
    end

    test "commits operation after majority prepare-ok", %{primary: primary, backup1: backup1} do
      Replica.client_request(primary, {:put, "key1", "value1"}, "client1", 1)

      # Allow full prepare/commit cycle
      Process.sleep(50)

      primary_state = Replica.dump(primary)
      backup1_state = Replica.dump(backup1)

      assert primary_state.commit_number == 1
      assert backup1_state.commit_number == 1

      # Check that value was stored
      assert Replica.get(primary, "key1") == {:ok, "value1"}
      assert Replica.get(backup1, "key1") == {:ok, "value1"}
    end
  end

  describe "normal operation - backup" do
    setup do
      {:ok, primary} = Replica.start_link(replica_id: 1, configuration: [1, 2, 3])
      {:ok, backup1} = Replica.start_link(replica_id: 2, configuration: [1, 2, 3])
      {:ok, backup2} = Replica.start_link(replica_id: 3, configuration: [1, 2, 3])

      # Connect replicas to each other
      Replica.connect(primary, backup1)
      Replica.connect(primary, backup2)
      Replica.connect(backup1, primary)
      Replica.connect(backup1, backup2)
      Replica.connect(backup2, primary)
      Replica.connect(backup2, backup1)
      {:ok, backup} = Replica.start_link(replica_id: 2, configuration: [1, 2, 3])

      %{primary: primary, backup: backup}
    end

    test "accepts prepare message and responds with prepare-ok", %{backup: backup} do
      operation = {:put, "key1", "value1"}

      # Send prepare message to backup
      send(backup, {:prepare, 0, 1, operation, 0, 1})

      Process.sleep(10)

      state = Replica.dump(backup)
      assert length(state.log) == 1
      assert state.op_number == 1
    end

    test "commits operation on commit message", %{backup: backup} do
      operation = {:put, "key1", "value1"}

      # Send prepare then commit
      send(backup, {:prepare, 0, 1, operation, 0, 1})
      send(backup, {:commit, 0, 1})

      Process.sleep(10)

      state = Replica.dump(backup)
      assert state.commit_number == 1
      assert Replica.get(backup, "key1") == {:ok, "value1"}
    end
  end

  describe "view change" do
    setup do
      {:ok, primary} = Replica.start_link(replica_id: 1, configuration: [1, 2, 3])
      {:ok, backup1} = Replica.start_link(replica_id: 2, configuration: [1, 2, 3])
      {:ok, backup2} = Replica.start_link(replica_id: 3, configuration: [1, 2, 3])

      # Connect replicas to each other
      Replica.connect(primary, backup1)
      Replica.connect(primary, backup2)
      Replica.connect(backup1, primary)
      Replica.connect(backup1, backup2)
      Replica.connect(backup2, primary)
      Replica.connect(backup2, backup1)
      {:ok, replica1} = Replica.start_link(replica_id: 1, configuration: [1, 2, 3])
      {:ok, replica2} = Replica.start_link(replica_id: 2, configuration: [1, 2, 3])
      {:ok, replica3} = Replica.start_link(replica_id: 3, configuration: [1, 2, 3])

      %{replica1: replica1, replica2: replica2, replica3: replica3}
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

      # Send start-view-change messages
      send(replica1, {:start_view_change, 1, 2})
      send(replica3, {:start_view_change, 1, 2})

      # Allow view change to complete
      Process.sleep(50)

      # Check that view change completed and new primary is determined
      replica2_state = Replica.dump(replica2)
      # view 1
      expected_new_primary = rem(1, 3) + 1
      assert replica2_state.view_number == 1
      assert replica2_state.primary == expected_new_primary
    end
  end

  describe "key-value operations" do
    setup do
      {:ok, replica} = Replica.start_link(replica_id: 4, configuration: [4], name: nil)
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
        Replica.start_link(replica_id: 1, configuration: [1], blocking: true, name: nil)

      # Start async operation that should block
      task =
        Task.async(fn ->
          Replica.put(replica, "key1", "value1")
        end)

      # Operation should not complete immediately
      refute Task.yield(task, 50)

      # Unblock the replica
      send(replica, {:unblock, 1})

      # Now operation should complete
      assert Task.await(task, 100) == :ok
    end
  end

  describe "state transfer" do
    setup do
      {:ok, primary} = Replica.start_link(replica_id: 1, configuration: [1, 2, 3])
      {:ok, backup1} = Replica.start_link(replica_id: 2, configuration: [1, 2, 3])
      {:ok, backup2} = Replica.start_link(replica_id: 3, configuration: [1, 2, 3])

      # Connect replicas to each other
      Replica.connect(primary, backup1)
      Replica.connect(primary, backup2)
      Replica.connect(backup1, primary)
      Replica.connect(backup1, backup2)
      Replica.connect(backup2, primary)
      Replica.connect(backup2, backup1)
      {:ok, replica1} = Replica.start_link(replica_id: 1, configuration: [1, 2])
      {:ok, replica2} = Replica.start_link(replica_id: 2, configuration: [1, 2])

      %{replica1: replica1, replica2: replica2}
    end

    test "lagging replica requests and receives state", %{replica1: replica1, replica2: replica2} do
      # Add some operations to replica1
      Replica.put(replica1, "key1", "value1")
      Replica.put(replica1, "key2", "value2")

      # Simulate replica2 falling behind and requesting state
      Replica.get_state(replica2, replica1)

      Process.sleep(50)

      # Check that replica2 caught up
      replica2_state = Replica.dump(replica2)
      assert replica2_state.op_number >= 2
      assert Replica.get(replica2, "key1") == {:ok, "value1"}
      assert Replica.get(replica2, "key2") == {:ok, "value2"}
    end
  end
end
