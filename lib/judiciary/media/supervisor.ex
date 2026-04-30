defmodule Judiciary.Media.Supervisor do
  @moduledoc """
  Master supervisor for the media pipeline.
  
  Starts:
  - Registries for room sessions and peer supervisors
  - RoomSupervisor for managing room sessions
  """

  use Supervisor
  require Logger

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    Logger.info("Starting Media Supervision Tree")

    children = [
      # Registry for mapping room_id to RoomSession PID
      {Registry, keys: :unique, name: Judiciary.Media.RoomRegistry},
      # Registry for mapping room_id to PeerSupervisor PID
      {Registry, keys: :unique, name: Judiciary.Media.PeerSupervisor},
      # Main room supervisor
      Judiciary.Media.RoomSupervisor
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
