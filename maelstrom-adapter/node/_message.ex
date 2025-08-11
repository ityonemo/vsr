defmodule Maelstrom.Node.Message.Ok do
  @moduledoc """
  convenience module that provides a common `*.Ok` message reply.
  """
  defmacro __using__(type: type) do
    quote do
      defmodule Ok do
        @moduledoc """
        init_ok message body sent in response to Init message.
        """

        @derive [JSON.Encoder]
        @type t :: %__MODULE__{
                type: unquote(type),
                in_reply_to: non_neg_integer()
              }

        defstruct [:in_reply_to, type: unquote(type)]
      end
    end
  end
end

defmodule Maelstrom.Node.Message do
  @moduledoc """
  Main Maelstrom message struct with src, dest, and body fields.

  All Maelstrom messages follow this format regardless of message type.
  The body field contains the specific message type struct.
  """

  alias Maelstrom.Node.Init
  alias Maelstrom.Node.Echo
  alias Maelstrom.Node.Read
  alias Maelstrom.Node.Write
  alias Maelstrom.Node.Cas
  alias Maelstrom.Node.Error

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
          | Vsr.message()

  @derive [JSON.Encoder]
  defstruct [:src, :dest, :body]

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
                          Error
                        ],
                        &{"#{&1.__struct__().type}", &1}
                      )

  # OK message type helpers  
  @ok_message_types [Cas, Echo, Init, Read, Write]
  @ok_modules Map.new(@ok_message_types, &{&1, Module.concat(&1, Ok)})

  # Add OK message types to the message type mapping
  @ok_message_map Map.new(@ok_message_types, fn mod ->
                    ok_module = Module.concat(mod, Ok)
                    ok_type_atom = ok_module.__struct__().type
                    ok_type_str = "#{ok_type_atom}"
                    {ok_type_str, ok_module}
                  end)

  @message_types Map.merge(@vsr_messages, @maelstrom_messages) |> Map.merge(@ok_message_map)

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
      body: body_from_json_map(body)
    }
  end

  # Convert JSON map to appropriate body struct
  defp body_from_json_map(%{"type" => type} = body) do
    base_struct = Map.fetch!(@message_types, type).__struct__()

    for field <- Map.keys(base_struct), field not in [:__struct__, :type], reduce: base_struct do
      struct -> Map.replace!(struct, field, Map.fetch!(body, "#{field}"))
    end
  end

  def reply_ok(%{body: %body_mod{}} = msg, io_target) do
    maelstrom = %Maelstrom.Comms{node_name: msg.dest, io_target: io_target}

    Maelstrom.Comms.send_reply(
      maelstrom,
      msg.src,
      struct!(@ok_modules[body_mod], in_reply_to: msg.body.msg_id)
    )
  end
end
