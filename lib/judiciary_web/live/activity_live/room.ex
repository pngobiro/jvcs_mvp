defmodule JudiciaryWeb.ActivityLive.Room do
  use JudiciaryWeb, :live_view

  alias Judiciary.Court
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
     |> assign(:joined, false)}
  end

  @impl true
  def handle_event("set_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, :display_name, name)}
  end

  @impl true
  def handle_event("join_call", %{"peer_id" => peer_id}, socket) do
    display_name = socket.assigns.display_name || "Guest"
    PubSub.broadcast_from(Judiciary.PubSub, self(), "room:#{socket.assigns.activity.id}", {:peer_joined, peer_id, display_name})
    {:noreply, socket |> assign(:current_peer_id, peer_id) |> assign(:joined, true)}
  end

  @impl true
  def handle_event("webrtc_signaling", %{"to" => to, "payload" => payload}, socket) do
    PubSub.broadcast(Judiciary.PubSub, "room:#{socket.assigns.activity.id}", {:webrtc_signaling, to, socket.assigns.current_peer_id, payload})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:peer_joined, peer_id, display_name}, socket) do
    # Tell the new peer that we are already here so they can initiate an offer
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
