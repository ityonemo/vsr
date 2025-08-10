use Protoss

defprotocol Vsr.Comms do
  @moduledoc """
  Behaviour for VSR communications.
  """

  @type id :: any
  @type filter :: (any -> boolean)

  @type t :: struct

  @spec send_to(t, id :: id, message :: term) :: term
  def send_to(comms, id, message)

  @spec send_reply(t, from :: id, message :: term) :: term
  def send_reply(comms, from, message)

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
  @type from :: GenServer.from()

  @impl true
  def send_to(_, id, message), do: Message.vsr_send(id, message)

  @impl true
  def send_reply(_, from, message), do: GenServer.reply(from, message)

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
