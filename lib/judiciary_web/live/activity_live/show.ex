defmodule JudiciaryWeb.ActivityLive.Show do
  use JudiciaryWeb, :live_view

  alias Judiciary.Court

  @impl true
  def mount(_params, _session, socket) do
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

  defp page_title(:show), do: "Show Activity"
  defp page_title(:edit), do: "Edit Activity"
end
