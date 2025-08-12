defmodule Maelstrom.Application do
  @moduledoc """
  Main application supervisor for Maelstrom integration.

  This application starts the Maelstrom node which handles the JSON protocol
  and integrates with VSR for distributed consensus testing.
  """

  use Application

  def start(_type, _args) do
    children = [
      Maelstrom.Node,
      Maelstrom.Stdin,
      Maelstrom.GlobalData,
      {DynamicSupervisor, name: Maelstrom.Supervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: Maelstrom.Application]
    Supervisor.start_link(children, opts)
  end
end
