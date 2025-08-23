defmodule Maelstrom.Message.Cas do
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

  defmodule Ok do
    @moduledoc """
    cas_ok message body sent in response to cas message.
    """

    @derive [JSON.Encoder]
    @type t :: %__MODULE__{
            type: :cas_ok,
            in_reply_to: non_neg_integer()
          }

    @enforce_keys [:in_reply_to]

    defstruct @enforce_keys ++ [type: :cas_ok]
  end

  def reply(msg, :ok) do
    # CAS success replies
    %Ok{
      in_reply_to: msg.msg_id
    }
  end

  def reply(msg, {:error, :precondition_failed}) do
    # CAS precondition failed
    %Maelstrom.Message.Error{
      in_reply_to: msg.msg_id,
      code: 22,
      text: "precondition failed"
    }
  end

  def reply(msg, {:error, reason}) do
    # Other CAS errors
    %Maelstrom.Message.Error{
      in_reply_to: msg.msg_id,
      code: 13,
      text: "cas failed: #{reason}"
    }
  end
end
