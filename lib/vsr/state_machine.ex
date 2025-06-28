defprotocol Vsr.StateMachine do
  @moduledoc """
  Protocol for pluggable state machines in VSR replicas.

  This protocol allows different state machine implementations to be
  used with VSR replicas, making the consensus algorithm truly modular.
  The state machine handles the actual business logic operations while
  VSR handles the distributed consensus.
  """

  @doc """
  Creates a new state machine instance with the given options.
  """
  def new(state_machine, opts \\ [])

  @doc """
  Applies an operation to the state machine and returns the new state
  and the operation result.

  Returns `{new_state_machine, result}` where:
  - `new_state_machine` is the updated state machine
  - `result` is the operation result to return to the client
  """
  def apply_operation(state_machine, operation)

  @doc """
  Gets the current state of the state machine.
  Used for state transfer between replicas.
  """
  def get_state(state_machine)

  @doc """
  Sets the state machine to a specific state.
  Used during state transfer from other replicas.
  """
  def set_state(state_machine, new_state)

  @doc """
  Creates a new state machine of the given implementation type.
  This is a convenience function for creating state machines.
  """
  def new(implementation_module, opts) when is_atom(implementation_module) do
    implementation_module.new(opts)
  end
end
