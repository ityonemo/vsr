defmodule Maelstrom.NodeTest do
  use ExUnit.Case, async: true
  alias Maelstrom.Node

  @moduletag :maelstrom

  # Clean up any running nodes after each test
  setup t do
    node_svr = start_supervised!({Node, name: :"#{t.test}-node", io_target: self()})
    {:ok, node_svr: node_svr}
  end

  describe "start_link/1 and init/1" do
    test "starts node in test mode without STDIN reader", %{node_svr: node_svr} do
      # Verify initial state

      assert %Node{
               node_id: nil,
               node_ids: nil,
               vsr_replica: nil,
               msg_id_counter: 0,
               pending_requests: %{}
             } = :sys.get_state(node_svr)
    end

    test "starts node in production mode (but skip STDIN for tests)", %{node_svr: _node_svr} do
      # We can't easily test the STDIN reader in unit tests
      # The test_mode: true flag prevents the STDIN reader from starting
      {:ok, pid} = Node.start_link(test_mode: true)

      assert Process.alive?(pid)
      assert Process.whereis(Node) == pid
    end
  end

  describe "handle_cast/2 - maelstrom messages" do
    setup do
      {:ok, pid} = Node.start_link(test_mode: true)
      {:ok, pid: pid}
    end

    test "handles init message", %{pid: pid} do
      init_msg = %{
        "src" => "c1",
        "dest" => "n1",
        "body" => %{
          "type" => "init",
          "msg_id" => 1,
          "node_id" => "n1",
          "node_ids" => ["n1", "n2", "n3"]
        }
      }

      # Capture stdout to check response
      ExUnit.CaptureIO.capture_io(fn ->
        GenServer.cast(pid, {:maelstrom_msg, init_msg})
        # Allow message to be processed
        Process.sleep(100)
      end)

      # Verify state was updated
      state = :sys.get_state(pid)
      assert state.node_id == "n1"
      assert state.node_ids == ["n1", "n2", "n3"]
      # VSR startup is skipped in test mode
      assert state.vsr_replica == nil
    end

    test "handles echo message", %{pid: pid} do
      echo_msg = %{
        "src" => "c1",
        "dest" => "n1",
        "body" => %{
          "type" => "echo",
          "msg_id" => 2,
          "echo" => "Hello World"
        }
      }

      # Initialize node first
      init_node(pid, "n1", ["n1"])

      # Just verify the message doesn't crash the node
      GenServer.cast(pid, {:maelstrom_msg, echo_msg})
      Process.sleep(100)

      # Node should still be alive and responsive
      assert Process.alive?(pid)
      assert GenServer.call(pid, :get_cluster) == {:ok, ["n1"]}
    end

    test "handles write operation", %{pid: pid} do
      write_msg = %{
        "src" => "c1",
        "dest" => "n1",
        "body" => %{
          "type" => "write",
          "msg_id" => 3,
          "key" => "test_key",
          "value" => "test_value"
        }
      }

      # Initialize node first
      init_node(pid, "n1", ["n1"])

      # Just verify the message doesn't crash the node
      GenServer.cast(pid, {:maelstrom_msg, write_msg})
      # VSR operations may take longer
      Process.sleep(200)

      # Node should still be alive and responsive
      assert Process.alive?(pid)
    end

    test "handles read operation", %{pid: pid} do
      # Initialize node
      init_node(pid, "n1", ["n1"])

      read_msg = %{
        "src" => "c1",
        "dest" => "n1",
        "body" => %{"type" => "read", "msg_id" => 2, "key" => "test_key"}
      }

      # Just verify the message doesn't crash the node
      GenServer.cast(pid, {:maelstrom_msg, read_msg})
      Process.sleep(200)

      # Node should still be alive and responsive
      assert Process.alive?(pid)
    end

    test "handles cas operation", %{pid: pid} do
      init_node(pid, "n1", ["n1"])

      # CAS operation
      cas_msg = %{
        "src" => "c1",
        "dest" => "n1",
        "body" => %{"type" => "cas", "msg_id" => 2, "key" => "counter", "from" => 0, "to" => 1}
      }

      # Just verify the message doesn't crash the node
      GenServer.cast(pid, {:maelstrom_msg, cas_msg})
      Process.sleep(200)

      # Node should still be alive and responsive
      assert Process.alive?(pid)
    end

    test "handles operations before initialization", %{pid: pid} do
      read_msg = %{
        "src" => "c1",
        "dest" => "n1",
        "body" => %{"type" => "read", "msg_id" => 1, "key" => "any_key"}
      }

      # Just verify the message doesn't crash the node
      GenServer.cast(pid, {:maelstrom_msg, read_msg})
      Process.sleep(100)

      # Node should still be alive and responsive
      assert Process.alive?(pid)
    end

    test "handles unknown message type", %{pid: pid} do
      unknown_msg = %{
        "src" => "c1",
        "dest" => "n1",
        "body" => %{"type" => "unknown_type", "msg_id" => 1}
      }

      # Should not crash, just log warning
      GenServer.cast(pid, {:maelstrom_msg, unknown_msg})
      Process.sleep(50)

      # Node should still be alive
      assert Process.alive?(pid)
    end
  end

  describe "handle_cast/2 - VSR message sending" do
    setup do
      {:ok, pid} = Node.start_link(test_mode: true)
      init_node(pid, "n1", ["n1", "n2"])
      {:ok, pid: pid}
    end

    test "handles send_vsr_message", %{pid: pid} do
      vsr_msg = %{type: :prepare, view: 1, op_number: 1}

      # Just verify the message doesn't crash the node
      GenServer.cast(pid, {:send_vsr_message, "n2", vsr_msg})
      Process.sleep(50)

      # Node should still be alive and responsive
      assert Process.alive?(pid)
      assert GenServer.call(pid, :get_cluster) == {:ok, ["n1", "n2"]}
    end
  end

  describe "handle_call/3" do
    setup do
      {:ok, pid} = Node.start_link(test_mode: true)
      {:ok, pid: pid}
    end

    test "get_cluster returns cluster when initialized", %{pid: pid} do
      init_node(pid, "n1", ["n1", "n2", "n3"])

      assert GenServer.call(pid, :get_cluster) == {:ok, ["n1", "n2", "n3"]}
    end

    test "get_cluster returns not_initialized when not initialized", %{pid: pid} do
      assert GenServer.call(pid, :get_cluster) == {:error, :not_initialized}
    end
  end

  describe "JSON protocol compliance" do
    setup do
      {:ok, pid} = Node.start_link(test_mode: true)
      {:ok, pid: pid}
    end

    test "handles JSON message without crashing", %{pid: pid} do
      init_msg = %{
        "src" => "c1",
        "dest" => "n1",
        "body" => %{"type" => "init", "msg_id" => 1, "node_id" => "n1", "node_ids" => ["n1"]}
      }

      # Just verify the message processing doesn't crash
      GenServer.cast(pid, {:maelstrom_msg, init_msg})
      Process.sleep(100)

      # Verify state was updated correctly
      state = :sys.get_state(pid)
      assert state.node_id == "n1"
      assert state.node_ids == ["n1"]
    end

    test "handles message ID increments", %{pid: pid} do
      init_node(pid, "n1", ["n1"])

      # Send multiple messages and verify node remains stable
      msg1 = %{
        "src" => "c1",
        "dest" => "n1",
        "body" => %{"type" => "echo", "msg_id" => 1, "echo" => "first"}
      }

      msg2 = %{
        "src" => "c1",
        "dest" => "n1",
        "body" => %{"type" => "echo", "msg_id" => 2, "echo" => "second"}
      }

      GenServer.cast(pid, {:maelstrom_msg, msg1})
      GenServer.cast(pid, {:maelstrom_msg, msg2})
      Process.sleep(100)

      # Verify message counter increased
      state = :sys.get_state(pid)
      assert state.msg_id_counter > 0

      # Node should still be responsive
      assert Process.alive?(pid)
    end
  end

  # Helper function to initialize a node
  defp init_node(pid, node_id, node_ids) do
    init_msg = %{
      "src" => "c1",
      "dest" => node_id,
      "body" => %{
        "type" => "init",
        "msg_id" => 1,
        "node_id" => node_id,
        "node_ids" => node_ids
      }
    }

    ExUnit.CaptureIO.capture_io(fn ->
      GenServer.cast(pid, {:maelstrom_msg, init_msg})
      # Allow VSR to start up
      Process.sleep(200)
    end)
  end
end
