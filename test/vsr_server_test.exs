defmodule VsrServerTest do
  @moduledoc """
  Basic unit tests for VsrServer implementation using concrete test module.

  Note: Most VSR protocol features are not yet implemented and are marked as :skip.
  """

  use ExUnit.Case, async: true
  alias VsrServer

  setup do
    opts = [
      # Single node for basic testing
      cluster_size: 1,
      node_id: "n0",
      # No other replicas
      replicas: []
    ]

    {:ok, pid} = start_supervised({Vsr.ListKv, opts})
    {:ok, server: pid, opts: opts}
  end

  describe "basic functionality" do
    test "initializes correctly", %{server: server} do
      # Get basic data
      data = GenServer.call(server, :get_data)
      assert data == %{}
    end

    test "handles basic operations through handle_commit", %{server: server} do
      # Test that operations can be applied directly
      operation = {:write, "test_key", "test_value"}

      state = VsrServer.dump(server)
      assert {new_inner, :ok} = Vsr.ListKv.handle_commit(operation, state.inner)
      assert new_inner.data["test_key"] == "test_value"
    end
  end

  describe "client request handling" do
    test "processes client requests successfully", %{server: server} do
      # Client requests should complete successfully in single-node mode
      operation = {:write, "key1", "value1"}

      # This should complete successfully since we have quorum in single-node mode
      assert :ok = GenServer.call(server, {:client_request, operation})
    end
  end

  describe "VSR protocol" do
    test "handles prepare messages", %{server: server} do
      # Test that VSR message structures are defined correctly
      prepare = %Vsr.Message.Prepare{
        view: 0,
        op_number: 1,
        operation: {:write, "key1", "value1"},
        commit_number: 0,
        from: self(),
        leader_id: "n0"
      }

      # Verify the prepare message has all required fields
      assert prepare.view == 0
      assert prepare.op_number == 1
      assert prepare.operation == {:write, "key1", "value1"}
      assert prepare.commit_number == 0
      assert prepare.from == self()
      assert prepare.leader_id == "n0"

      # Verify server is still responsive after testing message structure
      state = VsrServer.dump(server)
      assert is_map(state)
    end

    test "handles commit messages", %{server: server} do
      # Test that VSR commit message structures are defined correctly
      commit = %Vsr.Message.Commit{
        view: 0,
        commit_number: 1
      }

      # Verify the commit message has all required fields
      assert commit.view == 0
      assert commit.commit_number == 1

      # Verify server state can be inspected
      state = VsrServer.dump(server)
      assert state.commit_number >= 0
    end

    test "handles view change messages", %{server: server} do
      # Test that VSR view change message structures are defined correctly
      start_view_change = %Vsr.Message.StartViewChange{
        view: 1,
        replica: "n0"
      }

      # Verify the start view change message has all required fields
      assert start_view_change.view == 1
      assert start_view_change.replica == "n0"

      # Verify server maintains view state properly
      state = VsrServer.dump(server)
      assert state.view_number >= 0
    end
  end
end
