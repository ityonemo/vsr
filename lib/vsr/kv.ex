defmodule Vsr.KV do
  @moduledoc """
  Key-Value store implementation of the Vsr.StateMachine protocol.

  Provides a simple key-value storage backend using ETS tables,
  suitable for demonstrating VSR consensus on basic CRUD operations.
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

defimpl Vsr.StateMachine, for: Vsr.KV do
  def new(state_machine_impl, opts), do: Vsr.KV.new(opts)

  def apply_operation(kv, operation), do: Vsr.KV.apply_operation(kv, operation)

  def get_state(kv), do: Vsr.KV.get_state(kv)

  def set_state(kv, state), do: Vsr.KV.set_state(kv, state)
end
