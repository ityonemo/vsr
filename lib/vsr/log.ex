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
  Get alldefprotocol Vsr.Log do
  @moduledoc \"""
  Protocol for abstract log storage in VSR.

  This protocol allows different storage backends to be used
  for the VSR operation log, enabling flexibility in deployment
  scenarios (in-memory, persistent, distributed, etc.).
  """

  @type view :: non_neg_integer()
  @type op_number :: non_neg_integer()
  @type operation :: term()
  @type sender_id :: pid()
  @type log_entry :: {view(), op_number(), operation(), sender_id()}

  @doc """
  Create a new log instance.
  """
  def new(log_impl, opts \\ [])

  @doc """
  Append an entry to the log.

  Returns the updated log.
  """
  def append(log, view, op_number, operation, sender_id)

  @doc """
  Get an entry at the specified operation number.

  Returns `{:ok, entry}` if found, `{:error, :not_found}` otherwise.
  """
  def get(log, op_number)

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
