defmodule Maelstrom.Message.Init do
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

  defmodule Ok do
    @moduledoc """
    init_ok message body sent in response to init message.
    """

    @derive [JSON.Encoder]
    @type t :: %__MODULE__{
            type: :init_ok,
            in_reply_to: non_neg_integer()
          }

    @enforce_keys [:in_reply_to]

    defstruct @enforce_keys ++ [type: :init_ok]
  end

  def reply(msg, _response) do
    # Init replies are simple acknowledgments
    %Ok{
      in_reply_to: msg.msg_id
    }
  end
end
