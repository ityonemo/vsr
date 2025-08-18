use Protoss

defprotocol Vsr.Comms do
  @moduledoc """
  Behaviour for VSR communications.
  """

  @type id :: any
  @type encoded_from :: any
  @type filter :: (any -> boolean)

  @type t :: struct

  @spec send_to(t, id :: id, message :: term) :: term
  def send_to(comms, id, message)

  @spec node_id(t) :: id
  @doc """
  Returns the node identifier for this communications module.
  Must be called from the VSR process.
  """
  def node_id(comms)

  @spec encode_from(t, from :: GenServer.from()) :: encoded_from
  def encode_from(comms, from)

  @spec send_reply(t, encoded_from, message :: term) :: term
  def send_reply(comms, encoded_from, message)

  @spec initial_cluster(t) :: [id]
  def initial_cluster(comms)

  @spec monitor(t, id :: id) :: reference
  def monitor(comms, id)
end

defmodule Vsr.StdComms do
  @moduledoc """
  standard communications module for VSR.

  This module uses Erlang's builtin distribution as a fabric for node-to-node communication.
  It also uses the standard `Node` module for discovery.  Two configuration options are
  available:  

  - `:cluster_filter`:  (`{m, f, a}`) -- after obtaining all node names in the cluster,
    `apply(m, f, [node | a])` is called and if a truthy value is returned,
    the node is included in the cluster discovery.
  - `:process_name`: the expected registered name of the singleton VSR process on the
    remote node.

  If you need more than one VSR systems in your cluster, you will need to implement
  your own `Vsr.Comms` behaviour module.
  """

  use Vsr.Comms

  alias Vsr.Message

  defstruct [:filter, name: Vsr]

  @type id :: pid
  @type encoded_from :: GenServer.from()

  @impl true
  def send_to(_, id, message), do: Message.vsr_send(id, message)

  @impl true
  def send_reply(_, from, message), do: GenServer.reply(from, message)

  @impl true
  def node_id(_), do: self()

  @impl true
  def encode_from(_comms, from), do: from

  @impl true
  def initial_cluster(comms), do: Enum.flat_map(Node.list(), &attempt_connect(comms, &1))

  defp attempt_connect(%{filter: filter} = comms, node) do
    List.wrap(
      if filter && filter.(node) do
        :rpc.call(node, Process, :whereis, [comms.name])
      end
    )
  catch
    _, _ -> []
  end

  @impl true
  def monitor(_, pid), do: Process.monitor(pid)
end
