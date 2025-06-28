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
  @spec new(keyword()) :: t()
  def new(opts \\ [])

  @doc """
  Append an entry to the log.

  Returns the updated log.
  """
  @spec append(t(), view(), op_number(), operation(), sender_id()) :: t()
  def append(log, view, op_number, operation, sender_id)

  @doc """
  Get an entry at the specified operation number.

  Returns `{:ok, entry}` if found, `{:error, :not_found}` otherwise.
  """
  @spec get(t(), op_number()) :: {:ok, log_entry()} | {:error, :not_found}
  def get(log, op_number)

  @doc """
  Get all entries in the log.

  Returns a list of log entries in order.
  """
  @spec get_all(t()) :: [log_entry()]
  def get_all(log)

  @doc """
  Get entries from the specified operation number onwards.

  Returns a list of log entries from op_number to the end.
  """
  @spec get_from(t(), op_number()) :: [log_entry()]
  def get_from(log, op_number)

  @doc """
  Get the length of the log (number of entries).
  """
  @spec length(t()) :: non_neg_integer()
  def length(log)

  @doc """
  Replace the entire log with new entries.

  Used during state transfer and view changes.
  """
  @spec replace(t(), [log_entry()]) :: t()
  def replace(log, entries)

  @doc """
  Clear all entries from the log.
  """
  @spec clear(t()) :: t()
  def clear(log)
end
