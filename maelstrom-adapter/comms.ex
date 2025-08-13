defmodule Maelstrom.Comms do
  @moduledoc """
  Communication module for VSR that routes through Maelstrom's network simulation.

  This implements the Vsr.Comms behavior, allowing VSR replicas to communicate
  through Maelstrom's simulated network with partition injection and message delays.
  """

  @enforce_keys [:node_name]
  defstruct @enforce_keys

  use Vsr.Comms

  alias Maelstrom.GlobalData
  alias Maelstrom.Node
  alias Maelstrom.Node.Message

  @type id :: String.t()

  # it is not possible for Maelstrom to provide a cluster at initialization time,
  # as it is only notified of the cluster AFTER initialization.
  @impl true
  def initial_cluster(_comms), do: []

  # VSR.Comms protocol implementation
  # loopback in the case the node is trying to communicate with itself.nup
  @impl true
  def send_to(%{node_name: node_name}, node_name, message) do
    case GlobalData.fetch(node_name) do
      {:ok, pid} ->
        Node.message(pid, message)

      :error ->
        raise "Node #{node_name} not registered"
    end
  end

  def send_to(maelstrom, dest_id, message) do
    maelstrom.node_name
    |> Message.new(dest_id, message)
    |> send_stdout()
  end

  @impl true
  def send_reply(_, from, message) do
    case from do
      from when is_integer(from) ->
        from
        |> GlobalData.pop!()
        |> GenServer.reply(message)

      genserver_from ->
        GenServer.reply(genserver_from, message)
    end
  end

  @impl true
  def node_id(%{node_name: node_name}), do: node_name

  # Send JSON message to IO target
  defp send_stdout(message) do
    message
    |> JSON.encode!()
    |> IO.puts()
  end

  @impl true
  # Return dummy reference since Maelstrom nodes down detection is through timeout.
  def monitor(_, _pid), do: make_ref()
end
