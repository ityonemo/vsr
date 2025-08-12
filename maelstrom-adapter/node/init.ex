defmodule Maelstrom.Node.Init do
  @moduledoc """
  Init message body sent by Maelstrom to initialize a node.
  """

  @derive [JSON.Encoder]
  @type t :: %__MODULE__{
          type: :init,
          msg_id: non_neg_integer(),
          node_id: String.t(),
          node_ids: [String.t()]
        }

  defstruct [:msg_id, :node_id, :node_ids, type: :init]

  use Maelstrom.Node.Message, type: :init_ok
end
