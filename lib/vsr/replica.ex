defmodule Vsr.Replica do
  use GenServer
  require Logger
  alias Vsr.Messages
  alias Vsr.Log
  alias Vsr.EtsLog
  alias Vsr.StateMachine
  alias Vsr.KV

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
    :state_machine,
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
    state_machine_impl = Keyword.get(opts, :state_machine, KV)
    name = Keyword.get(opts, :name)

    start_opts = if name, do: [name: name], else: []

    GenServer.start_link(
      __MODULE__,
      {configuration, total_quorum_number, blocking, state_machine_impl},
      start_opts
    )
  end

  def init({configuration, total_quorum_number, blocking, state_machine_impl}) do
    # Monitor other replicas
    Process.flag(:trap_exit, true)

    client_table = :ets.new(:client_table, [:set, :private])
    log = EtsLog.new(nil)
    state_machine = StateMachine.new(state_machine_impl, [])

    state = %__MODULE__{
      view_number: 0,
      status: :normal,
      op_number: 0,
      commit_number: 0,
      log: log,
      configuration: configuration,
      total_quorum_number: total_quorum_number,
      connected_replicas: MapSet.new(),
      primary: primary_for_view(0, configuration),
      state_machine: state_machine,
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
    # Convert log back to list for backward compatibility with tests
    log_list = Log.get_all(state.log)
    compat_state = %{state | log: log_list}
    {:reply, compat_state, state}
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
          new_log = Log.append(state.log, state.view_number, new_op_number, operation, self())

          # Send prepare messages to all connected backups
          prepare_message = %Messages.Prepare{
            view: state.view_number,
            op_number: new_op_number,
            operation: operation,
            commit_number: state.commit_number,
            sender: self()
          }

          for {replica_pid, _ref} <- state.connected_replicas do
            Messages.vsr_send(replica_pid, prepare_message)
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
    {_updated_state_machine, result} =
      StateMachine.apply_operation(state.state_machine, {:get, key})

    {:reply, result, state}
  end

  defp put_impl({key, value}, from, state) do
    if state.blocking do
      # For blocking replicas, block until unblocked
      receive do
        %Messages.Unblock{} ->
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

    new_log = Log.append(state.log, state.view_number, new_op_number, operation, self())

    if MapSet.size(state.connected_replicas) == 0 do
      {new_state_machine, _result} = StateMachine.apply_operation(state.state_machine, operation)

      new_state = %{
        state
        | op_number: new_op_number,
          log: new_log,
          commit_number: new_op_number,
          state_machine: new_state_machine
      }

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
        %Messages.Unblock{} ->
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

    new_log = Log.append(state.log, state.view_number, new_op_number, operation, self())

    if MapSet.size(state.connected_replicas) == 0 do
      {new_state_machine, _result} = StateMachine.apply_operation(state.state_machine, operation)

      new_state = %{
        state
        | op_number: new_op_number,
          log: new_log,
          commit_number: new_op_number,
          state_machine: new_state_machine
      }

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
    reply = %Messages.ClientReply{request_id: request_id, result: result}
    send(client_id, reply)
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

  def handle_call({:update_configuration, new_configuration}, _from, state) do
    new_state = %{
      state
      | configuration: new_configuration,
        total_quorum_number: length(new_configuration),
        primary: primary_for_view(state.view_number, new_configuration)
    }

    {:reply, :ok, new_state}
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
    start_view_change_msg = %Messages.StartViewChange{
      view: new_view_number,
      sender: self()
    }

    for {replica_pid, _ref} <- state.connected_replicas do
      Messages.vsr_send(replica_pid, start_view_change_msg)
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
    get_state_msg = %Messages.GetState{
      view: state.view_number,
      op_number: state.op_number,
      sender: self()
    }

    Messages.vsr_send(target_replica, get_state_msg)
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

  def handle_info(%Messages.Prepare{} = msg, state) do
    if msg.view >= state.view_number do
      # Append to log if new operation
      cond do
        msg.op_number > Log.length(state.log) ->
          new_log = Log.append(state.log, msg.view, msg.op_number, msg.operation, msg.sender)
          new_state = %{state | log: new_log, op_number: msg.op_number}

          # Send prepare-ok back to sender
          prepare_ok_msg = %Messages.PrepareOk{
            view: msg.view,
            op_number: msg.op_number,
            sender: self()
          }

          Messages.vsr_send(msg.sender, prepare_ok_msg)
          {:noreply, new_state}

        msg.op_number <= Log.length(state.log) ->
          # Already have operation, just send ok
          prepare_ok_msg = %Messages.PrepareOk{
            view: msg.view,
            op_number: msg.op_number,
            sender: self()
          }

          Messages.vsr_send(msg.sender, prepare_ok_msg)
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(%Messages.PrepareOk{} = msg, state) do
    if msg.view == state.view_number and self() == state.primary do
      current_count = Map.get(state.prepare_ok_count, msg.op_number, 0) + 1
      new_prepare_ok_count = Map.put(state.prepare_ok_count, msg.op_number, current_count)

      # +1 for self
      connected_count = MapSet.size(state.connected_replicas) + 1

      # Check if we have majority
      if current_count > div(connected_count, 2) do
        # Majority received, commit operation and send commit messages
        new_commit_number = max(state.commit_number, msg.op_number)

        # Apply all operations up to commit point
        log_entries = Log.get_all(state.log)

        new_state_machine =
          Enum.reduce(log_entries, state.state_machine, fn {_v, op, operation, _sender_pid}, sm ->
            if op <= new_commit_number and op > state.commit_number do
              {updated_sm, _result} = StateMachine.apply_operation(sm, operation)
              updated_sm
            else
              sm
            end
          end)

        # Send commit messages to connected replicas
        commit_message = %Messages.Commit{
          view: msg.view,
          commit_number: new_commit_number
        }

        for {replica_pid, _ref} <- state.connected_replicas do
          Messages.vsr_send(replica_pid, commit_message)
        end

        {:noreply,
         %{
           state
           | commit_number: new_commit_number,
             prepare_ok_count: new_prepare_ok_count,
             state_machine: new_state_machine
         }}
      else
        {:noreply, %{state | prepare_ok_count: new_prepare_ok_count}}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(%Messages.Commit{} = msg, state) do
    if msg.view == state.view_number and msg.commit_number > state.commit_number do
      # Apply all operations up to commit point
      log_entries = Log.get_all(state.log)

      new_state_machine =
        Enum.reduce(log_entries, state.state_machine, fn {_v, op, operation, _sender_pid}, sm ->
          if op <= msg.commit_number and op > state.commit_number do
            {updated_sm, _result} = StateMachine.apply_operation(sm, operation)
            updated_sm
          else
            sm
          end
        end)

      new_state = %{state | commit_number: msg.commit_number, state_machine: new_state_machine}
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info(%Messages.StartViewChange{} = msg, state) do
    if msg.view > state.view_number do
      new_view_change_votes = Map.put(state.view_change_votes, msg.sender, true)

      new_state = %{
        state
        | view_number: msg.view,
          status: :view_change,
          view_change_votes: new_view_change_votes,
          primary: primary_for_view(msg.view, state.configuration)
      }

      # Send vote back to sender
      ack_msg = %Messages.StartViewChangeAck{view: msg.view, sender: self()}
      Messages.vsr_send(msg.sender, ack_msg)

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

  def handle_info(%Messages.DoViewChange{} = msg, state) do
    if msg.view >= state.view_number do
      # Replacement for primary. Here, start view and set new state
      new_log = EtsLog.new(nil) |> Log.replace(msg.log)

      new_state = %{
        state
        | view_number: msg.view,
          log: new_log,
          last_normal_view: msg.last_normal_view,
          op_number: msg.op_number,
          commit_number: msg.commit_number,
          status: :normal,
          primary: primary_for_view(msg.view, state.configuration)
      }

      # Send start view messages to other replicas
      start_view_msg = %Messages.StartView{
        view: msg.view,
        log: msg.log,
        op_number: msg.op_number,
        commit_number: msg.commit_number
      }

      for {replica_pid, _ref} <- state.connected_replicas do
        Messages.vsr_send(replica_pid, start_view_msg)
      end

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info(%Messages.StartView{} = msg, state) do
    if msg.view >= state.view_number do
      new_log = EtsLog.new(nil) |> Log.replace(msg.log)

      new_state = %{
        state
        | view_number: msg.view,
          log: new_log,
          op_number: msg.op_number,
          commit_number: msg.commit_number,
          status: :normal,
          primary: primary_for_view(msg.view, state.configuration)
      }

      view_change_ok_msg = %Messages.ViewChangeOk{view: msg.view, sender: self()}
      Messages.vsr_send(new_state.primary, view_change_ok_msg)

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info(%Messages.StartViewChangeAck{}, state) do
    # Handle view change acknowledgment
    {:noreply, state}
  end

  def handle_info(%Messages.ViewChangeOk{} = msg, state) do
    new_votes = Map.put(state.view_change_votes, msg.sender, true)

    # +1 for self
    connected_count = MapSet.size(state.connected_replicas) + 1

    # Check majority
    if count_true(new_votes) > div(connected_count, 2) do
      new_state = %{
        state
        | view_change_votes: %{},
          status: :normal,
          last_normal_view: msg.view
      }

      {:noreply, new_state}
    else
      {:noreply, %{state | view_change_votes: new_votes}}
    end
  end

  def handle_info(%Messages.GetState{} = msg, state) do
    # Always send state regardless of view number
    log_entries = Log.get_all(state.log)
    state_machine_state = StateMachine.get_state(state.state_machine)

    new_state_msg = %Messages.NewState{
      view: state.view_number,
      log: log_entries,
      op_number: state.op_number,
      commit_number: state.commit_number,
      state_machine_state: state_machine_state
    }

    Messages.vsr_send(msg.sender, new_state_msg)
    {:noreply, state}
  end

  def handle_info(%Messages.NewState{} = msg, state) do
    if msg.view >= state.view_number or msg.op_number > state.op_number do
      # Replace our log with the new log
      new_log = EtsLog.new(nil) |> Log.replace(msg.log)

      # Replace state machine state
      new_state_machine = StateMachine.set_state(state.state_machine, msg.state_machine_state)

      new_state = %{
        state
        | view_number: msg.view,
          log: new_log,
          op_number: msg.op_number,
          commit_number: msg.commit_number,
          status: :normal,
          state_machine: new_state_machine
      }

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:request_state_from, target_replica}, state) do
    get_state_msg = %Messages.GetState{
      view: state.view_number,
      op_number: state.op_number,
      sender: self()
    }

    Messages.vsr_send(target_replica, get_state_msg)
    {:noreply, state}
  end

  def handle_info(%Messages.Unblock{}, state) do
    # This message is handled by the blocking receive in put_impl/delete_impl
    {:noreply, state}
  end

  defp commit_operation(state, op_number) do
    case Log.get(state.log, op_number) do
      {:error, :not_found} ->
        :ok

      {:ok, {_v, _op, operation, _sender_pid}} ->
        {_updated_state_machine, _result} =
          StateMachine.apply_operation(state.state_machine, operation)
    end
  end

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
