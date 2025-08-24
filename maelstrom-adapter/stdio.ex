defmodule Maelstrom.Stdio do
  use Task
  require Logger

  alias Maelstrom.Message
  alias Maelstrom.Message.ForwardedReply

  def start_link(_), do: Task.start_link(__MODULE__, :loop, [])

  @new_state elem(:json.decode_start("", :ok, %{null: nil}), 1)

  def loop do
    Logger.info("Starting stdio handler...")
    loop(@new_state)
  end

  defp loop(state) do
    res = IO.read(:stdio, 1)

    case res do
      :eof ->
        Logger.info("STDIO closed, shutting down")
        System.halt(0)

      {:error, reason} ->
        Logger.error("Error reading from STDIO: #{inspect(reason)}")
        System.halt(1)

      byte ->
        case :json.decode_continue(byte, state) do
          {:continue, new_state} ->
            loop(new_state)

          {result, _acc, ""} ->
            Task.Supervisor.start_child(
              Maelstrom.Supervisor,
              fn ->
                result
                |> tap(&Logger.debug("Decoded JSON: #{JSON.encode!(&1)}"))
                |> Message.from_json_map()
                |> route_message()
              end
            )

            loop(@new_state)
        end
    end
  end

  # VSR message types that route to VsrServer
  @vsr_messages [
    Vsr.Message.Prepare,
    Vsr.Message.PrepareOk,
    Vsr.Message.Commit,
    Vsr.Message.StartViewChange,
    Vsr.Message.StartViewChangeAck,
    Vsr.Message.DoViewChange,
    Vsr.Message.StartView,
    Vsr.Message.ViewChangeOk,
    Vsr.Message.GetState,
    Vsr.Message.NewState,
    Vsr.Message.ClientRequest,
    Vsr.Message.Heartbeat
  ]

  def route_message(%{body: %{__struct__: type}} = message) when type in @vsr_messages do
    VsrServer.vsr_send(MaelstromKv, message.body)
  end

  def route_message(%{body: %ForwardedReply{}} = message), do: MaelstromKv.message(message)

  def route_message(message) do
    message
    |> MaelstromKv.message()
    |> then(&Maelstrom.Message.reply(message, &1))
    |> then(&Maelstrom.Message.new(message.dest, message.src, &1))
    |> JSON.encode!()
    |> IO.puts()
  end
end
