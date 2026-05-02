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

  scope "/api", JudiciaryWeb do
    pipe_through :api

    post "/media/upload", MediaController, :upload
  end

  scope "/", JudiciaryWeb do
    pipe_through :browser

    get "/", PageController, :home

    # Causelist is Public
    live_session :public_activities,
      on_mount: [{JudiciaryWeb.UserAuth, :mount_current_scope}] do
      live "/activities", ActivityLive.Index, :index
      live "/activities/:id", ActivityLive.Show, :show
    end
  end

  ## Authentication routes

  scope "/", JudiciaryWeb do
    pipe_through [:browser]

    live_session :current_scope,
      on_mount: [{JudiciaryWeb.UserAuth, :mount_current_scope}, {JudiciaryWeb.UserAuth, :redirect_if_user_is_authenticated}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log_in", UserLive.Login, :new
    end

    post "/users/log_in", UserSessionController, :create
    get "/users/log_in/:token", UserSessionController, :magic_link_login
    post "/users/update_password", UserSessionController, :update_password
    delete "/users/log_out", UserSessionController, :delete
  end

  scope "/", JudiciaryWeb do
    pipe_through [:browser, :require_authenticated_user, :require_court_staff]

    live_session :require_court_staff,
      on_mount: [{JudiciaryWeb.UserAuth, :require_court_staff}] do

      # Court Management are Secured
      live "/activities/new", ActivityLive.Index, :new
      live "/activities/:id/edit", ActivityLive.Index, :edit
      live "/activities/:id/show/edit", ActivityLive.Show, :edit

      # Virtual Room Management
      live "/rooms", VirtualRoomLive.Index, :index
      live "/rooms/new", VirtualRoomLive.Index, :new
      live "/rooms/:id/edit", VirtualRoomLive.Index, :edit
    end
  end

  scope "/", JudiciaryWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{JudiciaryWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm_email/:token", UserLive.Settings, :confirm_email
      live "/rooms/:id", ActivityLive.Room, :room
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
