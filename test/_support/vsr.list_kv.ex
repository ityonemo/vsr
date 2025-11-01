defmodule Vsr.ListKv do
  @moduledoc """
  A simple VSR server implementation for testing that uses a list as durable storage
  and a key-value map as the materialized state machine.

  This module demonstrates how to implement the VsrServer behavior with:
  - List-based log storage (simulates durable storage)
  - Key-value cache as state machine
  - Standard GenServer communication
  """

  use VsrServer

  defstruct data: %{}

  @type t :: %__MODULE__{
          data: %{term() => term()}
        }

  # Client API
  def start_link(opts \\ []) do
    VsrServer.start_link(__MODULE__, opts)
  end

  # VsrServer.init callback - returns {:ok, log, state}
  def init(_opts) do
    # Empty list as initial log
    log = []
    # Empty KV cache as initial state
    state = %__MODULE__{}
    {:ok, log, state}
  end

  defp read_impl(key, state) do
    result = Map.get(state.data, key)
    {state, {:ok, result}}
  end

  defp write_impl(key, value, state) do
    new_data = Map.put(state.data, key, value)
    new_state = %{state | data: new_data}
    {new_state, :ok}
  end

  defp delete_impl(key, state) do
    new_data = Map.delete(state.data, key)
    new_state = %{state | data: new_data}
    {new_state, :ok}
  end

  defp cas_impl(key, old_value, new_value, state) do
    current_value = Map.get(state.data, key)

    if current_value == old_value do
      new_data = Map.put(state.data, key, new_value)
      new_state = %{state | data: new_data}
      {new_state, :ok}
    else
      {state, {:error, :cas_failed}}
    end
  end

  defp test_op_impl(data, state) do
    {state, {:ok, "test_result_#{data}"}}
  end

  defp increment_counter_impl(state) do
    current_counter = Map.get(state.data, :counter, 0)
    new_data = Map.put(state.data, :counter, current_counter + 1)
    new_state = %{state | data: new_data}
    {new_state, {:ok, current_counter + 1}}
  end

  # VSR commit callback - apply operations to the state machine
  def handle_commit({:read, key}, state), do: read_impl(key, state)
  def handle_commit({:write, key, value}, state), do: write_impl(key, value, state)
  def handle_commit({:delete, key}, state), do: delete_impl(key, state)

  def handle_commit({:cas, key, old_value, new_value}, state),
    do: cas_impl(key, old_value, new_value, state)

  def handle_commit({:test_op, data}, state), do: test_op_impl(data, state)
  def handle_commit(:increment_counter, state), do: increment_counter_impl(state)

  # Log callback implementations - required by VsrServer

  def log_append(log, entry) do
    log ++ [entry]
  end

  def log_fetch(log, op_number) do
    case Enum.find(log, fn entry -> entry.op_number == op_number end) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  def log_get_all(log) do
    log
  end

  def log_get_from(log, op_number) do
    Enum.filter(log, fn entry -> entry.op_number >= op_number end)
  end

  def log_length(log) do
    length(log)
  end

  def log_replace(_log, entries) do
    entries
  end

  def log_clear(_log) do
    []
  end

  # Client API convenience functions

  @doc """
  Reads a value from the key-value store.
  """
  def read(server, key) do
    GenServer.call(server, {:client_request, {:read, key}})
  end

  @doc """
  Writes a value to the key-value store.
  """
  def write(server, key, value) do
    GenServer.call(server, {:client_request, {:write, key, value}})
  end

  @doc """
  Deletes a key from the key-value store.
  """
  def delete(server, key) do
    GenServer.call(server, {:client_request, {:delete, key}})
  end

  @doc """
  Compare-and-swap operation on the key-value store.
  """
  def cas(server, key, old_value, new_value) do
    GenServer.call(server, {:client_request, {:cas, key, old_value, new_value}})
  end

  # VsrServer handle_call - required to handle client_request messages
  def handle_call({:client_request, operation}, from, state) do
    {:noreply, state, {:client_request, from, operation}}
  end

  # Support new client deduplication format with client_id and request_id
  def handle_call({:client_request, client_info, operation}, from, state) do
    {:noreply, state, {:client_request, Map.put(client_info, :reply_to, from), operation}}
  end

  def handle_call(:get_data, _from, state) do
    {:reply, state.data, state}
  end

  # Required VsrServer state management callbacks
  def get_state(state) do
    state.data
  end

  def set_state(state, new_data) do
    %{state | data: new_data}
  end

  # VsrServer send_reply callback for client deduplication
  def send_reply(client_info, reply, _vsr_state) when is_map(client_info) do
    # For client deduplication, extract reply_to from client_info
    case Map.get(client_info, :reply_to) do
      # No reply needed
      nil -> :ok
      reply_to -> GenServer.reply(reply_to, reply)
    end
  end

  # Handle old-style direct GenServer.from tuple
  def send_reply(from_tuple, reply, _vsr_state) when is_tuple(from_tuple) do
    GenServer.reply(from_tuple, reply)
  end
end
