defmodule JudiciaryWeb.ActivityLive.FormComponent do
  use JudiciaryWeb, :live_component

  alias Judiciary.Court

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        {@title}
        <:subtitle>Use this form to manage activity records in your database.</:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="activity-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <.input
          field={@form[:court_id]}
          type="select"
          label="Court"
          options={@court_options}
          prompt="Select a Court"
        />
        <.input
          field={@form[:judge_id]}
          type="select"
          label="Presiding Judge"
          options={@judge_options}
          prompt="Select a Judge"
        />
        <.input
          field={@form[:virtual_room_id]}
          type="select"
          label="Assigned Virtual Room"
          options={@room_options}
          prompt="Select a Room"
        />
        <.input field={@form[:link]} type="text" label="Meeting Link" />
        <.input field={@form[:case_number]} type="text" label="Case number" />
        <.input field={@form[:title]} type="text" label="Title" />
        <.input field={@form[:start_time]} type="datetime-local" label="Start time" />
        <.input
          field={@form[:status]}
          type="select"
          label="Status"
          options={["pending", "in_progress", "completed", "cancelled"]}
        />
        <.input field={@form[:judge_name]} type="text" label="Judge name" />
        <:actions>
          <.button phx-disable-with="Saving...">Save Activity</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def update(%{activity: activity} = assigns, socket) do
    changeset = Court.change_activity(activity)
    courts = Court.list_courts()
    court_options = Enum.map(courts, &{&1.name, &1.id})

    judges = Judiciary.Accounts.list_users() |> Enum.filter(&(&1.role == "judge"))
    judge_options = Enum.map(judges, &{&1.name, &1.id})

    rooms = Court.list_virtual_rooms()
    room_options = Enum.map(rooms, &{"#{&1.name} (#{&1.type})", &1.id})

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:court_options, court_options)
     |> assign(:judge_options, judge_options)
     |> assign(:room_options, room_options)
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("validate", %{"activity" => activity_params}, socket) do
    changeset =
      socket.assigns.activity
      |> Court.change_activity(activity_params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"activity" => activity_params}, socket) do
    save_activity(socket, socket.assigns.action, activity_params)
  end

  defp save_activity(socket, :edit, activity_params) do
    case Court.update_activity(socket.assigns.activity, activity_params) do
      {:ok, activity} ->
        notify_parent({:saved, activity})

        {:noreply,
         socket
         |> put_flash(:info, "Activity updated successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_activity(socket, :new, activity_params) do
    case Court.create_activity(activity_params) do
      {:ok, activity} ->
        notify_parent({:saved, activity})

        {:noreply,
         socket
         |> put_flash(:info, "Activity created successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
