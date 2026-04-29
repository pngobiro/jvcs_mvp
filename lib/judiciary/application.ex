defmodule Judiciary.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      JudiciaryWeb.Telemetry,
      Judiciary.Repo,
      {DNSCluster, query: Application.get_env(:judiciary, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Judiciary.PubSub},
      # Start a worker by calling: Judiciary.Worker.start_link(arg)
      # {Judiciary.Worker, arg},
      # Start to serve requests, typically the last entry
      JudiciaryWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Judiciary.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    JudiciaryWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
