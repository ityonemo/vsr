defmodule Vsr do
  use GenServer
  require Logger

  alias Vsr.Comms
  alias Vsr.Log
  alias Vsr.Log.Entry
  alias Vsr.Message.ClientRequest
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
  alias Vsr.Message.Heartbeat
  alias Vsr.StateMachine
  alias Vsr.StdComms

  # Section 0: State
  defstruct [
    :log,
    :cluster_size,
    :replicas,
    :state_machine,
    :heartbeat_timer_ref,
    :primary_inactivity_timer_ref,
    view_number: 0,
    status: :normal,
    op_number: 0,
    commit_number: 0,
    prepare_ok_count: %{},
    view_change_votes: %{},
    last_normal_view: 0,
    client_table: %{},
    comms: %StdComms{},
    primary_inactivity_timeout: 5000,
    view_change_timeout: 10_000,
    heartbeat_interval: 1000
  ]

  @type message ::
          Prepare.t()
          | PrepareOk.t()
          | Commit.t()
          | StartViewChange.t()
          | StartViewChangeAck.t()
          | DoViewChange.t()
          | StartView.t()
          | ViewChangeOk.t()
          | GetState.t()
          | NewState.t()
          | ClientRequest.t()
          | Heartbeat.t()

  @type state :: %__MODULE__{
          log: Log.t(),
          status: :normal | :view_change,
          view_number: non_neg_integer(),
          op_number: non_neg_integer(),
          commit_number: non_neg_integer(),
          replicas: MapSet.t(term()),
          state_machine: StateMachine.t(),
          prepare_ok_count: %{non_neg_integer() => non_neg_integer()},
          view_change_votes: map(),
          last_normal_view: non_neg_integer(),
          client_table: %{{pid(), reference()} => term()},
          primary_inactivity_timeout: non_neg_integer(),
          comms: Comms.t(),
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
    {sm_mod, sm_opts} =
      case Keyword.fetch!(opts, :state_machine) do
        {mod, opts} -> {mod, opts}
        mod when is_atom(mod) -> {mod, []}
      end

    opts
    |> Keyword.drop(~w[state_machine name]a)
    |> then(&struct!(__MODULE__, &1))
    |> Map.replace!(:state_machine, sm_mod._new(self(), sm_opts))
    |> initialize_cluster()
    |> start_timers()
    |> then(&{:ok, &1})
  end

  defp initialize_cluster(state) do
    replicas =
      state.comms
      |> Comms.initial_cluster()
      |> MapSet.new()

    %{state | replicas: replicas}
  end

  # Section 2: API
  @spec update(pid(), keyword()) :: :ok
  @spec connect(pid(), pid()) :: :ok | {:error, term()}
  @spec client_request(pid(), term()) :: :ok
  @spec start_view_change(pid()) :: :ok
  @spec get_state(pid()) :: term()

  # debug api
  @spec dump(pid()) :: %__MODULE__{}

  def update(pid, kv), do: GenServer.call(pid, {:update, kv})

  defp update_impl(kv, _from, state), do: {:reply, :ok, struct!(state, kv)}

  # Section 2: API Impls
  def connect(pid, to_pid), do: GenServer.call(pid, {:connect, to_pid})

  defp connect_impl(target_replica_pid, _from, state) do
    # Monitor the target replica
    Comms.monitor(state.comms, target_replica_pid)

    # Add to connected replicas
    new_replicas = MapSet.put(state.replicas, target_replica_pid)

    new_state = %{state | replicas: new_replicas}

    {:reply, :ok, new_state}
  end

  def client_request(pid, operation) do
    request_id = make_ref()
    Logger.debug("Client request (#{inspect(request_id)}): #{inspect(operation)}")

    pid
    |> GenServer.call({:client_request, operation}, 15_000)
    |> tap(&Logger.debug("Client request (#{inspect(request_id)}) response: #{inspect(&1)}"))
  end

  def client_request(pid, operation, request_id) do
    Logger.debug("Client request: (#{request_id}) #{inspect(operation)}")

    pid
    |> GenServer.call({:client_request, operation, self(), request_id}, 15_000)
    |> tap(&Logger.debug("Client request (#{request_id}) response: #{inspect(&1)}"))
  end

  defp client_request_impl(operation, from, state) do
    has_quorum = quorum?(state)
    requires_linearized = StateMachine._require_linearized?(state.state_machine, operation)
    read_only = StateMachine._read_only?(state.state_machine, operation)

    cond do
      requires_linearized and has_quorum ->
        # do the linearized operation.
        client_request_linearized(read_only, operation, from, state)

      read_only or not requires_linearized ->
        # do the read-only operation without the quorum.
        {new_state_machine, reply} = StateMachine._apply_operation(state.state_machine, operation)
        {:reply, reply, %{state | state_machine: new_state_machine}}

      :else ->
        # TODO: convert this into a proper quorum exception.
        {:reply, {:error, :quorum}, state}
    end
  end

  defp client_request_impl(operation, client_pid, request_id, from, state) do
    client_key = {client_pid, request_id}

    case Map.fetch(state.client_table, client_key) do
      {:ok, cached_result} ->
        # Request already processed - return cached result
        {:reply, cached_result, state}

      :error ->
        # New request - process it and cache result
        has_quorum = quorum?(state)
        requires_linearized = StateMachine._require_linearized?(state.state_machine, operation)
        read_only = StateMachine._read_only?(state.state_machine, operation)

        cond do
          requires_linearized and has_quorum ->
            # Process linearized operation with deduplication
            client_request_linearized_with_dedup(read_only, operation, client_key, from, state)

          read_only or not requires_linearized ->
            # Process read-only operation and cache result
            {new_state_machine, reply} =
              StateMachine._apply_operation(state.state_machine, operation)

            new_client_table = Map.put(state.client_table, client_key, reply)

            {:reply, reply,
             %{state | state_machine: new_state_machine, client_table: new_client_table}}

          :else ->
            {:reply, {:error, :quorum}, state}
        end
    end
  end

  defp client_request_linearized_with_dedup(read_only, operation, client_key, from, state) do
    is_primary = primary?(state)

    cond do
      state.status != :normal ->
        {:reply, {:error, :not_normal}, state}

      is_primary ->
        # For deduplication, we need to modify the ClientRequest to include the client_key
        # so it can be cached when the operation completes
        client_request_impl(
          %ClientRequest{
            operation: operation,
            from: Comms.encode_from(state.comms, from),
            read_only: read_only,
            client_key: client_key
          },
          state
        )

      :else ->
        # Send to primary with client_key for deduplication
        primary_pid = primary(state)

        Comms.send_to(state.comms, primary_pid, %ClientRequest{
          operation: operation,
          from: Comms.encode_from(state.comms, from),
          read_only: read_only,
          client_key: client_key
        })

        {:noreply, state}
    end
  end

  defp client_request_linearized(read_only, operation, from, state) do
    is_primary = primary?(state)

    cond do
      state.status != :normal ->
        # TODO: convert this into a better quorum exception
        {:reply, {:error, :not_normal}, state}

      is_primary ->
        client_request_impl(
          %ClientRequest{
            operation: operation,
            from: Comms.encode_from(state.comms, from),
            read_only: read_only
          },
          state
        )

      :else ->
        # send the client request to the primary
        primary_pid = primary(state)

        Comms.send_to(state.comms, primary_pid, %ClientRequest{
          operation: operation,
          from: Comms.encode_from(state.comms, from),
          read_only: read_only
        })

        {:noreply, state}
    end
  end

  # client request.  Received by the primary replica.
  defp client_request_impl(
         %ClientRequest{
           operation: operation,
           from: from,
           read_only: true,
           client_key: client_key
         },
         state
       ) do
    # If read-only with client_key, cache the result for deduplication
    {new_state_machine, reply} = StateMachine._apply_operation(state.state_machine, operation)
    Comms.send_reply(state.comms, from, reply)

    new_client_table =
      if client_key do
        Map.put(state.client_table, client_key, reply)
      else
        state.client_table
      end

    {:noreply, %{state | state_machine: new_state_machine, client_table: new_client_table}}
  end

  defp client_request_impl(
         %ClientRequest{operation: operation, from: from, read_only: true},
         state
       ) do
    # If read-only without client_key (legacy path)
    {new_state_machine, reply} = StateMachine._apply_operation(state.state_machine, operation)
    Comms.send_reply(state.comms, from, reply)
    {:noreply, %{state | state_machine: new_state_machine}}
  end

  defp client_request_impl(%ClientRequest{operation: operation, from: from}, state) do
    # not read-only case, so operation must be prepared and sent to replicas.
    # Append the operation to the log
    new_state =
      state
      |> increment_op_number()
      |> append_new_log(from, operation)

    # Craft and send prepare message to all replicas
    prepare_msg = prepare_msg(new_state, from, operation)
    Enum.each(new_state.replicas, &Comms.send_to(state.comms, &1, prepare_msg))

    # Check if we have quorum immediately (for single replica or immediate majority)
    new_state = maybe_commit_operation(new_state, new_state.op_number, state.comms)

    {:noreply, new_state}
  end

  defp prepare_msg(state, from, operation) do
    # Create the prepare message
    %Prepare{
      view: state.view_number,
      op_number: state.op_number,
      operation: operation,
      commit_number: state.commit_number,
      # Pass original client's encoded from for replies
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
    # - If `op_number == log_length + 1`: append operation to `log` 
    # - Update `op_number = max(op_number, received_op_number)`
    # - Send `PREPARE-OK(view, op-num, replica-id)` to primary

    # Reset primary inactivity timer since we got a message from primary
    state = reset_primary_inactivity_timer(state)
    log_length = Log.length(state.log)

    cond do
      prepare.view < state.view_number ->
        # Old view - ignore
        Logger.warning(
          "Received prepare with old view #{prepare.view}, current view #{state.view_number}"
        )

        {:noreply, state}

      prepare.op_number == log_length + 1 ->
        # Sequential operation - append to log
        entry = %Entry{
          view: prepare.view,
          op_number: prepare.op_number,
          operation: prepare.operation,
          sender_id: prepare.from
        }

        new_state =
          state
          |> Map.update!(:log, &Log.append(&1, entry))
          |> Map.replace(:op_number, prepare.op_number)

        send_prepare_ok(new_state, prepare)
        {:noreply, new_state}

      prepare.op_number <= log_length ->
        # Already have this operation - just respond with ok
        send_prepare_ok(state, prepare)
        {:noreply, state}

      prepare.op_number > log_length + 1 ->
        # Gap detected - trigger state transfer
        Logger.warning(
          "Gap detected: received op #{prepare.op_number}, expected #{log_length + 1}. Triggering state transfer."
        )

        primary_pid = primary(state)

        get_state_msg = %GetState{
          view: state.view_number,
          op_number: state.op_number,
          sender: Comms.node_id(state.comms)
        }

        Comms.send_to(state.comms, primary_pid, get_state_msg)
        {:noreply, state}
    end
  end

  defp send_prepare_ok(state, prepare) do
    primary_pid = primary(state)

    Comms.send_to(state.comms, primary_pid, %PrepareOk{
      view: prepare.view,
      op_number: prepare.op_number,
      replica: Comms.node_id(state.comms)
    })
  end

  defp prepare_ok_impl(prepare_ok, state) do
    if primary?(state) and prepare_ok.view == state.view_number do
      new_state = increment_ok_count(state, prepare_ok.op_number)
      new_state = maybe_commit_operation(new_state, prepare_ok.op_number, state.comms)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  defp increment_ok_count(%{prepare_ok_count: ok_count} = state, op_number) do
    count = Map.get(ok_count, op_number, 0) + 1
    %{state | prepare_ok_count: Map.put(ok_count, op_number, count)}
  end

  defp maybe_commit_operation(state, op_number, comms) do
    current_count = Map.get(state.prepare_ok_count, op_number, 0)
    # +1 for self (primary)
    connected_replicas = MapSet.size(state.replicas) + 1

    # Check if we have majority of CONNECTED replicas for consensus
    # But only if we have quorum of the total cluster for availability
    if quorum?(state) and current_count > div(connected_replicas, 2) do
      # Majority received, commit operation and send commit messages
      new_commit_number = max(state.commit_number, op_number)

      # Apply all operations up to commit point and send client replies
      log_entries = Log.get_all(state.log)

      {new_state_machine, operation_results} =
        apply_operations(
          log_entries,
          state.state_machine,
          state.commit_number,
          new_commit_number
        )

      # Send replies for newly committed operations
      send_client_replies_for_committed_operations(
        log_entries,
        operation_results,
        state.commit_number,
        new_commit_number,
        comms
      )

      # Send commit messages to connected replicas
      commit_message = %Commit{
        view: state.view_number,
        commit_number: new_commit_number
      }

      Enum.each(state.replicas, &Comms.send_to(state.comms, &1, commit_message))

      # Clean up prepare_ok_count for committed operations
      cleaned_prepare_ok_count =
        state.prepare_ok_count
        |> Enum.reject(fn {op_num, _count} -> op_num <= new_commit_number end)
        |> Map.new()

      %{
        state
        | commit_number: new_commit_number,
          state_machine: new_state_machine,
          prepare_ok_count: cleaned_prepare_ok_count
      }
    else
      state
    end
  end

  # Send client replies for operations that were just committed by the primary
  defp send_client_replies_for_committed_operations(
         log_entries,
         operation_results,
         old_commit_number,
         new_commit_number,
         comms
       ) do
    # Create a map of op_number -> result for quick lookup
    results_map = Map.new(operation_results)

    # Find operations to send replies for
    log_entries
    |> Enum.filter(fn entry ->
      entry.op_number > old_commit_number and entry.op_number <= new_commit_number
    end)
    |> Enum.sort_by(& &1.op_number)
    |> Enum.each(fn entry ->
      # Only send reply if this entry has a sender_id (client request)
      if entry.sender_id do
        case Map.get(results_map, entry.op_number) do
          nil -> :ok  # No result for this operation
          result -> Comms.send_reply(comms, entry.sender_id, result)
        end
      end
    end)
  end

  defp apply_operations(
         log_entries,
         state_machine,
         old_commit_number,
         new_commit_number
       ) do
    # Find operations to commit
    operations_to_commit =
      log_entries
      |> Enum.filter(fn entry ->
        entry.op_number > old_commit_number and entry.op_number <= new_commit_number
      end)
      |> Enum.sort_by(& &1.op_number)

    # Apply operations and collect results
    {final_state_machine, results} =
      Enum.reduce(operations_to_commit, {state_machine, []}, fn entry, {sm, results} ->
        {new_sm, result} = StateMachine._apply_operation(sm, entry.operation)

        {new_sm, [{entry.op_number, result} | results]}
      end)

    {final_state_machine, Enum.reverse(results)}
  end

  defp commit_impl(commit, state) do
    # Reset primary inactivity timer since we got a message from primary
    state = reset_primary_inactivity_timer(state)

    if commit.view == state.view_number and commit.commit_number > state.commit_number do
      # Apply all operations up to commit point
      log_entries = Log.get_all(state.log)

      {new_state_machine, _} =
        apply_operations(
          log_entries,
          state.state_machine,
          state.commit_number,
          commit.commit_number
        )

      # Clean up prepare_ok_count for committed operations
      cleaned_prepare_ok_count =
        state.prepare_ok_count
        |> Enum.reject(fn {op_num, _count} -> op_num <= commit.commit_number end)
        |> Map.new()

      new_state = %{
        state
        | commit_number: commit.commit_number,
          state_machine: new_state_machine,
          prepare_ok_count: cleaned_prepare_ok_count
      }

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  # View Change Message Implementations

  defp start_view_change_impl(start_view_change, state) do
    if start_view_change.view > state.view_number do
      # Transition to view change status
      new_state = %{
        state
        | status: :view_change,
          view_number: start_view_change.view,
          last_normal_view: state.view_number
      }

      # Broadcast START-VIEW-CHANGE-ACK to ALL replicas (including self)
      ack_msg = %StartViewChangeAck{
        view: start_view_change.view,
        replica: Comms.node_id(state.comms)
      }

      Enum.each(state.replicas, &Comms.send_to(state.comms, &1, ack_msg))
      # Also send to self
      GenServer.cast(self(), {:vsr, ack_msg})

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  defp start_view_change_ack_impl(ack, state) do
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

      # Check if we have enough votes to proceed from connected replicas
      vote_count = length(updated_votes)
      connected_replicas = MapSet.size(state.replicas) + 1

      # Only send DO-VIEW-CHANGE once when we first reach majority
      if vote_count > div(connected_replicas, 2) and
           length(existing_votes) <= div(connected_replicas, 2) do
        # Just reached enough votes, send DO-VIEW-CHANGE to new primary
        new_primary = primary_for_view(ack.view, state.replicas, state.comms)

        Comms.send_to(state.comms, new_primary, %DoViewChange{
          view: ack.view,
          log: Log.get_all(state.log),
          last_normal_view: state.last_normal_view,
          op_number: state.op_number,
          commit_number: state.commit_number,
          from: Comms.node_id(state.comms)
        })

        {:noreply, new_state}
      else
        {:noreply, new_state}
      end
    else
      {:noreply, state}
    end
  end

  defp do_view_change_impl(do_view_change, state) do
    if primary?(state) and do_view_change.view == state.view_number and
         state.status == :view_change do
      # Collect DO-VIEW-CHANGE messages - we need majority before proceeding
      do_view_change_key = "do_view_change_#{do_view_change.view}"
      existing_messages = Map.get(state.view_change_votes, do_view_change_key, [])

      # Add this message if not already received from this replica
      updated_messages =
        if do_view_change.from in existing_messages do
          existing_messages
        else
          [do_view_change.from | existing_messages]
        end

      new_votes = Map.put(state.view_change_votes, do_view_change_key, updated_messages)
      new_state = %{state | view_change_votes: new_votes}

      # Check if we have majority of DO-VIEW-CHANGE messages
      connected_replicas = MapSet.size(state.replicas) + 1

      if length(updated_messages) > div(connected_replicas, 2) do
        # Collect view change data and update log if necessary
        current_log = Log.get_all(state.log)
        received_log = do_view_change.log

        # Use the log with higher op_number or more recent view
        merged_log =
          if do_view_change.op_number > state.op_number do
            received_log
          else
            current_log
          end

        merged_state = %{
          new_state
          | log: Log.replace(state.log, merged_log),
            op_number: max(state.op_number, do_view_change.op_number),
            commit_number: max(state.commit_number, do_view_change.commit_number),
            # Primary transitions to normal
            status: :normal
        }

        # Send START-VIEW to all replicas
        start_view_msg = %StartView{
          view: state.view_number,
          log: Log.get_all(merged_state.log),
          op_number: merged_state.op_number,
          commit_number: merged_state.commit_number
        }

        Enum.each(state.replicas, &Comms.send_to(state.comms, &1, start_view_msg))

        # Restart timers since we're now primary
        final_state = start_timers(merged_state)

        {:noreply, final_state}
      else
        {:noreply, new_state}
      end
    else
      {:noreply, state}
    end
  end

  defp start_view_impl(start_view, state) do
    if start_view.view >= state.view_number do
      # Update state with new view information
      new_state = %{
        state
        | view_number: start_view.view,
          status: :normal,
          log: Log.replace(state.log, start_view.log),
          op_number: start_view.op_number,
          commit_number: start_view.commit_number,
          view_change_votes: %{}
      }

      # Send VIEW-CHANGE-OK to new primary
      new_primary = primary_for_view(start_view.view, state.replicas, state.comms)

      Comms.send_to(state.comms, new_primary, %ViewChangeOk{
        view: start_view.view,
        from: Comms.node_id(state.comms)
      })

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  defp view_change_ok_impl(view_change_ok, state) do
    if primary?(state) and view_change_ok.view == state.view_number do
      # View change complete for this replica
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  # State Transfer Message Implementations

  defp get_state_impl(v, state) do
    # Send current state to requesting replica
    new_state_msg = %NewState{
      view: state.view_number,
      log: Log.get_all(state.log),
      op_number: state.op_number,
      commit_number: state.commit_number,
      state_machine_state: StateMachine._get_state(state.state_machine)
    }

    Comms.send_to(state.comms, v.sender, new_state_msg)

    {:noreply, state}
  end

  defp new_state_impl(new_state, state) do
    if new_state.view >= state.view_number do
      # Update state with received information
      new_state_machine =
        StateMachine._set_state(state.state_machine, new_state.state_machine_state)

      updated_state = %{
        state
        | view_number: new_state.view,
          log: Log.replace(state.log, new_state.log),
          op_number: new_state.op_number,
          commit_number: new_state.commit_number,
          state_machine: new_state_machine
      }

      {:noreply, updated_state}
    else
      {:noreply, state}
    end
  end

  # Control Message Implementations

  defp heartbeat_impl(_heartbeat, state) do
    # Heartbeat received, replica is alive - reset inactivity timer
    new_state = reset_primary_inactivity_timer(state)
    {:noreply, new_state}
  end

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

  defp primary?(%{comms: comms} = state) do
    Comms.node_id(comms) == primary(state)
  end

  defp primary(state), do: primary_for_view(state.view_number, state.replicas, state.comms)

  defp primary_for_view(view_number, replicas, comms) do
    all_replicas = [Comms.node_id(comms) | MapSet.to_list(replicas)]
    sorted_replicas = Enum.sort(all_replicas)
    replica_count = length(sorted_replicas)

    if replica_count > 0 do
      Enum.at(sorted_replicas, rem(view_number, replica_count))
    else
      self()
    end
  end

  defp quorum?(state) do
    # +1 for self
    replica_count = MapSet.size(state.replicas) + 1
    replica_count > div(state.cluster_size, 2)
  end

  defp increment_op_number(state), do: Map.update!(state, :op_number, &(&1 + 1))

  # Timer management functions
  defp start_timers(state) do
    # Start heartbeat timer if we're primary
    heartbeat_ref =
      if primary?(state) do
        Process.send_after(self(), :heartbeat_tick, state.heartbeat_interval)
      else
        nil
      end

    # Start primary inactivity timer if we're backup
    inactivity_ref =
      if not primary?(state) do
        Process.send_after(self(), :primary_inactivity_timeout, state.primary_inactivity_timeout)
      else
        nil
      end

    %{state | heartbeat_timer_ref: heartbeat_ref, primary_inactivity_timer_ref: inactivity_ref}
  end

  defp reset_primary_inactivity_timer(state) do
    # Cancel existing timer
    if state.primary_inactivity_timer_ref do
      Process.cancel_timer(state.primary_inactivity_timer_ref)
    end

    # Start new timer if we're backup
    new_ref =
      if not primary?(state) do
        Process.send_after(self(), :primary_inactivity_timeout, state.primary_inactivity_timeout)
      else
        nil
      end

    %{state | primary_inactivity_timer_ref: new_ref}
  end

  defp start_heartbeat_timer(state) do
    # Cancel existing timer
    if state.heartbeat_timer_ref do
      Process.cancel_timer(state.heartbeat_timer_ref)
    end

    # Start new timer if we're primary
    new_ref =
      if primary?(state) do
        Process.send_after(self(), :heartbeat_tick, state.heartbeat_interval)
      else
        nil
      end

    %{state | heartbeat_timer_ref: new_ref}
  end

  # Section 4: Router

  def handle_call(:dump, from, state), do: dump_impl(from, state)

  def handle_call({:update, kv}, from, state), do: update_impl(kv, from, state)

  def handle_call({:connect, to_who}, from, state), do: connect_impl(to_who, from, state)

  def handle_call({:client_request, operation}, from, state),
    do: client_request_impl(operation, from, state)

  def handle_call({:client_request, operation, client_pid, request_id}, from, state),
    do: client_request_impl(operation, client_pid, request_id, from, state)

  def handle_cast({:vsr, %type{} = msg}, state) do
    case type do
      ClientRequest -> client_request_impl(msg, state)
      Prepare -> prepare_impl(msg, state)
      PrepareOk -> prepare_ok_impl(msg, state)
      Commit -> commit_impl(msg, state)
      StartViewChange -> start_view_change_impl(msg, state)
      StartViewChangeAck -> start_view_change_ack_impl(msg, state)
      DoViewChange -> do_view_change_impl(msg, state)
      StartView -> start_view_impl(msg, state)
      ViewChangeOk -> view_change_ok_impl(msg, state)
      GetState -> get_state_impl(msg, state)
      NewState -> new_state_impl(msg, state)
      Heartbeat -> heartbeat_impl(msg, state)
    end
  end

  def handle_cast(:start_view_change, state) do
    # Manually triggered view change (e.g., from timeout or API call)
    start_manual_view_change(state)
  end

  defp start_manual_view_change(state) do
    # Increment view and transition to view change status
    new_view = state.view_number + 1

    # Create and broadcast START-VIEW-CHANGE message
    start_view_change_msg = %StartViewChange{
      view: new_view,
      replica: Comms.node_id(state.comms)
    }

    # Send to all replicas (including self for consistency)
    Enum.each(state.replicas, &Comms.send_to(state.comms, &1, start_view_change_msg))

    # Also send to self to process it
    GenServer.cast(self(), {:vsr, start_view_change_msg})

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state),
    do: disconnect_impl(ref, pid, state)

  def handle_info(:heartbeat_tick, state) do
    # Primary sends heartbeats to all replicas
    if primary?(state) do
      heartbeat_msg = %Heartbeat{}
      Enum.each(state.replicas, &Comms.send_to(state.comms, &1, heartbeat_msg))

      # Restart heartbeat timer
      new_state = start_heartbeat_timer(state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info(:primary_inactivity_timeout, state) do
    # Backup detected primary inactivity - trigger view change
    if not primary?(state) and state.status == :normal do
      start_manual_view_change(state)
    else
      {:noreply, state}
    end
  end
end
