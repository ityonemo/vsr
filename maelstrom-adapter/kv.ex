defmodule Maelstrom.Kv do
  @moduledoc """
  Linearizable Key-Value store state machine for Maelstrom testing.

  This module implements an in-memory key-value store that can be 
  reconstructed from the durable log. The log provides durability,
  while this state machine provides fast in-memory access.
  """

  use Vsr.StateMachine

  # Current key-value state (in-memory)
  defstruct [:state]

  @type t :: %__MODULE__{
          state: %{binary() => term()}
        }

  # StateMachine callbacks

  def _new(_replica_node_pid, _opts) do
    %__MODULE__{
      state: %{}
    }
  end

  def _apply_operation(state_machine, operation) do
    # for maelstrom, operations are lists, because these are encodable to JSON.
    case operation do
      ["read", key] ->
        handle_read(state_machine, key)

      ["write", key, value] ->
        handle_write(state_machine, key, value)

      ["cas", key, from, to] ->
        handle_cas(state_machine, key, from, to)
    end
  end

  def _read_only?(_state_machine, operation), do: match?(["read", _], operation)

  # All operations require linearizability in a consistent key-value store
  def _require_linearized?(_state_machine, _operation), do: true

  def _get_state(state_machine), do: state_machine.state

  def _set_state(state_machine, new_state), do: %{state_machine | state: new_state}

  # Operation handlers

  defp handle_read(state_machine, key) do
    {state_machine, Map.get(state_machine.state, key)}
  end

  defp handle_write(state_machine, key, value) do
    {%{state_machine | state: Map.put(state_machine.state, key, value)}, :ok}
  end

  defp handle_cas(state_machine, key, from, to)
       when :erlang.map_get(key, state_machine.state) == from do
    {%{state_machine | state: Map.replace!(state_machine.state, key, to)}, :ok}
  end

  defp handle_cas(state_machine, _key, _from, _to), do: {state_machine, nil}
end
