defmodule Vsr do
  use GenServer
  require Logger
  alias Vsr.Log
  alias Vsr.Log.Entry
  alias Vsr.Message
  alias Vsr.Message.ClientRequest
  alias Vsr.Message.Prepare
  alias Vsr.Message.PrepareOk
  alias Vsr.StateMachine

  # Section 0: State
  defstruct [
    :log,
    :status,
    :view_number,
    :op_number,
    :commit_number,
    :cluster_size,
    :replicas,
    :state_machine,
    :prepare_ok_count,
    :view_change_votes,
    :last_normal_view,
    primary_inactivity_timeout: 5000,
    view_change_timeout: 10_000,
    heartbeat_interval: 1000
  ]

  @type state :: %__MODULE__{
          log: Log.t(),
          status: :normal | :view_change,
          view_number: non_neg_integer(),
          op_number: non_neg_integer(),
          commit_number: non_neg_integer(),
          replicas: MapSet.t(pid()),
          state_machine: StateMachine.t(),
          prepare_ok_count: %{non_neg_integer() => non_neg_integer()},
          view_change_votes: map(),
          last_normal_view: non_neg_integer(),
          primary_inactivity_timeout: non_neg_integer(),
          view_change_timeout: non_neg_integer(),
          heartbeat_interval: non_neg_integer()
        }

  # Section 1: Initialization
  def start_link(opts) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    server_opts = Keyword.take(opts, ~w[name]a)
    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  def init(opts) do
    log = Keyword.fetch!(opts, :log)

    state = %__MODULE__{
      view_number: 0,
      status: :normal,
      op_number: 0,
      commit_number: 0,
      log: log,
      replicas: MapSet.new(),
      state_machine: Keyword.fetch!(opts, :state_machine),
      cluster_size: Keyword.fetch!(opts, :cluster_size),
      prepare_ok_count: %{},
      view_change_votes: %{},
      last_normal_view: 0
    }

    {:ok, state}
  end

  # Section 2: API
  @spec connect(pid(), pid()) :: :ok | {:error, term()}
  @spec client_request(pid(), term()) :: :ok
  @spec start_view_change(pid()) :: :ok
  @spec get_state(pid()) :: term()

  # debug api
  @spec dump(pid()) :: %__MODULE__{}

  # Section 2: API Impls
  def connect(pid, to_pid), do: GenServer.call(pid, {:connect, to_pid})

  defp connect_impl({target_replica_pid}, _from, state) do
    # Monitor the target replica
    ref = Process.monitor(target_replica_pid)

    # Add to connected replicas with monitoring reference
    new_connected_replicas = MapSet.put(state.connected_replicas, {target_replica_pid, ref})

    new_state = %{state | connected_replicas: new_connected_replicas}

    {:reply, :ok, new_state}
  end

  def client_request(pid, operation) do
    case GenServer.call(pid, {:client_request, operation}) do
      {:ok, reply} ->
        reply

      {:error, reason} ->
        raise "Client request failed: #{inspect(reason)}"
    end
  end

  defp client_request_impl(operation, from, state) do
    has_quorum = quorum?(state)
    requires_linearized = StateMachine.require_linearized?(state.state_machine, operation)
    read_only = StateMachine.read_only?(state.state_machine, operation)

    cond do
      requires_linearized and has_quorum ->
        # do the linearized operation.
        client_request_linearized(read_only, operation, from, state)

      read_only or not requires_linearized ->
        # do the read-only operation without the quorum.
        {_, reply} = StateMachine.apply_operation(state.state_machine, operation)
        {:reply, {:ok, reply}, state}

      :else ->
        # TODO: convert this into a proper quorum exception.
        {:reply, {:error, :quorum}, state}
    end
  end

  defp client_request_linearized(read_only, operation, from, state) do
    primary = primary?(state)

    cond do
      state.status != :normal ->
        # TODO: convert this into a better quorum exception
        {:reply, {:error, :not_normal}, state}

      primary ->
        client_request_impl(
          %ClientRequest{operation: operation, from: from, read_only: read_only},
          state
        )

      :else ->
        # send the client request to the primary
        state
        |> primary
        |> Message.vsr_send(%ClientRequest{
          operation: operation,
          from: from,
          read_only: read_only
        })
    end
  end

  # client request.  Received by the primary replica.
  defp client_request_impl(%{operation: operation, from: from, read_only: true}, state) do
    # If read-only, we can reply immediately
    {_, reply} = StateMachine.apply_operation(state.state_machine, operation)
    GenServer.reply(from, {:ok, reply})
    {:noreply, state}
  end

  defp client_request_impl(%{operation: operation, from: from}, state) do
    # not read-only case, so operation must be prepared and sent to replicas.
    # Append the operation to the log
    new_state =
      state
      |> increment_op_number()
      |> append_new_log(from, operation)
      |> tap(fn state ->
        # Craft and send prepare message to all replicas 
        prepare_msg = prepare_msg(state, from, operation)
        Enum.each(state.replicas, &Message.vsr_send(&1, prepare_msg))
      end)

    {:noreply, new_state}
  end

  defp prepare_msg(state, from, operation) do
    # Create the prepare message
    %Prepare{
      view: state.view_number,
      op_number: state.op_number,
      operation: operation,
      commit_number: state.commit_number,
      from: from
    }
  end

  defp append_new_log(state, from, operation) do
    entry = %Entry{
      view: state.view_number,
      op_number: state.op_number,
      operation: operation,
      sender_id: from
    }

    state
    |> Map.update!(:log, &Log.append(&1, entry))
    |> Map.update!(:prepare_ok_count, &Map.put(&1, state.op_number, 1))
  end

  # prepare message.  Received by non-primary replicas.
  defp prepare_impl(prepare, state) do
    # - Validates `view >= view_number`
    # - If `op_number > length(log)`: append operation to `log`
    # - Update `op_number = max(op_number, received_op_number)`
    # - Send `PREPARE-OK(view, op-num, replica-id)` to primary

    with {:view, view} when view >= state.view_number <- {:view, prepare.view},
         log_length = Log.length(state.log),
         {:op, op} when op > log_length <- {:op, prepare.op_number} do
      entry = %Entry{
        view: view,
        op_number: op,
        operation: prepare.operation,
        sender_id: prepare.from
      }

      new_state =
        state
        |> Map.update!(:log, &Log.append(&1, entry))
        |> Map.replace(:op_number, prepare.op_number)
        |> send_prepare_ok(prepare)

      {:noreply, new_state}
    else
      {:op, _} ->
        # do nothing, we already have the operation but respond with ok.
        send_prepare_ok(state, prepare)
        {:noreply, state}

      {:view, _} ->
        # TODO: check to make sure that doing nothing is valid.
        # do we have to trigger an election?
        raise "unimplemented"
        {:noreply, state}
    end
  end

  defp send_prepare_ok(prepare, state) do
    state
    |> primary()
    |> Message.vsr_send(%PrepareOk{
      view: prepare.view,
      op_number: prepare.op_number,
      from: self()
    })
  end

  defp prepare_ok_impl(prepare_ok, state) do
    if primary?(state) and prepare_ok.view == state.view_number do
      state
      |> increment_ok_count(prepare_ok.op_number)
    else
      {:noreply, state}
    end
  end

  defp increment_ok_count(%{prepare_ok_count: ok_count} = state, op_number) do
    count = ok_count[op_number] + 1
    %{state | prepare_ok_count: Map.replace(ok_count, op_number, count)}
  end


    # if msg.view == state.view_number and self() == state.primary do
    #  current_count = Map.get(state.prepare_ok_count, msg.op_number, 0) + 1
    #  new_prepare_ok_count = Map.put(state.prepare_ok_count, msg.op_number, current_count)
    #
    #  # +1 for self
    #  connected_count = MapSet.size(state.connected_replicas) + 1
    #
    #  # Check if we have majority
    #  if current_count > div(connected_count, 2) do
    #    # Majority received, commit operation and send commit messages
    #    new_commit_number = max(state.commit_number, msg.op_number)
    #
    #    # Apply all operations up to commit point and send client replies
    #    log_entries = Log.get_all(state.log)
    #
    #    {new_state_machine, _} =
    #      apply_operations_and_send_replies(
    #        log_entries,
    #        state.state_machine,
    #        state.commit_number,
    #        new_commit_number,
    #        state.client_table
    #      )
    #
    #    # Send commit messages to connected replicas
    #    commit_message = %Messages.Commit{
    #      view: msg.view,
    #      commit_number: new_commit_number
    #    }
    #
    #    for {replica_pid, _ref} <- state.connected_replicas do
    #      Messages.vsr_send(replica_pid, commit_message)
    #    end
    #
    #    {:noreply,
    #     %{
    #       state
    #       | commit_number: new_commit_number,
    #         prepare_ok_count: new_prepare_ok_count,
    #         state_machine: new_state_machine
    #     }}
    #  else
    #    {:noreply, %{state | prepare_ok_count: new_prepare_ok_count}}
    #  end
    # else
    #  {:noreply, state}
    # end

  def start_view_change(pid), do: GenServer.cast(pid, :start_view_change)

  def get_state(pid), do: GenServer.call(pid, :get_state)

  # Debug impls

  def dump(pid), do: GenServer.call(pid, :dump)

  defp dump_impl(_from, state) do
    # Convert log back to list for backward compatibility with tests
    log_list = Log.get_all(state.log)
    compat_state = %{state | log: log_list}
    {:reply, compat_state, state}
  end

  defp disconnect_impl(_ref, pid, state) do
    # TODO: Abstract leader loss and/or quorum loss handling
    {:noreply, %{state | replicas: MapSet.delete(state.replicas, pid)}}
  end

  # Section 3: Helper functions

  defp primary?(state), do: self() == primary_for_view(state.view_number, state.replicas)

  defp primary(state), do: primary_for_view(state.view_number, state.replicas)

  defp primary_for_view(view_number, replicas) do
    [self() | MapSet.to_list(replicas)]
    |> Enum.sort()
    |> Enum.at(rem(view_number, length(replicas + 1)))
  end

  defp quorum?(state) do
    MapSet.size(state.replicas) > div(state.cluster_size, 2)
  end

  defp increment_op_number(state), do: Map.update!(state, :op_number, &(&1 + 1))

  # Section 4: Router

  def handle_call(:dump, from, state), do: dump_impl(from, state)

  def handle_call({:connect, to_who}, from, state), do: connect_impl(to_who, from, state)

  def handle_call({:client_request, operation}, from, state),
    do: client_request_impl(operation, from, state)

  def handle_cast({:vsr, %type{} = msg}, state) do
    case type do
      ClientRequest -> client_request_impl(msg, state)
      Prepare -> prepare_impl(msg, state)
      PrepareOk -> prepare_ok_impl(msg, state)
    end
  end

  #  def handle_cast({:start_view_change}, state) do
  #    new_view_number = state.view_number + 1
  #
  #    # Send start view change to all connected replicas
  #    start_view_change_msg = %Messages.StartViewChange{
  #      view: new_view_number,
  #      sender: self()
  #    }
  #
  #    for {replica_pid, _ref} <- state.connected_replicas do
  #      Messages.vsr_send(replica_pid, start_view_change_msg)
  #    end
  #
  #    new_state = %{
  #      state
  #      | view_number: new_view_number,
  #        status: :view_change,
  #        primary: primary_for_view(new_view_number, state.configuration),
  #        view_change_votes: Map.put(state.view_change_votes, self(), true)
  #    }
  #
  #    {:noreply, new_state}
  #  end
  #
  #  def handle_cast({:get_state, target_replica}, state) do
  #    # Synchronously request state from target replica
  #    get_state_msg = %Messages.GetState{
  #      view: state.view_number,
  #      op_number: state.op_number,
  #      sender: self()
  #    }
  #
  #    Messages.vsr_send(target_replica, get_state_msg)
  #    {:noreply, state}
  #  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state),
    do: disconnect_impl(ref, pid, state)
end
