defmodule JudiciaryWeb.VirtualRoomLive.FormComponent do
  use JudiciaryWeb, :live_component

  alias Judiciary.Court

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        {@title}
        <:subtitle>Configure virtual chambers and bench rooms.</:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="virtual-room-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <.input field={@form[:name]} type="text" label="Room Name" placeholder="e.g. Hon. Justice Tech's Chambers" />
        <.input 
          field={@form[:type]} 
          type="select" 
          label="Room Type" 
          options={[{"Judicial Chamber", "chamber"}, {"Multi-Judge Bench", "bench"}, {"Public Courtroom", "public"}]} 
        />
        <.input field={@form[:slug]} type="text" label="URL Slug" placeholder="justice-tech-chamber" />
        
        <%= if Ecto.Changeset.get_field(@form.source, :type) == "chamber" do %>
          <.input
            field={@form[:presiding_officer_id]}
            type="select"
            label="Presiding Officer"
            options={@judge_options}
            prompt="Select a Judge"
          />
        <% end %>

        <%= if Ecto.Changeset.get_field(@form.source, :type) == "bench" do %>
          <div class="space-y-2">
            <label class="block text-sm font-semibold leading-6 text-zinc-800">Bench Members</label>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-2 p-4 bg-zinc-50 rounded-xl border border-zinc-200">
              <%= for {name, id} <- @judge_options do %>
                <label class="flex items-center gap-2 cursor-pointer">
                  <input 
                    type="checkbox" 
                    name="virtual_room[bench_members][]" 
                    value={id} 
                    checked={id in (Ecto.Changeset.get_field(@form.source, :bench_members) || [])}
                    class="rounded border-zinc-300 text-judiciary-green focus:ring-judiciary-green" 
                  />
                  <span class="text-xs font-bold text-zinc-700">{name}</span>
                </label>
              <% end %>
            </div>
            <p class="text-[10px] text-zinc-400 uppercase tracking-tighter italic">Select all judges presiding in this bench</p>
          </div>
        <% end %>

        <:actions>
          <.button phx-disable-with="Saving...">Save Virtual Room</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def update(%{virtual_room: virtual_room} = assigns, socket) do
    changeset = Court.change_virtual_room(virtual_room)
    
    judges = Judiciary.Accounts.list_users() |> Enum.filter(&(&1.role == "judge"))
    judge_options = Enum.map(judges, &{&1.name, &1.id})

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:judge_options, judge_options)
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("validate", %{"virtual_room" => room_params}, socket) do
    # Handle empty bench_members array if checkbox is unselected
    room_params = Map.put_new(room_params, "bench_members", [])
    
    changeset =
      socket.assigns.virtual_room
      |> Court.change_virtual_room(room_params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"virtual_room" => room_params}, socket) do
    # Handle empty bench_members array if checkbox is unselected
    room_params = Map.put_new(room_params, "bench_members", [])
    save_virtual_room(socket, socket.assigns.action, room_params)
  end

  defp save_virtual_room(socket, :edit, room_params) do
    case Court.update_virtual_room(socket.assigns.virtual_room, room_params) do
      {:ok, virtual_room} ->
        notify_parent({:saved, virtual_room})

        {:noreply,
         socket
         |> put_flash(:info, "Virtual Room updated successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_virtual_room(socket, :new, room_params) do
    case Court.create_virtual_room(room_params) do
      {:ok, virtual_room} ->
        notify_parent({:saved, virtual_room})

        {:noreply,
         socket
         |> put_flash(:info, "Virtual Room created successfully")
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
