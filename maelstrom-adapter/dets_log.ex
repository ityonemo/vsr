defmodule Maelstrom.DetsLog do
  @moduledoc """
  DETS-based implementation of the Vsr.Log protocol.

  Provides durable log storage using Disk Erlang Term Storage.
  Each log is backed by a DETS table with operation numbers as keys.
  This ensures persistence across restarts, which is essential for 
  distributed consensus systems like VSR.
  """

  require Logger
  use Vsr.Log

  defstruct [:table_name, :dets_file]

  @type t :: %__MODULE__{
          table_name: :dets.table_name(),
          dets_file: String.t()
        }

  def _new(node_id, opts \\ []) do
    # Create unique DETS table name for this node's log
    table_name = String.to_atom("maelstrom_log_#{node_id}")
    dets_file = Keyword.get(opts, :dets_file, "#{node_id}_log.dets")

    # Ensure DETS directory exists
    dets_dir = Path.dirname(dets_file)
    File.mkdir_p!(dets_dir)

    # Open or create DETS table
    {:ok, ^table_name} = :dets.open_file(table_name, file: String.to_charlist(dets_file))

    %__MODULE__{
      table_name: table_name,
      dets_file: dets_file
    }
  end

  # Vsr.Log protocol implementation
  def append(%Maelstrom.DetsLog{table_name: table_name} = log, entry) do
    # Store the entry with its operation number as the key
    :ok = :dets.insert(table_name, {entry.op_number, entry})
    :ok = :dets.sync(table_name)
    log
  end

  def fetch(%Maelstrom.DetsLog{table_name: table_name}, op_number) do
    case :dets.lookup(table_name, op_number) do
      [{^op_number, entry}] -> {:ok, entry}
      [] -> {:error, :not_found}
    end
  end

  def get_all(%Maelstrom.DetsLog{table_name: table_name}) do
    case :dets.traverse(table_name, fn {_op_number, entry} ->
           {:continue, entry}
         end) do
      # Empty table
      [] ->
        []

      entries when is_list(entries) ->
        entries
        |> Enum.sort_by(& &1.op_number)

      {:error, _reason} ->
        []
    end
  end

  def get_from(%Maelstrom.DetsLog{table_name: table_name}, op_number) do
    # Get all entries first, then filter - simpler than dealing with DETS traverse skip semantics
    case :dets.traverse(table_name, fn {_op_num, entry} ->
           {:continue, entry}
         end) do
      # Empty table
      [] ->
        []

      entries when is_list(entries) ->
        entries
        |> Enum.filter(&(&1.op_number >= op_number))
        |> Enum.sort_by(& &1.op_number)

      {:error, _reason} ->
        []
    end
  end

  def length(%Maelstrom.DetsLog{table_name: table_name}) do
    case :dets.info(table_name, :size) do
      size when is_integer(size) -> size
      _ -> 0
    end
  end

  def replace(%Maelstrom.DetsLog{table_name: table_name} = log, entries) do
    # Clear existing entries
    :ok = :dets.delete_all_objects(table_name)

    Logger.debug("Replacing log entries: #{inspect entries}")

    # Insert new entries
    Enum.each(entries, fn entry ->
      :ok = :dets.insert(table_name, {entry.op_number, entry})
    end)

    :ok = :dets.sync(table_name)
    log
  end

  def clear(%Maelstrom.DetsLog{table_name: table_name} = log) do
    :ok = :dets.delete_all_objects(table_name)
    :ok = :dets.sync(table_name)
    log
  end
end
