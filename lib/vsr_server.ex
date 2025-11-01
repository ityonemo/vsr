defmodule VsrServer do
  @moduledoc """
  GenServer wrapper that implements the VSR (Viewstamped Replication) protocol.

  This module provides a framework for building VSR-enabled services by handling
  all VSR protocol messages while delegating application-specific logic to
  the implementing module.
  """

  use GenServer
  require Logger

  alias Vsr.Telemetry
  alias Vsr.Message.ClientRequest
  alias Vsr.Message.Prepare
  alias Vsr.Message.PrepareOk
  alias Vsr.Message.Commit
  alias Vsr.Message.StartViewChange
  alias Vsr.Message.StartViewChangeAck
  alias Vsr.Message.DoViewChange
  alias Vsr.Message.StartView
  alias Vsr.Message.GetState
  alias Vsr.Message.NewState
  alias Vsr.Message.Heartbeat
  alias Vsr.LogEntry

  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      @behaviour VsrServer

      unless Module.has_attribute?(__MODULE__, :doc) do
        @doc """
        Returns a specification to start this module under a supervisor.

        See `Supervisor`.
        """
      end

      def child_spec(init_arg) do
        default = %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [init_arg]}
        }

        Supervisor.child_spec(default, unquote(Macro.escape(opts)))
      end

      # Default callback implementations (matching GenServer's pattern)
      @doc false
      def handle_call(msg, _from, state) do
        proc =
          case Process.info(self(), :registered_name) do
            {_, []} -> self()
            {_, name} -> name
          end

        case :erlang.phash2(1, 1) do
          0 ->
            raise "attempted to call GenServer #{inspect(proc)} but no handle_call/3 clause was provided"

          1 ->
            {:stop, {:bad_call, msg}, state}
        end
      end

      @doc false
      def handle_cast(msg, state) do
        proc =
          case Process.info(self(), :registered_name) do
            {_, []} -> self()
            {_, name} -> name
          end

        case :erlang.phash2(1, 1) do
          0 ->
            raise "attempted to cast to GenServer #{inspect(proc)} but no handle_cast/2 clause was provided"

          1 ->
            {:stop, {:bad_cast, msg}, state}
        end
      end

      @doc false
      def handle_info(msg, state) do
        proc =
          case Process.info(self(), :registered_name) do
            {_, []} -> self()
            {_, name} -> name
          end

        :logger.error(
          %{
            label: {VsrServer, :no_handle_info},
            report: %{
              module: __MODULE__,
              message: msg,
              name: proc
            }
          },
          %{
            domain: [:otp, :elixir],
            error_logger: %{tag: :error_msg},
            report_cb: &GenServer.format_report/1
          }
        )

        {:noreply, state}
      end

      @doc false
      def handle_continue(_continue, state) do
        {:noreply, state}
      end

      @doc false
      def terminate(reason, state) do
        :ok
      end

      @doc false
      def code_change(old_vsn, state, extra) do
        {:ok, state}
      end

      # VSR-specific default implementations
      @doc false
      def handle_commit(_operation, vsr_state) do
        {vsr_state, :ok}
      end

      @doc false
      # the default implementation for send_vsr uses `pid`s or atoms as node id's.
      def send_vsr(destination, message, _vsr_state) do
        send(destination, {:"$vsr", message})
      end

      @doc false
      # the default implementation for monitoring nodes uses `pid`s as node id's.
      def monitor_node(pid, message, _vsr_state) do
        Process.monitor(pid)
      end

      @doc false
      # the default implementation for send_reply uses GenServer.reply for standard Erlang distribution.
      def send_reply(from, reply, _vsr_state) do
        GenServer.reply(from, reply)
      end

      defoverridable child_spec: 1,
                     handle_call: 3,
                     handle_cast: 2,
                     handle_info: 2,
                     handle_continue: 2,
                     terminate: 2,
                     code_change: 3,
                     handle_commit: 2,
                     send_vsr: 3,
                     monitor_node: 3,
                     send_reply: 3
    end
  end

  # insert docs here.
  @typedoc """
  A client request that does not expect a reply.  This should be used sparingly, typically, it is
  better to produce a synchronous reply, even if the response is just an `:ok` acknowledgement.
  """
  @type client_request_noreply :: {:client_request, term()}
  @typedoc """
  A client request that expects a reply.  The `from` parameter is typically a `GenServer.from()` term,
  if the cluster communicates using Erlang distribution.  If it does not, you may encode the `from`
  parameter in a way that is appropriate for the communication protocol used by the cluster.
  """
  @type client_request :: client_request_noreply | {:client_request, from :: term(), term()}

  @doc """
  Invoked when the server is started. `start_link/3` or `start/3` will
  block until it returns.

  See `c:GenServer.init/1` for general information about the `init/1` callback.

  The `VsrServer` init callback adds an additional `log` term in the success tuple,
  which initializes the VSR log,  This should be a durable, local store for logging
  VSR operations.

  If the log must be initialized at a later stage (for example, via an out-of band
  initialization, then you may return the normal {:ok, state} term)
  """
  @callback init(init_arg :: term) ::
              {:ok, state}
              | {:ok, log, state}
              | {:ok, log, state, timeout | :hibernate | {:continue, continue_arg :: term}}
              | :ignore
              | {:stop, reason :: term}
            when state: term, log: term

  @doc """
  Invoked to handle synchronous `call/3` messages.  Generally, initiating operations
  on the state machine that VSR wraps should be done through this callback.

  See `c:GenServer.handle_call/3` for general information about this callback.

  To initiate a VSR request, use the `:client_request` tuple.
  """
  @callback handle_call(request :: term, GenServer.from(), state :: term) ::
              {:reply, reply, new_state}
              | {:reply, reply, new_state,
                 timeout | :hibernate | {:continue, continue_arg :: term} | client_request_noreply}
              | {:noreply, new_state}
              | {:noreply, new_state,
                 timeout | :hibernate | {:continue, continue_arg :: term} | client_request}
              | {:stop, reason, reply, new_state}
              | {:stop, reason, new_state}
            when reply: term, new_state: term, reason: term

  @doc """
  Invoked to handle asynchronous `cast/2` messages.

  See `c:GenServer.handle_cast/2` for general information about this callback.

  To initiate a VSR request, pass the `:client_request` tuple.  You may use a `from` argument
  in the tuple that has been created by a previous call and stored in the server state.

  This callback is optional. If one is not implemented, the server will fail
  if a cast is performed against it.
  """
  @callback handle_cast(request :: term, state :: term) ::
              {:noreply, new_state}
              | {:noreply, new_state,
                 timeout | :hibernate | {:continue, continue_arg :: term} | client_request}
              | {:stop, reason :: term, new_state}
            when new_state: term

  @doc """
  Invoked to handle all other messages.

  See `c:GenServer.handle_info/2` for general information about this callback.

  Return values are the same as `c:handle_cast/2`.

  This callback is optional. If one is not implemented, the received message
  will be logged.
  """
  @callback handle_info(msg :: :timeout | term, state :: term) ::
              {:noreply, new_state}
              | {:noreply, new_state,
                 timeout | :hibernate | {:continue, continue_arg :: term} | client_request}
              | {:stop, reason :: term, new_state}
            when new_state: term

  @doc """
  Invoked to handle continue instructions.

  See `c:GenServer.handle_info/2` for general information about this callback.

  Return values are the same as `c:handle_cast/2`.

  This callback is optional. If one is not implemented, the server will fail
  if a continue instruction is used.
  """
  @callback handle_continue(continue_arg, state :: term) ::
              {:noreply, new_state}
              | {:noreply, new_state,
                 timeout | :hibernate | {:continue, continue_arg} | client_request}
              | {:stop, reason :: term, new_state}
            when new_state: term, continue_arg: term

  @doc """
  Invoked when the server is about to exit. It should do any cleanup required.

  See `c:GenServer.terminate/2` for general information about this callback.

  This callback is optional.
  """
  @callback terminate(reason, state :: term) :: term
            when reason: :normal | :shutdown | {:shutdown, term} | term

  @doc """
  Invoked to change the state of the `VsrServer` when a different version of a
  module is loaded (hot code swapping) and the state's term structure should be
  changed.

  See `c:GenServer.code_change/3` for general information about this callback.

  This callback is optional.
  """
  @callback code_change(old_vsn, state :: term, extra :: term) ::
              {:ok, new_state :: term}
              | {:error, reason :: term}
            when old_vsn: term | {:down, term}

  @doc """
  Invoked when a VSR operation is committed and needs to be applied to the state machine.

  This callback receives the operation that was committed, the current inner state,
  and the full VSR state. It should apply the operation and return the new inner state
  and any result value to be sent back to the client.
  """
  @callback handle_commit(operation :: term, inner_state :: term) ::
              {new_inner_state :: term, result :: term}

  @doc """
  Sends a VSR message to another node in the cluster.

  The default implementation uses PIDs as node identifiers and sends via raw `send/2`.
  Override this for custom communication protocols (e.g., Maelstrom, network protocols).
  """
  @callback send_vsr(node_id :: term, message :: term, inner_state :: term) :: term

  @doc """
  Monitors another node in the cluster for failure detection.

  The default implementation uses `Process.monitor/1` for PID-based node identifiers.
  Override this for custom monitoring mechanisms.
  """
  @callback monitor_node(node_id :: term, message :: term, inner_state :: term) :: reference

  @doc """
  Appends an entry to the VSR log.

  Required callback - must be implemented by all VSR modules.
  """
  @callback log_append(log :: term, entry :: LogEntry.t()) :: new_log :: term

  @doc """
  Fetches an entry from the VSR log by operation number.

  Required callback - must be implemented by all VSR modules.
  """
  @callback log_fetch(log :: term, op_number :: non_neg_integer) ::
              {:ok, LogEntry.t()} | {:error, :not_found}

  @doc """
  Gets all entries from the VSR log.

  Required callback - must be implemented by all VSR modules.
  """
  @callback log_get_all(log :: term) :: [LogEntry.t()]

  @doc """
  Gets entries from the specified operation number onwards.

  Required callback - must be implemented by all VSR modules.
  """
  @callback log_get_from(log :: term, op_number :: non_neg_integer) :: [LogEntry.t()]

  @doc """
  Gets the current length (number of entries) in the VSR log.

  Required callback - must be implemented by all VSR modules.
  """
  @callback log_length(log :: term) :: non_neg_integer

  @doc """
  Replaces the entire VSR log with new entries.

  Used during state transfer and view changes.
  Required callback - must be implemented by all VSR modules.
  """
  @callback log_replace(log :: term, entries :: [LogEntry.t()]) :: new_log :: term

  @doc """
  Clears all entries from the VSR log.

  Required callback - must be implemented by all VSR modules.
  """
  @callback log_clear(log :: term) :: new_log :: term

  @doc """
  Sends a reply to a client.

  The default implementation uses `GenServer.reply/2` for standard Erlang distribution.
  Override this for custom communication protocols where the `from` parameter
  needs to be handled differently (e.g., encoded node references, message passing).
  """
  @callback send_reply(from :: term, reply :: term, inner_state :: term) :: term

  @enforce_keys [:module]
  defstruct @enforce_keys ++
              [
                :inner,
                :log,
                :cluster_size,
                :replicas,
                :node_id,
                :status,
                view_number: 0,
                op_number: 0,
                commit_number: 0,
                prepare_ok_count: %{},
                view_change_votes: %{},
                last_normal_view: 0,
                heartbeat_timer_ref: nil,
                primary_inactivity_timer_ref: nil,
                primary_inactivity_timeout: 5000,
                view_change_timeout: 10_000,
                heartbeat_interval: 1000,
                client_table: %{}
              ]

  # the internal implementation of the VSR server state should be opaque to any
  # implementations of vsr_server, they should not depend on access to this information.

  @type node_id :: term
  @typep request_id :: non_neg_integer
  @typep client_processing :: {:processing, request_id}
  @typep client_cached :: {:cached, request_id, result :: term}
  @typep client_entry :: client_processing | client_cached

  defguardp client_entry_request_id(entry) when elem(entry, 1)

  @opaque state :: %__MODULE__{
            module: atom(),
            inner: term(),
            log: term(),
            cluster_size: non_neg_integer(),
            node_id: node_id(),
            replicas: MapSet.t(node_id()),
            status: :uninitialized | :normal | :view_change,
            view_number: non_neg_integer(),
            op_number: non_neg_integer(),
            commit_number: non_neg_integer(),
            prepare_ok_count: %{
              optional({non_neg_integer(), non_neg_integer()}) => non_neg_integer()
            },
            view_change_votes: map(),
            last_normal_view: non_neg_integer(),
            heartbeat_timer_ref: reference() | nil,
            primary_inactivity_timer_ref: reference() | nil,
            primary_inactivity_timeout: non_neg_integer(),
            view_change_timeout: non_neg_integer(),
            heartbeat_interval: non_neg_integer(),
            client_table: %{optional(node_id()) => client_entry}
          }

  def start_link(module, opts) do
    verify_required_callbacks!(module)
    GenServer.start_link(__MODULE__, {module, opts}, opts)
  end

  @impl true
  def init({module, opts}) do
    # Initialize with node_id and replicas?
    %__MODULE__{module: module}
    |> initialize_starting_cluster(opts)
    |> initialize_other_state()
    |> do_inner_init()
  end

  defp initialize_starting_cluster(state, opts) do
    case {Keyword.fetch(opts, :node_id), Keyword.fetch(opts, :replicas)} do
      {{:ok, node_id}, {:ok, replicas}} ->
        cluster_size = Keyword.get(opts, :cluster_size)

        {do_set_cluster(state, node_id, replicas, cluster_size),
         Keyword.drop(opts, [:node_id, :replicas, :cluster_size])}

      {:error, :error} ->
        {%{state | status: :uninitialized}, opts}

      _ ->
        raise "VSR cluster initialization must define both node_id and replicas"
    end
  end

  @settable_fields ~w[view_number op_number commit_number prepare_ok_count view_change_votes last_normal_view heartbeat_timer_ref
  primary_inactivity_timer_ref primary_inactivity_timeout view_change_timeout heartbeat_interval status]a
  defp initialize_other_state({state, opts}) do
    {vsr_state_fields, maybe_inner_opts} = Keyword.split(opts, @settable_fields)
    {struct!(state, vsr_state_fields), maybe_inner_opts}
  end

  defp do_inner_init({state, opts}) do
    case state.module.init(opts) do
      {:ok, inner_state} ->
        # this is the case where setting the log should be deferred till later.
        # note, we don't start timers until a log exists.
        {:ok, %{state | inner: inner_state}}

      {:ok, log, inner_state} ->
        %{state | inner: inner_state, log: log}
        |> start_timers
        |> then(&{:ok, &1})

      {:ok, log, inner_state, extra} ->
        %{state | inner: inner_state, log: log}
        |> start_timers
        |> then(&{:ok, &1, extra})

      ignore_or_stop ->
        ignore_or_stop
    end
  end

  # API

  @type server :: pid | atom
  @spec set_cluster(
          server,
          node_id,
          replicas :: Enumerable.t(node_id),
          cluster_size :: non_neg_integer() | nil
        ) :: :ok
        when node_id: term
  @spec set_log(server, log :: term()) :: :ok
  @spec vsr_send(server, message :: term()) :: term
  @spec dump(server) :: state()

  # IMPLEMENTATIONS

  @doc """
  In the case that the cluster cannot be known at boot time, this function may be used to set cluster details.
  """
  # this API call must be `cast` because it may be sent from within the implementation itself.
  def set_cluster(server, node_id, replicas, cluster_size \\ nil),
    do: GenServer.cast(server, {:"$vsr_set_cluster", node_id, replicas, cluster_size})

  defp set_cluster_impl(node_id, replicas, cluster_size, state),
    do: {:noreply, do_set_cluster(state, node_id, replicas, cluster_size)}

  @doc """
  In the case that the log cannot be known at boot time (for example, some parameter in the log setup depends
  on the cluster configuration), this function may be used to set the log.
  """
  def set_log(server, log), do: GenServer.cast(server, {:"$vsr_set_log", log})

  def set_log_impl(log, state), do: {:noreply, start_timers(%{state | log: log})}

  defp do_set_cluster(state, node_id, replicas, cluster_size) do
    # Create MapSet from replicas, excluding the current node_id
    replicas_set =
      replicas
      |> MapSet.new()
      |> MapSet.delete(node_id)

    # Use provided cluster_size or calculate from current node + replicas
    # +1 for current node
    actual_cluster_size = cluster_size || MapSet.size(replicas_set) + 1

    Process.put(:"$vsr_node_id", node_id)

    Logger.info(
      "VSR cluster configured: node_id=#{node_id}, size=#{actual_cluster_size}, replicas=#{inspect(MapSet.to_list(replicas_set))}"
    )

    %{
      state
      | node_id: node_id,
        cluster_size: actual_cluster_size,
        replicas: replicas_set,
        status: :normal
    }
  end

  @doc """
  Gets the node_id of a VSR server.
  """
  def node_id(server \\ self())

  def node_id(server) when server == self(),
    do: Process.get(:"$vsr_node_id") || raise("not running in a VSR server context")

  def node_id(server), do: GenServer.call(server, :"$vsr_node_id")

  defp node_id_impl(state) do
    {:reply, state.node_id, state}
  end

  @doc """
  In certain situations, you may need to send VSR messages *out-of-band* from the normal erlang distribution
  mechanism that VsrServer relies on by default.  In this case you may use this function to send VSR messages
  to VSR servers.
  """
  def vsr_send(server, message), do: send(server, {:"$vsr", message})

  @doc """
  Dumps the internal state of a VSR server for testing and debugging.
  """
  def dump(server), do: GenServer.call(server, :"$vsr_dump")

  defp dump_impl(state) do
    {:reply, state, state}
  end

  # VSR Protocol Implementation

  # client request handling.
  # - if the node is not primary, wrap the client request in a ClientRequest struct and send
  #   it as a VSR message to the primary node.
  # - if the node is primary, wrap it into a ClientRequest struct and tail-call.
  #
  # REPLIES:
  # replica nodes are responsible for sending replies to the client WHEN the operation is
  # committed, and they must detect that they are the source of the operation.
  # The primary node is responsible for sending replies to the client once the commit
  # message has been transmitted.

  defp client_request_impl(operation, from, state) do
    # this function should be a three-arity function.
    # perform wrapping into the ClientRequest struct (and sending or tail-calling) here.

    # Extract client deduplication info from from parameter if it's a map
    {client_id, request_id} =
      case from do
        %{client_id: cid, request_id: rid} -> {cid, rid}
        _ -> {nil, nil}
      end

    if primary?(state) do
      # If we are primary, wrap into ClientRequest and tail-call the struct version
      client_request = %ClientRequest{
        operation: operation,
        from: from,
        client_id: client_id,
        request_id: request_id
      }

      client_request_impl(client_request, state)
    else
      # If we are not primary, wrap and send to primary node
      primary_node = primary(state)

      client_request = %ClientRequest{
        operation: operation,
        from: from,
        client_id: client_id,
        request_id: request_id
      }

      send_to(state, primary_node, client_request)
      {:noreply, state}
    end
  end

  defp client_request_impl(
         %ClientRequest{
           operation: operation,
           from: from,
           client_id: client_id,
           request_id: request_id
         },
         state
       ) do
    # During network partitions or view changes, a ClientRequest may be forwarded to a node
    # that was primary when the message was sent but is no longer primary when received.
    # Handle this gracefully by checking current primary status and forwarding if needed.
    if not primary?(state) do
      primary_node = primary(state)

      client_request = %ClientRequest{
        operation: operation,
        from: from,
        client_id: client_id,
        request_id: request_id
      }

      send_to(state, primary_node, client_request)
      {:noreply, state}
    else
      cond do
        state.status != :normal ->
          maybe_send_reply({:error, :not_primary}, from, state)
          {:noreply, state}

        not quorum?(state) ->
          maybe_send_reply({:error, :no_quorum}, from, state)
          {:noreply, state}

        # Client deduplication: check if we've seen this request before
        client_id && request_id ->
          case Map.fetch(state.client_table, client_id) do
            :error ->
              # First request from this client - process normally
              process_new_client_request(state, operation, from, client_id, request_id)

            {:ok, client_entry} when request_id > client_entry_request_id(client_entry) ->
              # Newer request from same client - process and update cache
              process_new_client_request(state, operation, from, client_id, request_id)

            {:ok, {:cached, ^request_id, cached_result}} ->
              maybe_send_reply(cached_result, from, state)
              {:noreply, state}

            {:ok, {:cached, cached_request_id, _cached_result}}
            when request_id < cached_request_id ->
              # Older request - drop without reply (client should have already received response)
              {:noreply, state}

            _ ->
              # Request is still processing - duplicate request starves waiting for original to complete
              # TODO: Implement waiter list to support concurrent duplicate requests getting same reply
              {:noreply, state}
          end

        :else ->
          # No client deduplication info - process normally (backwards compatibility)
          process_new_client_request(state, operation, from, client_id, request_id)
      end
    end
  end

  defp maybe_send_reply(what, from, state) do
    if from, do: state.module.send_reply(from, what, state.inner)
  end

  defp process_new_client_request(state, operation, from, client_id, request_id) do
    # Emit telemetry event for client request start
    metadata = %{
      node_id: state.node_id,
      view_number: state.view_number,
      status: state.status,
      is_primary: true,
      operation: inspect(operation),
      client_id: client_id,
      request_id: request_id
    }

    Telemetry.execute([:vsr, :protocol, :client_request, :start], %{count: 1}, metadata)

    # Primary processes the operation (we are always primary in this function)
    new_state =
      state
      |> increment_op_number()
      |> append_to_log(operation, from)

    # Send prepare messages to all replicas
    prepare_msg = %Prepare{
      view: new_state.view_number,
      op_number: new_state.op_number,
      operation: operation,
      commit_number: new_state.commit_number,
      from: from,
      leader_id: new_state.node_id
    }

    # Emit telemetry for prepare broadcast
    Telemetry.execute(
      [:vsr, :protocol, :prepare, :sent],
      %{count: MapSet.size(new_state.replicas)},
      %{
        node_id: new_state.node_id,
        view_number: new_state.view_number,
        op_number: new_state.op_number
      }
    )

    broadcast(new_state, prepare_msg)

    # Store client info for deduplication if provided
    updated_state =
      if client_id && request_id do
        # We'll cache the result when the operation commits
        # For now, just store that we're processing this request
        %{
          new_state
          | client_table: Map.put(new_state.client_table, client_id, {:processing, request_id})
        }
      else
        new_state
      end

    # Check for immediate commit (single node case)
    final_state = maybe_commit_operation(updated_state, updated_state.op_number)
    {:noreply, final_state}
  end

  defp prepare_impl(%Prepare{} = prepare, state) do
    # Emit telemetry for prepare received
    Telemetry.execute(
      [:vsr, :protocol, :prepare, :received],
      %{count: 1},
      %{
        node_id: state.node_id,
        view_number: state.view_number,
        prepare_view: prepare.view,
        op_number: prepare.op_number,
        sender: prepare.leader_id
      }
    )

    state = reset_primary_inactivity_timer(state)
    log_length = get_log_length(state)

    cond do
      prepare.view < state.view_number ->
        Logger.warning(
          "Received prepare with old view #{prepare.view}, current view #{state.view_number}"
        )

        {:noreply, state}

      prepare.view > state.view_number ->
        # Higher view received - adopt the new view and set status to normal
        Logger.info("Adopting higher view #{prepare.view}, previous view #{state.view_number}")

        # Clear old ACK counts when adopting higher view
        cleared_prepare_ok_count = clear_old_view_acks(state.prepare_ok_count, prepare.view)

        updated_state = %{
          state
          | view_number: prepare.view,
            status: :normal,
            prepare_ok_count: cleared_prepare_ok_count,
            view_change_votes: %{}
        }

        # Now process the prepare with the updated view
        prepare_impl(prepare, updated_state)

      prepare.op_number == log_length + 1 ->
        # Sequential operation - append to log
        entry = %LogEntry{
          view: prepare.view,
          op_number: prepare.op_number,
          operation: prepare.operation,
          sender_id: prepare.from
        }

        new_state =
          state
          |> append_log_entry(entry)
          |> Map.replace(:op_number, prepare.op_number)

        send_prepare_ok(new_state, prepare)
        {:noreply, new_state}

      prepare.op_number <= log_length ->
        # Check if existing log entry matches to detect conflicts
        case state.module.log_fetch(state.log, prepare.op_number) do
          {:ok, %LogEntry{view: view, operation: operation}}
          when view == prepare.view and operation == prepare.operation ->
            # Exact match - idempotent ACK
            send_prepare_ok(state, prepare)
            {:noreply, state}

          _ ->
            # Conflict detected - but avoid excessive state transfers
            # Only request state transfer if we're significantly behind
            if prepare.view > state.view_number or prepare.op_number - log_length > 5 do
              Logger.warning(
                "Significant log conflict at op #{prepare.op_number}: requesting state transfer"
              )

              primary_node = prepare.leader_id || primary(state)

              get_state_msg = %GetState{
                # Use leader's view, not our stale view
                view: prepare.view,
                op_number: state.op_number,
                sender: state.node_id
              }

              send_to(state, primary_node, get_state_msg)
              {:noreply, state}
            else
              # Minor conflict - accept the leader's version and continue
              Logger.debug(
                "Minor log conflict at op #{prepare.op_number}: accepting leader's version"
              )

              entry = %LogEntry{
                view: prepare.view,
                op_number: prepare.op_number,
                operation: prepare.operation,
                sender_id: prepare.from
              }

              new_state =
                state
                |> replace_log_entry_at(entry, prepare.op_number)
                |> Map.replace(:op_number, max(state.op_number, prepare.op_number))

              send_prepare_ok(new_state, prepare)
              {:noreply, new_state}
            end
        end

      prepare.op_number > log_length + 1 ->
        # Gap detected - ignore this prepare and let normal commit/catch-up handle it
        # This prevents excessive state transfers during normal operation
        Logger.debug(
          "Gap detected: received op #{prepare.op_number}, expected #{log_length + 1}, ignoring"
        )

        {:noreply, state}
    end
  end

  defp prepare_ok_impl(%PrepareOk{} = prepare_ok, state) do
    # Emit telemetry for prepare_ok received
    Telemetry.execute(
      [:vsr, :protocol, :prepare_ok, :received],
      %{count: 1},
      %{
        node_id: state.node_id,
        view_number: state.view_number,
        op_number: prepare_ok.op_number,
        from: prepare_ok.replica
      }
    )

    if primary?(state) and prepare_ok.view == state.view_number do
      new_state = increment_ok_count(state, prepare_ok.op_number)
      final_state = maybe_commit_operation(new_state, prepare_ok.op_number)
      {:noreply, final_state}
    else
      {:noreply, state}
    end
  end

  defp commit_impl(%Commit{} = commit, state) do
    # Emit telemetry for commit received
    Telemetry.execute(
      [:vsr, :protocol, :commit, :received],
      %{count: 1},
      %{
        node_id: state.node_id,
        view_number: state.view_number,
        commit_number: commit.commit_number
      }
    )

    state = reset_primary_inactivity_timer(state)

    if commit.view == state.view_number and commit.commit_number > state.commit_number do
      new_state = apply_committed_operations(state, commit.commit_number)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  defp get_state_impl(%GetState{} = get_state, state) do
    # Emit telemetry for state transfer request received
    Telemetry.execute(
      [:vsr, :state_transfer, :request_received],
      %{count: 1},
      %{
        node_id: state.node_id,
        view_number: state.view_number,
        from: get_state.sender
      }
    )

    # Optimize state transfer by only sending what the requester actually needs
    # If they specify a starting op_number, send from there; otherwise send everything
    log_entries =
      case Map.get(get_state, :from_op_number) do
        nil ->
          # Legacy behavior - send everything (for compatibility)
          get_all_log_entries(state)

        from_op when is_integer(from_op) and from_op > 0 ->
          # Send only entries from the requested point onwards
          log_get_from(state, from_op)

        _ ->
          # Invalid from_op_number - send everything as fallback
          get_all_log_entries(state)
      end

    new_state_msg = %NewState{
      view: state.view_number,
      log: log_entries,
      op_number: state.op_number,
      commit_number: state.commit_number,
      state_machine_state: get_inner_state(state),
      leader_id: state.node_id
    }

    # Emit telemetry for snapshot sent
    Telemetry.execute(
      [:vsr, :state_transfer, :snapshot_sent],
      %{count: 1, entries_count: length(log_entries)},
      %{
        node_id: state.node_id,
        view_number: state.view_number,
        to: get_state.sender
      }
    )

    send_to(state, get_state.sender, new_state_msg)
    {:noreply, state}
  end

  defp new_state_impl(%NewState{} = new_state, state) do
    # Emit telemetry for snapshot received
    Telemetry.execute(
      [:vsr, :state_transfer, :snapshot_received],
      %{count: 1, entries_count: length(new_state.log)},
      %{
        node_id: state.node_id,
        view_number: state.view_number,
        from: new_state.leader_id
      }
    )

    # Only accept NewState from the legitimate leader for this view
    expected_leader = primary_for_view(new_state.view, state)

    if new_state.view >= state.view_number and new_state.leader_id == expected_leader do
      updated_state = %{
        state
        | view_number: new_state.view,
          op_number: new_state.op_number,
          commit_number: new_state.commit_number
      }

      # Replace log with entries from new_state
      final_state = replace_log(updated_state, new_state.log)

      # Update inner state
      final_state = set_inner_state(final_state, new_state.state_machine_state)

      # Apply committed operations for consistency (usually no-op since state is already applied)
      final_state = apply_committed_operations(final_state, final_state.commit_number)

      # Clear per-view counters after state transfer
      final_state = %{
        final_state
        | prepare_ok_count:
            clear_old_view_acks(final_state.prepare_ok_count, final_state.view_number),
          view_change_votes: %{}
      }

      {:noreply, final_state}
    else
      {:noreply, state}
    end
  end

  defp heartbeat_impl(heartbeat, state) do
    # Emit telemetry for heartbeat received
    Telemetry.execute(
      [:vsr, :timer, :heartbeat_received],
      %{count: 1},
      %{
        node_id: state.node_id,
        view_number: state.view_number,
        heartbeat_view: heartbeat.view,
        from: heartbeat.leader_id
      }
    )

    # Only reset primary inactivity timer if heartbeat is from current view and correct leader
    if heartbeat.view == state.view_number and heartbeat.leader_id == primary(state) do
      new_state = reset_primary_inactivity_timer(state)
      {:noreply, new_state}
    else
      Logger.debug(
        "Ignoring heartbeat from view #{heartbeat.view} leader #{heartbeat.leader_id}, " <>
          "current view #{state.view_number} leader #{primary(state)}"
      )

      {:noreply, state}
    end
  end

  # View change implementations
  defp start_view_change_impl(%StartViewChange{} = start_view_change, state) do
    if start_view_change.view > state.view_number do
      # Emit telemetry for view change start
      Telemetry.execute(
        [:vsr, :view_change, :start],
        %{count: 1},
        %{
          node_id: state.node_id,
          old_view: state.view_number,
          new_view: start_view_change.view,
          old_status: state.status
        }
      )

      # Transition to view change status and clear old ACK counts
      cleared_prepare_ok_count =
        clear_old_view_acks(state.prepare_ok_count, start_view_change.view)

      new_state = %{
        state
        | status: :view_change,
          view_number: start_view_change.view,
          last_normal_view: state.view_number,
          prepare_ok_count: cleared_prepare_ok_count
      }

      # Emit telemetry for status change
      Telemetry.execute(
        [:vsr, :state, :status_change],
        %{count: 1},
        %{
          node_id: state.node_id,
          old_status: state.status,
          new_status: :view_change,
          view_number: start_view_change.view
        }
      )

      # Broadcast START-VIEW-CHANGE-ACK to ALL replicas
      ack_msg = %StartViewChangeAck{
        view: start_view_change.view,
        replica: state.node_id
      }

      broadcast(new_state, ack_msg)
      # Also send to self
      send(self(), {:"$vsr", ack_msg})

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  defp start_view_change_ack_impl(%StartViewChangeAck{} = ack, state) do
    if ack.view == state.view_number and state.status == :view_change do
      # Count view change votes, ensuring no duplicates
      existing_votes = Map.get(state.view_change_votes, ack.view, [])

      # Only add if not already in the list
      updated_votes =
        if ack.replica in existing_votes do
          existing_votes
        else
          [ack.replica | existing_votes]
        end

      votes = Map.put(state.view_change_votes, ack.view, updated_votes)
      new_state = %{state | view_change_votes: votes}

      # Check if we have enough votes to proceed from cluster
      vote_count = length(updated_votes)

      # Emit telemetry for vote received
      Telemetry.execute(
        [:vsr, :view_change, :vote_received],
        %{vote_count: vote_count, required: div(state.cluster_size, 2) + 1},
        %{
          node_id: state.node_id,
          view_number: ack.view,
          from: ack.replica
        }
      )

      # Only send DO-VIEW-CHANGE once when we first reach majority
      if vote_count > div(state.cluster_size, 2) and
           length(existing_votes) <= div(state.cluster_size, 2) do
        # Just reached enough votes, send DO-VIEW-CHANGE to new primary
        new_primary = primary_for_view(ack.view, state)

        do_view_change_msg = %DoViewChange{
          view: ack.view,
          log: get_all_log_entries(state),
          last_normal_view: state.last_normal_view,
          op_number: state.op_number,
          commit_number: state.commit_number,
          from: state.node_id
        }

        # Emit telemetry for do_view_change sent
        Telemetry.execute(
          [:vsr, :view_change, :do_view_change, :sent],
          %{count: 1},
          %{
            node_id: state.node_id,
            view_number: ack.view,
            to: new_primary
          }
        )

        send_to(state, new_primary, do_view_change_msg)

        {:noreply, new_state}
      else
        {:noreply, new_state}
      end
    else
      {:noreply, state}
    end
  end

  defp do_view_change_impl(%DoViewChange{} = do_view_change, state) do
    # Emit telemetry for do_view_change received
    Telemetry.execute(
      [:vsr, :view_change, :do_view_change, :received],
      %{count: 1},
      %{
        node_id: state.node_id,
        view_number: state.view_number,
        from: do_view_change.from
      }
    )

    # Check if this node is the primary for the view in the DoViewChange message
    is_primary_for_view = state.node_id == primary_for_view(do_view_change.view, state)

    if is_primary_for_view and do_view_change.view == state.view_number and
         state.status == :view_change do
      # Collect DO-VIEW-CHANGE messages - we need majority before proceeding
      do_view_change_key = "do_view_change_#{do_view_change.view}"
      existing_messages = Map.get(state.view_change_votes, do_view_change_key, [])

      # Add this message if not already received from this replica
      # Store the complete message, not just the sender ID
      updated_messages =
        if Enum.any?(existing_messages, fn msg -> msg.from == do_view_change.from end) do
          existing_messages
        else
          [do_view_change | existing_messages]
        end

      new_votes = Map.put(state.view_change_votes, do_view_change_key, updated_messages)
      new_state = %{state | view_change_votes: new_votes}

      # Check if we have majority of DO-VIEW-CHANGE messages
      # Use cluster_size for quorum calculation, not connected replicas
      cluster_size = state.cluster_size

      # Include self in quorum calculation: 1 (self) + received messages > N/2
      if 1 + length(updated_messages) > div(cluster_size, 2) do
        # VSR log selection: find the message with highest (last_normal_view, op_number)
        # Include primary's own state as a candidate
        primary_candidate = %{
          last_normal_view: state.last_normal_view,
          op_number: state.op_number,
          commit_number: state.commit_number,
          log: get_all_log_entries(state)
        }

        # Find the best candidate from all DO-VIEW-CHANGE messages
        best_candidate =
          updated_messages
          |> Enum.map(fn msg ->
            %{
              last_normal_view: msg.last_normal_view,
              op_number: msg.op_number,
              commit_number: msg.commit_number,
              log: msg.log
            }
          end)
          |> then(fn candidates -> [primary_candidate | candidates] end)
          |> Enum.max_by(fn candidate ->
            {candidate.last_normal_view, candidate.op_number}
          end)

        # Use the maximum commit_number across all candidates
        max_commit_number =
          updated_messages
          |> Enum.map(& &1.commit_number)
          |> then(fn commits -> [state.commit_number | commits] end)
          |> Enum.max()

        # Clear old ACK counts for the new view
        cleared_prepare_ok_count =
          clear_old_view_acks(new_state.prepare_ok_count, state.view_number)

        merged_state = %{
          new_state
          | op_number: best_candidate.op_number,
            commit_number: max_commit_number,
            # Primary transitions to normal
            status: :normal,
            prepare_ok_count: cleared_prepare_ok_count
        }

        # Replace log with merged entries
        updated_state = replace_log(merged_state, best_candidate.log)

        # Apply any newly committed operations after view change
        final_state = apply_committed_operations(updated_state, updated_state.commit_number)

        # Send START-VIEW to all replicas
        start_view_msg = %StartView{
          view: state.view_number,
          log: get_all_log_entries(final_state),
          op_number: final_state.op_number,
          commit_number: final_state.commit_number
        }

        broadcast(final_state, start_view_msg)

        # Start heartbeat timer since this node is now the primary
        timer_updated_state = start_heartbeat_timer(final_state)

        {:noreply, timer_updated_state}
      else
        {:noreply, new_state}
      end
    else
      {:noreply, state}
    end
  end

  defp start_view_impl(%StartView{} = start_view, state) do
    if start_view.view >= state.view_number do
      # Emit telemetry for view change complete
      Telemetry.execute(
        [:vsr, :view_change, :complete],
        %{count: 1},
        %{
          node_id: state.node_id,
          old_view: state.view_number,
          new_view: start_view.view,
          old_status: state.status
        }
      )

      # Update state with new view information and clear old ACK counts
      cleared_prepare_ok_count = clear_old_view_acks(state.prepare_ok_count, start_view.view)

      new_state = %{
        state
        | view_number: start_view.view,
          status: :normal,
          op_number: start_view.op_number,
          commit_number: start_view.commit_number,
          view_change_votes: %{},
          prepare_ok_count: cleared_prepare_ok_count
      }

      # Emit telemetry for view number change
      Telemetry.execute(
        [:vsr, :state, :view_change],
        %{count: 1},
        %{
          node_id: state.node_id,
          old_view: state.view_number,
          new_view: start_view.view
        }
      )

      # Emit telemetry for status change
      Telemetry.execute(
        [:vsr, :state, :status_change],
        %{count: 1},
        %{
          node_id: state.node_id,
          old_status: state.status,
          new_status: :normal,
          view_number: start_view.view
        }
      )

      # Replace log with start_view log
      updated_state = replace_log(new_state, start_view.log)

      # Apply any newly committed operations after view change
      final_state = apply_committed_operations(updated_state, start_view.commit_number)

      # ViewChangeOk message removed - not part of standard VSR protocol

      # Reset primary inactivity timer since this node is now a follower
      timer_updated_state = reset_primary_inactivity_timer(final_state)

      {:noreply, timer_updated_state}
    else
      {:noreply, state}
    end
  end

  defp start_manual_view_change(state) do
    # Increment view and transition to view change status
    new_view = state.view_number + 1

    # Update state immediately to new view
    new_state = %{
      state
      | view_number: new_view,
        status: :view_change,
        last_normal_view: state.view_number
    }

    # Create and broadcast START-VIEW-CHANGE message
    start_view_change_msg = %StartViewChange{
      view: new_view,
      replica: state.node_id
    }

    # Send to all replicas
    broadcast(new_state, start_view_change_msg)

    # Also send to self to process it
    send(self(), {:"$vsr", start_view_change_msg})

    {:noreply, new_state}
  end

  defp primary_for_view(view_number, state) do
    all_replicas = [state.node_id | MapSet.to_list(state.replicas)]
    # Use :erlang.term_to_binary for stable, deterministic ordering across all nodes
    sorted_replicas = Enum.sort_by(all_replicas, &:erlang.term_to_binary/1)
    replica_count = length(sorted_replicas)

    if replica_count > 0 do
      Enum.at(sorted_replicas, rem(view_number, replica_count))
    else
      state.node_id
    end
  end

  # Helper functions

  defp clear_old_view_acks(prepare_ok_count, current_view) do
    # Remove ACK counts from views older than current_view
    prepare_ok_count
    |> Enum.reject(fn {{view, _op_num}, _count} -> view < current_view end)
    |> Map.new()
  end

  defp primary?(state) do
    state.node_id == primary(state)
  end

  defp primary(%{status: :uninitialized}) do
    nil
  end

  defp primary(state) do
    primary_for_view(state.view_number, state)
  end

  defp quorum?(state) do
    # Count currently connected replicas (including self)
    # +1 for self
    connected_count = MapSet.size(state.replicas) + 1
    # Check if connected nodes form a majority of the total cluster
    connected_count > div(state.cluster_size, 2)
  end

  defp increment_op_number(state) do
    %{state | op_number: state.op_number + 1}
  end

  defp increment_ok_count(state, op_number) do
    # Key by {view, op_number} to prevent cross-view contamination
    key = {state.view_number, op_number}
    count = Map.get(state.prepare_ok_count, key, 0) + 1
    %{state | prepare_ok_count: Map.put(state.prepare_ok_count, key, count)}
  end

  defp maybe_commit_operation(state, op_number) do
    # Use {view, op_number} key for ACK counting
    key = {state.view_number, op_number}
    current_count = Map.get(state.prepare_ok_count, key, 0)

    # Note: removed quorum?(state) check - it was always true
    # Use cluster_size for consistent quorum calculation
    if current_count > div(state.cluster_size, 2) do
      # Emit telemetry for quorum reached
      Telemetry.execute(
        [:vsr, :replication, :quorum_reached],
        %{count: 1, ack_count: current_count, required: div(state.cluster_size, 2) + 1},
        %{
          node_id: state.node_id,
          view_number: state.view_number,
          op_number: op_number
        }
      )

      # Commit advancement: Safe to advance commit_number directly to op_number
      # since VSR's "append only at log_length + 1" rule ensures same majority
      # has accepted all operations ≤ op_number due to sequential ordering
      new_commit_number = max(state.commit_number, op_number)

      # Apply operations and send replies
      new_state = apply_committed_operations(state, new_commit_number)

      # Send commit messages
      commit_msg = %Commit{
        view: state.view_number,
        commit_number: new_commit_number
      }

      # Emit telemetry for commit sent
      Telemetry.execute(
        [:vsr, :protocol, :commit, :sent],
        %{count: MapSet.size(state.replicas)},
        %{
          node_id: state.node_id,
          view_number: state.view_number,
          commit_number: new_commit_number
        }
      )

      broadcast(new_state, commit_msg)

      # Clean up prepare_ok_count - remove committed operations
      cleaned_count =
        state.prepare_ok_count
        |> Enum.reject(fn {{_view, op_num}, _} -> op_num <= new_commit_number end)
        |> Map.new()

      %{new_state | prepare_ok_count: cleaned_count}
    else
      state
    end
  end

  defp apply_committed_operations(state, new_commit_number) do
    if new_commit_number > state.commit_number do
      old_commit_number = state.commit_number
      log_entries = get_log_entries_range(state, state.commit_number + 1, new_commit_number)

      {new_inner, operation_results} =
        Enum.reduce(log_entries, {state.inner, []}, fn entry, {inner_acc, results_acc} ->
          # Execute operation with telemetry span
          {new_inner, result} =
            :telemetry.span(
              [:vsr, :state_machine, :operation],
              %{
                node_id: state.node_id,
                view_number: state.view_number,
                op_number: entry.op_number,
                operation: inspect(entry.operation)
              },
              fn ->
                {new_inner, result} = state.module.handle_commit(entry.operation, inner_acc)
                {{new_inner, result}, %{}}
              end
            )

          {new_inner, [{entry.op_number, result, entry.sender_id} | results_acc]}
        end)

      # Emit telemetry for commit number advancement
      Telemetry.execute(
        [:vsr, :state, :commit_advance],
        %{
          old_commit_number: old_commit_number,
          new_commit_number: new_commit_number,
          operations_committed: new_commit_number - old_commit_number
        },
        %{
          node_id: state.node_id,
          view_number: state.view_number
        }
      )

      # Update client_table with results for deduplication
      updated_client_table =
        if primary?(state) do
          Enum.reduce(operation_results, state.client_table, fn {_op_num, result, sender_id},
                                                                client_table_acc ->
            # Extract client_id and request_id from sender_id if it's a map with deduplication info
            case sender_id do
              %{client_id: client_id, request_id: request_id}
              when not is_nil(client_id) and not is_nil(request_id) ->
                Map.put(client_table_acc, client_id, {:cached, request_id, result})

              _ ->
                client_table_acc
            end
          end)
        else
          state.client_table
        end

      # Send client replies for committed operations (only primary does this)
      if primary?(state) do
        Enum.each(operation_results, fn {_op_num, result, sender_id} ->
          if sender_id do
            state.module.send_reply(sender_id, result, state.inner)
          end
        end)
      end

      %{
        state
        | commit_number: new_commit_number,
          inner: new_inner,
          client_table: updated_client_table
      }
    else
      state
    end
  end

  defp send_prepare_ok(state, prepare) do
    # Reply to the leader_id from the Prepare message, not computed primary
    leader_node = prepare.leader_id || primary(state)

    prepare_ok = %PrepareOk{
      view: prepare.view,
      op_number: prepare.op_number,
      replica: state.node_id
    }

    # Emit telemetry for prepare_ok sent
    Telemetry.execute(
      [:vsr, :protocol, :prepare_ok, :sent],
      %{count: 1},
      %{
        node_id: state.node_id,
        view_number: prepare.view,
        op_number: prepare.op_number,
        to: leader_node
      }
    )

    send_to(state, leader_node, prepare_ok)
  end

  defp broadcast(%{status: :uninitialized}, _message) do
    # No-op when uninitialized
  end

  defp broadcast(state, message) do
    Enum.each(state.replicas, fn replica ->
      send_to(state, replica, message)
    end)
  end

  defp send_to(state, node_id, message) do
    state.module.send_vsr(node_id, message, state.inner)
  end

  # Log operations
  defp append_to_log(state, operation, from) do
    entry = %LogEntry{
      view: state.view_number,
      op_number: state.op_number,
      operation: operation,
      sender_id: from
    }

    append_log_entry(state, entry)
  end

  defp append_log_entry(state, entry) do
    new_log = log_append(state, entry)

    # Emit telemetry for log append
    Telemetry.execute(
      [:vsr, :replication, :log_append],
      %{count: 1, log_length: get_log_length(%{state | log: new_log})},
      %{
        node_id: state.node_id,
        view_number: entry.view,
        op_number: entry.op_number
      }
    )

    # Initialize ACK count for this {view, op_number}
    key = {state.view_number, entry.op_number}
    new_prepare_ok_count = Map.put(state.prepare_ok_count, key, 1)
    %{state | log: new_log, prepare_ok_count: new_prepare_ok_count}
  end

  defp get_log_length(state) do
    log_length(state)
  end

  defp get_all_log_entries(state) do
    log_get_all(state)
  end

  defp get_log_entries_range(state, start_op, end_op) do
    get_all_log_entries(state)
    |> Enum.filter(fn entry ->
      entry.op_number >= start_op and entry.op_number <= end_op
    end)
    |> Enum.sort_by(& &1.op_number)
  end

  defp replace_log(state, entries) do
    new_log = log_replace(state, entries)
    %{state | log: new_log}
  end

  defp replace_log_entry_at(state, entry, op_number) do
    # Replace the entry at a specific position
    current_entries = get_all_log_entries(state)

    updated_entries =
      current_entries
      |> Enum.map(fn existing_entry ->
        if existing_entry.op_number == op_number do
          entry
        else
          existing_entry
        end
      end)

    replace_log(state, updated_entries)
  end

  # Inner state management
  defp get_inner_state(state) do
    if function_exported?(state.module, :get_state, 1) do
      state.module.get_state(state.inner)
    else
      state.inner
    end
  end

  defp set_inner_state(state, new_inner_state) do
    if function_exported?(state.module, :set_state, 2) do
      new_inner = state.module.set_state(state.inner, new_inner_state)
      %{state | inner: new_inner}
    else
      %{state | inner: new_inner_state}
    end
  end

  # Timer management
  defp start_timers(state) do
    heartbeat_ref =
      if primary?(state) do
        Process.send_after(self(), :"$vsr_heartbeat_tick", state.heartbeat_interval)
      else
        nil
      end

    inactivity_ref =
      if not primary?(state) do
        Process.send_after(
          self(),
          :"$vsr_primary_inactivity_timeout",
          state.primary_inactivity_timeout
        )
      else
        nil
      end

    %{state | heartbeat_timer_ref: heartbeat_ref, primary_inactivity_timer_ref: inactivity_ref}
  end

  defp reset_primary_inactivity_timer(state) do
    if state.primary_inactivity_timer_ref do
      Process.cancel_timer(state.primary_inactivity_timer_ref)
    end

    new_ref =
      if not primary?(state) do
        Process.send_after(
          self(),
          :"$vsr_primary_inactivity_timeout",
          state.primary_inactivity_timeout
        )
      else
        nil
      end

    %{state | primary_inactivity_timer_ref: new_ref}
  end

  defp start_heartbeat_timer(state) do
    if state.heartbeat_timer_ref do
      Process.cancel_timer(state.heartbeat_timer_ref)
    end

    new_ref =
      if primary?(state) do
        Process.send_after(self(), :"$vsr_heartbeat_tick", state.heartbeat_interval)
      else
        nil
      end

    %{state | heartbeat_timer_ref: new_ref}
  end

  # Log callback adapters
  defp log_append(state, entry), do: state.module.log_append(state.log, entry)
  defp log_length(state), do: state.module.log_length(state.log)
  defp log_get_all(state), do: state.module.log_get_all(state.log)
  defp log_get_from(state, op_number), do: state.module.log_get_from(state.log, op_number)
  defp log_replace(state, entries), do: state.module.log_replace(state.log, entries)

  # ROUTER

  # Privileged VSR handlers
  @impl true
  def handle_call(:"$vsr_dump", _from, state) do
    dump_impl(state)
  end

  def handle_call(:"$vsr_node_id", _from, state) do
    node_id_impl(state)
  end

  def handle_call(message, from, state) do
    message
    |> state.module.handle_call(from, state.inner)
    |> wrap_reply(state)
    |> wrap_noreply(state)
  end

  @impl true
  def handle_cast({:"$vsr_set_cluster", node_id, replicas, cluster_size}, state),
    do: set_cluster_impl(node_id, replicas, cluster_size, state)

  def handle_cast({:"$vsr_set_log", log}, state), do: set_log_impl(log, state)

  def handle_cast(other, state) do
    other
    |> state.module.handle_cast(state.inner)
    |> wrap_noreply(state)
  end

  @impl true
  def handle_info({:"$vsr", _}, %{status: :uninitialized}),
    do: raise("vsr message received while uninitialized")

  def handle_info({:"$vsr", vsr_message}, state) do
    case vsr_message do
      %ClientRequest{} -> client_request_impl(vsr_message, state)
      %Prepare{} -> prepare_impl(vsr_message, state)
      %PrepareOk{} -> prepare_ok_impl(vsr_message, state)
      %Commit{} -> commit_impl(vsr_message, state)
      %StartViewChange{} -> start_view_change_impl(vsr_message, state)
      %StartViewChangeAck{} -> start_view_change_ack_impl(vsr_message, state)
      %DoViewChange{} -> do_view_change_impl(vsr_message, state)
      %StartView{} -> start_view_impl(vsr_message, state)
      %GetState{} -> get_state_impl(vsr_message, state)
      %NewState{} -> new_state_impl(vsr_message, state)
      %Heartbeat{} -> heartbeat_impl(vsr_message, state)
    end
  end

  def handle_info(:"$vsr_heartbeat_tick", state) do
    if primary?(state) do
      heartbeat_msg = %Heartbeat{
        view: state.view_number,
        leader_id: state.node_id
      }

      # Emit telemetry for heartbeat sent
      Telemetry.execute(
        [:vsr, :timer, :heartbeat_sent],
        %{count: MapSet.size(state.replicas)},
        %{
          node_id: state.node_id,
          view_number: state.view_number
        }
      )

      broadcast(state, heartbeat_msg)
      new_state = start_heartbeat_timer(state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info(:"$vsr_primary_inactivity_timeout", state) do
    if not primary?(state) and state.status == :normal do
      # Emit telemetry for primary timeout
      Telemetry.execute(
        [:vsr, :timer, :primary_timeout],
        %{count: 1},
        %{
          node_id: state.node_id,
          view_number: state.view_number
        }
      )

      start_manual_view_change(state)
    else
      {:noreply, state}
    end
  end

  def handle_info(other, state) do
    other
    |> state.module.handle_info(state.inner)
    |> wrap_noreply(state)
  end

  @impl true
  def handle_continue(continue, state) do
    continue
    |> state.module.handle_continue(state.inner)
    |> wrap_noreply(state)
  end

  @impl GenServer
  def terminate(reason, state) do
    state.module.terminate(reason, state.inner)
  end

  @impl true
  def code_change(old_vsn, state, extra) do
    case state.module.code_change(old_vsn, state.inner, extra) do
      {:ok, new_inner} -> {:ok, %{state | inner: new_inner}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Helpers

  defp wrap_reply({:reply, reply, inner}, state), do: {:reply, reply, %{state | inner: inner}}

  defp wrap_reply({:reply, reply, inner, {:client_request, operation}}, state) do
    case client_request_impl(operation, nil, %{state | inner: inner}) do
      {:noreply, new_state} ->
        {:reply, reply, new_state}
    end
  end

  defp wrap_reply({:reply, reply, inner, extra}, state) do
    {:reply, reply, %{state | inner: inner}, extra}
  end

  defp wrap_reply({:stop, reason, reply, inner}, state),
    do: {:stop, reason, reply, %{state | inner: inner}}

  defp wrap_reply(noreply, _state), do: noreply

  defp wrap_noreply({:noreply, inner}, state), do: {:noreply, %{state | inner: inner}}

  defp wrap_noreply({:noreply, inner, {:client_request, from, operation}}, state),
    do: client_request_impl(operation, from, %{state | inner: inner})

  defp wrap_noreply({:noreply, inner, {:client_request, operation}}, state),
    do: client_request_impl(operation, nil, %{state | inner: inner})

  defp wrap_noreply({:noreply, inner, extra}, state),
    do: {:noreply, %{state | inner: inner}, extra}

  defp wrap_noreply({:stop, reason, inner}, state), do: {:stop, reason, %{state | inner: inner}}
  defp wrap_noreply(reply, _state), do: reply

  @log_callbacks [
    log_append: 2,
    log_fetch: 2,
    log_get_all: 1,
    log_get_from: 2,
    log_length: 1,
    log_replace: 2,
    log_clear: 1
  ]

  @vsr_callbacks [
    get_state: 1,
    set_state: 2
  ]

  @required_callbacks @log_callbacks ++ @vsr_callbacks

  defp verify_required_callbacks!(module) do
    for {func, arity} <- @required_callbacks, not function_exported?(module, func, arity) do
      raise ArgumentError, "Module #{module} must implement #{func}/#{arity} callback"
    end
  end
end
