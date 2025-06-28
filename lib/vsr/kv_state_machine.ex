defmodule Vsr.KVStateMachine do
  @moduledoc """
  Key-Value state machine implementation for VSR replicas.

  This module implements the StateMachine protocol and provides
  the actual state management for key-value operations within
  a VSR replica.
  """

  defstruct [:data]

  def new(_opts) do
    %__MODULE__{
  end

  defimpl Vsr.StateMachine, for: __MODULE__ do
    def new(state_machine, _opts) do
      %Vsr.KVStateMachine{data: %{}}
    end

    def apply_operation(state_machine, operation) do
      case operation do
        {:put, key, value} ->
          new_data = Map.put(state_machine.data, key, value)
          new_state_machine = %{state_machine | data: new_data}
          {new_state_machine, :ok}

        {:get, key} ->
          case Map.get(state_machine.data, key) do
            nil -> {state_machine, {:error, :not_found}}
            value -> {state_machine, {:ok, value}}
          end

        {:delete, key} ->
          new_data = Map.delete(state_machine.data, key)
          new_state_machine = %{state_machinedata}
          {new_state_machine, :ok}

        _ ->
          {state_machine, {:error, :unknown_operation}}
      end
    end

    def get_state(state_machine) do
      state_machine.data
    end

    def set_state(state_machine, new_data) do
      %{state_machine | data: new_data}
    end
  end
end
