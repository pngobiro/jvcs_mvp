defmodule JudiciaryWeb.ActivityLive.Room do
  use JudiciaryWeb, :live_view

  require Logger

  alias Judiciary.Court
  alias Judiciary.Media.RoomSession
  alias JudiciaryWeb.Presence
  alias Phoenix.PubSub

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    # Handle "main" ID for a constant/stable test room
    activity = case id do
      "main" ->
        case Court.list_activities() do
          [first | _] -> first
          [] -> 
            # Fallback for empty DB
            %Judiciary.Court.Activity{id: 0, title: "Main Courtroom", case_number: "DEMO-001", judge_name: "Presiding Officer"}
        end
      _ -> Court.get_activity(id)
    end

    case activity do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Activity not found")
         |> redirect(to: ~p"/activities")}

      activity ->
        mount_with_activity(activity, socket)
    end
  end

  defp mount_with_activity(activity, socket) do
    topic = "room:#{activity.id}"

    user = socket.assigns.current_scope.user
    display_name = user.name
    role = user.role
    
    # Use assign_new to keep the same peer_id between static and live render
    socket = assign_new(socket, :current_peer_id, fn -> M.random_id() end)
    peer_id = socket.assigns.current_peer_id
    
    # Status initialization: check if already admitted (e.g. on refresh)
    # We look through current presence for ANY session belonging to this user that is 'admitted'
    peers_snapshot = if connected?(socket), do: Presence.list(topic), else: %{}
    
    already_admitted? = Enum.any?(peers_snapshot, fn {_id, %{metas: metas}} ->
      Enum.any?(metas, fn meta -> 
        Map.get(meta, :user_id) == user.id and Map.get(meta, :status) == "admitted"
      end)
    end)

    status = cond do
      role in ["judge", "clerk"] -> "admitted"
      already_admitted? -> "admitted"
      true -> "waiting"
    end

    if connected?(socket) do
      PubSub.subscribe(Judiciary.PubSub, topic)
      # Attempt to start room session (non-blocking)
      Judiciary.Media.RoomSupervisor.start_room(activity.id)

      Presence.track(self(), topic, peer_id, %{
        user_id: user.id,
        display_name: display_name,
        role: role,
        status: status,
        online_at: System.system_time(:second)
      })

      Logger.info("Tracked presence for #{peer_id}: #{display_name} (#{role}) - status: #{status}")

      # Register peer with room session for state tracking (only if not already registered)
      case RoomSession.add_peer(activity.id, peer_id, %{
        name: display_name,
        role: role
      }) do
        {:ok, :added} ->
          Logger.info("Peer #{peer_id} registered with room session")
        {:ok, :already_exists} ->
          Logger.info("Peer #{peer_id} already registered, skipping")
        {:error, reason} ->
          Logger.error("Failed to register peer: #{inspect(reason)}")
      end
    end

    peers = if connected?(socket) do
      Presence.list(topic)
    else
      %{}
    end

    Logger.info("Mount complete for #{peer_id}. Total peers in room: #{map_size(peers)}")
    Logger.debug("Peers: #{inspect(peers, pretty: true)}")

    {:ok,
     socket
     |> assign(:activity, activity)
     |> assign(:page_title, "Court Room: #{activity.title}")
     |> assign(:display_name, display_name)
     |> assign(:role, role)
     |> assign(:status, status)
     |> assign(:peers, peers)
     |> assign(:messages, [])
     |> assign(:sidebar_open, false)
     |> assign(:connection_status, :connected)
     |> assign(:recording_status, :idle)
     |> assign(:error_message, nil)}
  end

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :sidebar_open, !socket.assigns.sidebar_open)}
  end

  @impl true
  def handle_event("toggle_recording", _params, socket) do
    if socket.assigns.role in ["judge", "clerk"] do
      new_status = if socket.assigns.recording_status == :recording, do: :idle, else: :recording
      
      # Inform room session
      action = if new_status == :recording, do: :start_recording, else: :stop_recording
      RoomSession.update_recording_status(socket.assigns.activity.id, action)
      
      {:noreply, assign(socket, :recording_status, new_status)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("admit_peer", %{"peer_id" => peer_id}, socket) do
    if socket.assigns.role in ["judge", "clerk"] do
      # Find the peer's name from presence
      peers = Presence.list("room:#{socket.assigns.activity.id}")
      display_name = case Map.get(peers, peer_id) do
        %{metas: [%{display_name: name} | _]} -> name
        _ -> "Participant"
      end

      Logger.info("Admitting peer #{peer_id} (#{display_name}) to room #{socket.assigns.activity.id}")
      PubSub.broadcast(Judiciary.PubSub, "room:#{socket.assigns.activity.id}", {:peer_admitted, peer_id, display_name})
    end
    {:noreply, socket}
  end

  @impl true
  def handle_event("send_message", %{"body" => body, "to" => _to}, socket) do
    message = %{
      id: M.random_id(),
      from: socket.assigns.display_name,
      from_id: socket.assigns.current_peer_id,
      body: body,
      type: "public",
      at: DateTime.utc_now()
    }

    PubSub.broadcast(Judiciary.PubSub, "room:#{socket.assigns.activity.id}", {:new_message, message})
    {:noreply, socket}
  end

  @impl true
  def handle_event("heartbeat", %{"peer_id" => peer_id}, socket) do
    if socket.assigns.current_peer_id == peer_id do
      # Simply calling send_signal update_heartbeat logic
      # But better to have a specific function
      Judiciary.Media.RoomSession.send_signal(socket.assigns.activity.id, peer_id, peer_id, %{"type" => "heartbeat"})
    end
    {:noreply, socket}
  end

  @impl true
  def handle_event("join_call", _params, socket) do
    PubSub.broadcast_from(Judiciary.PubSub, self(), "room:#{socket.assigns.activity.id}",
      {:peer_joined_call, socket.assigns.current_peer_id, socket.assigns.display_name})
    {:noreply, assign(socket, :connection_status, :connected)}
  end

  @impl true
  def handle_event("webrtc_signaling", %{"payload" => payload, "to" => to_peer_id}, socket) do
    from = socket.assigns.current_peer_id
    Logger.info("SIGNAL EVENT: from=#{from}, to=#{to_peer_id}, type=#{Map.get(payload, "type", "ice/other")}")

    # In server-side SFU, client always talks to its own peer (to == from)

    # Send signal to room session for processing
    case RoomSession.send_signal(socket.assigns.activity.id, from, from, payload) do
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
    peers = Presence.list("room:#{socket.assigns.activity.id}")
    
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

    if socket.assigns.current_peer_id == peer_id do
      # I was admitted! Update own status
      Logger.info("I was admitted! Updating my status")

      Presence.update(self(), "room:#{socket.assigns.activity.id}", peer_id, fn meta ->
        meta
        |> Map.put(:status, "admitted")
        |> Map.put(:user_id, socket.assigns.current_scope.user.id)
      end)

      # Notify other peers (for UI updates)
      PubSub.broadcast_from(
        Judiciary.PubSub,
        self(),
        "room:#{socket.assigns.activity.id}",
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
    activity = Map.get(socket.assigns, :activity)

    if peer_id && activity do
      # Remove from room session
      case RoomSession.remove_peer(activity.id, peer_id) do
        :ok ->
          Logger.info("Peer #{peer_id} removed from room session")
        {:error, err} ->
          Logger.error("Error removing peer: #{inspect(err)}")
      end

      # Explicitly untrack from presence (though it should happen automatically)
      # This ensures cleanup even if the process crashes
      topic = "room:#{activity.id}"

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
