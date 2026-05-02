defmodule Judiciary.Media.WebRTCPeer do
  @moduledoc """
  GenServer managing a server-side WebRTC peer connection.

  This is a full SFU (Selective Forwarding Unit) implementation where:
  - Server manages all WebRTC peer connections
  - Media flows through the server for routing
  - Clients only send/receive media to/from server
  - Simpler client code (no peer-to-peer complexity)

  Flow:
  1. Client sends offer with sendrecv transceivers
  2. Server answers, accepting the client's media
  3. When another peer's tracks need forwarding, server adds sendonly
     transceivers and sends a NEW offer to the client
  4. Client answers the renegotiation
  5. Server forwards RTP packets between peers
  """

  use GenServer
  require Logger

  alias ExWebRTC.{PeerConnection, SessionDescription, ICECandidate, MediaStreamTrack}
  alias ExRTCP.Packet.PayloadFeedback.PLI
  alias Phoenix.PubSub

  @ice_servers [
    %{urls: "stun:stun.l.google.com:19302"},
    %{urls: "stun:stun1.l.google.com:19302"}
  ]

  defmodule State do
    @moduledoc false
    defstruct [
      :room_id,
      :peer_id,
      :display_name,
      :role,
      :pc,
      :local_tracks,
      :remote_tracks,
      :pending_remote_tracks,
      :ice_candidates_queue,
      :connection_state,
      :signaling_state,
      :creating_offer?,
      :created_at
    ]
  end

  ## Client API

  def start_link(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    peer_id = Keyword.fetch!(opts, :peer_id)
    metadata = Keyword.fetch!(opts, :metadata)

    GenServer.start_link(__MODULE__, {room_id, peer_id, metadata},
      name: via_tuple(room_id, peer_id))
  end

  def handle_signal(room_id, peer_id, from_peer_id, signal) do
    case Registry.lookup(Judiciary.Media.PeerRegistry, {room_id, peer_id}) do
      [{pid, _}] ->
        GenServer.cast(pid, {:handle_signal, from_peer_id, signal})
        :ok
      [] ->
        {:error, :peer_not_found}
    end
  end

  def add_ice_candidate(room_id, peer_id, candidate) do
    case Registry.lookup(Judiciary.Media.PeerRegistry, {room_id, peer_id}) do
      [{pid, _}] ->
        GenServer.cast(pid, {:add_ice_candidate, candidate})
        :ok
      [] ->
        {:error, :peer_not_found}
    end
  end

  def get_stats(room_id, peer_id) do
    case Registry.lookup(Judiciary.Media.PeerRegistry, {room_id, peer_id}) do
      [{pid, _}] ->
        GenServer.call(pid, :get_stats)
      [] ->
        {:error, :peer_not_found}
    end
  end

  ## Server Callbacks

  @impl true
  def init({room_id, peer_id, metadata}) do
    Logger.info("Initializing WebRTC peer #{peer_id} in room #{room_id}")

    # Subscribe to room events
    PubSub.subscribe(Judiciary.PubSub, "room:#{room_id}")

    # Create PeerConnection with ICE servers and IP filter to avoid Docker internal interfaces
    # which often cause connectivity issues even in host mode.
    {:ok, pc} = PeerConnection.start_link(
      ice_servers: @ice_servers,
      ice_aggressive_nomination: true,
      ice_port_range: 50000..50050,
      video_codecs: [
        %ExWebRTC.RTPCodecParameters{
          payload_type: 96,
          mime_type: "video/VP8",
          clock_rate: 90000
        }
      ],
      audio_codecs: [
        %ExWebRTC.RTPCodecParameters{
          payload_type: 111,
          mime_type: "audio/opus",
          clock_rate: 48000,
          channels: 2
        }
      ],
      ice_ip_filter: fn ip ->

        ip_str = :inet.ntoa(ip) |> to_string()
        # Exclude loopback, IPv6, and Docker-internal networks (172.x.x.x)
        not (String.starts_with?(ip_str, "127.") or 
             String.contains?(ip_str, ":") or 
             String.starts_with?(ip_str, "172."))
      end
    )

    # Set up PeerConnection callbacks
    :ok = PeerConnection.controlling_process(pc, self())

    state = %State{
      room_id: room_id,
      peer_id: peer_id,
      display_name: Map.get(metadata, :name, "Participant"),
      role: Map.get(metadata, :role, "participant"),
      pc: pc,
      local_tracks: [],
      remote_tracks: [],
      pending_remote_tracks: [],
      ice_candidates_queue: [],
      connection_state: :new,
      signaling_state: :stable,
      creating_offer?: false,
      created_at: System.monotonic_time(:millisecond)
    }

    {:ok, state}
  end

  # Handle client OFFER — client initiates the connection
  @impl true
  def handle_cast({:handle_signal, _from_peer_id, %{"type" => "offer", "sdp" => sdp}}, state) do
    Logger.info("Received offer from client #{state.peer_id}")
    
    try do
      offer = SessionDescription.from_json(%{"type" => "offer", "sdp" => sdp})

      # Try to set remote description
      case PeerConnection.set_remote_description(state.pc, offer) do
        :ok ->
          send_answer(state)
          {:noreply, %{state | creating_offer?: false}}

        {:error, :invalid_state} ->
          # Handle Glare (both sides sent offers)
          pc_state = PeerConnection.get_signaling_state(state.pc)
          Logger.warning("PC in invalid state (#{pc_state}) for offer from #{state.peer_id}")
          
          if pc_state == :have_local_offer do
            # In glare, we act as the IMPOLITE peer.
            # We ignore the client's offer, assuming the client (as the polite peer)
            # will rollback its own offer and accept ours.
            Logger.info("Glare detected with #{state.peer_id}, ignoring client offer (server is impolite)")
            {:noreply, state}
          else
            # Not glare, but still invalid state? Recreate PC as a last resort.
            recreate_pc_and_accept_offer(offer, state)
          end

        {:error, reason} ->
          Logger.error("Failed to set remote description: #{inspect(reason)}")
          {:noreply, state}
      end
    rescue
      e ->
        Logger.error("Failed to process offer for #{state.peer_id}: #{inspect(e)}")
        {:noreply, state}
    end
  end

  # Handle client ANSWER — client responds to our renegotiation offer
  @impl true
  def handle_cast({:handle_signal, _from_peer_id, %{"type" => "answer", "sdp" => sdp}}, state) do
    Logger.info("Received answer from client #{state.peer_id} (renegotiation response)")
    
    try do
      answer = SessionDescription.from_json(%{"type" => "answer", "sdp" => sdp})

      case PeerConnection.set_remote_description(state.pc, answer) do
        :ok ->
          # Process queued ICE candidates
          state = process_ice_queue(state)
          Logger.info("Renegotiation complete for peer #{state.peer_id}")
          {:noreply, %{state | creating_offer?: false}}

        {:error, :invalid_state} ->
          # This often happens if the client sent an offer at the same time (glare)
          # or if the state moved on. If we're already stable, we can ignore.
          pc_state = PeerConnection.get_signaling_state(state.pc)
          Logger.warning("Received answer for #{state.peer_id} in invalid state: #{pc_state}")
          
          if pc_state == :stable do
            Logger.info("PC is already stable, ignoring stale answer")
            {:noreply, %{state | creating_offer?: false}}
          else
            # Try to recover by rolling back or just resetting the flag
            {:noreply, %{state | creating_offer?: false}}
          end

        {:error, reason} ->
          Logger.warning("Failed to set answer remote description for #{state.peer_id}: #{inspect(reason)}")
          {:noreply, %{state | creating_offer?: false}}
      end
    rescue
      e ->
        Logger.error("Failed to process answer for #{state.peer_id}: #{inspect(e)}")
        {:noreply, %{state | creating_offer?: false}}
    end
  end

  @impl true
  def handle_cast({:add_ice_candidate, candidate_data}, state) do
    try do
      candidate = ICECandidate.from_json(candidate_data)
      Logger.debug("Received ICE candidate from client #{state.peer_id}: #{candidate.candidate}")

      case PeerConnection.add_ice_candidate(state.pc, candidate) do
        :ok ->
          {:noreply, state}

        {:error, :no_remote_description} ->
          # Queue for later
          Logger.debug("Queuing ICE candidate for peer #{state.peer_id} (no remote description yet)")
          new_queue = [candidate | state.ice_candidates_queue]
          {:noreply, %{state | ice_candidates_queue: new_queue}}

        {:error, reason} ->
          Logger.warning("Failed to add ICE candidate for peer #{state.peer_id}: #{inspect(reason)}")
          {:noreply, state}
      end
    rescue
      e ->
        Logger.error("Failed to parse ICE candidate from client #{state.peer_id}: #{inspect(e)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:create_offer, state) do
    handle_info(:create_offer, state)
  end

  ## Info handlers

  # Create a server-initiated offer (for renegotiation after adding tracks)
  @impl true
  def handle_info(:create_offer, state) do
    pc_state = PeerConnection.get_signaling_state(state.pc)

    cond do
      state.creating_offer? ->
        Logger.debug("Offer generation already in progress for peer #{state.peer_id}, skipping")
        {:noreply, state}

      pc_state != :stable ->
        Logger.debug("PC signaling state is #{pc_state}, delaying offer for peer #{state.peer_id}")
        Process.send_after(self(), :create_offer, 500)
        {:noreply, state}

      true ->
        Logger.info("Creating renegotiation offer for peer #{state.peer_id}")
        case PeerConnection.create_offer(state.pc) do
          {:ok, offer} ->
            Logger.debug("Generated offer SDP: #{offer.sdp}")
            :ok = PeerConnection.set_local_description(state.pc, offer)
            offer_json = SessionDescription.to_json(offer)
            send_to_client(state.room_id, state.peer_id, "offer", offer_json)
            Logger.info("Sent renegotiation offer to client #{state.peer_id}")
            {:noreply, %{state | creating_offer?: true}}

          {:error, reason} ->
            Logger.error("Failed to create offer for peer #{state.peer_id}: #{inspect(reason)}")
            {:noreply, state}
        end
    end
  end

  # Process pending remote tracks (tracks from other peers to forward)
  @impl true
  def handle_info(:process_pending_tracks, %{pending_remote_tracks: []} = state), do: {:noreply, state}

  @impl true
  def handle_info(:process_pending_tracks, state) do
    pc_state = PeerConnection.get_signaling_state(state.pc)

    # Only add tracks if signaling is stable AND we are connected
    # establishment of the initial connection is required before we start renegotiating
    if pc_state == :stable and state.connection_state == :connected do
      Logger.info("Processing #{length(state.pending_remote_tracks)} pending remote tracks for peer #{state.peer_id}")

      {updated_state, tracks_added} =
        Enum.reduce(state.pending_remote_tracks, {state, 0}, fn {from_id, track}, {acc, count} ->
          # Create a NEW local track that acts as a proxy for the remote track
          # Use from_id as stream ID so the client can identify the peer
          stream_id = "stream_#{from_id}"
          local_proxy_track = MediaStreamTrack.new(track.kind, [stream_id])

          case PeerConnection.add_track(acc.pc, local_proxy_track) do
            {:ok, _sender} ->
              Logger.info("Added proxy #{track.kind} track from #{from_id} to #{acc.peer_id} (track: #{local_proxy_track.id}, stream: #{stream_id})")
              
              # Request a keyframe from the original publisher if it's a video track
              if track.kind == :video do
                request_pli_from_source(acc.room_id, from_id, track.id)
              end

              # Store {source_track_id, local_proxy_track} — send_rtp needs the TRACK id, not the sender id
              {%{acc | local_tracks: [{track.id, local_proxy_track} | acc.local_tracks]}, count + 1}

            {:error, reason} ->
              Logger.error("Failed to add proxy track for #{from_id}: #{inspect(reason)}")
              {acc, count}
          end
        end)

      # Clear queue and trigger renegotiation if tracks were added
      if tracks_added > 0 do
        Logger.info("Added #{tracks_added} forwarding tracks, triggering renegotiation for #{state.peer_id}")
        # Short delay to batch multiple track additions
        Process.send_after(self(), :create_offer, 100)
      end

      {:noreply, %{updated_state | pending_remote_tracks: []}}
    else
      # Signaling busy or not yet connected, retry later
      Logger.debug("Waiting for stable connection to process tracks for #{state.peer_id} (PC State: #{pc_state}, Conn State: #{state.connection_state})")
      
      # If we are not connected, we should wait longer
      delay = if state.connection_state == :connected, do: 1000, else: 2000
      Process.send_after(self(), :process_pending_tracks, delay)
      {:noreply, state}
    end
  end

  # PeerConnection notifications

  @impl true
  def handle_info(:reset_connection, state) do
    Logger.info("Resetting WebRTC connection for peer #{state.peer_id} as requested")
    
    # Close old PC
    try do
      PeerConnection.close(state.pc)
    catch
      _, _ -> :ok
    end

    # Create fresh PC
    {:ok, new_pc} = PeerConnection.start_link(
      ice_servers: @ice_servers,
      ice_aggressive_nomination: true,
      ice_port_range: 50000..50050,
      video_codecs: [
        %ExWebRTC.RTPCodecParameters{
          payload_type: 96,
          mime_type: "video/VP8",
          clock_rate: 90000
        }
      ],
      audio_codecs: [
        %ExWebRTC.RTPCodecParameters{
          payload_type: 111,
          mime_type: "audio/opus",
          clock_rate: 48000,
          channels: 2
        }
      ],
      ice_ip_filter: fn ip ->
        ip_str = :inet.ntoa(ip) |> to_string()
        not (String.starts_with?(ip_str, "127.") or 
             String.contains?(ip_str, ":") or 
             String.starts_with?(ip_str, "172."))
      end
    )
    :ok = PeerConnection.controlling_process(new_pc, self())

    # We keep local_tracks (they will be re-added when the client sends a new offer and 
    # we process_pending_tracks)
    # Actually, we should probably clear them because they are tied to the OLD PC.
    
    # Re-inform RoomSession that we are fresh so it can re-send existing tracks
    case get_room_session(state.room_id) do
      {:ok, pid} -> send(pid, {:peer_restarted, state.peer_id})
      _ -> nil
    end

    {:noreply, %{state | 
      pc: new_pc, 
      local_tracks: [], 
      remote_tracks: [], 
      pending_remote_tracks: [], 
      ice_candidates_queue: [],
      connection_state: :new,
      signaling_state: :stable,
      creating_offer?: false
    }}
  end

  @impl true
  def handle_info({:ex_webrtc, _pc, {:ice_candidate, candidate}}, state) do
    Logger.debug("Generated ICE candidate for peer #{state.peer_id}")

    candidate_json = ICECandidate.to_json(candidate)
    send_to_client(state.room_id, state.peer_id, "ice", candidate_json)

    {:noreply, state}
  end

  @impl true
  def handle_info({:ex_webrtc, _pc, {:connection_state_change, new_state}}, state) do
    Logger.info("Peer #{state.peer_id} connection state changed to: #{new_state}")

    if new_state == :connected do
      Logger.info("Connection established for #{state.peer_id}, processing pending remote tracks")
      send(self(), :process_pending_tracks)
    end

    # Notify room about connection state
    PubSub.broadcast(
      Judiciary.PubSub,
      "room:#{state.room_id}",
      {:peer_connection_state, state.peer_id, new_state}
    )

    {:noreply, %{state | connection_state: new_state}}
  end

  @impl true
  def handle_info({:ex_webrtc, _pc, {:signaling_state_change, new_state}}, state) do
    Logger.debug("Peer #{state.peer_id} signaling state: #{new_state}")

    if new_state == :stable do
      send(self(), :process_pending_tracks)
    end

    {:noreply, %{state | signaling_state: new_state}}
  end

  # Handle incoming track from the client
  @impl true
  def handle_info({:ex_webrtc, _pc, {:track, track}}, state) do
    Logger.info("Received #{track.kind} track from client #{state.peer_id} (track ID: #{track.id})")

    # Notify RoomSession about the new track so it can forward to other peers
    case get_room_session(state.room_id) do
      {:ok, pid} ->
        send(pid, {:peer_track_added, state.peer_id, track})
      :error ->
        Logger.warning("RoomSession not found for track notification")
    end

    {:noreply, %{state | remote_tracks: [track | state.remote_tracks]}}
  end

  # Handle incoming RTP packet from the client
  # ex_webrtc sends {:rtp, track_id, rid, packet} where rid is nil for non-simulcast
  @impl true
  def handle_info({:ex_webrtc, _pc, {:rtp, track_id, _rid, packet}}, state) do
    # Forward RTP packet to RoomSession for distribution to other peers
    case get_room_session(state.room_id) do
      {:ok, pid} ->
        # Sample logging
        if :rand.uniform(100) == 1 do
          Logger.debug("RECEIVE: RTP from #{state.peer_id} on track #{track_id}")
        end
        send(pid, {:rtp_packet, state.peer_id, track_id, packet})
      :error ->
        nil
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:ex_webrtc, _pc, {:rtcp, packets}}, state) do
    # Check if any of the RTCP packets are PLIs (Picture Loss Indicators)
    # If so, we notify the room session to forward the request to the original publisher
    for packet <- packets do
      case packet do
        {_ssrc, %PLI{media_ssrc: media_ssrc}} ->
          Logger.info("Received PLI from client #{state.peer_id} for media SSRC #{media_ssrc}")
          notify_room_about_pli(state, media_ssrc)
        _ ->
          nil
      end
    end
    {:noreply, state}
  end

  @impl true
  def handle_info({:request_pli, track_id}, state) do
    # This is a request from another peer (via RoomSession) to send a keyframe
    # because they just subscribed to our track.
    Logger.info("Requesting PLI from client #{state.peer_id} for track #{track_id}")
    PeerConnection.send_pli(state.pc, track_id)
    {:noreply, state}
  end

  @impl true
  def handle_info({:ex_webrtc, _pc, :negotiation_needed}, state) do
    Logger.debug("Negotiation needed for peer #{state.peer_id}")
    send(self(), :create_offer)
    {:noreply, state}
  end

  @impl true
  def handle_info({:ex_webrtc, _pc, {:ice_transport_state_change, _state}}, state), do: {:noreply, state}

  @impl true
  def handle_info({:ex_webrtc, _pc, {:dtls_transport_state_change, _state}}, state), do: {:noreply, state}

  @impl true
  def handle_info({:ex_webrtc, _pc, {:ice_connection_state_change, _state}}, state), do: {:noreply, state}

  @impl true
  def handle_info({:ex_webrtc, _pc, msg}, state) do
    Logger.debug("Unhandled WebRTC message for #{state.peer_id}: #{inspect(msg)}")
    {:noreply, state}
  end

  # Handle request to add remote track from another peer (forwarding)
  @impl true
  def handle_info({:add_remote_track, from_peer_id, remote_track}, state) do
    Logger.info("Queuing #{remote_track.kind} track from #{from_peer_id} for forwarding to #{state.peer_id}")

    # Add to pending queue
    new_pending = [{from_peer_id, remote_track} | state.pending_remote_tracks]

    # Trigger processing
    send(self(), :process_pending_tracks)

    {:noreply, %{state | pending_remote_tracks: new_pending}}
  end

  # Handle RTP packet to forward to this peer's client
  @impl true
  def handle_info({:forward_rtp, source_track_id, packet}, state) do
    # Only forward packets if we are connected
    if state.connection_state == :connected do
      # Find the local proxy track that corresponds to this source track
      case Enum.find(state.local_tracks, fn {remote_id, _local_track} -> remote_id == source_track_id end) do
        {_remote_id, local_track} ->
          # Targeted sampled logging
          if :rand.uniform(500) == 1 do
            Logger.debug("FORWARD: Sending RTP to #{state.peer_id} from source track #{source_track_id} via local track #{local_track.id}")
          end
          # Send the RTP packet to our client through the proxy track
          PeerConnection.send_rtp(state.pc, local_track.id, packet)
        nil ->
          # Track not yet added or negotiation in progress — silently ignore
          if :rand.uniform(500) == 1 do
            Logger.debug("MISS: Target #{state.peer_id} has no local track for source track #{source_track_id}. Local tracks: #{inspect(Enum.map(state.local_tracks, &elem(&1, 0)))}")
          end
          nil
      end
    else
      if :rand.uniform(500) == 1 do
        Logger.debug("SKIP: Target #{state.peer_id} connection state is #{state.connection_state}")
      end
    end

    {:noreply, state}
  end

  # Ignore broadcast messages that are meant for other processes
  @impl true
  def handle_info({:peer_admitted, _peer_id, _display_name}, state), do: {:noreply, state}

  @impl true
  def handle_info({:webrtc_signal_to_client, _peer_id, _signal_type, _signal}, state), do: {:noreply, state}

  @impl true
  def handle_info({:peer_joined_webrtc, _peer_id, _metadata}, state), do: {:noreply, state}

  @impl true
  def handle_info({:peer_left, _peer_id}, state), do: {:noreply, state}

  @impl true
  def handle_info({:peer_joined_call, _peer_id, _display_name}, state), do: {:noreply, state}

  @impl true
  def handle_info(%{event: "presence_diff"}, state), do: {:noreply, state}

  @impl true
  def handle_info({:peer_connection_state, _peer_id, _connection_state}, state), do: {:noreply, state}

  @impl true
  def handle_info({:peer_track, _peer_id, _track_kind}, state), do: {:noreply, state}

  @impl true
  def handle_info({:peer_track_added, _peer_id, _track}, state), do: {:noreply, state}

  @impl true
  def handle_info({:rtp_packet, _from_peer_id, _track_id, _packet}, state), do: {:noreply, state}

  @impl true
  def handle_info({:webrtc_signal, _from_peer_id, _to_peer_id, _signal}, state), do: {:noreply, state}

  @impl true
  def handle_info({:new_message, _message}, state), do: {:noreply, state}

  # Catch-all for other messages
  @impl true
  def handle_info(msg, state) do
    Logger.debug("WebRTCPeer #{state.peer_id} ignoring message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Terminating WebRTC peer #{state.peer_id}: #{inspect(reason)}")

    if state.pc do
      PeerConnection.close(state.pc)
    end

    :ok
  end

  ## Private Functions

  defp via_tuple(room_id, peer_id) do
    {:via, Registry, {Judiciary.Media.PeerRegistry, {room_id, peer_id}}}
  end

  defp send_to_client(room_id, peer_id, signal_type, signal) do
    # Send signal to specific client via LiveView
    PubSub.broadcast(
      Judiciary.PubSub,
      "room:#{room_id}",
      {:webrtc_signal_to_client, peer_id, signal_type, signal}
    )
  end

  defp get_room_session(room_id) do
    case Registry.lookup(Judiciary.Media.RoomRegistry, room_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp request_pli_from_source(room_id, source_peer_id, source_track_id) do
    case get_room_session(room_id) do
      {:ok, pid} -> send(pid, {:request_pli, source_peer_id, source_track_id})
      :error -> nil
    end
  end

  defp notify_room_about_pli(state, _media_ssrc) do
    # Find which remote track (the track we are forwarding TO this client) 
    # matches this SSRC.
    case get_room_session(state.room_id) do
      {:ok, room_pid} ->
        # We need to know which source track this SSRC corresponds to.
        # This information is tricky as ex_webrtc hides SSRC details.
        # But for now, we can request a PLI for ALL video tracks 
        # from other peers to this room.
        send(room_pid, {:request_all_video_plis, state.peer_id})
      :error -> 
        nil
    end
  end

  defp process_ice_queue(%{ice_candidates_queue: []} = state), do: state
  defp process_ice_queue(%{ice_candidates_queue: queue, pc: pc} = state) do
    Enum.each(queue, fn candidate ->
      case PeerConnection.add_ice_candidate(pc, candidate) do
        :ok ->
          Logger.debug("Processed queued ICE candidate")
        {:error, reason} ->
          Logger.warning("Failed to process queued ICE candidate: #{inspect(reason)}")
      end
    end)

    %{state | ice_candidates_queue: []}
  end

  defp send_answer(state) do
    {:ok, answer} = PeerConnection.create_answer(state.pc)
    Logger.debug("Generated answer SDP: #{answer.sdp}")
    :ok = PeerConnection.set_local_description(state.pc, answer)

    # Send answer back to client via LiveView
    answer_json = SessionDescription.to_json(answer)
    send_to_client(state.room_id, state.peer_id, "answer", answer_json)

    # Process queued ICE candidates
    process_ice_queue(state)
  end

  defp recreate_pc_and_accept_offer(offer, state) do
    Logger.warning("Recreating PC for peer #{state.peer_id} as last resort recovery")
    
    # Notify client to also reset their side for a clean slate
    # This prevents ICE mismatches between old and new PCs
    PubSub.broadcast(
      Judiciary.PubSub,
      "room:#{state.room_id}",
      {:webrtc_signal_to_client, state.peer_id, "reconnect", %{}}
    )

    try do
      PeerConnection.close(state.pc)
    catch
      _, _ -> :ok
    end
    
    {:ok, new_pc} = PeerConnection.start_link(ice_servers: @ice_servers)
    :ok = PeerConnection.controlling_process(new_pc, self())
    
    # Create NEW proxy tracks for all tracks we were previously forwarding
    new_local_tracks = Enum.map(state.local_tracks, fn {source_track_id, old_track} ->
      # Extract streams (should be [source_peer_id])
      streams = old_track.streams
      new_proxy = MediaStreamTrack.new(old_track.kind, streams)
      
      case PeerConnection.add_track(new_pc, new_proxy) do
        {:ok, _sender} -> {source_track_id, new_proxy}
        _ -> nil
      end
    end) |> Enum.filter(& &1)
    
    new_state = %{state | pc: new_pc, local_tracks: new_local_tracks, ice_candidates_queue: [], creating_offer?: false}
    
    # Try to apply the offer to the NEW PC
    case PeerConnection.set_remote_description(new_pc, offer) do
      :ok ->
        send_answer(new_state)
        {:noreply, new_state}
      {:error, reason} ->
        Logger.error("Failed to set remote description on fresh PC for #{state.peer_id}: #{inspect(reason)}")
        {:noreply, new_state}
    end
  end
end
