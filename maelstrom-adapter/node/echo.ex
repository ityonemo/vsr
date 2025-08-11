defmodule Maelstrom.Node.Echo do
  @moduledoc """
  Echo message body for testing basic communication.
  """

  @derive [JSON.Encoder]
  @type t :: %__MODULE__{
          type: :echo,
          msg_id: non_neg_integer(),
          echo: term()
        }

  defstruct [:msg_id, :echo, type: :echo]

  defmodule Ok do
    @moduledoc """
    echo_ok message body sent in response to Echo message.
    """

    @derive [JSON.Encoder]
    @type t :: %__MODULE__{
            type: :echo_ok,
            msg_id: non_neg_integer(),
            echo: term(),
            in_reply_to: non_neg_integer()
          }

    defstruct [:in_reply_to, :msg_id, :echo, type: :echo_ok]
  end

  def reply(msg, msg_id, echo, io_target) do
    maelstrom = %Maelstrom.Comms{node_name: msg.dest, io_target: io_target}

    Maelstrom.Comms.send_reply(maelstrom, msg.src, %Ok{
      in_reply_to: msg.msg_id,
      msg_id: msg_id,
      echo: echo
    })
  end
end
