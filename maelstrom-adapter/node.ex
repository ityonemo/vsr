defmodule Maelstrom.Node do
  @moduledoc """
  Main Maelstrom node implementation that handles JSON protocol via message/STDOUT.

  This module bridges Maelstrom's JSON protocol with our VSR implementation,
  providing a distributed systems testing interface.
  """

  use GenServer
  require Logger

  # maelstrom inbound messages
  alias Maelstrom.Node.Message
  alias Maelstrom.Node.Init
  alias Maelstrom.Node.Echo
  alias Maelstrom.Node.Read
  alias Maelstrom.Node.Write
  alias Maelstrom.Node.Cas

  # maelstrom components
  alias Maelstrom.Comms
  alias Maelstrom.GlobalData
  alias Maelstrom.DetsLog
  alias Maelstrom.Kv

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

  defstruct [
    :node_id,
    :node_ids,
    vsr_replica: Vsr,
    msg_id_counter: 0,
    pending_requests: %{}
  ]

  # node_id and node_ids may only be nil in the pre-init phase.
  @type state :: %__MODULE__{
          node_id: String.t() | nil,
          node_ids: [String.t()] | nil,
          vsr_replica: pid() | atom(),
          msg_id_counter: non_neg_integer(),
          pending_requests: map()
        }

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def init(opts) do
    {:ok, struct!(__MODULE__, Keyword.drop(opts, [:name]))}
  end

  @vsr_messages [
    Prepare,
    PrepareOk,
    Commit,
    StartViewChange,
    StartViewChangeAck,
    DoViewChange,
    StartView,
    ViewChangeOk,
    GetState,
    NewState,
    ClientRequest,
    Heartbeat
  ]

  def message(server \\ __MODULE__, message)

  def message(server, message) when is_binary(message) do
    message
    |> JSON.decode!()
    |> Message.from_json_map()
    |> then(&message(server, &1))
  end

  def message(server, message) do
    GenServer.call(server, {:message, message})
  end

  defp message_impl(message, _from, state) do
    Logger.debug("Received Maelstrom message: #{JSON.encode!(message)}")

    new_state =
      case message.body do
        %Init{} = init ->
          do_init(init, message, state)

        %Echo{} = echo ->
          do_echo(echo, message, state)

        %Read{} = read ->
          do_read(read, message, state)

        %Write{} = write ->
          do_write(write, message, state)

        %Cas{} = cas ->
          do_cas(cas, message, state)

        %struct{} when struct in @vsr_messages ->
          # Forward VSR messages to the VSR replica process using VSR API
          Vsr.Message.vsr_send(state.vsr_replica, message.body)
          state

        _ ->
          Logger.warning("Unhandled message type: #{inspect(message.body)}")
          state
      end

    {:reply, :ok, new_state}
  end

  defp do_init(%{node_id: node_id, node_ids: node_ids} = init, message, state) do
    Logger.info("Initializing Maelstrom node #{node_id} with cluster: #{inspect(node_ids)}")

    GlobalData.register(node_id)

    # Update VSR with cluster information
    Vsr.set_cluster(state.vsr_replica, node_ids)

    Message.reply(init, to: message)

    %{state | node_id: node_id, node_ids: node_ids}
  end

  defp do_echo(%Echo{msg_id: msg_id} = echo, message, state) do
    Logger.debug("Echoing message #{msg_id} with content: #{inspect(echo)}")
    new_msg_id = state.msg_id_counter + 1

    Message.reply(echo, to: message, echo: echo.echo, msg_id: new_msg_id)

    %{state | msg_id_counter: new_msg_id}
  end

  # KV operation implementations
  defp do_read(%Read{key: key} = read, message, state) do
    # Execute read operation through VSR
    case Vsr.client_request(state.vsr_replica, ["read", key]) do
      {:ok, value} ->
        Message.reply(read, to: message, value: value)

        state

      {:error, :not_found} ->
        send_error_reply(message, state, 20, "key not found")

      {:error, _reason} ->
        send_error_reply(message, state, 13, "temporarily unavailable")
    end
  end

  defp do_write(%Write{key: key, value: value} = write, message, state) do
    # Execute write operation through VSR
    case Vsr.client_request(state.vsr_replica, ["write", key, value]) do
      :ok ->
        Message.reply(write, to: message)

        state

      {:error, _reason} ->
        send_error_reply(message, state, 13, "temporarily unavailable")
    end
  end

  defp do_cas(%Cas{key: key, from: from, to: to} = cas, message, state) do
    # Execute CAS operation through VSR
    case Vsr.client_request(state.vsr_replica, ["cas", key, from, to]) do
      :ok ->
        Message.reply(cas, to: message)

        state

      {:error, :precondition_failed} ->
        send_error_reply(message, state, 22, "precondition failed")

      {:error, _reason} ->
        send_error_reply(message, state, 13, "temporarily unavailable")
    end
  end

  defp send_error_reply(message, state, code, text) do
    message.dest
    |> Message.new(message.src, %Maelstrom.Node.Error{
      in_reply_to: message.body.msg_id,
      code: code,
      text: text
    })
    |> JSON.encode!()
    |> IO.puts()

    state
  end

  def handle_call({:message, message}, from, state), do: message_impl(message, from, state)
end
