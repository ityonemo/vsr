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
    test "handles prepare messages"

    test "handles commit messages"

    test "handles view change messages"
  end
end
