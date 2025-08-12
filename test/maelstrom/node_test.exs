defmodule Maelstrom.NodeTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias Maelstrom.Node.Message
  alias Maelstrom.Node.Init
  alias Maelstrom.Node.Echo
  alias Maelstrom.Node.Read
  alias Maelstrom.Node.Write
  alias Maelstrom.Node.Cas

  require Logger

  @moduletag :maelstrom

  defp setup_server(t, vsr_expectation) do
    listener = spawn_link(vsr_expectation)

    {Maelstrom.Node, name: :"#{t.test}-node", vsr_replica: listener}
    |> start_supervised!()
    |> tap(&Process.group_leader(&1, Process.group_leader()))
  end

  defmacrop assert_called(what, reply) do
    quote do
      assert_receive {:"$gen_call", from, unquote(what)}, 1000
      GenServer.reply(from, unquote(reply))
    end
  end

  describe "maelstrom messages" do
    test "handles init message", t do
      capture_io(fn ->
        node_svr =
          setup_server(t, fn ->
            assert_called({:set_cluster, ["n1", "n2", "n3"]}, :ok)
            :done
          end)

        send_message(node_svr, %Init{
          msg_id: 1,
          node_id: "n1",
          node_ids: ["n1", "n2", "n3"]
        })

        # Allow message to be processed
        Process.sleep(100)

        # Verify state was updated
        state = :sys.get_state(node_svr)
        assert state.node_id == "n1"
        assert state.node_ids == ["n1", "n2", "n3"]
      end)
    end

    test "handles echo message", t do
      output =
        capture_io(fn ->
          node_svr =
            setup_server(t, fn ->
              assert_called({:set_cluster, ["n1"]}, :ok)
            end)

          # Initialize node first
          init_node(node_svr, "n1", ["n1"])

          send_message(node_svr, %Echo{
            msg_id: 2,
            echo: "Hello World"
          })

          Process.sleep(100)
        end)

      assert [
               %{"body" => %{"type" => "init_ok"}},
               %{"body" => %{"type" => "echo_ok", "echo" => "Hello World"}}
             ] =
               output
               |> String.split("\n", parts: 2)
               |> Enum.map(&JSON.decode!/1)
    end

    test "handles write operation", t do
      capture_io(fn ->
        node_svr =
          setup_server(t, fn ->
            assert_called({:set_cluster, ["n1"]}, :ok)

            assert_called(
              {:client_request, ["write", "test_key", "test_value"]},
              :ok
            )
          end)

        # Initialize node first
        init_node(node_svr, "n1", ["n1"])

        send_message(node_svr, %Write{
          msg_id: 3,
          key: "test_key",
          value: "test_value"
        })

        Process.sleep(100)
      end)
    end

    test "handles read operation", t do
      capture_io(fn ->
        node_svr =
          setup_server(t, fn ->
            assert_called({:set_cluster, ["n1"]}, :ok)
            assert_called({:client_request, ["read", "test_key"]}, {:ok, "test_value"})
          end)

        # Initialize node
        init_node(node_svr, "n1", ["n1"])

        send_message(node_svr, %Read{
          msg_id: 2,
          key: "test_key"
        })

        Process.sleep(100)
      end)
    end

    test "handles cas operation", t do
      capture_io(fn ->
        node_svr =
          setup_server(t, fn ->
            assert_called({:set_cluster, ["n1"]}, :ok)
            assert_called({:client_request, ["cas", "counter", 0, 1]}, :ok)
            :done
          end)

        init_node(node_svr, "n1", ["n1"])

        send_message(node_svr, %Cas{
          msg_id: 2,
          key: "counter",
          from: 0,
          to: 1
        })

        Process.sleep(200)

        # Node should still be alive and responsive
        assert Process.alive?(node_svr)
      end)
    end
  end

  describe "increments message ID" do
    test "handles message ID increments", t do
      capture_io(fn ->
        node_svr =
          setup_server(t, fn ->
            assert_called({:set_cluster, ["n1"]}, :ok)
          end)

        init_node(node_svr, "n1", ["n1"])

        # Send multiple echo messages and verify node remains stable
        send_message(node_svr, %Echo{
          msg_id: 1,
          echo: "first"
        })

        send_message(
          node_svr,
          %Echo{
            msg_id: 2,
            echo: "second"
          }
        )

        Process.sleep(100)

        # Verify message counter increased
        state = :sys.get_state(node_svr)
        assert state.msg_id_counter > 0

        # Node should still be responsive
        assert Process.alive?(node_svr)
      end)
    end
  end

  # Helper function to directly send a message (no JSON encoding)
  # note that JSON encoding is tested in the *_server_test.exs files.
  defp send_message(svr, message) do
    "c1"
    |> Message.new("n1", message)
    |> then(&Maelstrom.Node.message(svr, &1))
  end

  # Helper function to initialize a node
  defp init_node(node_svr, node_id, node_ids) do
    send_message(node_svr, %Init{
      msg_id: 1,
      node_id: node_id,
      node_ids: node_ids
    })

    # Allow VSR to start up
    Process.sleep(200)
  end
end
