defmodule Maelstrom.Message.ForwardedReply do
  @moduledoc """
  ForwardedReply message for completing GenServer calls across nodes.

  This message is sent when a VSR reply needs to be forwarded back to the
  originating node to complete a pending GenServer.call.
  """

  @type t :: %__MODULE__{
          type: :forwarded_reply,
          from_hash: non_neg_integer(),
          result: term()
        }

  defstruct [:from_hash, :result, type: :forwarded_reply]

  @doc """
  Decode the base64 encoded result back to an Erlang term.
  """
  def decode_result(%__MODULE__{result: result}) do
    result
    |> Base.decode64!()
    |> :erlang.binary_to_term()
  end

  defimpl JSON.Encoder do
    def encode(reply, opts) do
      reply
      |> Map.from_struct()
      |> Map.update!(:result, &term_encode/1)
      |> JSON.Encoder.encode(opts)
    end

    defp term_encode(term) do
      term
      |> :erlang.term_to_binary()
      |> Base.encode64()
    end
  end
end
