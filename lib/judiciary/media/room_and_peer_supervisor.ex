defmodule Judiciary.Media.RoomAndPeerSupervisor do
  @moduledoc """
  Supervisor for a single room that manages both the RoomSession
  and its nested PeerSupervisor.

  Ensures that both are started together and tightly coupled.
  """

  use Supervisor
  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    Logger.info("Starting RoomAndPeerSupervisor for room: #{room_id}")

    children = [
      # Start peer supervisor for this specific room
      {
        Judiciary.Media.PeerSupervisor,
        [room_id: room_id]
      },
      # Start room session that will use the peer supervisor
      {
        Judiciary.Media.RoomSession,
        [room_id: room_id]
      }
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
