defmodule ExpirableStore.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      %{
        id: :pg,
        start: {:pg, :start_link, [:expirable_store]}
      },
      {Registry, keys: :unique, name: ExpirableStore.LocalRegistry},
      {DynamicSupervisor, name: ExpirableStore.Supervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: ExpirableStore.ApplicationSupervisor]
    Supervisor.start_link(children, opts)
  end
end
