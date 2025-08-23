defmodule Maelstrom.EchoServerTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias Maelstrom.Message.Init
  alias Maelstrom.Message.Echo

  setup t do
    # Use temporary directory for DETS files
    temp_dir = System.tmp_dir!()
    unique_id = System.unique_integer([:positive])
    node_id = "n1"
    dets_file = Path.join(temp_dir, "echo_test_#{unique_id}_log.dets")
    
    # MaelstromKv must be started through VsrServer since it uses VsrServer
    pid =
      start_supervised!({MaelstromKv, name: :"#{t.test}-node", node_id: node_id, dets_file: dets_file, replicas: []})

    # Clean up DETS file on test completion
    on_exit(fn ->
      File.rm(dets_file)
    end)

    {:ok, pid: pid}
  end

  @tag :maelstrom
  test "echo server responds to echo messages with echo_ok", %{pid: pid} do
    # Use capture_io and set group leader to capture IO from the node process
    output =
      capture_io(fn ->
        # Set the group leader so IO from the node process gets captured
        Process.group_leader(pid, Process.group_leader())

        # First initialize the node using proper Maelstrom structs
        init_body = %Init{
          msg_id: 1,
          node_id: "n1",
          node_ids: ["n1", "n2", "n3"]
        }

        init_message = Maelstrom.Message.new("c1", "n1", init_body)
        init_json = JSON.encode!(init_message)
        assert :ok = MaelstromKv.message(pid, init_json)

        # Now send an echo message using proper Maelstrom structs
        echo_body = %Echo{
          msg_id: 2,
          echo: "Hello, world!"
        }

        echo_message = Maelstrom.Message.new("c1", "n1", echo_body)
        echo_json = JSON.encode!(echo_message)
        assert :ok = MaelstromKv.message(pid, echo_json)

        # Give the GenServer time to process and respond
        :timer.sleep(100)
      end)

    # Parse and verify the responses
    response_lines = String.split(String.trim(output), "\n", trim: true)
    assert length(response_lines) >= 2, "Should have init_ok and echo_ok responses"

    # Parse all responses
    responses = Enum.map(response_lines, &JSON.decode!/1)

    # Verify init_ok response
    init_response = Enum.find(responses, fn resp -> resp["body"]["type"] == "init_ok" end)
    assert init_response, "Should have init_ok response"

    assert %{
             "src" => "n1",
             "dest" => "c1",
             "body" => %{
               "type" => "init_ok",
               "in_reply_to" => 1
             }
           } = init_response

    # Verify echo_ok response
    echo_response = Enum.find(responses, fn resp -> resp["body"]["type"] == "echo_ok" end)
    assert echo_response, "Should have echo_ok response"

    assert %{
             "src" => "n1",
             "dest" => "c1",
             "body" => %{
               "type" => "echo_ok",
               "echo" => "Hello, world!",
               "in_reply_to" => 2,
               "msg_id" => msg_id
             }
           } = echo_response

    assert is_integer(msg_id)
  end

  @tag :maelstrom
  test "echo server handles multiple echo messages with incremental msg_ids", %{pid: pid} do
    # Send multiple echo messages and capture all responses
    output =
      capture_io(fn ->
        # Set the group leader so IO from the node process gets captured
        Process.group_leader(pid, Process.group_leader())

        # Initialize the node first using proper Maelstrom structs
        init_body = %Init{
          msg_id: 1,
          node_id: "n1",
          node_ids: ["n1"]
        }

        init_message = Maelstrom.Message.new("c1", "n1", init_body)
        init_json = JSON.encode!(init_message)
        assert :ok = MaelstromKv.message(pid, init_json)

        # First echo using proper Maelstrom structs
        echo1_body = %Echo{
          msg_id: 10,
          echo: "First message"
        }

        echo1_message = Maelstrom.Message.new("c1", "n1", echo1_body)
        echo1_json = JSON.encode!(echo1_message)
        assert :ok = MaelstromKv.message(pid, echo1_json)

        # Second echo using proper Maelstrom structs
        echo2_body = %Echo{
          msg_id: 20,
          echo: "Second message"
        }

        echo2_message = Maelstrom.Message.new("c1", "n1", echo2_body)
        echo2_json = JSON.encode!(echo2_message)
        assert :ok = MaelstromKv.message(pid, echo2_json)

        :timer.sleep(100)
      end)

    # Parse all response lines
    response_lines = String.split(String.trim(output), "\n", trim: true)

    # Should have init_ok plus two echo responses
    assert length(response_lines) >= 3, "Should have init_ok and two echo_ok responses"

    # Parse all responses
    responses = Enum.map(response_lines, &JSON.decode!/1)

    # Verify init_ok response
    init_response = Enum.find(responses, fn resp -> resp["body"]["type"] == "init_ok" end)
    assert init_response, "Should have init_ok response"

    assert %{
             "src" => "n1",
             "dest" => "c1",
             "body" => %{
               "type" => "init_ok",
               "in_reply_to" => 1
             }
           } = init_response

    # Find echo responses
    echo_responses = Enum.filter(responses, fn resp -> resp["body"]["type"] == "echo_ok" end)
    assert length(echo_responses) == 2

    # Verify responses using map destructuring
    [resp1, resp2] = Enum.sort_by(echo_responses, & &1["body"]["in_reply_to"])

    assert %{
             "body" => %{
               "echo" => "First message",
               "in_reply_to" => 10,
               "msg_id" => 1
             }
           } = resp1

    assert %{
             "body" => %{
               "echo" => "Second message",
               "in_reply_to" => 20,
               "msg_id" => 2
             }
           } = resp2
  end
end
