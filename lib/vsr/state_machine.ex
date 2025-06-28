defprotocol Vsr.StateMachine do
  @moduledoc """
  Protocol for abstract state machine operations in VSR.

  This protocol allows different state machine implementations to be used
  with the VSR consensus algorithm, enabling flexibility for various
  application domains (key-value stores, databases, file systems, etc.).
  """

  @type operation :: term()
  @type state :: term()
  @type result :: term()

  @doc """
  Apply an operation to the state machine.

  Returns the updated state machine and the operation result.
  The result can be used for client replies.
  """
  @spec apply_operation(state_machine :: t(), operation()) :: {t(), result()}
  def apply_operation(state_machine, operation)

  @doc """
  Get the current state of the state machine.

  Used during state transfer to serialize the current state.
  Returns the internal state that can be used with set_state/2.
  """
  @spec get_state(state_machine :: t()) :: state()
  def get_state(state_machine)

  @doc """
  Set the state of the state machine.

  Used during state transfer to restore state from another replica.
  The state should be in the same format returned by get_state/1.
  """
  @spec set_state(state_machine :: t(), state()) :: t()
  def set_state(state_machine, state)

  @doc """
  Create a new instance of the state machine.

  Used during replica initialization to create a fresh state machine.
  """
  @spec new(opts :: keyword()) :: t()
  def new(opts \\ [])
end
