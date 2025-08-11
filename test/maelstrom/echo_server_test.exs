defmodule Maelstrom.EchoServerTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  alias Maelstrom.Node
  alias Maelstrom.Node.Message
  alias Maelstrom.Node.Init
  alias Maelstrom.Node.Echo

  @tag :maelstrom
  test "echo server responds to echo messages with echo_ok" do
    # Use capture_io to trap the JSON response sent to stdout
    output =
      capture_io(fn ->
        # Start the node - it will use the captured IO as its target
        {:ok, pid} = Node.start_link()

        # First initialize the node using proper Maelstrom structs
        init_body = %Init{
          msg_id: 1,
          node_id: "n1",
          node_ids: ["n1", "n2", "n3"]
        }

        init_message = Message.new("c1", "n1", init_body)
        init_json = JSON.encode!(init_message)
        assert :ok = Node.stdin(pid, init_json)

        # Now send an echo message using proper Maelstrom structs
        echo_body = %Echo{
          msg_id: 2,
          echo: "Hello, world!"
        }

        echo_message = Message.new("c1", "n1", echo_body)
        echo_json = JSON.encode!(echo_message)
        assert :ok = Node.stdin(pid, echo_json)

        # Give the GenServer time to process and respond
        :timer.sleep(50)
      end)

    # Parse and verify the response
    response_lines = String.split(String.trim(output), "\n", trim: true)
    assert length(response_lines) >= 1, "Should have at least one response line"

    # Get the echo response (should be the last line after any init_ok)
    echo_response_json = List.last(response_lines)

    # Verify the response structure using map destructuring
    assert %{
             "src" => "n1",
             "dest" => "c1",
             "body" => %{
               "type" => "echo_ok",
               "echo" => "Hello, world!",
               "in_reply_to" => 2,
               "msg_id" => msg_id
             }
           } = JSON.decode!(echo_response_json)

    assert is_integer(msg_id)
  end

  @tag :maelstrom
  test "echo server handles multiple echo messages with incremental msg_ids" do
    # Send multiple echo messages and capture all responses
    output =
      capture_io(fn ->
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

        # First echo using proper Maelstrom structs
        echo1_body = %Echo{
          msg_id: 10,
          echo: "First message"
        }

        echo1_message = Message.new("c1", "n1", echo1_body)
        echo1_json = JSON.encode!(echo1_message)
        assert :ok = Node.stdin(pid, echo1_json)

        # Second echo using proper Maelstrom structs
        echo2_body = %Echo{
          msg_id: 20,
          echo: "Second message"
        }

        echo2_message = Message.new("c1", "n1", echo2_body)
        echo2_json = JSON.encode!(echo2_message)
        assert :ok = Node.stdin(pid, echo2_json)

        :timer.sleep(100)
      end)

    # Parse all response lines
    response_lines = String.split(String.trim(output), "\n", trim: true)

    # Should have init_ok plus two echo responses
    assert length(response_lines) >= 2

    # Find echo responses (skip init_ok)
    echo_responses =
      response_lines
      |> Enum.map(&JSON.decode!/1)
      |> Enum.filter(fn resp -> resp["body"]["type"] == "echo_ok" end)

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
