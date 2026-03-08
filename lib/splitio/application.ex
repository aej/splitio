defmodule Splitio.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # ETS table owner - must start first
      Splitio.Storage.TableOwner
    ]

    opts = [strategy: :one_for_one, name: Splitio.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
