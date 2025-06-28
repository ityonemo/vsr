defmodule Vsr.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Start the Registry for our replicas
      {Registry, keys: :unique, name: Vsr.Registry}
    ]

    opts = [strategy: :one_for_one, name: Vsr.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
