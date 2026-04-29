defmodule Judiciary.Repo do
  use Ecto.Repo,
    otp_app: :judiciary,
    adapter: Ecto.Adapters.Postgres
end
