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

  defmodule Ok do
    @moduledoc """
    read_ok message body sent in response to Read message.
    """

    @derive [JSON.Encoder]
    @type t :: %__MODULE__{
            type: :read_ok,
            value: term(),
            in_reply_to: non_neg_integer()
          }

    defstruct [:in_reply_to, :value, type: :read_ok]
  end

  def reply(msg, value, io_target) do
    maelstrom = %Maelstrom.Comms{node_name: msg.dest, io_target: io_target}
    Maelstrom.Comms.send_reply(maelstrom, msg.src, %Ok{in_reply_to: msg.msg_id, value: value})
  end
end
