defmodule Judiciary.Media.RoomSession do
  @moduledoc """
  GenServer managing a court room session with fault tolerance.

  Handles:
  - Peer connection state tracking
  - Connection health monitoring
  - Automatic peer recovery on disconnect
  - Message queuing with retry logic
  - Graceful degradation
  """

  use GenServer
  require Logger

  alias Phoenix.PubSub
  alias Judiciary.Media.PeerConnection

  @heartbeat_interval 30_000  # 30 seconds
  @peer_timeout 120_000       # 2 minutes before removing peer
  @message_queue_limit 1000

  def start_link(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {Judiciary.Media.RoomRegistry, room_id}})
  end

  def add_peer(room_id, peer_id, metadata) do
    case get_room_session(room_id) do
      {:ok, pid} ->
        GenServer.call(pid, {:add_peer, peer_id, metadata}, 5_000)

      :error ->
        {:error, :room_not_found}
    end
  end

  def remove_peer(room_id, peer_id) do
    case get_room_session(room_id) do
      {:ok, pid} ->
        GenServer.call(pid, {:remove_peer, peer_id}, 5_000)

      :error ->
        {:error, :room_not_found}
    end
  end

  def send_signal(room_id, from_peer_id, to_peer_id, payload) do
    case get_room_session(room_id) do
      {:ok, pid} ->
        GenServer.cast(pid, {:queue_signal, from_peer_id, to_peer_id, payload})

      :error ->
        {:error, :room_not_found}
    end
  end

  def get_peers(room_id) do
    case get_room_session(room_id) do
      {:ok, pid} ->
        GenServer.call(pid, :get_peers, 5_000)

      :error ->
        {:error, :room_not_found}
    end
  end

  def get_room_session(room_id) do
    case Registry.lookup(Judiciary.Media.RoomRegistry, room_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @impl true
  def init(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    Logger.info("Initializing RoomSession for room: #{room_id}")

    # Start periodic health check
    schedule_heartbeat()

    {:ok,
     %{
       room_id: room_id,
       peers: %{},
       message_queue: [],
       connection_attempts: %{},
       created_at: System.monotonic_time(:millisecond)
     }}
  end

  @impl true
  def handle_call({:add_peer, peer_id, metadata}, _from, state) do
    Logger.info("Adding peer #{peer_id} to room #{state.room_id}")

    case state.peers do
      %{^peer_id => _} ->
        Logger.warning("Peer #{peer_id} already exists, reconnecting")
        {:reply, {:ok, :reconnected}, state}

      _ ->
        # Start peer connection supervisor
        case start_peer_connection(state.room_id, peer_id, metadata) do
          {:ok, peer_pid} ->
            new_peers = Map.put(state.peers, peer_id, %{
              pid: peer_pid,
              status: :connected,
              metadata: metadata,
              connected_at: System.monotonic_time(:millisecond),
              last_heartbeat: System.monotonic_time(:millisecond),
              failed_attempts: 0
            })

            {:reply, {:ok, :added}, %{state | peers: new_peers}}

          {:error, reason} ->
            Logger.error("Failed to start peer connection: #{inspect(reason)}")
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:remove_peer, peer_id}, _from, state) do
    Logger.info("Removing peer #{peer_id} from room #{state.room_id}")

    case Map.fetch(state.peers, peer_id) do
      {:ok, peer_info} ->
        stop_peer_connection(state.room_id, peer_info.pid)
        new_peers = Map.delete(state.peers, peer_id)
        {:reply, :ok, %{state | peers: new_peers}}

      :error ->
        {:reply, {:error, :peer_not_found}, state}
    end
  end

  @impl true
  def handle_call(:get_peers, _from, state) do
    peer_list =
      state.peers
      |> Enum.map(fn {peer_id, info} ->
        %{
          id: peer_id,
          status: info.status,
          connected_at: info.connected_at,
          metadata: info.metadata
        }
      end)

    {:reply, {:ok, peer_list}, state}
  end

  @impl true
  def handle_cast({:queue_signal, from_peer_id, to_peer_id, payload}, state) do
    # Direct signaling via PubSub for MVP reliability
    PubSub.broadcast(Judiciary.PubSub, "room:#{state.room_id}", {:webrtc_signaling, to_peer_id, from_peer_id, payload})
    
    case Map.fetch(state.peers, to_peer_id) do
      {:ok, peer_info} ->
        spawn(fn -> PeerConnection.handle_signal(peer_info.pid, from_peer_id, payload) end)
        new_peers = update_peer_heartbeat(state.peers, to_peer_id)
        {:noreply, %{state | peers: new_peers}}
      
      :error ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:heartbeat, state) do
    schedule_heartbeat()

    # Check peer health
    updated_peers =
      state.peers
      |> Enum.reduce(state.peers, fn {peer_id, peer_info}, acc ->
        case check_peer_health(peer_info) do
          :healthy ->
            acc

          :stale ->
            Logger.warning("Peer #{peer_id} is stale, attempting recovery")
            attempt_peer_recovery(acc, peer_id, peer_info)

          :dead ->
            Logger.error("Peer #{peer_id} is dead, removing")
            Map.delete(acc, peer_id)
        end
      end)

    # Process message queue for reconnected peers
    new_queue =
      Enum.reduce(state.message_queue, [], fn {from_id, to_id, payload, queued_at}, queue ->
        case Map.fetch(updated_peers, to_id) do
          {:ok, peer_info} when peer_info.status == :connected ->
            case PeerConnection.handle_signal(peer_info.pid, from_id, payload) do
              :ok ->
                Logger.info("Delivered queued signal from #{from_id} to #{to_id}")
                queue

              {:error, _} ->
                [
                  {from_id, to_id, payload, queued_at} | queue
                ]
            end

          _ ->
            [{from_id, to_id, payload, queued_at} | queue]
        end
      end)

    {:noreply, %{state | peers: updated_peers, message_queue: new_queue}}
  end

  ## Helpers

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
  end

  defp check_peer_health(peer_info) do
    now = System.monotonic_time(:millisecond)
    time_since_heartbeat = now - peer_info.last_heartbeat

    cond do
      time_since_heartbeat > @peer_timeout -> :dead
      time_since_heartbeat > @heartbeat_interval * 2 -> :stale
      true -> :healthy
    end
  end

  defp attempt_peer_recovery(peers, peer_id, peer_info) do
    if peer_info.failed_attempts < 3 do
      Logger.info("Attempting recovery for peer #{peer_id}, attempt #{peer_info.failed_attempts + 1}/3")

      updated_info = %{
        peer_info
        | failed_attempts: peer_info.failed_attempts + 1,
          last_heartbeat: System.monotonic_time(:millisecond)
      }

      Map.put(peers, peer_id, updated_info)
    else
      Logger.error("Peer #{peer_id} recovery failed after 3 attempts, removing")
      Map.delete(peers, peer_id)
    end
  end

  defp update_peer_heartbeat(peers, peer_id) do
    case Map.fetch(peers, peer_id) do
      {:ok, peer_info} ->
        Map.put(
          peers,
          peer_id,
          %{peer_info | last_heartbeat: System.monotonic_time(:millisecond), failed_attempts: 0}
        )

      :error ->
        peers
    end
  end

  defp start_peer_connection(room_id, peer_id, metadata) do
    child_spec = {
      PeerConnection,
      [room_id, peer_id, metadata]
    }

    case DynamicSupervisor.start_child(
           {:via, Registry, {Judiciary.Media.PeerSupervisor, room_id}},
           child_spec
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stop_peer_connection(room_id, pid) do
    DynamicSupervisor.terminate_child(
      {:via, Registry, {Judiciary.Media.PeerSupervisor, room_id}},
      pid
    )
  rescue
    _ -> :ok
  end
end
