defmodule JudiciaryWeb.Presence do
  use Phoenix.Presence,
    otp_app: :judiciary,
    pubsub_server: Judiciary.PubSub
end
