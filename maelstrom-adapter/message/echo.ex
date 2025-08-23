defmodule Maelstrom.Message.Echo do
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
    echo_ok message body sent in response to echo message.
    """

    @derive [JSON.Encoder]
    @type t :: %__MODULE__{
            type: :echo_ok,
            in_reply_to: non_neg_integer(),
            echo: term(),
            msg_id: non_neg_integer()
          }

    @enforce_keys [:in_reply_to, :echo, :msg_id]

    defstruct @enforce_keys ++ [type: :echo_ok]
  end

  def reply(msg, response) do
    # Echo replies should include the original echo value
    %Ok{
      in_reply_to: msg.msg_id,
      echo: msg.echo,
      msg_id: response[:msg_id] || 1
    }
  end
end
