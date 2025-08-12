defmodule Maelstrom.Stdin do
  use Task
  require Logger

  def start_link(_), do: Task.start_link(__MODULE__, :loop, [])

  def loop do
    case IO.read(:stdio, :line) do
      :eof ->
        Logger.info("STDIN closed, shutting down")
        System.halt(0)

      {:error, reason} ->
        Logger.error("Error reading from STDIN: #{inspect(reason)}")
        System.halt(1)

      line when is_binary(line) ->
        Maelstrom.Node.message(line)
    end
  end
end
