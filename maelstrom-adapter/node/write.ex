defmodule Maelstrom.Node.Write do
  @moduledoc """
  Write message body for key-value write operations.
  """

  @derive [JSON.Encoder]
  @type t :: %__MODULE__{
          type: :write,
          msg_id: non_neg_integer(),
          key: String.t(),
          value: term()
        }

  defstruct [:msg_id, :key, :value, type: :write]

  use Maelstrom.Node.Message, type: :write_ok
end
