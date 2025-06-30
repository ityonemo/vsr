use Protoss

defprotocol Vsr.StateMachine do
  @moduledoc """
  Protocol for pluggable state machines in VSR replicas.

  This protocol allows different state machine implementations to be
  used with VSR replicas, making the consensus algorithm truly modular.
  The state machine handles the actual business logic operations while
  VSR handles the distributed consensus.
  """

  @doc """
  true if the operation must be linearizable.  If not, then
  the VSR replica will pick speed and use a stale read instead.
  """
  def _require_linearized?(state_machine, operation)

  @doc """
  true if the operation is read-only and does not change its
  state.  Read-only operations may be performed if the network
  does not have a quorum.
  """
  def _read_only?(state_machine, operation)

  @doc """
  Applies an operation to the state machine and returns the new state
  and the operation result.

  Returns `{new_state_machine, result}` where:
  - `new_state_machine` is the updated state machine
  - `result` is the operation result to return to the client
  """
  def _apply_operation(state_machine, operation)

  @doc """
  Gets the current state of the state machine.
  Used for state transfer between replicas.
  """
  def _get_state(state_machine)

  @doc """
  Sets the state machine to a specific state.
  Used during state transfer from other replicas.
  """
  def _set_state(state_machine, new_state)
after
  # generically, state machines must be initialized with a vsr instance.
  @callback _new(vsr:: pid, options :: keyword) :: t
end
