defmodule JudiciaryWeb.Router do
  use JudiciaryWeb, :router

  import JudiciaryWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {JudiciaryWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", JudiciaryWeb do
    pipe_through :browser

    get "/", PageController, :home

    # Zoom-style access: Publicly accessible activities and rooms
    live "/activities", ActivityLive.Index, :index
    live "/activities/new", ActivityLive.Index, :new
    live "/activities/:id/edit", ActivityLive.Index, :edit
    live "/activities/:id", ActivityLive.Show, :show
    live "/activities/:id/show/edit", ActivityLive.Show, :edit
    live "/activities/:id/room", ActivityLive.Room, :room
  end

  ## Authentication routes (Optional/Admin)

  scope "/", JudiciaryWeb do
    pipe_through [:browser]

    live_session :current_scope,
      on_mount: [{JudiciaryWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log_in", UserLive.Login, :new
    end

    post "/users/log_in", UserSessionController, :create
    post "/users/update_password", UserSessionController, :update_password
    delete "/users/log_out", UserSessionController, :delete
  end

  scope "/", JudiciaryWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{JudiciaryWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
    end
  end

  scope "/", JudiciaryWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{JudiciaryWeb.UserAuth, :mount_current_scope}] do
      live "/users/confirm", UserLive.Confirmation, :new
    end
  end
end
