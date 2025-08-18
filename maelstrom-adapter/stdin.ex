defmodule Maelstrom.Stdin do
  use Task
  require Logger

  def start_link(_), do: Task.start_link(__MODULE__, :loop, [])

  @new_state elem(:json.decode_start("", :ok, %{}), 1)

  def loop do
    Logger.info("Starting stdin reader...")
    loop(@new_state)
  end

  defp loop(state) do
    res = IO.read(:stdio, 1)

    case res do
      :eof ->
        Logger.info("STDIN closed, shutting down")
        System.halt(0)

      {:error, reason} ->
        Logger.error("Error reading from STDIN: #{inspect(reason)}")
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
                |> JSON.encode!()
                |> tap(&Logger.debug("Decoded Maelstrom message: #{&1}"))
                |> Maelstrom.Node.message()
              end
            )

            loop(@new_state)
        end
    end
  end
end
