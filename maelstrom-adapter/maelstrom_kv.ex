defmodule MaelstromKv do
  @moduledoc """
  Maelstrom-compatible Key-Value store with integrated VSR consensus and JSON protocol handling.

  This module combines the functionality of the old Maelstrom.Node and implements:
  - VSR consensus protocol for distributed consistency
  - Maelstrom JSON message protocol over STDIN/STDOUT
  - DETS-based durable log storage
  - Key-value operations (read, write, cas)
  """

  use VsrServer
  require Logger

  # Maelstrom message types
  alias Maelstrom.Message
  alias Maelstrom.Message.Init
  alias Maelstrom.Message.Echo
  alias Maelstrom.Message.Read
  alias Maelstrom.Message.Write
  alias Maelstrom.Message.Cas
  alias Maelstrom.Message.ForwardedReply

  defstruct [
    :from_table,
    dets_root: ".",
    data: %{},
    msg_id_counter: 0
  ]

  @type state :: %__MODULE__{
          from_table: :ets.tid() | nil,
          data: %{term() => term()},
          msg_id_counter: non_neg_integer(),
          dets_root: Path.t()
        }

  # Client API
  def start_link(opts \\ []) do
    VsrServer.start_link(__MODULE__, opts)
  end

  # VsrServer callbacks
  def init(opts) do
    # Create ETS table for GenServer.from translation (private, store reference)
    from_table_ref = :ets.new(__MODULE__, [:set, :private])
    dets_opts = Keyword.take(opts, [:dets_root])
    inner_state = struct!(__MODULE__, [from_table: from_table_ref] ++ dets_opts)
    # Return VSR-compatible init tuple without a log.  Log will be set on init.
    {:ok, inner_state}
  end

  # Client API functions for Maelstrom protocol (convenience wrappers)
  def echo(server, echo_value, from, msg_id) do
    echo_msg = %Echo{echo: echo_value, msg_id: msg_id}

    from
    |> Message.new(VsrServer.node_id(server), echo_msg)
    |> then(&message(server, &1))
  end

  # VsrServer callback for sending VSR messages over Maelstrom network
  def send_vsr(dest_node_id, vsr_message, _inner_state) do
    # Get the current node ID from VSR server
    current_node_id = VsrServer.node_id()

    # Create Maelstrom message with VSR message as body
    # VSR messages already implement JSON.Encoder, so they can be directly encoded

    current_node_id
    |> Message.new(dest_node_id, vsr_message)
    |> JSON.encode!()
    |> tap(&Logger.debug("Sending VSR message: #{&1}"))
    |> IO.puts()
  end

  def read(server, key, from, msg_id) do
    read_msg = %Read{key: key, msg_id: msg_id}

    from
    |> Message.new(VsrServer.node_id(server), read_msg)
    |> then(&message(server, &1))
  end

  def write(server, key, value, from, msg_id) do
    write_msg = %Write{key: key, value: value, msg_id: msg_id}

    from
    |> Message.new(VsrServer.node_id(server), write_msg)
    |> then(&message(server, &1))
  end

  def cas(server, key, from_value, to_value, from, msg_id) do
    cas_msg = %Cas{key: key, from: from_value, to: to_value, msg_id: msg_id}

    from
    |> Message.new(VsrServer.node_id(server), cas_msg)
    |> then(&message(server, &1))
  end

  # Direct maelstrom message handling
  def message(server \\ __MODULE__, message)

  def message(server, message) when is_binary(message) do
    message
    |> JSON.decode!()
    |> Message.from_json_map()
    |> then(&message(server, &1))
  end

  def message(server, message) do
    Logger.debug("Node Received message: #{JSON.encode!(message)}")

    server
    |> GenServer.call({:message, message}, 20_000)
    |> tap(&Logger.debug("Node Processed message: #{inspect(&1)}"))
  end

  # Maelstrom message handlers (integrated from Maelstrom.Node)

  defp do_init(%{node_id: node_id, node_ids: node_ids}, _from, state) do
    Logger.info("Initializing Maelstrom node #{node_id} with cluster: #{inspect(node_ids)}")

    # Initialize VSR cluster with the provided node list
    # Calculate other replicas (excluding self)
    other_replicas = Enum.reject(node_ids, &(&1 == node_id))
    cluster_size = length(node_ids)
    VsrServer.set_cluster(self(), node_id, other_replicas, cluster_size)

    # Open or create DETS table
    table_name = String.to_atom("maelstrom_log_#{node_id}")
    dets_file = Path.join(state.dets_root, "#{node_id}.dets")
    {:ok, log} = :dets.open_file(table_name, file: String.to_charlist(dets_file))
    VsrServer.set_log(self(), log)

    # Return state unchanged - node info handled at protocol level
    {:reply, :ok, state}
  end

  defp do_echo(%{msg_id: msg_id} = echo, _from, state) do
    Logger.debug("Echoing message #{msg_id} with content: #{echo}")
    new_msg_id = state.msg_id_counter + 1
    {:reply, %{msg_id: new_msg_id}, %{state | msg_id_counter: new_msg_id}}
  end

  defp request_with(value, from, state) do
    from_hash = push_from(state, from)
    # Get node_id from VsrServer (not stored in MaelstromKv state)
    node_id = VsrServer.node_id(self())
    encoded_from = %{"node" => node_id, "from" => from_hash}
    {:client_request, encoded_from, value}
  end

  defp do_read(%{key: key}, from, state) do
    {:noreply, state, request_with(["read", key], from, state)}
  end

  defp do_write(%{key: key, value: value}, from, state) do
    {:noreply, state, request_with(["write", key, value], from, state)}
  end

  defp do_cas(%{key: key, from: cas_from, to: to}, from, state) do
    {:noreply, state, request_with(["cas", key, cas_from, to], from, state)}
  end

  defp do_forwarded_reply(%ForwardedReply{from_hash: from_hash} = forwarded_reply, _from, state) do
    # Decode the base64 encoded reply back to Erlang term
    decoded_reply = ForwardedReply.decode_reply(forwarded_reply)
    # Get the from_tuple from our ETS table and reply
    local_reply(state, from_hash, decoded_reply)
    {:reply, :ok, state}
  end

  defp read_impl(key, state) do
    value = Map.get(state.data, key)
    result = if value, do: {:ok, value}, else: {:error, :not_found}
    {state, result}
  end

  defp write_impl(key, value, state) do
    new_data = Map.put(state.data, key, value)
    new_state = %{state | data: new_data}
    {new_state, :ok}
  end

  defp cas_impl(key, from_value, to_value, state) do
    current_value = Map.get(state.data, key)

    if current_value == from_value do
      new_data = Map.put(state.data, key, to_value)
      new_state = %{state | data: new_data}
      {new_state, :ok}
    else
      # CAS failed - precondition not met
      {state, {:error, :precondition_failed}}
    end
  end

  # VSR commit handler for Maelstrom operations
  def handle_commit(["read", key], state), do: read_impl(key, state)
  def handle_commit(["write", key, value], state), do: write_impl(key, value, state)
  def handle_commit(["cas", key, from_value, to_value], state), do: cas_impl(key, from_value, to_value, state)
  # No other commit messages are acknoweldeged.

  def send_reply(%{"node" => node_id, "from" => from_hash}, reply, state) do
    if node_id == VsrServer.node_id() do
      local_reply(state, from_hash, reply)
    else
      VsrServer.node_id()
      |> Message.new(node_id, %ForwardedReply{from_hash: from_hash, reply: reply})
      |> JSON.encode!()
      |> IO.puts()
    end
  end

  # Required log callback implementations for DETS storage
  def log_append(log, entry) do
    table_name = log
    :ok = :dets.insert(table_name, {entry.op_number, entry})
    :ok = :dets.sync(table_name)
    log
  end

  def log_fetch(log, op_number) do
    case :dets.lookup(log, op_number) do
      [{^op_number, entry}] -> {:ok, entry}
      [] -> {:error, :not_found}
    end
  end

  def log_get_all(log) do
    # Use select to get all entries efficiently - much faster than foldl
    :dets.select(log, [{{:"$1", :"$2"}, [], [:"$2"]}])
  end

  def log_get_from(log, op_number) do
    # Use select with guard to filter entries efficiently
    :dets.select(log, [{{:"$1", :"$2"}, [{:>=, {:map_get, :op_number, :"$2"}, op_number}], [:"$2"]}])
  end

  def log_length(log) doigno
    case :dets.info(log, :size) do
      size when is_integer(size) -> size
      _ -> 0
    end
  end

  def log_replace(log, entries) do
    Logger.debug("Replacing log entries: #{inspect(entries)}")

    Enum.each(entries, fn entry ->
      :ok = :dets.insert(log, {entry.op_number, entry})
    end)

    :ok = :dets.sync(log)
    log
  end

  def log_clear(log) do
    :ok = :dets.delete_all_objects(log)
    :ok = :dets.sync(log)
    log
  end

  # State management for VSR
  def get_state(state) do
    %{data: state.data}
  end

  def set_state(state, new_state_data) do
    %{state | data: new_state_data[:data] || new_state_data["data"] || %{}}
  end

  # ETS translation layer for GenServer.from ↔ {node_id, from_hash} mapping

  @doc """
  Store a GenServer.from tuple in ETS and return a hash for Maelstrom transmission.
  """
  def push_from(state, from_tuple) do
    from_hash = :erlang.phash2(from_tuple)
    :ets.insert(state.from_table, {from_hash, from_tuple})
    from_hash
  end

  @doc """
  Retrieve a GenServer.from tuple from ETS using the hash.
  """
  def local_reply(%{from_table: from_table}, from_hash, reply) do
    case :ets.lookup(from_table, from_hash) do
      [{^from_hash, from}] ->
        :ets.delete(from_table, from_hash)
        GenServer.reply(from, reply)
      [] ->
        Logger.error("reply failed, could not find hash #{from_hash}")
    end
  end

  @doc """
  Remove a GenServer.from tuple from ETS after use.
  """
  def delete_from(state, from_hash) do
    :ets.delete(state.from_table, from_hash)
    :ok
  end

  ## ROUTER

  # Handle Maelstrom JSON protocol messages
  def handle_call({:message, message}, from, state) do
    Logger.debug("Received Maelstrom message: #{JSON.encode!(message)}")

    case message.body do
      %Init{} = init ->
        do_init(init, from, state)

      %Echo{} = echo ->
        do_echo(echo, from, state)

      %Read{} = read ->
        do_read(read, from, state)

      %Write{} = write ->
        do_write(write, from, state)

      %Cas{} = cas ->
        do_cas(cas, from, state)

      %ForwardedReply{} = forwarded_reply ->
        do_forwarded_reply(forwarded_reply, from, state)
    end
  end
end
