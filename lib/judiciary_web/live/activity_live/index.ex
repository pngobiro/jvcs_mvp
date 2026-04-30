defmodule JudiciaryWeb.ActivityLive.Index do
  use JudiciaryWeb, :live_view

  alias Judiciary.Court
  alias Judiciary.Court.Activity

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Judiciary.PubSub, "activities")
    end

    {:ok, stream(socket, :activities, Court.list_activities())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Activity")
    |> assign(:activity, Court.get_activity!(id))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Activity")
    |> assign(:activity, %Activity{})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Activities")
    |> assign(:activity, nil)
  end

  @impl true
  def handle_info({:activity_updated, activity}, socket) do
    {:noreply, stream_insert(socket, :activities, activity)}
  end

  @impl true
  def handle_info({JudiciaryWeb.ActivityLive.FormComponent, {:saved, activity}}, socket) do
    {:noreply, stream_insert(socket, :activities, activity)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    activity = Court.get_activity!(id)
    {:ok, _} = Court.delete_activity(activity)

    {:noreply, stream_delete(socket, :activities, activity)}
  end

  defp status_classes("in_progress"), do: "bg-red-100 text-red-700 border-red-200 shadow-sm"
  defp status_classes("completed"), do: "bg-green-100 text-green-700 border-green-200"
  defp status_classes("pending"), do: "bg-zinc-100 text-zinc-700 border-zinc-200"
  defp status_classes("cancelled"), do: "bg-orange-100 text-zinc-500 border-zinc-200 opacity-50"
  defp status_classes(_), do: "bg-zinc-50 text-zinc-500 border-zinc-100"
end
