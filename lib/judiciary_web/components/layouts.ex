defmodule JudiciaryWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use JudiciaryWeb, :html

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current scope"

  def app(assigns) do
    ~H"""
    <header class="navbar px-4 sm:px-6 lg:px-8 bg-judiciary-green text-white shadow-xl border-b-[6px] border-judiciary-gold flex flex-col md:flex-row items-center gap-4 py-4 md:py-0">
      <div class="flex-1 w-full md:w-auto">
        <a href="/" class="flex items-center gap-3 md:gap-4 group justify-center md:justify-start">
          <div class="p-1 bg-white rounded-xl shadow-lg group-hover:scale-105 transition-transform">
            <img src={~p"/images/judiciary-logo.png"} class="h-10 md:h-14 w-auto object-contain" alt="Judiciary Logo" />
          </div>
          <div class="flex flex-col">
            <span class="text-lg md:text-xl font-black tracking-tight leading-none group-hover:text-judiciary-gold-light transition-colors">THE JUDICIARY</span>
            <span class="text-[8px] md:text-[10px] font-bold tracking-[0.25em] text-judiciary-gold-light uppercase opacity-90">Republic of Kenya</span>
          </div>
        </a>
      </div>
      <div class="flex-none w-full md:w-auto">
        <ul class="flex flex-row justify-center md:justify-end px-1 space-x-4 md:space-x-8 items-center overflow-x-auto no-scrollbar">
          <li>
            <.link href={~p"/activities"} class="text-xs md:text-sm font-black uppercase tracking-widest hover:text-judiciary-gold-light transition-all border-b-2 border-transparent hover:border-judiciary-gold pb-1 whitespace-nowrap">
              Causelist
            </.link>
          </li>
          <%= if @current_scope && @current_scope.user do %>
            <li class="hidden sm:block text-[0.8125rem] leading-6 text-zinc-300 truncate max-w-[150px]">
              {@current_scope.user.email}
            </li>
            <li>
              <.link href={~p"/users/log_out"} method="delete" class="text-xs md:text-[0.8125rem] leading-6 font-semibold hover:text-zinc-300 whitespace-nowrap">
                Log out
              </.link>
            </li>
          <% end %>
          <li class="shrink-0">
            <.theme_toggle />
          </li>
        </ul>
      </div>
    </header>

    <main class="px-4 py-8 sm:px-6 lg:px-10">
      <div class="mx-auto w-full space-y-4">
        {@inner_content}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full text-zinc-900">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3 z-10"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3 z-10"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3 z-10"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end

  # Embed all files in layouts/* within this module.
  embed_templates "layouts/*"
end
