defmodule JudiciaryWeb.VirtualRoomLive.Index do
  use JudiciaryWeb, :live_view

  alias Judiciary.Court
  alias Judiciary.Court.VirtualRoom

  @impl true
  def mount(_params, _session, socket) do
    {:ok, stream(socket, :virtual_rooms, Court.list_virtual_rooms())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Virtual Room")
    |> assign(:virtual_room, Court.get_virtual_room!(id))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Virtual Room")
    |> assign(:virtual_room, %VirtualRoom{})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Virtual Rooms")
    |> assign(:virtual_room, nil)
  end

  @impl true
  def handle_info({JudiciaryWeb.VirtualRoomLive.FormComponent, {:saved, virtual_room}}, socket) do
    {:noreply, stream_insert(socket, :virtual_rooms, virtual_room)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    virtual_room = Court.get_virtual_room!(id)
    {:ok, _} = Court.delete_virtual_room(virtual_room)

    {:noreply, stream_delete(socket, :virtual_rooms, virtual_room)}
  end
end
