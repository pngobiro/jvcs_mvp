defmodule JudiciaryWeb.ActivityLive.Room do
  use JudiciaryWeb, :live_view

  alias Judiciary.Court
  alias JudiciaryWeb.Presence
  alias Phoenix.PubSub

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    activity = Court.get_activity!(id)
    
    if connected?(socket) do
      PubSub.subscribe(Judiciary.PubSub, "room:#{activity.id}")
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
     |> assign(:current_peer_id, nil)}
  end

  @impl true
  def handle_event("set_identity", %{"name" => name, "role" => role}, socket) do
    peer_id = Math.random_id()
    # Judge and Clerk are admitted by default for the MVP, others start in waiting
    status = if role in ["judge", "clerk"], do: "admitted", else: "waiting"
    
    if connected?(socket) do
      Presence.track(self(), "room:#{socket.assigns.activity.id}", peer_id, %{
        display_name: name,
        role: role,
        status: status,
        online_at: inspect(System.system_time(:second))
      })
    end

    {:noreply,
     socket
     |> assign(:display_name, name)
     |> assign(:role, role)
     |> assign(:status, status)
     |> assign(:current_peer_id, peer_id)}
  end

  @impl true
  def handle_event("admit_peer", %{"peer_id" => peer_id}, socket) do
    if socket.assigns.role in ["judge", "clerk"] do
      PubSub.broadcast(Judiciary.PubSub, "room:#{socket.assigns.activity.id}", {:peer_admitted, peer_id})
    end
    {:noreply, socket}
  end

  @impl true
  def handle_event("send_message", %{"body" => body, "to" => to}, socket) do
    message = %{
      id: Math.random_id(),
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
    {:noreply, socket}
  end

  @impl true
  def handle_event("webrtc_signaling", %{"to" => to, "payload" => payload}, socket) do
    PubSub.broadcast(Judiciary.PubSub, "room:#{socket.assigns.activity.id}", 
      {:webrtc_signaling, to, socket.assigns.current_peer_id, payload})
    {:noreply, socket}
  end

  @impl true
  def handle_info(%{event: "presence_diff", payload: _payload}, socket) do
    peers = Presence.list("room:#{socket.assigns.activity.id}")
    {:noreply, assign(socket, :peers, peers)}
  end

  @impl true
  def handle_info({:peer_admitted, peer_id}, socket) do
    if socket.assigns.current_peer_id == peer_id do
      # Update own presence status
      Presence.update(self(), "room:#{socket.assigns.activity.id}", peer_id, fn meta ->
        Map.put(meta, :status, "admitted")
      end)
      {:noreply, assign(socket, :status, "admitted")}
    else
      {:noreply, socket}
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
end

defmodule Math do
  def random_id, do: :crypto.strong_rand_bytes(8) |> Base.url_encode64() |> binary_part(0, 8)
end
