defmodule Maelstrom.Message.Error do
  @moduledoc """
  Error message body for error responses.
  """

  @derive [JSON.Encoder]
  @type t :: %__MODULE__{
          type: :error,
          in_reply_to: non_neg_integer(),
          code: non_neg_integer(),
          text: String.t()
        }

  defstruct [:in_reply_to, :code, :text, type: :error]
end
