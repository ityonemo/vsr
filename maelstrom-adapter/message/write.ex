defmodule Maelstrom.Message.Write do
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

  defmodule Ok do
    @moduledoc """
    write_ok message body sent in response to write message.
    """

    @derive [JSON.Encoder]
    @type t :: %__MODULE__{
            type: :write_ok,
            in_reply_to: non_neg_integer()
          }

    @enforce_keys [:in_reply_to]

    defstruct @enforce_keys ++ [type: :write_ok]
  end

  def reply(msg, :ok) do
    # Write success replies
    %Ok{
      in_reply_to: msg.msg_id
    }
  end

  def reply(msg, {:error, reason}) do
    # Write error
    %Maelstrom.Message.Error{
      in_reply_to: msg.msg_id,
      code: 13,
      text: "write failed: #{reason}"
    }
  end
end
