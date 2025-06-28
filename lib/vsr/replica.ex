defmodule Vsr.Replica do
  use GenServer
  require Logger

  # Section 0: State
  defstruct [
    :replica_id,
    :view_number,
    :status,
    :op_number,
    :commit_number,
    :log,
    :configuration,
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
    replica_id = Keyword.fetch!(opts, :replica_id)
    configuration = Keyword.fetch!(opts, :configuration)
    blocking = Keyword.get(opts, :blocking, false)

    GenServer.start_link(__MODULE__, {replica_id, configuration, blocking},
      name: via_tuple(replica_id)
    )
  end

  def init({replica_id, configuration, blocking}) do
    store = :ets.new(:store, [:set, :private])
    client_table = :ets.new(:client_table, [:set, :private])

    state = %__MODULE__{
      replica_id: replica_id,
      view_number: 0,
      status: :normal,
      op_number: 0,
      commit_number: 0,
      log: [],
      configuration: configuration,
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

  defp client_request_impl({operation, client_id, request_id}, state) do
    if state.replica_id == state.primary and state.status == :normal do
      # Check if this request was already processed
      case :ets.lookup(state.client_table, {client_id, request_id}) do
        [{_, result}] ->
          # Already processed, return cached result
          send_client_reply(client_id, request_id, result)
          {:noreply, state}

        [] ->
          # New request, process it
          new_op_number = state.op_number + 1
          log_entry = {state.view_number, new_op_number, operation, client_id, request_id}
          new_log = state.log ++ [log_entry]

          # Send prepare messages to all backups
          prepare_message =
            {:prepare, state.view_number, new_op_number, operation, state.commit_number,
             state.replica_id}

          for replica_id <- state.configuration, replica_id != state.replica_id do
            send_to_replica(replica_id, prepare_message)
          end

          new_state = %{
            state
            | op_number: new_op_number,
              log: new_log,
              prepare_ok_count: Map.put(state.prepare_ok_count, new_op_number, 1)
          }

          # Check if we have majority immediately (single replica case)
          if length(state.configuration) == 1 do
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
    # Always use VSR protocol for logging, even single replica
    operation = {:put, key, value}
    new_op_number = state.op_number + 1

    log_entry =
      {state.view_number, new_op_number, operation, self(), :os.system_time(:microsecond)}

    new_log = state.log ++ [log_entry]

    # Apply operation immediately for single replica
    if length(state.configuration) == 1 do
      :ets.insert(state.store, {key, value})
      new_state = %{state | op_number: new_op_number, log: new_log, commit_number: new_op_number}
      {:reply, :ok, new_state}
    else
      # Multi-replica: use full VSR protocol
      client_request_impl({operation, self(), :os.system_time(:microsecond)}, state)
      {:reply, :ok, state}
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
    # Always use VSR protocol for logging, even single replica
    operation = {:delete, key}
    new_op_number = state.op_number + 1

    log_entry =
      {state.view_number, new_op_number, operation, self(), :os.system_time(:microsecond)}

    new_log = state.log ++ [log_entry]

    # Apply operation immediately for single replica
    if length(state.configuration) == 1 do
      :ets.delete(state.store, key)
      new_state = %{state | op_number: new_op_number, log: new_log, commit_number: new_op_number}
      {:reply, :ok, new_state}
    else
      # Multi-replica: use full VSR protocol
      client_request_impl({operation, self(), :os.system_time(:microsecond)}, state)
      {:reply, :ok, state}
    end
  end

  # Sending replies back to clients
  defp send_client_reply(client_id, request_id, result) do
    send(client_id, {:reply, request_id, result})
  end

  # Sending messages to replicas via Registry
  defp send_to_replica(replica_id, message) do
    case Registry.lookup(Vsr.Registry, replica_id) do
      [{pid, _}] -> send(pid, message)
      [] -> :ok
    end
  end

  # Handling GenServer callbacks

  def handle_call({:dump}, from, state) do
    dump_impl(:dump, from, state)
  end

  def handle_call({:get, key}, from, state) do
    get_impl({key}, from, state)
  end

  def handle_call({:put, key, value}, from, state) do
    put_impl({key, value}, from, state)
  end

  def handle_call({:delete, key}, from, state) do
    delete_impl({key}, from, state)
  end

  def handle_cast({:client_request, operation, client_id, request_id}, state) do
    client_request_impl({operation, client_id, request_id}, state)
  end

  def handle_cast({:start_view_change}, state) do
    new_view_number = state.view_number + 1

    # Send start view change to all replicas
    for replica_id <- state.configuration, replica_id != state.replica_id do
      send_to_replica(replica_id, {:start_view_change, new_view_number, state.replica_id})
    end

    state = %{
      state
      | view_number: new_view_number,
        status: :view_change,
        view_change_votes: Map.put(state.view_change_votes, state.replica_id, true)
    }

    {:noreply, state}
  end

  def handle_cast({:get_state, target_replica}, state) do
    send(target_replica, {:get_state, state.view_number, state.op_number, self()})
    {:noreply, state}
  end

  def handle_info({:prepare, view_number, op_number, operation, _commit_number, sender_id}, state) do
    if view_number >= state.view_number do
      # Append to log if new operation
      cond do
        op_number > length(state.log) ->
          new_log = state.log ++ [{view_number, op_number, operation, sender_id}]
          new_state = %{state | log: new_log, op_number: op_number}
          send_to_replica(sender_id, {:prepare_ok, view_number, op_number, state.replica_id})

          {:noreply, new_state}

        op_number <= length(state.log) ->
          # Already have operation, just send ok
          send_to_replica(sender_id, {:prepare_ok, view_number, op_number, state.replica_id})

          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:prepare_ok, view_number, op_number, _replica_id}, state) do
    if view_number == state.view_number and state.replica_id == state.primary do
      current_count = Map.get(state.prepare_ok_count, op_number, 0) + 1
      new_prepare_ok_count = Map.put(state.prepare_ok_count, op_number, current_count)

      # Check if we have majority
      if current_count > div(length(state.configuration), 2) do
        # Majority received, commit operation and send commit messages
        new_commit_number = max(state.commit_number, op_number)

        # Apply all operations up to commit point
        Enum.each(state.log, fn {_v, op, _op_data, _cid, _reqid} ->
          if op <= new_commit_number and op > state.commit_number do
            commit_operation(state, op)
          end
        end)

        # Send commit messages to backups
        commit_message = {:commit, view_number, new_commit_number}

        for replica_id <- state.configuration, replica_id != state.replica_id do
          send_to_replica(replica_id, commit_message)
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
      Enum.each(state.log, fn {_v, op, _op_data, _cid, _reqid} ->
        if op <= commit_number and op > state.commit_number do
          commit_operation(state, op)
        end
      end)

      new_state = %{state | commit_number: commit_number}
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:start_view_change, new_view_number, sender_id}, state) do
    if new_view_number > state.view_number do
      new_view_change_votes = Map.put(state.view_change_votes, sender_id, true)

      new_state = %{
        state
        | view_number: new_view_number,
          status: :view_change,
          view_change_votes: new_view_change_votes,
          primary: primary_for_view(new_view_number, state.configuration)
      }

      # Send vote back to sender
      send_to_replica(sender_id, {:start_view_change_ack, new_view_number, state.replica_id})

      # Check if we have majority for view change
      if count_true(new_view_change_votes) > div(length(state.configuration), 2) do
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
         _sender_id},
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
      for replica_id <- state.configuration do
        if replica_id != state.replica_id do
          send_to_replica(
            replica_id,
            {:start_view, new_view_number, log, op_number, commit_number}
          )
        end
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

      send_to_replica(new_state.primary, {:view_change_ok, new_view_number, state.replica_id})

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:start_view_change_ack, _new_view_number, _replica_id}, state) do
    # Handle view change acknowledgment
    {:noreply, state}
  end

  def handle_info({:view_change_ok, new_view_number, replica_id}, state) do
    new_votes = Map.put(state.view_change_votes, replica_id, true)

    # Check majority
    if count_true(new_votes) > div(length(state.configuration), 2) do
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

  def handle_info({:get_state, view_number, _op_number, requester}, state) do
    if view_number == state.view_number do
      send(requester, {:new_state, view_number, state.log, state.op_number, state.commit_number})
    end

    {:noreply, state}
  end

  def handle_info({:new_state, new_view_number, log, op_number, commit_number}, state) do
    if new_view_number >= state.view_number do
      # Apply all operations from new state
      Enum.each(log, fn {_v, op, operation, _cid, _reqid} ->
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

  def handle_info({:unblock, _}, state) do
    # This message is handled by the blocking receive in put_impl/delete_impl
    {:noreply, state}
  end

  defp commit_operation(state, op_number) do
    case Enum.find(state.log, fn {_v, op, _operation, _cid, _rid} -> op == op_number end) do
      nil ->
        :ok

      {_v, _op, operation, _cid, _rid} ->
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

  # Helper to find primary for a view
  defp primary_for_view(view_number, configuration) do
    index = rem(view_number, length(configuration))
    Enum.at(configuration, index)
  end

  # Helpers for via tuple registration
  defp via_tuple(replica_id) do
    {:via, Registry, {Vsr.Registry, replica_id}}
  end
end
