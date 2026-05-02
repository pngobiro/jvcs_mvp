defmodule JudiciaryWeb.ActivityLive.Show do
  use JudiciaryWeb, :live_view

  alias Judiciary.Court

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Judiciary.PubSub, "activities")
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _, socket) do
    case Court.get_activity(id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Activity not found")
         |> redirect(to: ~p"/activities")}

      activity ->
        {:noreply,
         socket
         |> assign(:page_title, page_title(socket.assigns.live_action))
         |> assign(:activity, activity)}
    end
  end

  @impl true
  def handle_event("transcribe", _params, socket) do
    activity = socket.assigns.activity

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

  @impl true
  def handle_info({:activity_updated, activity}, socket) do
    if activity.id == socket.assigns.activity.id do
      {:noreply, assign(socket, :activity, activity)}
    else
      {:noreply, socket}
    end
  end

  defp page_title(:show), do: "Show Activity"
  defp page_title(:edit), do: "Edit Activity"
end
