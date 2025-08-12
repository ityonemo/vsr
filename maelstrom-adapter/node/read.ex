defmodule Maelstrom.Node.Read do
  @moduledoc """
  Read message body for key-value read operations.
  """

  @derive [JSON.Encoder]
  @type t :: %__MODULE__{
          type: :read,
          msg_id: non_neg_integer(),
          key: String.t()
        }

  defstruct [:msg_id, :key, type: :read]

  use Maelstrom.Node.Message, type: :read_ok, value: term()
end
