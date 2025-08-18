defmodule Maelstrom.Comms do
  @moduledoc """
  Communication module for VSR that routes through Maelstrom's network simulation.

  This implements the Vsr.Comms behavior, allowing VSR replicas to communicate
  through Maelstrom's simulated network with partition injection and message delays.
  """

  @enforce_keys [:node_name]
  defstruct @enforce_keys

  use Vsr.Comms

  require Logger
  alias Maelstrom.GlobalData
  alias Maelstrom.Node
  alias Maelstrom.Node.Message

  @type id :: String.t()
  @type encoded_from :: %{optional(String.t()) => term}
  # "node_name" => String.t()
  # "from" => non_neg_integer()

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
        # Wrap local messages in same format as remote messages
        node_name
        |> Message.new(node_name, message)
        |> then(&Node.message(pid, &1))

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
  def send_reply(%{node_name: node_name}, %{"node" => node_name, "from" => from}, message) do
    from
    |> GlobalData.pop!()
    |> GenServer.reply(message)
  end

  def send_reply(%{node_name: node_name}, %{"node" => target_node, "from" => from_hash}, message)
      when target_node != node_name do
    # Send ForwardedReply to the target node
    node_name
    |> Message.new(target_node, %Maelstrom.Node.ForwardedReply{
      from_hash: from_hash,
      result: message
    })
    |> send_stdout()
  end

  @impl true
  def encode_from(%{node_name: node_name}, from) do
    %{"node" => node_name, "from" => GlobalData.store_from(from)}
  end

  @impl true
  def node_id(%{node_name: node_name}), do: node_name

  # Send JSON message to IO target
  defp send_stdout(message) do
    message
    |> JSON.encode!()
    |> tap(&Logger.debug("Sending Maelstrom message: #{&1}"))
    |> IO.puts()
  end

  @impl true
  # Return dummy reference since Maelstrom nodes down detection is through timeout.
  def monitor(_, _pid), do: make_ref()
end
