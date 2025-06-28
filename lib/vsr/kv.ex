defmodule Vsr.KV do
  @moduledoc """
  Key-Value store client that wraps Vsr.Replica operations.

  Provides a clean API for key-value operations that are backed by
  VSR consensus. This module acts as a client interface that sends
  operations to a Vsr.Replica instance.
  """

  alias Vsr.Replica
  alias Vsr.Messages

  defstruct [:replica_pid]

  @type t :: %__MODULE__{
          replica_pid: pid()
        }

  @doc """
  Create a new KV store client connected to a replica.

  ## Options
  - `:replica_pid` - PID of the Vsr.Replica to connect to
  - `:configuration` - List of replica PIDs for cluster setup
  - `:blocking` - Whether operations should block (for testing)
  """
  def new(opts \\ []) do
    replica_pid = Keyword.get(opts, :replica_pid)

    if replica_pid do
      %__MODULE__{replica_pid: replica_pid}
    else
      # Start a new replica if none provided
      configuration = Keyword.get(opts, :configuration, [])
      blocking = Keyword.get(opts, :blocking, false)

      {:ok, replica_pid} =
        Replica.start_link(
          configuration: configuration,
          blocking: blocking,
          state_machine: Vsr.KVStateMachine,
          name: nil
        )

      %__MODULE__{replica_pid: replica_pid}
    end
  end

  @doc """
  Store a key-value pair.
  """
  def put(%__MODULE__{replica_pid: replica_pid}, key, value) do
    operation = {:put, key, value}
    request_id = make_ref()
    client_id = self()

    Replica.client_request(replica_pid, operation, client_id, request_id)

    # Wait for reply
    receive do
      %Messages.ClientReply{request_id: ^request_id, result: result} ->
        result
    after
      5000 ->
        {:error, :timeout}
    end
  end

  @doc """
  Retrieve a value by key.
  """
  def get(%__MODULE__{replica_pid: replica_pid}, key) do
    operation = {:get, key}
    request_id = make_ref()
    client_id = self()

    Replica.client_request(replica_pid, operation, client_id, request_id)

    # Wait for reply
    receive do
      %Messages.ClientReply{request_id: ^request_id, result: result} ->
        result
    after
      5000 ->
        {:error, :timeout}
    end
  end

  @doc """
  Delete a key-value pair.
  """
  def delete(%__MODULE__{replica_pid: replica_pid}, key) do
    operation = {:delete, key}
    request_id = make_ref()
    client_id = self()

    Replica.client_request(replica_pid, operation, client_id, request_id)

    # Wait for reply
    receive do
      %Messages.ClientReply{request_id: ^request_id, result: result} ->
        result
    after
      5000 ->
        {:error, :timeout}
    end
  end

  @doc """
  Connect this KV store's replica to another replica for clustering.
  """
  def connect(%__MODULE__{replica_pid: replica_pid}, target_replica_pid) do
    Replica.connect(replica_pid, target_replica_pid)
  end

  @doc """
  Get the underlying replica PID for advanced operations.
  """
  def replica_pid(%__MODULE__{replica_pid: replica_pid}), do: replica_pid

  @doc """
  Dump the replica state for debugging.
  """
  def dump(%__MODULE__{replica_pid: replica_pid}) do
    Replica.dump(replica_pid)
  end
end

defmodule Vsr.KVStateMachine do
  @moduledoc """
  Key-Value state machine implementation for Vsr.StateMachine protocol.

  This is the actual state machine that handles the storage operations
  within the VSR consensus system.
  """

  defstruct [:table_id]

  @type t :: %__MODULE__{
          table_id: :ets.tid()
        }

  @type operation ::
          {:put, key :: term(), value :: term()}
          | {:get, key :: term()}
          | {:delete, key :: term()}
  @type result :: :ok | {:ok, term()} | {:error, :not_found}

  def new(_opts \\ []) do
    table_id = :ets.new(:vsr_kv, [:set, :private])
    %__MODULE__{table_id: table_id}
  end

  def apply_operation(%__MODULE__{table_id: table_id} = kv, {:put, key, value}) do
    :ets.insert(table_id, {key, value})
    {kv, :ok}
  end

  def apply_operation(%__MODULE__{table_id: table_id} = kv, {:get, key}) do
    result =
      case :ets.lookup(table_id, key) do
        [{^key, value}] -> {:ok, value}
        [] -> {:error, :not_found}
      end

    {kv, result}
  end

  def apply_operation(%__MODULE__{table_id: table_id} = kv, {:delete, key}) do
    :ets.delete(table_id, key)
    {kv, :ok}
  end

  def apply_operation(kv, _unknown_operation) do
    {kv, {:error, :unknown_operation}}
  end

  def get_state(%__MODULE__{table_id: table_id}) do
    :ets.tab2list(table_id)
  end

  def set_state(%__MODULE__{table_id: table_id} = kv, state) when is_list(state) do
    # Clear existing state
    :ets.delete_all_objects(table_id)
    # Insert new state
    :ets.insert(table_id, state)
    kv
  end

  @doc """
  Clean up the ETS table when the KV store is no longer needed.
  """
  def destroy(%__MODULE__{table_id: table_id}) do
    :ets.delete(table_id)
    :ok
  end
end

defimpl Vsr.StateMachine, for: Vsr.KVStateMachine do
  def new(opts), do: Vsr.KVStateMachine.new(opts)

  def apply_operation(kv, operation), do: Vsr.KVStateMachine.apply_operation(kv, operation)

  def get_state(kv), do: Vsr.KVStateMachine.get_state(kv)

  def set_state(kv, state), do: Vsr.KVStateMachine.set_state(kv, state)
end
