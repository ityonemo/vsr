defmodule Maelstrom.Comms do
  @moduledoc """
  Communication module for VSR that routes through Maelstrom's network simulation.

  This implements the Vsr.Comms behavior, allowing VSR replicas to communicate
  through Maelstrom's simulated network with partition injection and message delays.
  """

  @enforce_keys [:node_name]
  defstruct @enforce_keys ++ [io_target: :stdio]

  use Vsr.Comms

  alias Maelstrom.Node.Message

  # addresses in Maelstrom are a tuple of the pid of the Maelstrom.Node process
  # (or Maelstrom.Node atom) and the Maelstrom node name.

  @type id :: {pid | Maelstrom.Node, node_name :: String.t()}

  # it is not possible for Maelstrom to provide a cluster at initialization time,
  # as it is only notified of the cluster AFTER initialization.
  @impl true
  def initial_cluster(_comms), do: []

  # VSR.Comms protocol implementation (3-arity versions)
  @impl true
  def send_to(maelstrom, dest_id, message) do
    maelstrom.node_name
    |> Message.new(dest_id, message)
    |> send_stdout(maelstrom.io_target)
  end

  @impl true
  def send_reply(maelstrom, from, message) do
    maelstrom.node_name
    |> Message.new(from, message)
    |> send_stdout(maelstrom.io_target)
  end

  # Send JSON message to IO target
  defp send_stdout(message, io_target) do
    message
    |> JSON.encode!()
    |> then(&IO.puts(io_target, &1))
  end

  @impl true
  # Return dummy reference since Maelstrom handles node monitoring
  def monitor(_, _pid), do: make_ref()
end
