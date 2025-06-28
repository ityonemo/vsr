defmodule Vsr.Replica do
  use GenServer
  require Logger

  # Section 0: State
  defstruct [
    :view_number,
    :status,
    :op_number,
    :commit_number,
    :log,
    :configuration,
    :total_quorum_number,
    :connected_replicas,
    :primary,
    :store,
    :blocking,
    :client_table,
    :prepare_ok_count,
    :view_change_votes,
    :last_normal_view
  ]

  # Section 1: Initialization
  def start_link(opts) do
    configuration = Keyword.fetch!(opts, :configuration)
    total_quorum_number = Keyword.get(opts, :total_quorum_number, length(configuration))
    blocking = Keyword.get(opts, :blocking, false)
    name = Keyword.get(opts, :name)

    start_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, {configuration, total_quorum_number, blocking}, start_opts)
  end

  def init({configuration, total_quorum_number, blocking}) do
    # Monitor other replicas
    Process.flag(:trap_exit, true)

    store = :ets.new(:store, [:set, :private])
    client_table = :ets.new(:client_table, [:set, :private])

    state = %__MODULE__{
      view_number: 0,
      status: :normal,
      op_number: 0,
      commit_number: 0,
      log: [],
      configuration: configuration,
      total_quorum_number: total_quorum_number,
      connected_replicas: MapSet.new(),
      primary: primary_for_view(0, configuration),
      store: store,
      blocking: blocking,
      client_table: client_table,
      prepare_ok_count: %{},
      view_change_votes: %{},
      last_normal_view: 0
    }

    {:ok, state}
  end

  # Section 2: API
  @spec dump(pid()) :: %__MODULE__{}
  def dump(pid) do
    GenServer.call(pid, {:dump})
  end

  @spec connect(pid(), pid()) :: :ok | {:error, term()}
  def connect(pid, target_replica_pid) do
    GenServer.call(pid, {:connect, target_replica_pid})
  end

  @spec client_request(pid(), term(), term(), integer()) :: :ok
  def client_request(pid, operation, client_id, request_id) do
    GenServer.cast(pid, {:client_request, operation, client_id, request_id})
  end

  @spec get(pid(), term()) :: {:ok, term()} | {:error, :not_found}
  def get(pid, key) do
    GenServer.call(pid, {:get, key})
  end

  @spec put(pid(), term(), term()) :: :ok
  def put(pid, key, value) do
    GenServer.call(pid, {:put, key, value})
  end

  @spec delete(pid(), term()) :: :ok
  def delete(pid, key) do
    GenServer.call(pid, {:delete, key})
  end

  @spec start_view_change(pid()) :: :ok
  def start_view_change(pid) do
    GenServer.cast(pid, {:start_view_change})
  end

  @spec get_state(pid(), pid()) :: :ok
  def get_state(pid, target_replica) do
    GenServer.cast(pid, {:get_state, target_replica})
  end

  # Section 3: Impls
  defp dump_impl(_payload, _from, state) do
    {:reply, state, state}
  end

  defp connect_impl({target_replica_pid}, _from, state) do
    # Monitor the target replica
    ref = Process.monitor(target_replica_pid)

    # Add to connected replicas with monitoring reference
    new_connected_replicas = MapSet.put(state.connected_replicas, {target_replica_pid, ref})

    new_state = %{state | connected_replicas: new_connected_replicas}

    {:reply, :ok, new_state}
  end

  defp client_request_impl({operation, client_id, request_id}, state) do
    if self() == state.primary and state.status == :normal do
      # Check if this request was already processed
      case :ets.lookup(state.client_table, {client_id, request_id}) do
        [{_, result}] ->
          # Already processed, return cached result
          send_client_reply(client_id, request_id, result)
          {:noreply, state}

        [] ->
          # New request, process it
          new_op_number = state.op_number + 1
          log_entry = {state.view_number, new_op_number, operation, self()}
          new_log = state.log ++ [log_entry]

          # Send prepare messages to all connected backups
          prepare_message =
            {:prepare, state.view_number, new_op_number, operation, state.commit_number, self()}

          for {replica_pid, _ref} <- state.connected_replicas do
            send(replica_pid, prepare_message)
          end

          new_state = %{
            state
            | op_number: new_op_number,
              log: new_log,
              prepare_ok_count: Map.put(state.prepare_ok_count, new_op_number, 1)
          }

          # Check if we have majority immediately (single replica case)
          if MapSet.size(state.connected_replicas) == 0 do
            # Single replica - commit immediately
            commit_operation(new_state, new_op_number)
            new_state = %{new_state | commit_number: new_op_number}
            {:noreply, new_state}
          else
            {:noreply, new_state}
          end
      end
    else
      # Not primary, ignore or forward
      {:noreply, state}
    end
  end

  defp get_impl({key}, _from, state) do
    case :ets.lookup(state.store, key) do
      [{^key, value}] -> {:reply, {:ok, value}, state}
      [] -> {:reply, {:error, :not_found}, state}
    end
  end

  defp put_impl({key, value}, from, state) do
    if state.blocking do
      # For blocking replicas, block until unblocked
      receive do
        {:unblock, _} ->
          put_impl_internal({key, value}, from, state)
      end
    else
      put_impl_internal({key, value}, from, state)
    end
  end

  defp put_impl_internal({key, value}, _from, state) do
    # Always use VSR protocol for logging
    operation = {:put, key, value}
    new_op_number = state.op_number + 1

    log_entry = {state.view_number, new_op_number, operation, self()}
    new_log = state.log ++ [log_entry]

    # Apply operation immediately for single replica
    if MapSet.size(state.connected_replicas) == 0 do
      :ets.insert(state.store, {key, value})
      new_state = %{state | op_number: new_op_number, log: new_log, commit_number: new_op_number}
      {:reply, :ok, new_state}
    else
      # Multi-replica: use full VSR protocol
      new_state = %{state | op_number: new_op_number, log: new_log}

      case client_request_impl({operation, self(), :os.system_time(:microsecond)}, new_state) do
        {:noreply, updated_state} -> {:reply, :ok, updated_state}
        other -> other
      end
    end
  end

  defp delete_impl({key}, from, state) do
    if state.blocking do
      # For blocking replicas, block until unblocked
      receive do
        {:unblock, _} ->
          delete_impl_internal({key}, from, state)
      end
    else
      delete_impl_internal({key}, from, state)
    end
  end

  defp delete_impl_internal({key}, _from, state) do
    # Always use VSR protocol for logging
    operation = {:delete, key}
    new_op_number = state.op_number + 1

    log_entry = {state.view_number, new_op_number, operation, self()}
    new_log = state.log ++ [log_entry]

    # Apply operation immediately for single replica
    if MapSet.size(state.connected_replicas) == 0 do
      :ets.delete(state.store, key)
      new_state = %{state | op_number: new_op_number, log: new_log, commit_number: new_op_number}
      {:reply, :ok, new_state}
    else
      # Multi-replica: use full VSR protocol
      new_state = %{state | op_number: new_op_number, log: new_log}

      case client_request_impl({operation, self(), :os.system_time(:microsecond)}, new_state) do
        {:noreply, updated_state} -> {:reply, :ok, updated_state}
        other -> other
      end
    end
  end

  # Sending replies back to clients
  defp send_client_reply(client_id, request_id, result) do
    send(client_id, {:reply, request_id, result})
  end

  # Handling GenServer callbacks

  def handle_call({:dump}, from, state) do
    dump_impl(:dump, from, state)
  end

  def handle_call({:connect, target_replica_pid}, from, state) do
    connect_impl({target_replica_pid}, from, state)
  end

  def handle_call({:get, key}, from, state) do
    get_impl({key}, from, state)
  end

  def handle_call({:put, key, value}, from, state) do
    put_impl({key, value}, from, state)
  end

  def handle_call({:update_configuration, new_configuration}, _from, state) do\
    new_state = %{state | configuration: new_configuration, total_quorum_number: length(new_configuration), primary: primary_for_view(state.view_number, new_configuration)}\
    {:reply, :ok, new_state}\
  end
  def handle_call({:delete, key}, from, state) do
    delete_impl({key}, from, state)
  end

  def handle_cast({:client_request, operation, client_id, request_id}, state) do
    client_request_impl({operation, client_id, request_id}, state)
  end

  def handle_cast({:start_view_change}, state) do
    new_view_number = state.view_number + 1

    # Send start view change to all connected replicas
    for {replica_pid, _ref} <- state.connected_replicas do
      send(replica_pid, {:start_view_change, new_view_number, self()})
    end

    new_state = %{
      state
      | view_number: new_view_number,
        status: :view_change,
        primary: primary_for_view(new_view_number, state.configuration),
        view_change_votes: Map.put(state.view_change_votes, self(), true)
    }

    {:noreply, new_state}
  end

  def handle_cast({:get_state, target_replica}, state) do
    # Synchronously request state from target replica
    send(target_replica, {:get_state, state.view_number, state.op_number, self()})
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    # Remove the disconnected replica from connected_replicas
    new_connected_replicas = MapSet.delete(state.connected_replicas, {pid, ref})

    # Check if we still have quorum
    # +1 for self
    connected_count = MapSet.size(new_connected_replicas) + 1

    new_state = %{state | connected_replicas: new_connected_replicas}

    if connected_count < majority(state.total_quorum_number) do
      Logger.warning(
        "Lost quorum: #{connected_count}/#{state.total_quorum_number} replicas connected"
      )

      # Could trigger view change or enter read-only mode
    end

    {:noreply, new_state}
  end

  def handle_info(
        {:prepare, view_number, op_number, operation, _commit_number, sender_pid},
        state
      ) do
    if view_number >= state.view_number do
      # Append to log if new operation
      cond do
        op_number > length(state.log) ->
          new_log = state.log ++ [{view_number, op_number, operation, sender_pid}]
          new_state = %{state | log: new_log, op_number: op_number}

          # Send prepare-ok back to sender
          send(sender_pid, {:prepare_ok, view_number, op_number, self()})

          {:noreply, new_state}

        op_number <= length(state.log) ->
          # Already have operation, just send ok
          send(sender_pid, {:prepare_ok, view_number, op_number, self()})

          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:prepare_ok, view_number, op_number, _replica_pid}, state) do
    if view_number == state.view_number and self() == state.primary do
      current_count = Map.get(state.prepare_ok_count, op_number, 0) + 1
      new_prepare_ok_count = Map.put(state.prepare_ok_count, op_number, current_count)

      # +1 for self
      connected_count = MapSet.size(state.connected_replicas) + 1

      # Check if we have majority
      if current_count > div(connected_count, 2) do
        # Majority received, commit operation and send commit messages
        new_commit_number = max(state.commit_number, op_number)

        # Apply all operations up to commit point
        Enum.each(state.log, fn {_v, op, operation, _sender_pid} ->
          if op <= new_commit_number and op > state.commit_number do
            apply_operation(state, operation)
          end
        end)

        # Send commit messages to connected replicas
        commit_message = {:commit, view_number, new_commit_number}

        for {replica_pid, _ref} <- state.connected_replicas do
          send(replica_pid, commit_message)
        end

        {:noreply,
         %{state | commit_number: new_commit_number, prepare_ok_count: new_prepare_ok_count}}
      else
        {:noreply, %{state | prepare_ok_count: new_prepare_ok_count}}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:commit, view_number, commit_number}, state) do
    if view_number == state.view_number and commit_number > state.commit_number do
      # Apply all operations up to commit point
      Enum.each(state.log, fn {_v, op, operation, _sender_pid} ->
        if op <= commit_number and op > state.commit_number do
          apply_operation(state, operation)
        end
      end)

      new_state = %{state | commit_number: commit_number}
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:start_view_change, new_view_number, sender_pid}, state) do
    if new_view_number > state.view_number do
      new_view_change_votes = Map.put(state.view_change_votes, sender_pid, true)

      new_state = %{
        state
        | view_number: new_view_number,
          status: :view_change,
          view_change_votes: new_view_change_votes,
          primary: primary_for_view(new_view_number, state.configuration)
      }

      # Send vote back to sender
      send(sender_pid, {:start_view_change_ack, new_view_number, self()})

      # +1 for self
      connected_count = MapSet.size(state.connected_replicas) + 1

      # Check if we have majority for view change
      if count_true(new_view_change_votes) > div(connected_count, 2) do
        # We have majority, complete view change
        new_state = %{new_state | status: :normal, view_change_votes: %{}}
        {:noreply, new_state}
      else
        {:noreply, new_state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:do_view_change, new_view_number, log, last_normal_view, op_number, commit_number,
         _sender_pid},
        state
      ) do
    if new_view_number >= state.view_number do
      # Replacement for primary. Here, start view and set new state
      new_state = %{
        state
        | view_number: new_view_number,
          log: log,
          last_normal_view: last_normal_view,
          op_number: op_number,
          commit_number: commit_number,
          status: :normal,
          primary: primary_for_view(new_view_number, state.configuration)
      }

      # Send start view messages to other replicas
      for {replica_pid, _ref} <- state.connected_replicas do
        send(replica_pid, {:start_view, new_view_number, log, op_number, commit_number})
      end

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:start_view, new_view_number, log, op_number, commit_number}, state) do
    if new_view_number >= state.view_number do
      new_state = %{
        state
        | view_number: new_view_number,
          log: log,
          op_number: op_number,
          commit_number: commit_number,
          status: :normal,
          primary: primary_for_view(new_view_number, state.configuration)
      }

      send(new_state.primary, {:view_change_ok, new_view_number, self()})

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:start_view_change_ack, _new_view_number, _replica_pid}, state) do
    # Handle view change acknowledgment
    {:noreply, state}
  end

  def handle_info({:view_change_ok, new_view_number, replica_pid}, state) do
    new_votes = Map.put(state.view_change_votes, replica_pid, true)

    # +1 for self
    connected_count = MapSet.size(state.connected_replicas) + 1

    # Check majority
    if count_true(new_votes) > div(connected_count, 2) do
      new_state = %{
        state
        | view_change_votes: %{},
          status: :normal,
          last_normal_view: new_view_number
      }

      {:noreply, new_state}
    else
      {:noreply, %{state | view_change_votes: new_votes}}
    end
  end

  def handle_info({:get_state, _view_number, _op_number, requester}, state) do
    # Always send state regardless of view number
    send(
      requester,
      {:new_state, state.view_number, state.log, state.op_number, state.commit_number}
    )

    {:noreply, state}
  end

  def handle_info({:new_state, new_view_number, log, op_number, commit_number}, state) do
    if new_view_number >= state.view_number or op_number > state.op_number do
      # Apply all operations from new state
      Enum.each(log, fn {_v, op, operation, _sender_pid} ->
        if op <= commit_number do
          apply_operation(state, operation)
        end
      end)

      new_state = %{
        state
        | view_number: new_view_number,
          log: log,
          op_number: op_number,
          commit_number: commit_number,
          status: :normal
      }

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:request_state_from, target_replica}, state) do
    send(target_replica, {:get_state, state.view_number, state.op_number, self()})
    {:noreply, state}
  end

  def handle_info({:unblock, _}, state) do
    # This message is handled by the blocking receive in put_impl/delete_impl
    {:noreply, state}
  end

  defp commit_operation(state, op_number) do
    case Enum.find(state.log, fn {_v, op, _operation, _sender_pid} ->
           op == op_number
         end) do
      nil ->
        :ok

      {_v, _op, operation, _sender_pid} ->
        apply_operation(state, operation)
    end
  end

  defp apply_operation(state, {:put, key, value}) do
    :ets.insert(state.store, {key, value})
    state
  end

  defp apply_operation(state, {:delete, key}) do
    :ets.delete(state.store, key)
    state
  end

  defp apply_operation(state, _operation), do: state

  defp count_true(map) do
    Enum.count(map, fn {_k, v} -> v end)
  end

  defp majority(total_quorum_number) do
    div(total_quorum_number, 2) + 1
  end

  # Helper to find primary for a view
  defp primary_for_view(_view_number, []) do
    nil
  end

  defp primary_for_view(view_number, configuration) do
    index = rem(view_number, length(configuration))
    Enum.at(configuration, index)
  end
end
