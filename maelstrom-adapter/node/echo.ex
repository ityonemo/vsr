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

  use Maelstrom.Node.Message, type: :echo_ok, echo: term(), msg_id: non_neg_integer()
end
