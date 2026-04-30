defmodule Judiciary.Media.PeerSupervisor do
  @moduledoc """
  Supervisor for managing peer connections within a room.
  
  Uses a DynamicSupervisor with :one_for_one restart strategy.
  Each peer failure is isolated and won't affect other peers.
  """

  use DynamicSupervisor
  require Logger

  def start_link(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    DynamicSupervisor.start_link(
      __MODULE__,
      opts,
      name: {:via, Registry, {Judiciary.Media.PeerSupervisor, room_id}}
    )
  end

  @impl true
  def init(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    Logger.info("Initialized PeerSupervisor for room: #{room_id}")

    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
