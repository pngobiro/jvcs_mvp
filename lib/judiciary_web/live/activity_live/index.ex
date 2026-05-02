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
    case Court.get_activity(id) do
      nil ->
        socket
        |> put_flash(:error, "Activity not found")
        |> push_navigate(to: ~p"/activities")

      activity ->
        socket
        |> assign(:page_title, "Edit Activity")
        |> assign(:activity, activity)
    end
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
    case Court.get_activity(id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Activity not found")
         |> push_navigate(to: ~p"/activities")}

      activity ->
        {:ok, _} = Court.delete_activity(activity)
        {:noreply, stream_delete(socket, :activities, activity)}
    end
  end

  @impl true
  def handle_event("transcribe", %{"id" => id}, socket) do
    activity = Court.get_activity!(id)

    if activity.recording_url do
      # Trigger transcription in background
      %{activity_id: activity.id, recording_url: activity.recording_url}
      |> Judiciary.Workers.Transcriber.new()
      |> Oban.insert()

      {:noreply,
       socket
       |> put_flash(:info, "Transcription task started for #{activity.case_number}")}
    else
      {:noreply,
       socket
       |> put_flash(:error, "No recording found for this activity")}
    end
  end

  defp status_classes("in_progress"), do: "bg-red-100 text-red-700 border-red-200 shadow-sm"
  defp status_classes("completed"), do: "bg-green-100 text-green-700 border-green-200"
  defp status_classes("pending"), do: "bg-zinc-100 text-zinc-700 border-zinc-200"
  defp status_classes("cancelled"), do: "bg-orange-100 text-zinc-500 border-zinc-200 opacity-50"
  defp status_classes(_), do: "bg-zinc-50 text-zinc-500 border-zinc-100"
end
