defmodule Maelstrom.Application do
  @moduledoc """
  Main application supervisor for Maelstrom integration.

  This application starts the Maelstrom node which handles the JSON protocol
  and integrates with VSR for distributed consensus testing.
  """

  use Application

  require Logger

  def start(_type, _args) do
    # loglevel = System.get_env("LOG_LEVEL", "error")

    {:ok, handler_config} = :logger.get_handler_config(:default)
    stderr_config = put_in(handler_config, [:config, :type], :standard_error)

    :ok = :logger.remove_handler(:default)
    :ok = :logger.add_handler(:default, :logger_std_h, stderr_config)

    Logger.info("Starting...")

    children = [
      {Vsr, state_machine: Maelstrom.Kv},
      Maelstrom.Node,
      Maelstrom.Stdin,
      Maelstrom.GlobalData,
      {DynamicSupervisor, name: Maelstrom.Supervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: Maelstrom.Application]
    Supervisor.start_link(children, opts)
  end
end
