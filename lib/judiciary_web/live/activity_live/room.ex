defmodule JudiciaryWeb.ActivityLive.Room do
  use JudiciaryWeb, :live_view

  require Logger

  alias Judiciary.Court
  alias Judiciary.Media.RoomSession
  alias JudiciaryWeb.Presence
  alias Phoenix.PubSub

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    activity = Court.get_activity!(id)

    if connected?(socket) do
      PubSub.subscribe(Judiciary.PubSub, "room:#{activity.id}")
      # Attempt to start room session (non-blocking)
      Judiciary.Media.RoomSupervisor.start_room(activity.id)
    end

    {:ok,
     socket
     |> assign(:activity, activity)
     |> assign(:page_title, "Court Room: #{activity.title}")
     |> assign(:display_name, nil)
     |> assign(:role, "guest")
     |> assign(:status, "waiting") # waiting | admitted
     |> assign(:peers, %{})
     |> assign(:messages, [])
     |> assign(:current_peer_id, nil)
     |> assign(:sidebar_open, false)
     |> assign(:connection_status, :connecting)
     |> assign(:error_message, nil)}
  end

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :sidebar_open, !socket.assigns.sidebar_open)}
  end

  @impl true
  def handle_event("set_identity", %{"name" => name, "role" => role}, socket) do
    peer_id = M.random_id()
    # Judge and Clerk are admitted by default for the MVP, others start in waiting
    status = if role in ["judge", "clerk"], do: "admitted", else: "waiting"

    if connected?(socket) do
      Presence.track(self(), "room:#{socket.assigns.activity.id}", peer_id, %{
        display_name: name,
        role: role,
        status: status,
        online_at: System.system_time(:second)
      })

      # Register peer with room session for state tracking
      case RoomSession.add_peer(socket.assigns.activity.id, peer_id, %{
        name: name,
        role: role
      }) do
        {:ok, _} ->
          Logger.info("Peer #{peer_id} registered with room session")
        {:error, reason} ->
          Logger.error("Failed to register peer: #{inspect(reason)}")
      end
    end

    {:noreply,
     socket
     |> assign(:display_name, name)
     |> assign(:role, role)
     |> assign(:status, status)
     |> assign(:current_peer_id, peer_id)
     |> assign(:connection_status, :connected)}
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

      PubSub.broadcast(Judiciary.PubSub, "room:#{socket.assigns.activity.id}", {:peer_admitted, peer_id, display_name})
    end
    {:noreply, socket}
  end

  @impl true
  def handle_event("send_message", %{"body" => body, "to" => to}, socket) do
    message = %{
      id: M.random_id(),
      from: socket.assigns.display_name,
      from_id: socket.assigns.current_peer_id,
      body: body,
      type: if(to == "all", do: "public", else: "private"),
      at: DateTime.utc_now()
    }

    if to == "all" do
      PubSub.broadcast(Judiciary.PubSub, "room:#{socket.assigns.activity.id}", {:new_message, message})
    else
      # Private message
      PubSub.broadcast(Judiciary.PubSub, "room:#{socket.assigns.activity.id}", {:private_message, to, message})
      # Also add to sender's own list
      {:noreply, assign(socket, :messages, socket.assigns.messages ++ [message])}
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
  def handle_event("webrtc_signaling", %{"to" => to, "payload" => payload}, socket) do
    # Send through room session for queuing and retry logic
    case RoomSession.send_signal(socket.assigns.activity.id, socket.assigns.current_peer_id, to, payload) do
      :ok ->
        {:noreply, socket}
      {:error, reason} ->
        Logger.error("Failed to send signal: #{inspect(reason)}")
        error_msg = "Signal delivery failed: #{inspect(reason)}"
        {:noreply, assign(socket, :error_message, error_msg)}
    end
  end

  @impl true
  def handle_info(%{event: "presence_diff", payload: _payload}, socket) do
    peers = Presence.list("room:#{socket.assigns.activity.id}")
    {:noreply, assign(socket, :peers, peers)}
  end

  @impl true
  def handle_info({:peer_admitted, peer_id, display_name}, socket) do
    if socket.assigns.current_peer_id == peer_id do
      # Update own presence status
      Presence.update(self(), "room:#{socket.assigns.activity.id}", peer_id, fn meta ->
        Map.put(meta, :status, "admitted")
      end)
      {:noreply, assign(socket, :status, "admitted")}
    else
      # For everyone else, start the WebRTC handshake for this newly admitted peer
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
  def handle_info({:webrtc_signaling, target_peer_id, from_peer_id, payload}, socket) do
    if socket.assigns.current_peer_id == target_peer_id do
      {:noreply, push_event(socket, "webrtc_signaling", %{from: from_peer_id, payload: payload})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:connection_error, error}, socket) do
    Logger.error("Connection error: #{inspect(error)}")
    {:noreply, assign(socket, :error_message, error)}
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns.current_peer_id do
      case RoomSession.remove_peer(socket.assigns.activity.id, socket.assigns.current_peer_id) do
        :ok ->
          Logger.info("Peer #{socket.assigns.current_peer_id} removed from room session")
        {:error, err} ->
          Logger.error("Error removing peer: #{inspect(err)}")
      end
    end
    :ok
  end

  ## Helpers

  defp start_room_session(room_id) do
    Judiciary.Media.RoomSupervisor.start_room(room_id)
  end
end

defmodule M do
  def random_id, do: :crypto.strong_rand_bytes(8) |> Base.url_encode64() |> binary_part(0, 8)
end
