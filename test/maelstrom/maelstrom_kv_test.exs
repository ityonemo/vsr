defmodule MaelstromKvTest do
  @moduledoc """
  Comprehensive unit tests for MaelstromKv implementation.
  """

  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias VsrServer

  setup do
    # Use temporary directory for DETS files
    temp_dir = System.tmp_dir!()
    unique_id = System.unique_integer([:positive])
    node_id = "n0_#{unique_id}"
    dets_file = Path.join(temp_dir, "test_#{unique_id}_log.dets")

    # Start with basic options - cluster and log will be set afterwards
    opts = [dets_root: temp_dir]

    {:ok, pid} = MaelstromKv.start_link(opts)

    # Set cluster configuration (single-node cluster for unit tests)
    VsrServer.set_cluster(pid, node_id, [], 1)

    # Set up DETS log
    table_name = String.to_atom("test_log_#{unique_id}")
    {:ok, log} = :dets.open_file(table_name, file: String.to_charlist(dets_file))
    VsrServer.set_log(pid, log)

    # Clean up DETS file on test completion
    on_exit(fn ->
      File.rm(dets_file)
    end)

    {:ok, server: pid, opts: opts}
  end

  describe "initialization" do
    test "starts with empty data store", %{server: server} do
      state = VsrServer.dump(server)
      kv_state = state.inner

      assert kv_state.data == %{}
    end
  end

  describe "echo operation" do
    test "handles echo requests immediately", %{server: server} do
      # Test echo functionality using the implemented client API
      capture_log(fn ->
        Process.group_leader(server, Process.group_leader())
        result = MaelstromKv.echo(server, "hello world", "test_client", 1)
        assert result == :ok
      end)
    end
  end

  describe "read operations" do
    test "reads return error for non-existent keys", %{server: server} do
      # Test read functionality for non-existent keys
      result = MaelstromKv.read(server, "nonexistent", "test_client", 1)
      assert result == {:error, :not_found}
    end

    test "reads return values for existing keys", %{server: server} do
      # Set data through proper VSR consensus instead of direct state modification
      # First write the value through consensus
      write_result = MaelstromKv.write(server, "key1", "value1", "test_client", 1)
      assert write_result == :ok

      # Wait for consensus to complete
      :timer.sleep(50)

      # Then read it back
      result = MaelstromKv.read(server, "key1", "test_client", 2)
      assert result == {:ok, "value1"}
    end
  end

  describe "write operations" do
    test "write operations complete after consensus", %{server: _server} do
      # Manually test handle_commit functionality
      operation = ["write", "key1", "value1"]

      # Apply the operation through handle_commit
      kv_state = %MaelstromKv{}
      {new_kv_state, result} = MaelstromKv.handle_commit(operation, kv_state, nil)

      assert result == :ok
      assert new_kv_state.data["key1"] == "value1"
    end
  end

  describe "compare-and-swap (CAS) operations" do
    test "CAS succeeds when expected value matches", %{server: _server} do
      # Set initial value
      kv_state = %MaelstromKv{data: %{"key1" => "old_value"}}
      operation = ["cas", "key1", "old_value", "new_value"]

      {new_kv_state, result} = MaelstromKv.handle_commit(operation, kv_state, nil)

      assert result == :ok
      assert new_kv_state.data["key1"] == "new_value"
    end

    test "CAS fails when expected value doesn't match", %{server: _server} do
      # Set initial value
      kv_state = %MaelstromKv{data: %{"key1" => "actual_value"}}
      operation = ["cas", "key1", "expected_value", "new_value"]

      {new_kv_state, result} = MaelstromKv.handle_commit(operation, kv_state, nil)

      assert result == {:error, :precondition_failed}
      # Unchanged
      assert new_kv_state.data["key1"] == "actual_value"
    end

    test "CAS works with nil values", %{server: _server} do
      # Test CAS from nil to value
      kv_state = %MaelstromKv{}
      operation = ["cas", "new_key", nil, "value1"]

      {new_kv_state, result} = MaelstromKv.handle_commit(operation, kv_state, nil)

      assert result == :ok
      assert new_kv_state.data["new_key"] == "value1"
    end
  end

  describe "state management" do
    test "get_state returns data", %{server: _server} do
      kv_state = %MaelstromKv{data: %{"key1" => "value1"}}
      result = MaelstromKv.get_state(kv_state)

      assert result == %{data: %{"key1" => "value1"}}
    end

    test "set_state updates data with atom keys", %{server: _server} do
      kv_state = %MaelstromKv{}
      new_state_data = %{data: %{"key1" => "value1"}}

      result = MaelstromKv.set_state(kv_state, new_state_data)

      assert result.data == %{"key1" => "value1"}
    end
  end

  describe "error handling" do
    test "handles unknown operations gracefully", %{server: _server} do
      kv_state = %MaelstromKv{}
      operation = ["unknown_operation", "param"]

      {new_kv_state, result} = MaelstromKv.handle_commit(operation, kv_state, nil)

      assert result == :ok
      # Unchanged
      assert new_kv_state == kv_state
    end
  end
end
