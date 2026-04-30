defmodule Judiciary.Media.RoomSupervisor do
  @moduledoc """
  Supervisor for managing all active court room sessions.

  Uses a DynamicSupervisor to allow rooms to be created/destroyed on demand.
  Each room has its own RoomSession and nested PeerSupervisor.
  """

  use DynamicSupervisor
  require Logger

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  def start_room(room_id) do
    # Check if either the room session or peer supervisor are already registered
    # This prevents the "already_started" error when part of the tree is still alive
    room_exists = case Registry.lookup(Judiciary.Media.RoomRegistry, room_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end

    peer_sup_exists = case Registry.lookup(Judiciary.Media.PeerSupervisor, room_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end

    if room_exists != :error or peer_sup_exists != :error do
      Logger.info("Room session or peer supervisor already active for room: #{room_id}")
      {:ok, room_exists}
    else
      # Create a supervisor spec that starts both PeerSupervisor and RoomSession
      child_spec = {
        Judiciary.Media.RoomAndPeerSupervisor,
        [room_id: room_id]
      }

      case DynamicSupervisor.start_child(__MODULE__, child_spec) do
        {:ok, pid} ->
          Logger.info("Started room and peer supervisor for room: #{room_id}")
          {:ok, pid}

        {:error, {:already_started, pid}} ->
          Logger.info("Room supervisor already exists for room: #{room_id}")
          {:ok, pid}

        {:error, reason} ->
          Logger.error("Failed to start room supervisor: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  def stop_room(room_id) do
    case Judiciary.Media.RoomSession.get_room_session(room_id) do
      {:ok, pid} ->
        Logger.info("Stopping room session for room: #{room_id}")
        DynamicSupervisor.terminate_child(__MODULE__, pid)

      :error ->
        {:error, :room_not_found}
    end
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
