defmodule Vsr.EtsLog do
  @moduledoc """
  ETS-based implementation of the Vsr.Log protocol.

  Provides fast in-memory log storage using Erlang Term Storage.
  Each log is backed by an ETS table with operation numbers as keys.
  """

  @behaviour Vsr.Log

  defstruct [:table_id, :length]

  @type t :: %__MODULE__{
          table_id: :ets.tid(),
          length: non_neg_integer()
        }

  @impl Vsr.Log
  def new(_opts \\ []) do
    table_id = :ets.new(:vsr_log, [:ordered_set, :private])
    %__MODULE__{table_id: table_id, length: 0}
  end

  @impl Vsr.Log
  def append(
        %__MODULE__{table_id: table_id, length: current_length} = log,
        view,
        op_number,
        operation,
        sender_id
      ) do
    entry = {view, op_number, operation, sender_id}
    :ets.insert(table_id, {op_number, entry})
    %{log | length: max(current_length, op_number)}
  end

  @impl Vsr.Log
  def get(%__MODULE__{table_id: table_id}, op_number) do
    case :ets.lookup(table_id, op_number) do
      [{^op_number, entry}] -> {:ok, entry}
      [] -> {:error, :not_found}
    end
  end

  @impl Vsr.Log
  def get_all(%__MODULE__{table_id: table_id}) do
    table_id
    |> :ets.tab2list()
    |> Enum.sort_by(fn {op_number, _entry} -> op_number end)
    |> Enum.map(fn {_op_number, entry} -> entry end)
  end

  @impl Vsr.Log
  def get_from(%__MODULE__{table_id: table_id}, op_number) do
    table_id
    |> :ets.tab2list()
    |> Enum.filter(fn {op_num, _entry} -> op_num >= op_number end)
    |> Enum.sort_by(fn {op_num, _entry} -> op_num end)
    |> Enum.map(fn {_op_num, entry} -> entry end)
  end

  @impl Vsr.Log
  def length(%__MODULE__{length: length}), do: length

  @impl Vsr.Log
  def replace(%__MODULE__{table_id: table_id} = log, entries) do
    # Clear existing entries
    :ets.delete_all_objects(table_id)

    # Insert new entries
    new_length =
      Enum.reduce(entries, 0, fn {view, op_number, operation, sender_id}, acc ->
        entry = {view, op_number, operation, sender_id}
        :ets.insert(table_id, {op_number, entry})
        max(acc, op_number)
      end)

    %{log | length: new_length}
  end

  @impl Vsr.Log
  def clear(%__MODULE__{table_id: table_id} = log) do
    :ets.delete_all_objects(table_id)
    %{log | length: 0}
  end

  @doc """
  Clean up the ETS table when the log is no longer needed.
  """
  def destroy(%__MODULE__{table_id: table_id}) do
    :ets.delete(table_id)
    :ok
  end
end

defimpl Vsr.Log, for: Vsr.EtsLog do
  def new(opts), do: Vsr.EtsLog.new(opts)

  def append(log, view, op_number, operation, sender_id),
    do: Vsr.EtsLog.append(log, view, op_number, operation, sender_id)

  def get(log, op_number), do: Vsr.EtsLog.get(log, op_number)
  def get_all(log), do: Vsr.EtsLog.get_all(log)
  def get_from(log, op_number), do: Vsr.EtsLog.get_from(log, op_number)
  def length(log), do: Vsr.EtsLog.length(log)
  def replace(log, entries), do: Vsr.EtsLog.replace(log, entries)
  def clear(log), do: Vsr.EtsLog.clear(log)
end
