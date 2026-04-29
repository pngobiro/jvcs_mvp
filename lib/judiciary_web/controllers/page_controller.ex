defmodule JudiciaryWeb.PageController do
  use JudiciaryWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
