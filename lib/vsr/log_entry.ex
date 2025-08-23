defmodule Vsr.LogEntry do
  @moduledoc """
  Represents a single entry in the VSR log.

  Each entry contains the essential information needed for VSR consensus:
  - view: The view number when this operation was prepared
  - op_number: The operation number (sequence position in log)
  - operation: The actual operation to be applied
  - sender_id: ID of the client that sent this operation (for deduplication)
  """

  @enforce_keys [:view, :op_number, :operation, :sender_id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          view: non_neg_integer(),
          op_number: non_neg_integer(),
          operation: term(),
          sender_id: term()
        }
end
