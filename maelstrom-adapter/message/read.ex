defmodule Maelstrom.Message.Read do
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
    read_ok message body sent in response to read message.
    """

    @derive [JSON.Encoder]
    @type t :: %__MODULE__{
            type: :read_ok,
            in_reply_to: non_neg_integer(),
            value: term()
          }

    @enforce_keys [:in_reply_to, :value]

    defstruct @enforce_keys ++ [type: :read_ok]
  end

  def reply(msg, {:ok, value}) do
    # Read success replies include the value
    %Ok{
      in_reply_to: msg.msg_id,
      value: value
    }
  end

  def reply(msg, {:error, :not_found}) do
    # Read error for missing key - should be an Error message
    %Maelstrom.Message.Error{
      in_reply_to: msg.msg_id,
      code: 20,
      text: "key not found"
    }
  end
end
