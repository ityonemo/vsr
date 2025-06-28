defmodule Vsr.Log do
  @moduledoc """
  Protocol for abstract log storage in VSR.

  This protocol allows different storage backends to be used
  for the VSR operation log, enabling flexibility in deployment
  scenarios (in-memory, persistent, distributed, etc.).
  """

  @type t :: term()
  @type view :: non_neg_integer()
  @type op_number :: non_neg_integer()
  @type operation :: term()
  @type sender_id :: pid()
  @type log_entry :: {view(), op_number(), operation(), sender_id()}

  @doc """
  Create a new log instance.
  """
  @callback new(keyword()) :: t()

  @doc """
  Append an entry to the log.

  Returns the updated log.
  """
  @callback append(t(), view(), op_number(), operation(), sender_id()) :: t()

  @doc """
  Get an entry at the specified operation number.

  Returns `{:ok, entry}` if found, `{:error, :not_found}` otherwise.
  """
  @callback get(t(), op_number()) :: {:ok, log_entry()} | {:error, :not_found}

  @doc """
  Get all entries in the log.

  Returns a list of log entries in order.
  """
  @callback get_all(t()) :: [log_entry()]

  @doc """
  Get entries from the specified operation number onwards.

  Returns a list of log entries from op_number to the end.
  """
  @callback get_from(t(), op_number()) :: [log_entry()]

  @doc """
  Get the length of the log (number of entries).
  """
  @callback length(t()) :: non_neg_integer()

  @doc """
  Replace the entire log with new entries.

  Used during state transfer and view changes.
  """
  @callback replace(t(), [log_entry()]) :: t()

  @doc """
  Clear all entries from the log.
  """
  @callback clear(t()) :: t()

  # Convenience functions that delegate to the implementation
  def new(log_impl, opts \\ []), do: log_impl.new(opts)

  def append(log, view, op_number, operation, sender_id),
    do: log.__struct__.append(log, view, op_number, operation, sender_id)

  def get(log, op_number), do: log.__struct__.get(log, op_number)
  def get_all(log), do: log.__struct__.get_all(log)
  def get_from(log, op_number), do: log.__struct__.get_from(log, op_number)
  def length(log), do: log.__struct__.length(log)
  def replace(log, entries), do: log.__struct__.replace(log, entries)
  def clear(log), do: log.__struct__.clear(log)
end
