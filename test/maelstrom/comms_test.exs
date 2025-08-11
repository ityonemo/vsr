defmodule Maelstrom.CommsTest do
  use ExUnit.Case
  import ExUnit.CaptureIO
  alias Maelstrom.Comms

  @moduletag :maelstrom

  describe "initial_cluster/1" do
    test "returns empty list as expected" do
      maelstrom = %Comms{node_name: "n1", io_target: self()}
      assert Comms.initial_cluster(maelstrom) == []
    end
  end

  describe "Vsr.Comms protocol implementation (3-arity functions)" do
    test "send_to/3 sends JSON to IO target" do
      dest_id = "n2"
      message = %{type: :prepare, view: 1, op_number: 5}

      # Capture the IO output
      output =
        capture_io(fn ->
          maelstrom = %Comms{node_name: "n1", io_target: Process.group_leader()}
          Comms.send_to(maelstrom, dest_id, message)
        end)

      # Parse and verify the JSON output
      json_line = String.trim(output)
      decoded = JSON.decode!(json_line)

      expected = %{
        "src" => "n1",
        "dest" => "n2",
        "body" => %{"type" => "prepare", "view" => 1, "op_number" => 5}
      }

      assert decoded == expected
    end

    test "send_reply/3 sends JSON to IO target" do
      from = "n2"
      message = %{type: :prepare_ok, view: 1, op_number: 5}

      # Capture the IO output
      output =
        capture_io(fn ->
          maelstrom = %Comms{node_name: "n1", io_target: Process.group_leader()}
          Comms.send_reply(maelstrom, from, message)
        end)

      # Parse and verify the JSON output
      json_line = String.trim(output)
      decoded = JSON.decode!(json_line)

      expected = %{
        "src" => "n1",
        "dest" => "n2",
        "body" => %{"type" => "prepare_ok", "view" => 1, "op_number" => 5}
      }

      assert decoded == expected
    end

    test "monitor/2 returns reference" do
      maelstrom = %Comms{node_name: "n1", io_target: self()}
      ref = Comms.monitor(maelstrom, "n2")

      assert is_reference(ref)
    end
  end

  describe "behavior compliance" do
    test "implements all required Vsr.Comms callbacks" do
      # Verify the module implements the behavior
      assert Maelstrom.Comms.__info__(:attributes)[:behaviour] == [Vsr.Comms]

      # Verify all required protocol functions are exported
      exports = Maelstrom.Comms.__info__(:functions)

      assert Keyword.has_key?(exports, :initial_cluster)
      assert 1 in Keyword.get_values(exports, :initial_cluster)

      assert Keyword.has_key?(exports, :send_to)
      # 3-arity protocol function
      assert 3 in Keyword.get_values(exports, :send_to)

      assert Keyword.has_key?(exports, :send_reply)
      # 3-arity protocol function
      assert 3 in Keyword.get_values(exports, :send_reply)

      assert Keyword.has_key?(exports, :monitor)
      # 2-arity protocol function
      assert 2 in Keyword.get_values(exports, :monitor)
    end
  end
end
