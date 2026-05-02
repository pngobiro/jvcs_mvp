defmodule JudiciaryWeb.ActivityLive.Room do
  use JudiciaryWeb, :live_view

  require Logger

  alias Judiciary.Court
  alias Judiciary.Media.RoomSession
  alias JudiciaryWeb.Presence
  alias Phoenix.PubSub

  @impl true
  def mount(%{"id" => slug}, _session, socket) do
    # Handle "main" slug for a constant/stable test room
    room = case slug do
      "main" ->
        # Find or create a main courtroom
        case Court.get_virtual_room_by_slug("main-courtroom") do
          nil ->
            {:ok, room} = Court.create_virtual_room(%{
              name: "Main Courtroom",
              type: "public",
              slug: "main-courtroom"
            })
            room
          room -> room
        end
      _ -> 
        Court.get_virtual_room_by_slug(slug)
    end

    case room do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Court room not found")
         |> redirect(to: ~p"/activities")}

      room ->
        mount_with_room(room, socket)
    end
  end

  defp mount_with_room(room, socket) do
    # The room slug is used as the WebRTC identifier
    room_handle = room.slug
    topic = "room:#{room_handle}"

    user = socket.assigns.current_scope.user
    display_name = user.name
    role = user.role
    
    # Use assign_new to keep the same peer_id between static and live render
    socket = assign_new(socket, :current_peer_id, fn -> M.random_id() end)
    peer_id = socket.assigns.current_peer_id
    
    # Status initialization: check if already admitted (e.g. on refresh)
    peers_snapshot = if connected?(socket), do: Presence.list(topic), else: %{}
    
    already_admitted? = Enum.any?(peers_snapshot, fn {_id, %{metas: metas}} ->
      Enum.any?(metas, fn meta -> 
        Map.get(meta, :user_id) == user.id and Map.get(meta, :status) == "admitted"
      end)
    end)

    status = cond do
      role in ["judge", "clerk"] -> "admitted"
      # If it's your own chamber, you are admitted
      role == "judge" and room.presiding_officer_id == user.id -> "admitted"
      # If you are a member of the bench
      role == "judge" and user.id in (room.bench_members || []) -> "admitted"
      already_admitted? -> "admitted"
      true -> "waiting"
    end

    if connected?(socket) do
      PubSub.subscribe(Judiciary.PubSub, topic)
      # Attempt to start room session (non-blocking)
      Judiciary.Media.RoomSupervisor.start_room(room_handle)

      Presence.track(self(), topic, peer_id, %{
        user_id: user.id,
        display_name: display_name,
        role: role,
        status: status,
        online_at: System.system_time(:second)
      })

      Logger.info("Tracked presence for #{peer_id}: #{display_name} (#{role}) in room #{room_handle}")

      # Register peer with room session
      case RoomSession.add_peer(room_handle, peer_id, %{
        name: display_name,
        role: role
      }) do
        {:ok, _} ->
          Logger.info("Peer #{peer_id} registered with room session #{room_handle}")
        {:error, reason} ->
          Logger.error("Failed to register peer: #{inspect(reason)}")
      end

      # Push initial names to JS hook
      initial_names = Enum.reduce(Presence.list(topic), %{}, fn {p_id, %{metas: [meta | _]}}, acc ->
        Map.put(acc, p_id, meta.display_name)
      end)
      socket = push_event(socket, "initial_peer_names", %{names: initial_names})
      
      peers = Presence.list(topic)

      # Determine current activity for this session (for recording/context)
      current_activity = Enum.find(room.activities, fn a -> a.status == "in_progress" end) || 
                         Enum.find(room.activities, fn a -> a.status == "pending" end) ||
                         List.first(room.activities)

      {:ok,
       socket
       |> assign(:room, room)
       |> assign(:activity, current_activity)
       |> assign(:page_title, "Virtual Court: #{room.name}")
       |> assign(:display_name, display_name)
       |> assign(:role, role)
       |> assign(:status, status)
       |> assign(:peers, peers)
       |> assign(:messages, [])
       |> assign(:sidebar_open, false)
       |> assign(:connection_status, :connected)
       |> assign(:recording_status, :idle)
       |> assign(:error_message, nil)}
    else
      current_activity = Enum.find(room.activities, fn a -> a.status == "in_progress" end) || 
                         Enum.find(room.activities, fn a -> a.status == "pending" end) ||
                         List.first(room.activities)

      {:ok,
       socket
       |> assign(:room, room)
       |> assign(:activity, current_activity)
       |> assign(:page_title, "Virtual Court: #{room.name}")
       |> assign(:display_name, display_name)
       |> assign(:role, role)
       |> assign(:status, status)
       |> assign(:peers, %{})
       |> assign(:messages, [])
       |> assign(:sidebar_open, false)
       |> assign(:connection_status, :connected)
       |> assign(:recording_status, :idle)
       |> assign(:error_message, nil)}
    end
  end

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :sidebar_open, !socket.assigns.sidebar_open)}
  end

  @impl true
  def handle_event("reconnect_media", _params, socket) do
    Logger.info("Manual reconnection requested by #{socket.assigns.current_peer_id}")
    {:noreply, push_event(socket, "reconnect_webrtc", %{peer_id: socket.assigns.current_peer_id})}
  end

  @impl true
  def handle_event("toggle_recording", _params, socket) do
    if socket.assigns.role in ["judge", "clerk"] do
      new_status = if socket.assigns.recording_status == :recording, do: :idle, else: :recording
      
      # Inform room session
      action = if new_status == :recording, do: :start_recording, else: :stop_recording
      RoomSession.update_recording_status(socket.assigns.room.slug, action)
      
      {:noreply, assign(socket, :recording_status, new_status)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("admit_peer", %{"peer_id" => peer_id}, socket) do
    if socket.assigns.role in ["judge", "clerk"] do
      # Find the peer's name from presence
      room_handle = socket.assigns.room.slug
      peers = Presence.list("room:#{room_handle}")
      display_name = case Map.get(peers, peer_id) do
        %{metas: [%{display_name: name} | _]} -> name
        _ -> "Participant"
      end

      Logger.info("Admitting peer #{peer_id} (#{display_name}) to room #{room_handle}")
      PubSub.broadcast(Judiciary.PubSub, "room:#{room_handle}", {:peer_admitted, peer_id, display_name})
    end
    {:noreply, socket}
  end

  @impl true
  def handle_event("send_message", %{"body" => body, "to" => _to}, socket) do
    room_handle = socket.assigns.room.slug
    message = %{
      id: M.random_id(),
      from: socket.assigns.display_name,
      from_id: socket.assigns.current_peer_id,
      body: body,
      type: "public",
      at: DateTime.utc_now()
    }

    PubSub.broadcast(Judiciary.PubSub, "room:#{room_handle}", {:new_message, message})
    {:noreply, socket}
  end

  @impl true
  def handle_event("heartbeat", %{"peer_id" => peer_id}, socket) do
    if socket.assigns.current_peer_id == peer_id do
      Judiciary.Media.RoomSession.send_signal(socket.assigns.room.slug, peer_id, peer_id, %{"type" => "heartbeat"})
    end
    {:noreply, socket}
  end

  @impl true
  def handle_event("join_call", _params, socket) do
    room_handle = socket.assigns.room.slug
    PubSub.broadcast_from(Judiciary.PubSub, self(), "room:#{room_handle}",
      {:peer_joined_call, socket.assigns.current_peer_id, socket.assigns.display_name})
    {:noreply, assign(socket, :connection_status, :connected)}
  end

  @impl true
  def handle_event("webrtc_signaling", %{"payload" => payload, "to" => to_peer_id}, socket) do
    from = socket.assigns.current_peer_id
    room_handle = socket.assigns.room.slug
    Logger.info("SIGNAL EVENT: from=#{from}, to=#{to_peer_id}, type=#{Map.get(payload, "type", "ice/other")}")

    # Send signal to room session for processing
    case RoomSession.send_signal(room_handle, from, from, payload) do
      :ok ->
        {:noreply, socket}
      {:error, reason} ->
        Logger.error("Failed to send signal: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:recording_status_updated, status}, socket) do
    {:noreply, 
      socket 
      |> assign(:recording_status, status)
      |> push_event("recording_status_updated", %{status: status})}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", payload: %{joins: _joins, leaves: leaves}}, socket) do
    # Handle Leaves
    socket = Enum.reduce(leaves, socket, fn {peer_id, _}, acc_socket ->
      push_event(acc_socket, "peer_left", %{peer_id: peer_id})
    end)

    # Note: Joins are handled separately by peer_admitted or join_call for signaling logic,
    # but we still need to update the @peers assign for the UI (participants list).
    room_handle = socket.assigns.room.slug
    peers = Presence.list("room:#{room_handle}")
    
    # Robust Status Sync: check if I was admitted via presence metadata
    # (fallback for missed broadcasts)
    my_peer_id = socket.assigns.current_peer_id
    new_status = case Map.get(peers, my_peer_id) do
      %{metas: [%{status: status} | _]} -> status
      _ -> socket.assigns.status
    end

    socket = if new_status != socket.assigns.status do
      Logger.info("Status sync for #{my_peer_id}: #{socket.assigns.status} -> #{new_status}")
      
      if new_status == "admitted" do
        socket
        |> assign(:status, "admitted")
        |> push_event("reconnect_webrtc", %{peer_id: my_peer_id})
      else
        assign(socket, :status, new_status)
      end
    else
      socket
    end

    {:noreply, assign(socket, :peers, peers)}
  end

  @impl true
  def handle_info({:peer_admitted, peer_id, display_name}, socket) do
    Logger.info("Peer #{peer_id} admitted, current peer: #{socket.assigns.current_peer_id}")
    room_handle = socket.assigns.room.slug

    if socket.assigns.current_peer_id == peer_id do
      # I was admitted! Update own status
      Logger.info("I was admitted! Updating my status")

      Presence.update(self(), "room:#{room_handle}", peer_id, fn meta ->
        meta
        |> Map.put(:status, "admitted")
        |> Map.put(:user_id, socket.assigns.current_scope.user.id)
      end)

      # Notify other peers (for UI updates)
      PubSub.broadcast_from(
        Judiciary.PubSub,
        self(),
        "room:#{room_handle}",
        {:peer_joined_call, peer_id, display_name}
      )

      # Tell the JS hook to re-create the WebRTC connection now that we're admitted
      socket =
        socket
        |> assign(:status, "admitted")
        |> push_event("reconnect_webrtc", %{peer_id: peer_id})

      {:noreply, socket}
    else
      # Someone else was admitted (for UI notification)
      Logger.info("Someone else (#{peer_id}) was admitted")
      {:noreply, push_event(socket, "peer_joined", %{peer_id: peer_id, display_name: display_name})}
    end
  end

  @impl true
  def handle_info({:new_message, message}, socket) do
    {:noreply, assign(socket, :messages, socket.assigns.messages ++ [message])}
  end

  @impl true
  def handle_info({:private_message, to_id, message}, socket) do
    if socket.assigns.current_peer_id == to_id do
      {:noreply, assign(socket, :messages, socket.assigns.messages ++ [message])}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:peer_joined_call, peer_id, display_name}, socket) do
    {:noreply, push_event(socket, "peer_joined", %{peer_id: peer_id, display_name: display_name})}
  end

  @impl true
  def handle_info({:peer_joined_webrtc, _peer_id, _metadata}, socket) do
    # Ignore WebRTC peer join notifications (handled by presence)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:webrtc_signal_to_client, peer_id, signal_type, signal}, socket) do
    if socket.assigns.current_peer_id == peer_id do
      Logger.debug("Delivering #{signal_type} from server to client #{peer_id}")
      {:noreply, push_event(socket, "webrtc_signal_to_client", %{
        peer_id: peer_id,
        signal_type: signal_type,
        payload: signal
      })}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:peer_connection_state, _peer_id, _state}, socket) do
    # Ignore peer connection state updates (handled by WebRTCPeer)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:peer_left, peer_id}, socket) do
    Logger.info("Peer #{peer_id} left the room")
    {:noreply, push_event(socket, "peer_left", %{peer_id: peer_id})}
  end

  @impl true
  def handle_info({:peer_track_added, _peer_id, _track}, socket) do
    # Ignore track notifications (handled by RoomSession/WebRTCPeer)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:rtp_packet, _from, _track_id, _packet}, socket) do
    # Ignore RTP packets (handled by RoomSession/WebRTCPeer)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:connection_error, error}, socket) do
    Logger.error("Connection error: #{inspect(error)}")
    {:noreply, assign(socket, :error_message, error)}
  end

  @impl true
  def terminate(_reason, socket) do
    # Get assigns safely
    peer_id = Map.get(socket.assigns, :current_peer_id)
    room = Map.get(socket.assigns, :room)

    if peer_id && room do
      # Remove from room session
      case RoomSession.remove_peer(room.slug, peer_id) do
        :ok ->
          Logger.info("Peer #{peer_id} removed from room session")
        {:error, err} ->
          Logger.error("Error removing peer: #{inspect(err)}")
      end

      # Explicitly untrack from presence (though it should happen automatically)
      # This ensures cleanup even if the process crashes
      topic = "room:#{room.slug}"

      # Check if we're still tracking before trying to untrack
      case Presence.get_by_key(topic, peer_id) do
        [] ->
          Logger.debug("Peer #{peer_id} already untracked from presence")
        _ ->
          # We're still tracked, but since we're terminating, Presence will auto-cleanup
          Logger.debug("Peer #{peer_id} will be auto-untracked by Presence")
      end
    end

    :ok
  end
end

defmodule M do
  def random_id, do: :crypto.strong_rand_bytes(8) |> Base.url_encode64() |> binary_part(0, 8)
end
