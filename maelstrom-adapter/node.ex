defmodule Maelstrom.Node do
  @moduledoc """
  Main Maelstrom node implementation that handles JSON protocol via STDIN/STDOUT.

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

  defstruct [
    :node_id,
    :node_ids,
    :vsr_replica,
    io_target: :stdio,
    msg_id_counter: 0,
    pending_requests: %{}
  ]

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def init(opts) do
    opts = Keyword.take(opts, [:io_target])
    {:ok, struct!(__MODULE__, opts)}
  end

  @maelstrom_actions [Echo, Read, Write, Cas]
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
    ClientRequest
  ]

  def stdin(server \\ __MODULE__, stdin), do: GenServer.call(server, {:stdin, stdin})

  defp stdin_impl(stdin, _from, state) do
    Logger.debug("Received Maelstrom message: #{stdin}")

    json_map = JSON.decode!(stdin)
    message = Message.from_json_map(json_map)

    new_state =
      case message.body do
        %Init{} = init ->
          do_init(init, state)

        %Echo{echo: echo} ->
          # Handle echo message by sending echo_ok reply
          new_msg_id = state.msg_id_counter + 1

          reply_body = %Echo.Ok{
            in_reply_to: message.body.msg_id,
            msg_id: new_msg_id,
            echo: echo
          }

          reply_message = Message.new(message.dest, message.src, reply_body)
          send_stdout(reply_message, state.io_target)
          %{state | msg_id_counter: new_msg_id}

        %struct{} when struct in @maelstrom_actions ->
          # Handle other maelstrom actions - for now just return current state
          state

        %struct{} when struct in @vsr_messages ->
          # Handle VSR messages - for now just return current state  
          state

        _ ->
          Logger.warning("Unhandled message type: #{inspect(message.body)}")
          state
      end

    {:reply, :ok, new_state}
  end

  defp do_init(%{node_id: node_id, node_ids: node_ids} = _init, state) do
    Logger.info("Initializing Maelstrom node #{node_id} with cluster: #{inspect(node_ids)}")

    # In test environments, skip VSR replica startup since Maelstrom.Supervisor isn't available
    vsr_replica =
      if Process.whereis(Maelstrom.Supervisor) do
        # start VSR replica.
        vsr_opts = [
          log: {DetsLog, [node_id, [dets_file: "#{node_id}_log.dets"]]},
          state_machine: Kv,
          cluster_size: length(node_ids),
          comms_module: Comms
        ]

        case DynamicSupervisor.start_child(Maelstrom.Supervisor, {Vsr, [vsr_opts]}) do
          {:ok, replica} ->
            Process.link(replica)

            Enum.each(node_ids, fn other_node ->
              if other_node != node_id do
                Vsr.connect(replica, other_node)
              end
            end)

            replica

          {:error, _reason} ->
            nil
        end
      else
        Logger.debug("Skipping VSR replica startup in test environment")
        nil
      end

    %{state | node_id: node_id, node_ids: node_ids, vsr_replica: vsr_replica}
  end

  def vsr_message(server \\ __MODULE__, dest_node, message),
    do: GenServer.call(server, {:vsr_message, dest_node, message})

  defp vsr_message_impl(dest_node, message, _from, state) do
    state.node_id
    |> Message.new(dest_node, message)
    |> send_stdout(state.io_target)

    {:reply, :ok, state}
  end

  # Send JSON message to STDOUT
  defp send_stdout(message, io_target) do
    message
    |> JSON.encode!()
    |> then(&IO.puts(io_target, &1))
  end

  def handle_call({:stdin, stdin}, from, state), do: stdin_impl(stdin, from, state)

  def handle_call({:vsr_message, dest_node, message}, from, state),
    do: vsr_message_impl(dest_node, message, from, state)

  def handle_call(:get_cluster, _from, %{node_ids: nil} = state) do
    {:reply, {:error, :not_initialized}, state}
  end

  def handle_call(:get_cluster, _from, %{node_ids: node_ids} = state) do
    {:reply, {:ok, node_ids}, state}
  end

  def handle_cast({:maelstrom_msg, msg_map}, state) do
    try do
      message = Message.from_json_map(msg_map)

      case message.body do
        %Init{} = init ->
          new_state = do_init(init, state)
          {:noreply, new_state}

        %Echo{echo: echo} ->
          # Handle echo message by sending echo_ok reply
          new_msg_id = state.msg_id_counter + 1

          reply_body = %Echo.Ok{
            in_reply_to: message.body.msg_id,
            msg_id: new_msg_id,
            echo: echo
          }

          reply_message = Message.new(message.dest, message.src, reply_body)
          send_stdout(reply_message, state.io_target)
          new_state = %{state | msg_id_counter: new_msg_id}
          {:noreply, new_state}

        %struct{} when struct in @maelstrom_actions ->
          # Handle other maelstrom operations like Read, Write, Cas
          {:noreply, state}

        %struct{} when struct in @vsr_messages ->
          # Handle VSR messages
          {:noreply, state}

        _ ->
          Logger.warning("Unhandled message type: #{inspect(message.body)}")
          {:noreply, state}
      end
    rescue
      error ->
        Logger.error("Failed to process maelstrom message: #{inspect(error)}")
        {:noreply, state}
    end
  end

  def handle_cast(msg, state) do
    Logger.warning("Unhandled cast message: #{inspect(msg)}")
    {:noreply, state}
  end
end
