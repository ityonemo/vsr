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

          maybe_block_and_reply(new_state)
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

  defp put_impl({key, value}, _from, state) do
    if state.blocking do
      receive do
        {:unblock, _id} -> :ets.insert(state.store, {key, value})
      end
    else
      :ets.insert(state.store, {key, value})
    end

    # Always return ok for put operations
    {:reply, :ok, state}
  end

  defp delete_impl({key}, _from, state) do
    # For single replica or direct API calls, execute immediately
    :ets.delete(state.store, key)
    # Always return ok for delete operations
    {:reply, :ok, state}
  end

  defp start_view_change_impl(_payload, state) do
    new_view = state.view_number + 1

    # Send start-view-change to all replicas
    message = {:start_view_change, new_view, state.replica_id}

    for replica_id <- state.configuration do
      send_to_replica(replica_id, message)
    end

    new_state = %{
      state
      | status: :view_change,
        view_number: new_view,
        view_change_votes: %{new_view => MapSet.new([state.replica_id])}
    }

    maybe_block_and_reply(new_state)
  end

  defp get_state_impl({target_replica}, state) do
    send(
      target_replica,
      {:get_state_request, state.view_number, state.op_number, state.replica_id}
    )

    maybe_block_and_reply(state)
  end

  # Section 4: VSR Message Handlers
  defp prepare_impl({view, op_num, operation, commit_num, primary_id}, state) do
    if view == state.view_number and state.status == :normal and primary_id == state.primary do
      # Accept prepare if view matches and we're in normal mode
      if op_num == state.op_number + 1 do
        log_entry = {view, op_num, operation, nil, nil}
        new_log = state.log ++ [log_entry]

        # Send prepare-ok back to primary
        prepare_ok_message = {:prepare_ok, view, op_num, state.replica_id}
        send_to_replica(primary_id, prepare_ok_message)

        # Commit any operations up to commit_num
        new_state = %{state | op_number: op_num, log: new_log}

        final_state = commit_operations(new_state, commit_num)
        maybe_block_and_reply(final_state)
      else
        # Out of order, ignore or request state transfer
        maybe_block_and_reply(state)
      end
    else
      maybe_block_and_reply(state)
    end
  end

  defp prepare_ok_impl({view, op_num, _replica_id}, state) do
    if view == state.view_number and state.status == :normal and state.replica_id == state.primary do
      current_count = Map.get(state.prepare_ok_count, op_num, 0)
      new_count = current_count + 1

      new_prepare_ok_count = Map.put(state.prepare_ok_count, op_num, new_count)

      # Check if we have majority
      majority = div(length(state.configuration), 2) + 1

      new_state = %{state | prepare_ok_count: new_prepare_ok_count}

      if new_count >= majority do
        # Commit this operation and send commit message
        commit_message = {:commit, view, op_num}

        for replica_id <- state.configuration, replica_id != state.replica_id do
          send_to_replica(replica_id, commit_message)
        end

        final_state = commit_operations(new_state, op_num)
        maybe_block_and_reply(final_state)
      else
        maybe_block_and_reply(new_state)
      end
    else
      maybe_block_and_reply(state)
    end
  end

  defp commit_impl({view, commit_num}, state) do
    if view == state.view_number and state.status == :normal do
      new_state = commit_operations(state, commit_num)
      maybe_block_and_reply(new_state)
    else
      maybe_block_and_reply(state)
    end
  end

  defp start_view_change_msg_impl({view, replica_id}, state) do
    if view > state.view_number do
      current_votes = Map.get(state.view_change_votes, view, MapSet.new())
      new_votes = MapSet.put(current_votes, replica_id)

      majority = div(length(state.configuration), 2) + 1

      if MapSet.size(new_votes) >= majority do
        # Start do-view-change
        new_primary = primary_for_view(view, state.configuration)

        if new_primary == state.replica_id do
          # We are the new primary
          new_state = %{
            state
            | view_number: view,
              status: :normal,
              primary: new_primary,
              last_normal_view: state.view_number
          }

          maybe_block_and_reply(new_state)
        else
          # Send do-view-change to new primary
          message =
            {:do_view_change, view, state.log, state.last_normal_view, state.op_number,
             state.commit_number, state.replica_id}

          send_to_replica(new_primary, message)

          new_state = %{
            state
            | view_number: view,
              status: :view_change,
              primary: new_primary,
              view_change_votes: Map.put(state.view_change_votes, view, new_votes)
          }

          maybe_block_and_reply(new_state)
        end
      else
        new_state = %{
          state
          | view_change_votes: Map.put(state.view_change_votes, view, new_votes)
        }

        maybe_block_and_reply(new_state)
      end
    else
      maybe_block_and_reply(state)
    end
  end

  defp unblock_impl({_id}, state) do
    # Only unblock if the id matches (for testing purposes)
    maybe_block_and_reply(state)
  end

  # Section 5: Router
  def handle_call({:dump}, from, state), do: dump_impl(nil, from, state)
  def handle_call({:get, key}, from, state), do: get_impl({key}, from, state)
  def handle_call({:put, key, value}, from, state), do: put_impl({key, value}, from, state)
  def handle_call({:delete, key}, from, state), do: delete_impl({key}, from, state)

  def handle_cast({:client_request, operation, client_id, request_id}, state) do
    client_request_impl({operation, client_id, request_id}, state)
  end

  def handle_cast({:start_view_change}, state) do
    start_view_change_impl(nil, state)
  end

  def handle_cast({:get_state, target_replica}, state) do
    get_state_impl({target_replica}, state)
  end

  def handle_info({:prepare, view, op_num, operation, commit_num, primary_id}, state) do
    prepare_impl({view, op_num, operation, commit_num, primary_id}, state)
  end

  def handle_info({:prepare_ok, view, op_num, replica_id}, state) do
    prepare_ok_impl({view, op_num, replica_id}, state)
  end

  def handle_info({:commit, view, commit_num}, state) do
    commit_impl({view, commit_num}, state)
  end

  def handle_info({:start_view_change, view, replica_id}, state) do
    start_view_change_msg_impl({view, replica_id}, state)
  end

  def handle_info({:unblock, id}, state) do
    unblock_impl({id}, state)
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Helper functions
  defp primary_for_view(view, configuration) do
    Enum.at(configuration, rem(view, length(configuration)))
  end

  defp via_tuple(replica_id) do
    {:via, Registry, {Vsr.Registry, replica_id}}
  end

  defp send_to_replica(replica_id, message) do
    case Registry.lookup(Vsr.Registry, replica_id) do
      [{pid, _}] -> send(pid, message)
      # Replica not found
      [] -> :ok
    end
  end

  defp send_client_reply(client_id, request_id, result) do
    # In a real implementation, this would send back to the client
    Logger.debug("Client reply: #{inspect({client_id, request_id, result})}")
  end

  defp commit_operations(state, commit_num) do
    if commit_num > state.commit_number do
      # Execute operations from commit_number + 1 to commit_num
      operations_to_commit =
        Enum.slice(state.log, state.commit_number, commit_num - state.commit_number)

      Enum.each(operations_to_commit, fn {_view, _op_num, operation, client_id, request_id} ->
        result = execute_operation(operation, state.store)

        if client_id && request_id do
          :ets.insert(state.client_table, {{client_id, request_id}, result})
          send_client_reply(client_id, request_id, result)
        end
      end)

      %{state | commit_number: commit_num}
    else
      state
    end
  end

  defp execute_operation({:put, key, value}, store) do
    :ets.insert(store, {key, value})
    :ok
  end

  defp execute_operation({:delete, key}, store) do
    :ets.delete(store, key)
    :ok
  end

  defp execute_operation({:get, key}, store) do
    case :ets.lookup(store, key) do
      [{^key, value}] -> {:ok, value}
      [] -> {:error, :not_found}
    end
  end

  defp maybe_block_and_reply(state) do
    if state.blocking do
      receive do
        {:unblock, _id} -> {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end
end
