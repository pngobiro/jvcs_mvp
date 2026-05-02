defmodule JudiciaryWeb.UserLive.Settings do
  use JudiciaryWeb, :live_view

  on_mount {JudiciaryWeb.UserAuth, :require_sudo_mode}

  alias Judiciary.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-[80vh] flex flex-col items-center justify-center bg-zinc-50 py-12 px-4 sm:px-6 lg:px-8">
      
      <div class="w-full max-w-2xl mb-4 flex justify-start">
        <.link navigate={~p"/"} class="bg-white border-2 border-zinc-200 text-zinc-600 hover:text-judiciary-green hover:border-judiciary-green hover:bg-judiciary-green/5 px-4 py-2 rounded-xl text-sm font-black uppercase tracking-widest flex items-center gap-2 shadow-sm transition-all active:scale-95">
          <.icon name="hero-arrow-left-solid" class="w-5 h-5" />
          Return to Home
        </.link>
      </div>

      <div class="max-w-2xl w-full bg-white p-10 rounded-3xl shadow-2xl border-t-8 border-judiciary-green">
        <div class="text-center mb-10">
          <div class="flex justify-center mb-6">
            <div class="p-3 bg-zinc-50 rounded-2xl shadow-inner border border-zinc-100">
              <img src={~p"/images/judiciary-logo.png"} class="h-16 w-auto object-contain" alt="Judiciary Logo" />
            </div>
          </div>
          <h2 class="mt-2 text-3xl font-black tracking-tight text-zinc-900 uppercase">
            Account Settings
          </h2>
          <p class="mt-2 text-sm text-zinc-500 font-medium">
            Manage your official profile and security credentials
          </p>
        </div>

        <div class="space-y-12">
          <!-- Profile Section -->
          <div class="bg-zinc-50 p-6 rounded-2xl border border-zinc-200">
            <div class="flex items-center gap-4 mb-6 pb-4 border-b border-zinc-200">
              <div class="w-12 h-12 bg-judiciary-green text-judiciary-gold-light rounded-xl flex items-center justify-center font-bold text-xl shadow-inner">
                {String.at(@current_scope.user.name || "U", 0)}
              </div>
              <div>
                <p class="font-bold text-zinc-900">{@current_scope.user.name}</p>
                <p class="text-xs font-black text-judiciary-green uppercase tracking-widest">Role: {@current_scope.user.role}</p>
              </div>
            </div>

            <h3 class="text-xs font-black uppercase tracking-widest text-zinc-500 mb-4">Official Email Address</h3>
            <.form for={@email_form} id="email_form" phx-submit="update_email" phx-change="validate_email" class="space-y-4">
              <.input
                field={@email_form[:email]}
                type="email"
                autocomplete="username"
                required
                class="w-full bg-white border-zinc-300 rounded-xl focus:ring-judiciary-green focus:border-judiciary-green px-4 py-3"
              />
              <div class="flex justify-end">
                <.button class="bg-zinc-800 hover:bg-zinc-900 text-white font-bold py-2 px-6 rounded-xl shadow-md transition-all text-sm uppercase tracking-wider" phx-disable-with="Changing...">
                  Update Email
                </.button>
              </div>
            </.form>
          </div>

          <!-- Security Section -->
          <div class="bg-zinc-50 p-6 rounded-2xl border border-zinc-200">
            <div class="flex items-center gap-2 mb-6 pb-4 border-b border-zinc-200">
              <.icon name="hero-shield-check-solid" class="w-6 h-6 text-judiciary-green" />
              <h3 class="text-sm font-black uppercase tracking-widest text-zinc-900">Security & Authentication</h3>
            </div>

            <.form
              for={@password_form}
              id="password_form"
              action={~p"/users/update_password"}
              method="post"
              phx-submit="update_password"
              phx-trigger-action={@trigger_submit}
              class="space-y-4"
            >
              <input
                name={@password_form[:email].name}
                type="hidden"
                id="hidden_user_email"
                autocomplete="username"
                value={@current_email}
              />
              
              <div>
                <label class="block text-xs font-black uppercase tracking-widest text-zinc-500 mb-2">New Password</label>
                <.input
                  field={@password_form[:password]}
                  type="password"
                  autocomplete="new-password"
                  required
                  class="w-full bg-white border-zinc-300 rounded-xl focus:ring-judiciary-green focus:border-judiciary-green px-4 py-3"
                />
              </div>

              <div>
                <label class="block text-xs font-black uppercase tracking-widest text-zinc-500 mb-2">Confirm New Password</label>
                <.input
                  field={@password_form[:password_confirmation]}
                  type="password"
                  autocomplete="new-password"
                  class="w-full bg-white border-zinc-300 rounded-xl focus:ring-judiciary-green focus:border-judiciary-green px-4 py-3"
                />
              </div>

              <div class="flex justify-end pt-2">
                <.button class="bg-judiciary-green hover:bg-judiciary-green-dark text-white font-bold py-3 px-8 rounded-xl shadow-lg border-b-4 border-judiciary-gold transition-all active:scale-[0.98] text-sm uppercase tracking-widest" phx-disable-with="Saving...">
                  Update Password
                </.button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm_email/#{&1}")
        )

        info = "A link to confirm your email change has been sent to the new address."
        {:noreply, socket |> put_flash(:info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end
end
