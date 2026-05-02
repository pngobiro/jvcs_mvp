defmodule Judiciary.Media.RoomSession do
  @moduledoc """
  GenServer managing a court room session with server-side WebRTC SFU.

  Handles:
  - WebRTC peer connection management (server-side)
  - SFU (Selective Forwarding Unit) track routing
  - Participant admission and lifecycle
  - Session health monitoring
  """

  use GenServer
  require Logger

  alias Judiciary.Media.WebRTCPeer
  alias Phoenix.PubSub
  alias JudiciaryWeb.Presence

  @heartbeat_interval 10_000 # 10 seconds
  @max_failed_attempts 3

  # Client API

  def start_link(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(room_id))
  end

  def add_peer(room_id, peer_id, metadata) do
    case Registry.lookup(Judiciary.Media.RoomRegistry, room_id) do
      [{pid, _}] ->
        GenServer.call(pid, {:add_peer, peer_id, metadata})
      [] ->
        # Start the room if it doesn't exist
        case Judiciary.Media.RoomSupervisor.start_room(room_id) do
          {:ok, _pid} ->
            # Registry lookup might still need a moment
            Process.sleep(50)
            add_peer(room_id, peer_id, metadata)
          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def remove_peer(room_id, peer_id) do
    case Registry.lookup(Judiciary.Media.RoomRegistry, room_id) do
      [{pid, _}] ->
        GenServer.call(pid, {:remove_peer, peer_id})
      [] ->
        {:error, :room_not_found}
    end
  end

  def send_signal(room_id, from_peer_id, to_peer_id, payload) do
    case Registry.lookup(Judiciary.Media.RoomRegistry, room_id) do
      [{pid, _}] ->
        GenServer.cast(pid, {:queue_signal, from_peer_id, to_peer_id, payload})
      [] ->
        {:error, :room_not_found}
    end
  end

  def get_room_session(room_id) do
    case Registry.lookup(Judiciary.Media.RoomRegistry, room_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  def update_recording_status(room_id, action) do
    case get_room_session(room_id) do
      {:ok, pid} -> GenServer.cast(pid, {:update_recording_status, action})
      :error -> {:error, :room_not_found}
    end
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    topic = "room:#{room_id}"
    Logger.info("Initializing RoomSession for room: #{room_id}")

    # Subscribe to room events for signaling and presence
    PubSub.subscribe(Judiciary.PubSub, topic)

    # Schedule initial heartbeat
    schedule_heartbeat()

    # Recover state from Presence if any participants are already there
    initial_peers = recover_peers_from_presence(room_id)
    if map_size(initial_peers) > 0 do
      Logger.info("Recovered #{map_size(initial_peers)} peers from presence for room #{room_id}")
    end

    {:ok, %{
      room_id: room_id,
      peers: initial_peers,
      recording_status: :idle,
      created_at: System.monotonic_time(:millisecond)
    }}
  end

  @impl true
  def handle_call({:add_peer, peer_id, metadata}, _from, state) do
    Logger.info("Adding peer #{peer_id} to room #{state.room_id}")

    case Map.fetch(state.peers, peer_id) do
      {:ok, peer_info} ->
        # If PID is nil, restart it
        if is_nil(peer_info.pid) or not Process.alive?(peer_info.pid) do
           case start_webrtc_peer(state.room_id, peer_id, metadata) do
             {:ok, pid} ->
                new_info = %{peer_info | pid: pid}
                {:reply, {:ok, :restarted}, %{state | peers: Map.put(state.peers, peer_id, new_info)}}
             _ ->
                {:reply, {:ok, :already_exists}, state}
           end
        else
          # PID exists and is alive. 
          # We should tell the peer process to RESET its connection
          # because the client is clearly trying to join again (likely a refresh or reconnect)
          send(peer_info.pid, :reset_connection)
          {:reply, {:ok, :already_exists}, state}
        end

      :error ->
        # Start WebRTC peer process
        case start_webrtc_peer(state.room_id, peer_id, metadata) do
          {:ok, peer_pid} ->
            new_peer_info = %{
              pid: peer_pid,
              status: :connected,
              metadata: metadata,
              connected_at: System.monotonic_time(:millisecond),
              last_heartbeat: System.monotonic_time(:millisecond),
              failed_attempts: 0,
              tracks: []
            }

            # Inform the NEW peer about all EXISTING tracks from OTHER peers
            for {other_id, other_info} <- state.peers do
              for track <- other_info.tracks do
                send(peer_pid, {:add_remote_track, other_id, track})
              end
            end

            new_peers = Map.put(state.peers, peer_id, new_peer_info)

            # Notify existing peers about new peer
            notify_peers_about_join(state.room_id, peer_id, metadata)

            {:reply, {:ok, :added}, %{state | peers: new_peers}}

          {:error, reason} ->
            Logger.error("Failed to start WebRTC peer: #{inspect(reason)}")
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:remove_peer, peer_id}, _from, state) do
    Logger.info("Removing peer #{peer_id} from room #{state.room_id}")

    case Map.fetch(state.peers, peer_id) do
      {:ok, peer_info} ->
        stop_webrtc_peer(peer_info.pid)
        new_peers = Map.delete(state.peers, peer_id)

        # Notify other peers
        PubSub.broadcast(
          Judiciary.PubSub,
          "room:#{state.room_id}",
          {:peer_left, peer_id}
        )

        {:reply, :ok, %{state | peers: new_peers}}

      :error ->
        {:reply, {:error, :peer_not_found}, state}
    end
  end

  @impl true
  def handle_cast({:queue_signal, from_peer_id, to_peer_id, payload}, state) do
    keys = Map.keys(payload)
    signal_type = Map.get(payload, "type", if(Map.has_key?(payload, "candidate"), do: "ice", else: "unknown"))
    Logger.debug("Queueing signal from #{from_peer_id} to #{to_peer_id}: type=#{signal_type}, keys=#{inspect(keys)}")
    
    case Map.fetch(state.peers, from_peer_id) do
      {:ok, _peer_info} ->
        case signal_type do
          "offer" ->
            WebRTCPeer.handle_signal(state.room_id, from_peer_id, from_peer_id, payload)
          "answer" ->
            WebRTCPeer.handle_signal(state.room_id, from_peer_id, from_peer_id, payload)
          "ice" ->
            WebRTCPeer.add_ice_candidate(state.room_id, from_peer_id, payload)
          "heartbeat" ->
            nil
          _ ->
            nil
        end

        new_peers = update_peer_heartbeat(state.peers, from_peer_id)
        {:noreply, %{state | peers: new_peers}}

      :error ->
        Logger.warning("Signal from unknown peer #{from_peer_id}, attempting recovery")
        initial_peers = recover_peers_from_presence(state.room_id)
        if Map.has_key?(initial_peers, from_peer_id) do
           new_peers = Map.merge(state.peers, initial_peers)
           {:noreply, %{state | peers: new_peers}}
        else
           {:noreply, state}
        end
    end
  end

  @impl true
  def handle_cast({:update_recording_status, action}, state) do
    new_status = if action == :start_recording, do: :recording, else: :idle
    Logger.info("Room #{state.room_id} recording status: #{new_status}")

    # Broadcast to all participants (LiveViews)
    PubSub.broadcast(
      Judiciary.PubSub,
      "room:#{state.room_id}",
      {:recording_status_updated, new_status}
    )

    {:noreply, %{state | recording_status: new_status}}
  end

  @impl true
  def handle_info({:webrtc_signal_to_client, _peer_id, _signal_type, _signal}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:peer_track_added, from_peer_id, track}, state) do
    Logger.info("Peer #{from_peer_id} added #{track.kind} track (ID: #{track.id}), forwarding to others")

    new_peers = case Map.fetch(state.peers, from_peer_id) do
      {:ok, peer_info} ->
        if Enum.any?(peer_info.tracks, fn t -> t.id == track.id end) do
           state.peers
        else
           updated_info = %{peer_info | tracks: [track | peer_info.tracks]}
           Map.put(state.peers, from_peer_id, updated_info)
        end
      :error ->
        state.peers
    end

    for {id, other_info} <- new_peers, id != from_peer_id do
      if other_info.pid, do: send(other_info.pid, {:add_remote_track, from_peer_id, track})
    end

    {:noreply, %{state | peers: new_peers}}
  end

  @impl true
  def handle_info({:rtp_packet, from_peer_id, track_id, packet}, state) do
    # Forward the RTP packet to all other peers in the room
    recipients = Enum.filter(state.peers, fn {id, _info} -> id != from_peer_id end)
    
    # Sample logging for routing
    if :rand.uniform(500) == 1 do
      Logger.debug("ROUTE: RTP from #{from_peer_id} to #{length(recipients)} peers")
    end
    
    for {_id, other_info} <- recipients do
      if other_info.pid, do: send(other_info.pid, {:forward_rtp, track_id, packet})
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:request_pli, source_peer_id, track_id}, state) do
    case Map.get(state.peers, source_peer_id) do
      %{pid: pid} when is_pid(pid) ->
        send(pid, {:request_pli, track_id})
      _ ->
        nil
    end
    {:noreply, state}
  end

  @impl true
  def handle_info({:request_all_video_plis, requester_id}, state) do
    # Request PLIs from all peers except the requester for their video tracks
    for {peer_id, peer_info} <- state.peers, peer_id != requester_id do
      for track <- peer_info.tracks, track.kind == :video do
        if peer_info.pid, do: send(peer_info.pid, {:request_pli, track.id})
      end
    end
    {:noreply, state}
  end

  @impl true
  def handle_info({:peer_restarted, peer_id}, state) do
    Logger.info("Peer #{peer_id} restarted, re-syncing tracks")
    
    case Map.get(state.peers, peer_id) do
      %{pid: peer_pid} = peer_info when is_pid(peer_pid) ->
        # Clear tracks in our state for this peer (they will be re-added when they start sending again)
        updated_info = %{peer_info | tracks: []}
        
        # Inform the restarted peer about all EXISTING tracks from OTHER peers
        for {id, other_info} <- state.peers, id != peer_id do
          for track <- other_info.tracks do
            send(peer_pid, {:add_remote_track, id, track})
          end
        end
        
        {:noreply, %{state | peers: Map.put(state.peers, peer_id, updated_info)}}
      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:heartbeat, state) do
    schedule_heartbeat()

    peer_count = map_size(state.peers)
    
    # Detailed status for debugging
    peers_detail = Enum.map(state.peers, fn {id, info} ->
      "#{id}(#{info.metadata.role}, tracks: #{length(info.tracks)})"
    end) |> Enum.join(", ")
    
    Logger.info("Room #{state.room_id} Status: #{peer_count} peers [#{peers_detail}]")

    updated_peers =
      state.peers
      |> Enum.reduce(state.peers, fn {peer_id, peer_info}, acc ->
        case check_peer_health(peer_info) do
          :healthy -> acc
          :stale -> attempt_peer_recovery(acc, state.room_id, peer_id, peer_info)
          :dead -> Map.delete(acc, peer_id)
        end
      end)

    {:noreply, %{state | peers: updated_peers}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  ## Helpers

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
  end

  defp check_peer_health(peer_info) do
    now = System.monotonic_time(:millisecond)
    diff = now - peer_info.last_heartbeat

    cond do
      diff > 90_000 -> :dead
      diff > 45_000 -> :stale
      true -> :healthy
    end
  end

  defp attempt_peer_recovery(peers, room_id, peer_id, peer_info) do
    if peer_info.failed_attempts < @max_failed_attempts do
      Logger.info("Attempting recovery for peer #{peer_id}")

      new_pid = if is_nil(peer_info.pid) or not Process.alive?(peer_info.pid) do
         case start_webrtc_peer(room_id, peer_id, peer_info.metadata) do
           {:ok, pid} -> 
             # Notify client to reconnect since we have a fresh process/PC
             PubSub.broadcast(
               Judiciary.PubSub,
               "room:#{room_id}",
               {:webrtc_signal_to_client, peer_id, "reconnect", %{}}
             )
             pid
           _ -> peer_info.pid
         end
      else
        peer_info.pid
      end

      updated_info = %{
        peer_info
        | pid: new_pid,
          failed_attempts: peer_info.failed_attempts + 1,
          last_heartbeat: System.monotonic_time(:millisecond)
      }
      Map.put(peers, peer_id, updated_info)
    else
      Map.delete(peers, peer_id)
    end
  end

  defp update_peer_heartbeat(peers, peer_id) do
    case Map.fetch(peers, peer_id) do
      {:ok, peer_info} ->
        updated_info = %{
          peer_info
          | last_heartbeat: System.monotonic_time(:millisecond),
            failed_attempts: 0
        }
        Map.put(peers, peer_id, updated_info)

      :error ->
        peers
    end
  end

  defp start_webrtc_peer(room_id, peer_id, metadata) do
    Judiciary.Media.RoomAndPeerSupervisor.start_peer(room_id, %{
      room_id: room_id,
      peer_id: peer_id,
      metadata: metadata
    })
  end

  defp stop_webrtc_peer(nil), do: :ok
  defp stop_webrtc_peer(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal, 5_000)
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp via_tuple(room_id) do
    {:via, Registry, {Judiciary.Media.RoomRegistry, room_id}}
  end

  defp notify_peers_about_join(room_id, new_peer_id, metadata) do
    PubSub.broadcast(
      Judiciary.PubSub,
      "room:#{room_id}",
      {:peer_joined_webrtc, new_peer_id, metadata}
    )
  end

  defp recover_peers_from_presence(room_id) do
    topic = "room:#{room_id}"
    Presence.list(topic)
    |> Enum.reduce(%{}, fn {peer_id, %{metas: [meta | _]}}, acc ->
      Map.put(acc, peer_id, %{
        pid: nil,
        status: :connected,
        metadata: %{name: meta[:display_name], role: meta[:role]},
        connected_at: System.monotonic_time(:millisecond),
        last_heartbeat: System.monotonic_time(:millisecond),
        failed_attempts: 0,
        tracks: []
      })
    end)
  end
end
