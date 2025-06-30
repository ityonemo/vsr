defmodule Vsr do
  use GenServer
  require Logger
  alias Vsr.Log
  alias Vsr.Log.Entry
  alias Vsr.Message
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
    state_machine_spec = Keyword.fetch!(opts, :state_machine)

    {sm_mod, sm_opts} =
      case state_machine_spec do
        {mod, opts} -> {mod, opts}
        mod when is_atom(mod) -> {mod, []}
      end

    state = %__MODULE__{
      view_number: 0,
      status: :normal,
      op_number: 0,
      commit_number: 0,
      log: log,
      replicas: MapSet.new(),
      state_machine: sm_mod._new(self(), sm_opts),
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

  defp connect_impl(target_replica_pid, _from, state) do
    # Monitor the target replica
    Process.monitor(target_replica_pid)

    # Add to connected replicas
    new_replicas = MapSet.put(state.replicas, target_replica_pid)

    new_state = %{state | replicas: new_replicas}

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
    requires_linearized = StateMachine._require_linearized?(state.state_machine, operation)
    read_only = StateMachine._read_only?(state.state_machine, operation)

    cond do
      requires_linearized and has_quorum ->
        # do the linearized operation.
        client_request_linearized(read_only, operation, from, state)

      read_only or not requires_linearized ->
        # do the read-only operation without the quorum.
        {new_state_machine, reply} = StateMachine._apply_operation(state.state_machine, operation)
        {:reply, {:ok, reply}, %{state | state_machine: new_state_machine}}

      :else ->
        # TODO: convert this into a proper quorum exception.
        {:reply, {:error, :quorum}, state}
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
          %ClientRequest{operation: operation, from: from, read_only: read_only},
          state
        )

      :else ->
        # send the client request to the primary
        primary_pid = primary(state)

        Message.vsr_send(primary_pid, %ClientRequest{
          operation: operation,
          from: from,
          read_only: read_only
        })

        {:noreply, state}
    end
  end

  # client request.  Received by the primary replica.
  defp client_request_impl(
         %ClientRequest{operation: operation, from: from, read_only: true},
         state
       ) do
    # If read-only, we can reply immediately
    {new_state_machine, reply} = StateMachine._apply_operation(state.state_machine, operation)
    GenServer.reply(from, {:ok, reply})
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
    Enum.each(new_state.replicas, &Message.vsr_send(&1, prepare_msg))

    # Check if we have quorum immediately (for single replica or immediate majority)
    new_state = maybe_commit_operation(new_state, new_state.op_number)

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

      send_prepare_ok(new_state, prepare)

      {:noreply, new_state}
    else
      {:op, _} ->
        # do nothing, we already have the operation but respond with ok.
        send_prepare_ok(state, prepare)
        {:noreply, state}

      {:view, _} ->
        Logger.warning(
          "Received prepare with old view #{prepare.view}, current view #{state.view_number}"
        )

        {:noreply, state}
    end
  end

  defp send_prepare_ok(state, prepare) do
    primary_pid = primary(state)

    Message.vsr_send(primary_pid, %PrepareOk{
      view: prepare.view,
      op_number: prepare.op_number,
      replica: self()
    })
  end

  defp prepare_ok_impl(prepare_ok, state) do
    if primary?(state) and prepare_ok.view == state.view_number do
      new_state = increment_ok_count(state, prepare_ok.op_number)
      new_state = maybe_commit_operation(new_state, prepare_ok.op_number)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  defp increment_ok_count(%{prepare_ok_count: ok_count} = state, op_number) do
    count = Map.get(ok_count, op_number, 0) + 1
    %{state | prepare_ok_count: Map.put(ok_count, op_number, count)}
  end

  defp maybe_commit_operation(state, op_number) do
    current_count = Map.get(state.prepare_ok_count, op_number, 0)
    # +1 for self (primary)
    replica_count = MapSet.size(state.replicas) + 1

    # Check if we have majority
    if current_count > div(replica_count, 2) do
      # Majority received, commit operation and send commit messages
      new_commit_number = max(state.commit_number, op_number)

      # Apply all operations up to commit point and send client replies
      log_entries = Log.get_all(state.log)

      {new_state_machine, _} =
        apply_operations_and_send_replies(
          log_entries,
          state.state_machine,
          state.commit_number,
          new_commit_number
        )

      # Send commit messages to connected replicas
      commit_message = %Commit{
        view: state.view_number,
        commit_number: new_commit_number
      }

      Enum.each(state.replicas, &Message.vsr_send(&1, commit_message))

      %{
        state
        | commit_number: new_commit_number,
          state_machine: new_state_machine
      }
    else
      state
    end
  end

  defp apply_operations_and_send_replies(
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
    {final_state_machine, _results} =
      Enum.reduce(operations_to_commit, {state_machine, []}, fn entry, {sm, results} ->
        {new_sm, result} = StateMachine._apply_operation(sm, entry.operation)

        # Send reply to client if this is a client request
        if entry.sender_id do
          GenServer.reply(entry.sender_id, {:ok, result})
        end

        {new_sm, [result | results]}
      end)

    {final_state_machine, :ok}
  end

  defp commit_impl(commit, state) do
    if commit.view == state.view_number and commit.commit_number > state.commit_number do
      # Apply all operations up to commit point
      log_entries = Log.get_all(state.log)

      {new_state_machine, _} =
        apply_operations_and_send_replies(
          log_entries,
          state.state_machine,
          state.commit_number,
          commit.commit_number
        )

      new_state = %{
        state
        | commit_number: commit.commit_number,
          state_machine: new_state_machine
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

      # Send acknowledgment
      Message.vsr_send(start_view_change.replica, %StartViewChangeAck{
        view: start_view_change.view,
        replica: self()
      })

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  defp start_view_change_ack_impl(ack, state) do
    if ack.view == state.view_number and state.status == :view_change do
      # Count view change votes
      votes = Map.update(state.view_change_votes, ack.view, [ack.replica], &[ack.replica | &1])
      new_state = %{state | view_change_votes: votes}

      # Check if we have enough votes to proceed
      vote_count = length(Map.get(votes, ack.view, []))
      total_replicas = MapSet.size(state.replicas) + 1

      if vote_count > div(total_replicas, 2) do
        # Enough votes, send DO-VIEW-CHANGE to new primary
        new_primary = primary_for_view(ack.view, state.replicas)

        Message.vsr_send(new_primary, %DoViewChange{
          view: ack.view,
          log: Log.get_all(state.log),
          last_normal_view: state.last_normal_view,
          op_number: state.op_number,
          commit_number: state.commit_number,
          from: self()
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
      # Collect view change data and update log if necessary
      current_log = Log.get_all(state.log)
      received_log = do_view_change.log

      # Use the log with higher op_number or more recent view
      new_log =
        if do_view_change.op_number > state.op_number do
          received_log
        else
          current_log
        end

      new_state = %{
        state
        | log: Log.replace(state.log, new_log),
          op_number: max(state.op_number, do_view_change.op_number),
          commit_number: max(state.commit_number, do_view_change.commit_number)
      }

      # Send START-VIEW to all replicas
      start_view_msg = %StartView{
        view: state.view_number,
        log: Log.get_all(new_state.log),
        op_number: new_state.op_number,
        commit_number: new_state.commit_number
      }

      Enum.each(state.replicas, &Message.vsr_send(&1, start_view_msg))

      {:noreply, new_state}
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
      new_primary = primary_for_view(start_view.view, state.replicas)

      Message.vsr_send(new_primary, %ViewChangeOk{
        view: start_view.view,
        from: self()
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

  defp get_state_impl(get_state, state) do
    # Send current state to requesting replica
    new_state_msg = %NewState{
      view: state.view_number,
      log: Log.get_all(state.log),
      op_number: state.op_number,
      commit_number: state.commit_number,
      state_machine_state: StateMachine._get_state(state.state_machine)
    }

    Message.vsr_send(get_state.sender, new_state_msg)

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
    # Heartbeat received, replica is alive
    {:noreply, state}
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

  defp primary?(state), do: self() == primary_for_view(state.view_number, state.replicas)

  defp primary(state), do: primary_for_view(state.view_number, state.replicas)

  defp primary_for_view(view_number, replicas) do
    all_replicas = [self() | MapSet.to_list(replicas)]
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

  def handle_info({:DOWN, ref, :process, pid, _reason}, state),
    do: disconnect_impl(ref, pid, state)
end
