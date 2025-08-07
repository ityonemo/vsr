defmodule Vsr.Comms do
  @moduledoc """
  Behaviour for VSR communications.
  """

  @type id :: any
  @type from :: any
  @type filter :: (any -> boolean)
  @callback send_to(id, message :: term) :: term
  @callback send_reply(from, message :: term) :: term
  @callback cluster() :: [id]
  @callback monitor(id) :: reference
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

  @behaviour Vsr.Comms

  @type id :: pid
  @type from :: GenServer.from()

  @impl true
  defdelegate send_to(id, message), to: Vsr.Message, as: :vsr_send

  @impl true
  defdelegate send_reply(from, message), to: GenServer, as: :reply

  @filter Application.compile_env(:vsr, :cluster_filter, {__MODULE__, :cluster_filter, []})
  @name Application.compile_env(:vsr, :process_name, Vsr)

  @impl true
  def cluster do
    Enum.flat_map(Node.list(), &attempt_connect/1)
  end

  defp attempt_connect(node) do
    {m, f, a} = @filter
    should_connect = apply(m, f, [node | a])

    List.wrap(
      if should_connect do
        :rpc.call(node, Process, :whereis, [@name])
      end
    )
  catch
    _, _ -> []
  end

  def cluster_filter(_), do: true

  @impl true
  defdelegate monitor(id), to: Process
end
