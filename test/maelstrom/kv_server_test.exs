defmodule Maelstrom.KvServerTest do
  @moduledoc """
  Tests for Maelstrom Node KV message handling.

  NOTE: KV operations (read/write) are not yet implemented in Maelstrom.Node.
  These tests verify message parsing and basic node behavior.
  """

  use ExUnit.Case
  import ExUnit.CaptureIO

  alias Maelstrom.Node
  alias Maelstrom.Node.Message
  alias Maelstrom.Node.Init
  alias Maelstrom.Node.Read
  alias Maelstrom.Node.Write
  alias Maelstrom.Node.Cas

  @tag :maelstrom
  test "kv server parses read and write messages without crashing" do
    # Test that the node can parse KV messages even though operations aren't implemented
    _output = capture_io(fn ->
      {:ok, pid} = Node.start_link()

      # Initialize the node first using proper Maelstrom structs
      init_body = %Init{
        msg_id: 1,
        node_id: "n1",
        node_ids: ["n1"]
      }

      init_message = Message.new("c1", "n1", init_body)
      init_json = JSON.encode!(init_message)
      assert :ok = Node.stdin(pid, init_json)

      # Send read message using proper Maelstrom structs - should not crash
      read_body = %Read{
        msg_id: 10,
        key: "test_key"
      }

      read_message = Message.new("c1", "n1", read_body)
      read_json = JSON.encode!(read_message)
      assert :ok = Node.stdin(pid, read_json)

      # Send write message using proper Maelstrom structs - should not crash  
      write_body = %Write{
        msg_id: 20,
        key: "test_key",
        value: "test_value"
      }

      write_message = Message.new("c1", "n1", write_body)
      write_json = JSON.encode!(write_message)
      assert :ok = Node.stdin(pid, write_json)

      # Verify node is still alive and responsive after processing KV messages
      assert Process.alive?(pid)
    end)
  end

  @tag :maelstrom
  test "kv server parses compare-and-swap (cas) messages without crashing" do
    # Test that the node can parse CAS messages even though operations aren't implemented
    capture_io(fn ->
      {:ok, pid} = Node.start_link()

      # Initialize node using proper Maelstrom structs
      init_body = %Init{
        msg_id: 1,
        node_id: "n1",
        node_ids: ["n1"]
      }

      init_message = Message.new("c1", "n1", init_body)
      init_json = JSON.encode!(init_message)
      assert :ok = Node.stdin(pid, init_json)

      # Send CAS message using proper Maelstrom structs
      cas_body = %Cas{
        msg_id: 10,
        key: "cas_key",
        from: "old_value", 
        to: "new_value"
      }

      cas_message = Message.new("c1", "n1", cas_body)
      cas_json = JSON.encode!(cas_message)
      assert :ok = Node.stdin(pid, cas_json)

      # Send another CAS with different values  
      cas2_body = %Cas{
        msg_id: 20,
        key: "cas_key2",
        from: nil,  # CAS from nil (key doesn't exist)
        to: "initial_value"
      }

      cas2_message = Message.new("c1", "n1", cas2_body)
      cas2_json = JSON.encode!(cas2_message) 
      assert :ok = Node.stdin(pid, cas2_json)

      # Verify node is still alive after processing CAS messages
      assert Process.alive?(pid)
    end)
  end
end
