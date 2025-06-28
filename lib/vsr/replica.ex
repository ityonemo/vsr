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

