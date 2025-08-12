defmodule Maelstrom.NodeTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias Maelstrom.Node.Message
  alias Maelstrom.Node.Init
  alias Maelstrom.Node.Echo
  alias Maelstrom.Node.Read
  alias Maelstrom.Node.Write
  alias Maelstrom.Node.Cas

  # VSR messages
  alias Vsr.Message.Prepare
  alias Vsr.Message.PrepareOk
  alias Vsr.Message.Commit
  alias Vsr.Message.StartViewChange
  alias Vsr.Message.StartViewChangeAck
  alias Vsr.Message.DoViewChange
  alias Vsr.Message.StartView
  alias Vsr.Message.ViewChangeOk
  alias Vsr.Message.GetState
  alias Vsr.Message.NewState
  alias Vsr.Message.ClientRequest
  alias Vsr.Message.Heartbeat

  require Logger

  @moduletag :maelstrom

  defp setup_server(t, vsr_expectation) do
    this = self()
    listener = spawn_link(fn -> 
      vsr_expectation.()
      send(this, :done)
    end)

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

  defmacrop assert_casted(what) do
    quote do
      assert_receive {:"$gen_cast", {:vsr, unquote(what)}}, 1000
    end
  end

  defmacrop assert_done do
    quote do
      assert_receive :done, 1000
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
        assert_done()
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
      assert_done()
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

        assert_done()
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

        assert_done()
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

        # Node should still be alive and responsive
        assert Process.alive?(node_svr)
        assert_done()
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
        assert_done()
      end)
    end
  end

  describe "VSR message handling" do
    test "handles Prepare message", t do
      capture_io(fn ->
        node_svr =
          setup_server(t, fn ->
            assert_called({:set_cluster, ["n1"]}, :ok)

            # VSR should receive the prepare message via cast
            assert_casted(%Prepare{view: 1, op_number: 1, operation: ["write", "key", "value"]})
          end)

        init_node(node_svr, "n1", ["n1"])

        prepare_msg = %Prepare{
          view: 1,
          op_number: 1,
          operation: ["write", "key", "value"],
          commit_number: 0,
          from: nil
        }

        send_vsr_message(node_svr, prepare_msg)
        assert_done()
      end)
    end

    test "handles PrepareOk message", t do
      capture_io(fn ->
        node_svr =
          setup_server(t, fn ->
            assert_called({:set_cluster, ["n1"]}, :ok)

            assert_casted(%PrepareOk{view: 1, op_number: 1, replica: "n2"})
          end)

        init_node(node_svr, "n1", ["n1"])

        prepare_ok_msg = %PrepareOk{
          view: 1,
          op_number: 1,
          replica: "n2"
        }

        send_vsr_message(node_svr, prepare_ok_msg)
        assert_done()
      end)
    end

    test "handles Commit message", t do
      capture_io(fn ->
        node_svr =
          setup_server(t, fn ->
            assert_called({:set_cluster, ["n1"]}, :ok)

            assert_casted(%Commit{view: 1, commit_number: 1})
          end)

        init_node(node_svr, "n1", ["n1"])

        commit_msg = %Commit{
          view: 1,
          commit_number: 1
        }

        send_vsr_message(node_svr, commit_msg)
        assert_done()
      end)
    end

    test "handles StartViewChange message", t do
      capture_io(fn ->
        node_svr =
          setup_server(t, fn ->
            assert_called({:set_cluster, ["n1"]}, :ok)

            assert_casted(%StartViewChange{view: 2, replica: "n2"})
          end)

        init_node(node_svr, "n1", ["n1"])

        start_view_change_msg = %StartViewChange{
          view: 2,
          replica: "n2"
        }

        send_vsr_message(node_svr, start_view_change_msg)
        assert_done()
      end)
    end

    test "handles StartViewChangeAck message", t do
      capture_io(fn ->
        node_svr =
          setup_server(t, fn ->
            assert_called({:set_cluster, ["n1"]}, :ok)

            assert_casted(%StartViewChangeAck{view: 2, replica: "n2"})
          end)

        init_node(node_svr, "n1", ["n1"])

        start_view_change_ack_msg = %StartViewChangeAck{
          view: 2,
          replica: "n2"
        }

        send_vsr_message(node_svr, start_view_change_ack_msg)
        assert_done()
      end)
    end

    test "handles DoViewChange message", t do
      capture_io(fn ->
        node_svr =
          setup_server(t, fn ->
            assert_called({:set_cluster, ["n1"]}, :ok)

            assert_casted(%DoViewChange{view: 2, log: [], last_normal_view: 1})
          end)

        init_node(node_svr, "n1", ["n1"])

        do_view_change_msg = %DoViewChange{
          view: 2,
          log: [],
          last_normal_view: 1,
          op_number: 0,
          commit_number: 0,
          from: nil
        }

        send_vsr_message(node_svr, do_view_change_msg)
        assert_done()
      end)
    end

    test "handles StartView message", t do
      capture_io(fn ->
        node_svr =
          setup_server(t, fn ->
            assert_called({:set_cluster, ["n1"]}, :ok)

            assert_casted(%StartView{view: 2, log: [], op_number: 0})
          end)

        init_node(node_svr, "n1", ["n1"])

        start_view_msg = %StartView{
          view: 2,
          log: [],
          op_number: 0,
          commit_number: 0
        }

        send_vsr_message(node_svr, start_view_msg)
        assert_done()
      end)
    end

    test "handles ViewChangeOk message", t do
      capture_io(fn ->
        node_svr =
          setup_server(t, fn ->
            assert_called({:set_cluster, ["n1"]}, :ok)

            assert_casted(%ViewChangeOk{view: 2, from: "n2"})
          end)

        init_node(node_svr, "n1", ["n1"])

        view_change_ok_msg = %ViewChangeOk{
          view: 2,
          from: "n2"
        }

        send_vsr_message(node_svr, view_change_ok_msg)
        assert_done()
      end)
    end

    test "handles GetState message", t do
      capture_io(fn ->
        node_svr =
          setup_server(t, fn ->
            assert_called({:set_cluster, ["n1"]}, :ok)

            assert_casted(%GetState{view: 1, op_number: 0, sender: "n2"})
          end)

        init_node(node_svr, "n1", ["n1"])

        get_state_msg = %GetState{
          view: 1,
          op_number: 0,
          sender: "n2"
        }

        send_vsr_message(node_svr, get_state_msg)
        assert_done()
      end)
    end

    test "handles NewState message", t do
      capture_io(fn ->
        node_svr =
          setup_server(t, fn ->
            assert_called({:set_cluster, ["n1"]}, :ok)

            assert_casted(%NewState{view: 1, log: [], op_number: 0})
          end)

        init_node(node_svr, "n1", ["n1"])

        new_state_msg = %NewState{
          view: 1,
          log: [],
          op_number: 0,
          commit_number: 0,
          state_machine_state: %{}
        }

        send_vsr_message(node_svr, new_state_msg)
        assert_done()
      end)
    end

    test "handles ClientRequest message", t do
      capture_io(fn ->
        node_svr =
          setup_server(t, fn ->
            assert_called({:set_cluster, ["n1"]}, :ok)

            assert_casted(%ClientRequest{operation: ["read", "key"], from: "client1"})
          end)

        init_node(node_svr, "n1", ["n1"])

        client_request_msg = %ClientRequest{
          operation: ["read", "key"],
          from: "client1",
          read_only: true,
          client_key: nil
        }

        send_vsr_message(node_svr, client_request_msg)
        assert_done()
      end)
    end

    test "handles Heartbeat message", t do
      capture_io(fn ->
        node_svr =
          setup_server(t, fn ->
            assert_called({:set_cluster, ["n1"]}, :ok)

            assert_casted(%Heartbeat{})
          end)

        init_node(node_svr, "n1", ["n1"])

        heartbeat_msg = %Heartbeat{}

        send_vsr_message(node_svr, heartbeat_msg)
        assert_done()
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

  # Helper function to send VSR messages
  defp send_vsr_message(svr, vsr_message) do
    "n2"
    |> Message.new("n1", vsr_message)
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
