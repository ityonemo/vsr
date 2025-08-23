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
    data: %{},
    msg_id_counter: 0,
    node_id: nil
  ]

  @type state :: %__MODULE__{
          from_table: :ets.tid() | nil,
          data: %{term() => term()},
          msg_id_counter: non_neg_integer(),
          node_id: String.t() | nil
        }

  # Client API
  def start_link(opts \\ []) do
    VsrServer.start_link(__MODULE__, opts)
  end

  # Client API functions for Maelstrom protocol (convenience wrappers)
  def echo(server, echo_value, from, msg_id) do
    echo_msg = %Echo{echo: echo_value, msg_id: msg_id}

    from
    |> Message.new(VsrServer.node_id(server), echo_msg)
    |> then(&message(server, &1))
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
    |> tap(&Logger.debug("Node Processed message: #{JSON.encode!(&1)}"))
  end

  # VsrServer callbacks
  def init(opts) do
    # Initialize DETS log directly (no separate DetsLog module)
    # Use unique default to avoid ETS table name conflicts
    default_node_id = "default_#{System.unique_integer([:positive])}"
    node_id = Keyword.get(opts, :node_id, default_node_id)
    table_name = String.to_atom("maelstrom_log_#{node_id}")
    dets_file = Keyword.get(opts, :dets_file, "#{node_id}_log.dets")

    # Ensure DETS directory exists
    dets_dir = Path.dirname(dets_file)
    File.mkdir_p!(dets_dir)

    # Open or create DETS table
    {:ok, ^table_name} = :dets.open_file(table_name, file: String.to_charlist(dets_file))

    # Create ETS table for GenServer.from translation (private, store reference)
    from_table_ref = :ets.new(__MODULE__, [:set, :private])

    # Initialize state with DETS log and empty KV store
    log = %{table_name: table_name, dets_file: dets_file}
    inner_state = %__MODULE__{from_table: from_table_ref, node_id: node_id}

    # Return VSR-compatible init tuple
    {:ok, log, inner_state}
  end

  # Maelstrom message handlers (integrated from Maelstrom.Node)

  defp do_init(%{node_id: node_id, node_ids: node_ids} = init, message, state) do
    Logger.info("Initializing Maelstrom node #{node_id} with cluster: #{inspect(node_ids)}")

    # Node registration is now handled in MaelstromKv init - no separate registration needed

    # Send init response
    reply_body = Message.reply(init, :ok)
    response_message = Message.new(message.dest, message.src, reply_body)

    JSON.encode!(response_message)
    |> tap(&Logger.debug("Sending Maelstrom message: #{&1}"))
    |> IO.puts()

    # Return state unchanged - node info handled at protocol level
    {:reply, :ok, state}
  end

  defp do_echo(%Echo{msg_id: msg_id} = echo, message, state) do
    Logger.debug("Echoing message #{msg_id} with content: #{inspect(echo)}")
    new_msg_id = state.msg_id_counter + 1

    reply_body = Message.reply(echo, %{echo: echo.echo, msg_id: new_msg_id})
    response_message = Message.new(message.dest, message.src, reply_body)

    JSON.encode!(response_message)
    |> tap(&Logger.debug("Sending Maelstrom message: #{&1}"))
    |> IO.puts()

    {:reply, :ok, %{state | msg_id_counter: new_msg_id}}
  end

  defp do_read(%Read{key: key}, message, from, state) do
    # Read operations require consensus for linearizability
    operation = ["read", key]

    # Store GenServer from in ETS and create encoded from for VSR
    from_hash = store_from(state, from)
    encoded_from = %{"node" => state.node_id, "from" => from_hash}

    # Store message for Maelstrom JSON reply later
    :ets.insert(state.from_table, {"message_#{from_hash}", message})

    {:noreply, state, {:client_request, encoded_from, operation}}
  end

  defp do_write(%Write{key: key, value: value}, message, from, state) do
    # Write operations require consensus
    operation = ["write", key, value]

    # Store GenServer from in ETS and create encoded from for VSR
    from_hash = store_from(state, from)
    encoded_from = %{"node" => state.node_id, "from" => from_hash}

    # Store message for Maelstrom JSON reply later
    :ets.insert(state.from_table, {"message_#{from_hash}", message})

    {:noreply, state, {:client_request, encoded_from, operation}}
  end

  defp do_cas(%Cas{key: key, from: cas_from, to: to}, message, genserver_from, state) do
    # CAS operations require consensus
    operation = ["cas", key, cas_from, to]

    # Store GenServer from in ETS and create encoded from for VSR
    from_hash = store_from(state, genserver_from)
    encoded_from = %{"node" => state.node_id, "from" => from_hash}

    # Store message for Maelstrom JSON reply later
    :ets.insert(state.from_table, {"message_#{from_hash}", message})

    {:noreply, state, {:client_request, encoded_from, operation}}
  end

  defp do_forwarded_reply(
         %ForwardedReply{from_hash: from_hash} = forwarded_reply,
         _message,
         state
       ) do
    # Get the from_tuple from our ETS table and reply
    case fetch_from(state, from_hash) do
      {:ok, from_tuple} ->
        delete_from(state, from_hash)
        GenServer.reply(from_tuple, ForwardedReply.decode_result(forwarded_reply))

      {:error, :not_found} ->
        Logger.error("ForwardedReply: from_hash #{from_hash} not found in ETS table")
    end

    {:reply, :ok, state}
  end

  defp send_error_reply_direct(message, code, text) do
    message.dest
    |> Message.new(message.src, %Maelstrom.Message.Error{
      in_reply_to: message.body.msg_id,
      code: code,
      text: text
    })
    |> JSON.encode!()
    |> tap(&Logger.debug("Sending Maelstrom message: #{&1}"))
    |> IO.puts()
  end

  # VSR commit handler for Maelstrom operations
  def handle_commit(operation, state, _vsr_state) do
    case operation do
      ["read", key] ->
        # Read operations through VSR consensus
        value = Map.get(state.data, key)
        result = if value, do: {:ok, value}, else: {:error, :not_found}
        {state, result}

      ["write", key, value] ->
        # Write operations through VSR consensus
        new_data = Map.put(state.data, key, value)
        new_state = %{state | data: new_data}
        {new_state, :ok}

      ["cas", key, from_value, to_value] ->
        # Compare-and-swap operations through VSR consensus
        current_value = Map.get(state.data, key)

        if current_value == from_value do
          new_data = Map.put(state.data, key, to_value)
          new_state = %{state | data: new_data}
          {new_state, :ok}
        else
          # CAS failed - precondition not met
          {state, {:error, :precondition_failed}}
        end

      _other ->
        {state, :ok}
    end
  end

  def send_reply(from, reply, inner_state) do
    # For Maelstrom, the 'from' parameter is the original Maelstrom message
    case from do
      %Maelstrom.Message{} = message ->
        # Send Maelstrom JSON reply based on the operation result
        case {message.body, reply} do
          {%Echo{}, _result} ->
            # Echo replies include the original echo value
            Message.reply(message.body, to: message, echo: message.body.echo)

          {%Read{}, {:ok, value}} ->
            # Read success replies include the value
            Message.reply(message.body, to: message, value: value)

          {%Read{}, {:error, :not_found}} ->
            # Read error for missing key
            send_error_reply_direct(message, 20, "key not found")

          {%Write{}, :ok} ->
            # Write success replies
            Message.reply(message.body, to: message)

          {%Cas{}, :ok} ->
            # CAS success replies
            Message.reply(message.body, to: message)

          {%Cas{}, {:error, :precondition_failed}} ->
            # CAS precondition failed
            send_error_reply_direct(message, 22, "precondition failed")

          _ ->
            # Generic error reply
            send_error_reply_direct(message, 13, "temporarily unavailable")
        end

      %{"node" => node_id, "from" => from_hash} ->
        # Legacy format for remote replies via ForwardedReply
        our_node_id = inner_state.node_id || "unknown"

        if node_id == our_node_id do
          # Local reply using ETS lookup
          case fetch_from(inner_state, from_hash) do
            {:ok, from_tuple} ->
              delete_from(inner_state, from_hash)
              GenServer.reply(from_tuple, reply)

            {:error, :not_found} ->
              Logger.error("Local reply: from_hash #{from_hash} not found in ETS table")
          end
        else
          # Remote reply via ForwardedReply
          our_node_id
          |> Message.new(node_id, %Maelstrom.Message.ForwardedReply{
            from_hash: from_hash,
            result: reply
          })
          |> JSON.encode!()
          |> tap(&Logger.debug("Sending Maelstrom message: #{&1}"))
          |> IO.puts()
        end

      _ ->
        # Direct GenServer reply for local operations
        GenServer.reply(from, reply)
    end
  end

  # Required log callback implementations for DETS storage
  def log_append(log, entry) do
    table_name = log.table_name
    :ok = :dets.insert(table_name, {entry.op_number, entry})
    :ok = :dets.sync(table_name)
    log
  end

  def log_fetch(log, op_number) do
    case :dets.lookup(log.table_name, op_number) do
      [{^op_number, entry}] -> {:ok, entry}
      [] -> {:error, :not_found}
    end
  end

  def log_get_all(log) do
    case :dets.traverse(log.table_name, fn {_op_number, entry} ->
           {:continue, entry}
         end) do
      [] ->
        []

      entries when is_list(entries) ->
        entries
        |> Enum.sort_by(& &1.op_number)

      {:error, _reason} ->
        []
    end
  end

  def log_get_from(log, op_number) do
    case :dets.traverse(log.table_name, fn {_op_num, entry} ->
           {:continue, entry}
         end) do
      [] ->
        []

      entries when is_list(entries) ->
        entries
        |> Enum.filter(&(&1.op_number >= op_number))
        |> Enum.sort_by(& &1.op_number)

      {:error, _reason} ->
        []
    end
  end

  def log_length(log) do
    case :dets.info(log.table_name, :size) do
      size when is_integer(size) -> size
      _ -> 0
    end
  end

  def log_replace(log, entries) do
    table_name = log.table_name
    :ok = :dets.delete_all_objects(table_name)

    Logger.debug("Replacing log entries: #{inspect(entries)}")

    Enum.each(entries, fn entry ->
      :ok = :dets.insert(table_name, {entry.op_number, entry})
    end)

    :ok = :dets.sync(table_name)
    log
  end

  def log_clear(log) do
    :ok = :dets.delete_all_objects(log.table_name)
    :ok = :dets.sync(log.table_name)
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
  def store_from(state, from_tuple) do
    from_hash = :erlang.phash2(from_tuple)
    :ets.insert(state.from_table, {from_hash, from_tuple})
    from_hash
  end

  @doc """
  Retrieve a GenServer.from tuple from ETS using the hash.
  """
  def fetch_from(state, from_hash) do
    case :ets.lookup(state.from_table, from_hash) do
      [{^from_hash, from_tuple}] -> {:ok, from_tuple}
      [] -> {:error, :not_found}
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
        do_init(init, message, state)

      %Echo{} = echo ->
        do_echo(echo, message, state)

      %Read{} = read ->
        do_read(read, message, from, state)

      %Write{} = write ->
        do_write(write, message, from, state)

      %Cas{} = cas ->
        do_cas(cas, message, from, state)

      %ForwardedReply{} = forwarded_reply ->
        do_forwarded_reply(forwarded_reply, message, state)
    end
  end

  # ETS translation layer GenServer API
  def handle_call({:store_from, from_tuple}, _from, state) do
    from_hash = store_from(state, from_tuple)
    {:reply, from_hash, state}
  end

  def handle_call({:fetch_from, from_hash}, _from, state) do
    result = fetch_from(state, from_hash)
    {:reply, result, state}
  end

  def handle_call({:delete_from, from_hash}, _from, state) do
    result = delete_from(state, from_hash)
    {:reply, result, state}
  end
end
