defmodule Vsr.Application do
  use Application

  def start(_type, _args) do
    children = [
      # No need for Registry since we use PIDs directly
    ]

    opts = [strategy: :one_for_one, name: Vsr.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
