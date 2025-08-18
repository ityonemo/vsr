use Protoss

defprotocol Maelstrom.Node.Message do
  @moduledoc """
  Main Maelstrom message struct with src, dest, and body fields.

  All Maelstrom messages follow this format regardless of message type.
  The body field contains the specific message type struct.

  All message types implement a `reply/2` function that sends a reply
  message, accessible through the `Maelstrom.Node.Message` protocol.

  The opts field *requires* a `:to` key with the message to reply to;
  and for Ok messages with further payloads, the fields must be set
  in the `opts` keyword list, with the values being the dialyzer types
  for the fields.
  """

  def reply(msg, opts)
after
  # AVERT YOUR EYES!
  defmacro __using__(opts) do
    {type, fields} = Keyword.pop!(opts, :type)

    parent =
      "#{type}"
      |> String.trim_trailing("_ok")
      |> String.to_atom()

    types =
      [
        type: type,
        in_reply_to:
          quote do
            non_neg_integer()
          end
      ] ++ fields

    enforced = Keyword.keys(fields) ++ [:in_reply_to]

    quote do
      defmodule Ok do
        @moduledoc """
        #{unquote(type)} message body sent in response to #{unquote(parent)} message.
        """

        @derive [JSON.Encoder]
        @type t :: %__MODULE__{unquote_splicing(types)}

        @enforce_keys unquote(enforced)

        defstruct @enforce_keys ++ [type: unquote(type)]
      end

      def reply(msg, opts) do
        require Logger

        {parent, fields} = Keyword.pop!(opts, :to)

        fields = Keyword.merge(fields, in_reply_to: msg.msg_id)

        parent.dest
        |> Maelstrom.Node.Message.new(parent.src, struct!(Ok, fields))
        |> JSON.encode!()
        |> tap(&Logger.debug("Sending Maelstrom message: #{&1}"))
        |> IO.puts()
      end
    end
  end

  alias Maelstrom.Node.Message.Types

  alias Maelstrom.Node.Init
  alias Maelstrom.Node.Echo
  alias Maelstrom.Node.Read
  alias Maelstrom.Node.Write
  alias Maelstrom.Node.Cas
  alias Maelstrom.Node.Error
  alias Maelstrom.Node.ForwardedReply

  @type node_id :: String.t()
  @type msg_id :: non_neg_integer()

  @type message :: %__MODULE__{
          src: node_id(),
          dest: node_id(),
          body: body()
        }

  @type body ::
          Init.t()
          | Init.Ok.t()
          | Echo.t()
          | Echo.Ok.t()
          | Read.t()
          | Read.Ok.t()
          | Write.t()
          | Write.Ok.t()
          | Cas.t()
          | Cas.Ok.t()
          | Error.t()
          | ForwardedReply.t()
          | Vsr.message()

  @derive [JSON.Encoder]
  defstruct [:src, :dest, :body]

  @doc """
  Creates a new Maelstrom message.
  """
  @spec new(node_id(), node_id(), body()) :: t()
  def new(src, dest, body) do
    %__MODULE__{src: src, dest: dest, body: body}
  end

  @doc """
  Creates a Maelstrom message struct from a JSON map received from Maelstrom.
  """
  @spec from_json_map(%{String.t() => term()}) :: t()
  def from_json_map(%{"src" => src, "dest" => dest, "body" => body}) do
    %__MODULE__{
      src: src,
      dest: dest,
      body: Types.body_from_json_map(body)
    }
  end
end

# this module needs to be defined separately to avoid circular dependencies
defmodule Maelstrom.Node.Message.Types do
  @moduledoc false

  alias Maelstrom.Node.Init
  alias Maelstrom.Node.Echo
  alias Maelstrom.Node.Read
  alias Maelstrom.Node.Write
  alias Maelstrom.Node.Cas
  alias Maelstrom.Node.Error
  alias Maelstrom.Node.ForwardedReply

  # Compile-time mapping of message type strings to modules
  @vsr_messages %{
    # VSR protocol messages
    "prepare" => Vsr.Message.Prepare,
    "prepare_ok" => Vsr.Message.PrepareOk,
    "commit" => Vsr.Message.Commit,
    "start_view_change" => Vsr.Message.StartViewChange,
    "start_view_change_ack" => Vsr.Message.StartViewChangeAck,
    "do_view_change" => Vsr.Message.DoViewChange,
    "start_view" => Vsr.Message.StartView,
    "view_change_ok" => Vsr.Message.ViewChangeOk,
    "get_state" => Vsr.Message.GetState,
    "new_state" => Vsr.Message.NewState,
    "client_request" => Vsr.Message.ClientRequest,
    "heartbeat" => Vsr.Message.Heartbeat
  }

  @maelstrom_messages Map.new(
                        [
                          Init,
                          Echo,
                          Read,
                          Write,
                          Cas,
                          Error,
                          ForwardedReply
                        ],
                        &{"#{&1.__struct__().type}", &1}
                      )

  # OK message type helpers  
  @ok_message_types [Cas, Echo, Init, Read, Write]

  # Add OK message types to the message type mapping
  @ok_message_map Map.new(@ok_message_types, fn mod ->
                    ok_module = Module.concat(mod, Ok)
                    ok_type_atom = ok_module.__struct__().type
                    ok_type_str = "#{ok_type_atom}"
                    {ok_type_str, ok_module}
                  end)

  @message_types Map.merge(@vsr_messages, @maelstrom_messages) |> Map.merge(@ok_message_map)

  require Logger

  # Convert JSON map to appropriate body struct
  def body_from_json_map(%{"type" => "new_state"} = body) do
    Vsr.Message.NewState
    |> body_from_json_map(body)
    |> Map.update!(:log, &reify_log/1)
  end

  def body_from_json_map(%{"type" => type} = body) do
    @message_types
    |> Map.fetch!(type)
    |> body_from_json_map(body)
  end

  defp body_from_json_map(module, body) do
    base_struct = module.__struct__()

    for field <- Map.keys(base_struct), field not in [:__struct__, :type], reduce: base_struct do
      struct -> Map.replace!(struct, field, Map.fetch!(body, "#{field}"))
    end
  end

  defp reify_log(log) do
    Enum.map(log, fn entry ->
      %Vsr.Log.Entry{
        view: Map.fetch!(entry, "view"),
        op_number: Map.fetch!(entry, "op_number"),
        operation: Map.fetch!(entry, "operation"),
        sender_id: Map.fetch!(entry, "sender_id")
      }
    end)
  end
end
