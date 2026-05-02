defmodule JudiciaryWeb.UserLive.Login do
  use JudiciaryWeb, :live_view

  alias Judiciary.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-[80vh] flex flex-col items-center justify-center bg-zinc-50 py-12 px-4 sm:px-6 lg:px-8">
      
      <div class="w-full max-w-md mb-4 flex justify-start">
        <.link navigate={~p"/"} class="bg-white border-2 border-zinc-200 text-zinc-600 hover:text-judiciary-green hover:border-judiciary-green hover:bg-judiciary-green/5 px-4 py-2 rounded-xl text-sm font-black uppercase tracking-widest flex items-center gap-2 shadow-sm transition-all active:scale-95">
          <.icon name="hero-arrow-left-solid" class="w-5 h-5" />
          Return to Home
        </.link>
      </div>

      <div class="max-w-md w-full space-y-8 bg-white p-10 rounded-3xl shadow-2xl border-t-8 border-judiciary-green">
        
        <div class="text-center">
          <div class="flex justify-center mb-6">
            <div class="p-3 bg-zinc-50 rounded-2xl shadow-inner border border-zinc-100">
              <img src={~p"/images/judiciary-logo.png"} class="h-20 w-auto object-contain" alt="Judiciary Logo" />
            </div>
          </div>
          <h2 class="mt-2 text-3xl font-black tracking-tight text-zinc-900 uppercase">
            Official Access
          </h2>
          <p class="mt-2 text-sm text-zinc-500 font-medium">
            <%= if @current_scope do %>
              You need to reauthenticate to perform sensitive actions.
            <% else %>
              Don't have an account? 
              <.link navigate={~p"/users/register"} class="font-bold text-judiciary-green hover:text-judiciary-gold transition-colors">
                Sign up now
              </.link>
            <% end %>
          </p>
        </div>

        <div class="bg-judiciary-green/5 border border-judiciary-green/20 rounded-2xl p-4 mb-6">
          <h3 class="text-xs font-black uppercase tracking-widest text-judiciary-green mb-3 flex items-center gap-2">
            <.icon name="hero-bolt" class="w-4 h-4" />
            Rapid Demo Access
          </h3>
          <div class="grid grid-cols-3 gap-2">
            <button 
              type="button"
              phx-click="autofill_demo" 
              phx-value-email="j.tech@judiciary.go.ke"
              class="flex flex-col items-center justify-center bg-white border border-zinc-200 p-3 rounded-xl hover:border-judiciary-green hover:bg-judiciary-green/5 transition-all group"
            >
              <.icon name="hero-scale" class="w-6 h-6 text-zinc-400 group-hover:text-judiciary-green mb-1" />
              <span class="text-[10px] font-black uppercase tracking-tighter text-zinc-500 group-hover:text-judiciary-green">Judge</span>
            </button>
            
            <button 
              type="button"
              phx-click="autofill_demo" 
              phx-value-email="c.clerk@judiciary.go.ke"
              class="flex flex-col items-center justify-center bg-white border border-zinc-200 p-3 rounded-xl hover:border-judiciary-green hover:bg-judiciary-green/5 transition-all group"
            >
              <.icon name="hero-document-text" class="w-6 h-6 text-zinc-400 group-hover:text-judiciary-green mb-1" />
              <span class="text-[10px] font-black uppercase tracking-tighter text-zinc-500 group-hover:text-judiciary-green">Clerk</span>
            </button>

            <button 
              type="button"
              phx-click="autofill_demo" 
              phx-value-email="a.lawyer@example.com"
              class="flex flex-col items-center justify-center bg-white border border-zinc-200 p-3 rounded-xl hover:border-judiciary-green hover:bg-judiciary-green/5 transition-all group"
            >
              <.icon name="hero-briefcase" class="w-6 h-6 text-zinc-400 group-hover:text-judiciary-green mb-1" />
              <span class="text-[10px] font-black uppercase tracking-tighter text-zinc-500 group-hover:text-judiciary-green">Advocate</span>
            </button>
          </div>
        </div>

        <.form
          :let={f}
          for={@form}
          id="login_form_password"
          action={~p"/users/log_in"}
          phx-submit="submit_password"
          phx-trigger-action={@trigger_submit}
          class="space-y-6 mt-4"
        >
          <div>
            <label class="block text-xs font-black uppercase tracking-widest text-zinc-500 mb-2">Official Email</label>
            <.input
              readonly={!!@current_scope}
              field={f[:email]}
              type="email"
              autocomplete="email"
              required
              class="w-full bg-zinc-50 border-zinc-200 rounded-xl focus:ring-judiciary-green focus:border-judiciary-green px-4 py-3"
              placeholder="e.g. name@judiciary.go.ke"
            />
          </div>
          
          <div>
            <label class="block text-xs font-black uppercase tracking-widest text-zinc-500 mb-2">Password</label>
            <.input
              field={f[:password]}
              type="password"
              autocomplete="current-password"
              required
              class="w-full bg-zinc-50 border-zinc-200 rounded-xl focus:ring-judiciary-green focus:border-judiciary-green px-4 py-3"
              placeholder="••••••••••••"
              value={@demo_password}
            />
          </div>

          <div class="flex items-center gap-2 text-sm mt-2 hidden">
            <input type="checkbox" name={f[:remember_me].name} value="true" checked="true" />
            <label>Remember me</label>
          </div>

          <div class="pt-4">
            <.button class="w-full bg-judiciary-green hover:bg-judiciary-dark text-white font-black py-4 rounded-xl shadow-lg border-b-4 border-judiciary-green-dark active:scale-[0.98] transition-all uppercase tracking-widest">
              Secure Log In
            </.button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok, assign(socket, form: form, trigger_submit: false, demo_password: "")}
  end

  @impl true
  def handle_event("autofill_demo", %{"email" => email}, socket) do
    if email == "" do
      {:noreply, socket}
    else
      form = to_form(%{"email" => email, "password" => "password1234"}, as: "user")
      {:noreply, assign(socket, form: form, demo_password: "password1234")}
    end
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log_in/#{&1}")
      )
    end

    info =
      "If your email is in our system, you will receive instructions for logging in shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log_in")}
  end

  defp local_mail_adapter? do
    Application.get_env(:judiciary, Judiciary.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
