defmodule Maelstrom.Node.Cas do
  @moduledoc """
  Compare-and-swap message body for atomic key-value operations.
  """

  @derive [JSON.Encoder]
  @type t :: %__MODULE__{
          type: :cas,
          msg_id: non_neg_integer(),
          key: String.t(),
          from: term(),
          to: term()
        }

  defstruct [:msg_id, :key, :from, :to, type: :cas]

  use Maelstrom.Node.Message, type: :cas_ok
end
