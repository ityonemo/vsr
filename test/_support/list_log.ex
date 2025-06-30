defimpl Vsr.Log, for: List do
  @moduledoc """
  most-recent-first list implemenation of the Vsr.Log protocol

  Only use this for testing purposese, as it is not durable.

  This implementation is preferable when introspection of the Vsr state
  is desired.
  """

  def append(log, t), do: [t | log]

  def fetch(log, op_number) do
    if entry = Enum.find(log, &(&1.op_number == op_number)) do
      {:ok, entry}
    else
      :error
    end
  end

  @doc """
  Get all entries in the log.

  Returns a list of log entries in order.
  """
  def get_all(log), do: Enum.reverse(log)

  @doc """
  Get entries from the specified operation number onwards.

  Returns a list of log entries from op_number to the end.
  """
  def get_from(log, op_number) do
    Enum.reduce_while(log, [], fn entry, acc ->
      if entry.op_number >= op_number do
        {:cont, [entry | acc]}
      else
        {:halt, acc}
      end
    end)
  end

  @doc """
  Get the length of the log (number of entries).
  """
  def length(log), do: Kernel.length(log)

  @doc """
  Replace the entire log with new entries.

  Used during state transfer and view changes.
  """
  def replace(log, entries), do: Enum.reverse(entries)

  @doc """
  Clear all entries from the log.
  """
  def clear(log), do: []
end
