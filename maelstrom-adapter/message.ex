defmodule Maelstrom.Message do
  @moduledoc """
  Main Maelstrom message struct with src, dest, and body fields.

  All Maelstrom messages follow this format regardless of message type.
  The body field contains the specific message type struct.
  """

  alias Maelstrom.Message.Types

  alias Maelstrom.Message.Init
  alias Maelstrom.Message.Echo
  alias Maelstrom.Message.Read
  alias Maelstrom.Message.Write
  alias Maelstrom.Message.Cas
  alias Maelstrom.Message.Error
  alias Maelstrom.Message.ForwardedReply

  @type node_id :: String.t()
  @type msg_id :: non_neg_integer()

  @type t :: %__MODULE__{
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

  @doc """
  Constructs the reply body for a message, based on the GenServer.call response
  obtained from MaelstromKv server.
  """
  def reply(msg, response) do
    msg.body.__struct__.reply(msg.body, response)
  end
end

# this module needs to be defined separately to avoid circular dependencies
defmodule Maelstrom.Message.Types do
  @moduledoc false

  alias Maelstrom.Message.Init
  alias Maelstrom.Message.Echo
  alias Maelstrom.Message.Read
  alias Maelstrom.Message.Write
  alias Maelstrom.Message.Cas
  alias Maelstrom.Message.Error
  alias Maelstrom.Message.ForwardedReply

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
      %Vsr.LogEntry{
        view: Map.fetch!(entry, "view"),
        op_number: Map.fetch!(entry, "op_number"),
        operation: Map.fetch!(entry, "operation"),
        sender_id: Map.fetch!(entry, "sender_id")
      }
    end)
  end
end
