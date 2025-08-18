use Protoss

defprotocol Vsr.Log do
  @moduledoc """
  Protocol for abstract log storage in VSR.

  This protocol allows different storage backends to be used
  for the VSR operation log, enabling flexibility in deployment
  scenarios (in-memory, persistent, distributed, etc.).
  """

  alias Vsr.Log.Entry

  @type log_entry :: Entry.t()

  @doc """
  Append an entry to the log.

  Returns the updated log.
  """
  def append(log, t)

  @doc """
  Fetch an entry at the specified operation number.

  Returns `{:ok, entry}` if found, `{:error, :not_found}` otherwise.
  """
  def fetch(log, op_number)

  @doc """
  Get all entries in the log.

  Returns a list of log entries in order.
  """
  def get_all(log)

  @doc """
  Get entries from the specified operation number onwards.

  Returns a list of log entries from op_number to the end.
  """
  def get_from(log, op_number)

  @doc """
  Get the length of the log (number of entries).
  """
  def length(log)

  @doc """
  Replace the entire log with new entries.

  Used during state transfer and view changes.
  """
  def replace(log, entries)

  @doc """
  Clear all entries from the log.
  """
  def clear(log)
end

defmodule Vsr.Log.Entry do
  @derive JSON.Encoder
  defstruct [:view, :op_number, :operation, :sender_id]

  @type t :: %__MODULE__{
          view: non_neg_integer(),
          op_number: non_neg_integer(),
          operation: term(),
          sender_id: term()
        }
end
