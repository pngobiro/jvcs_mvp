defmodule JudiciaryWeb.MediaController do
  use JudiciaryWeb, :controller

  require Logger
  alias Judiciary.Media.Storage

  def upload(conn, %{"file" => %Plug.Upload{} = upload, "filename" => filename} = params) do
    activity_id = params["activity_id"]

    case Storage.upload_recording(upload.path, filename) do
      {:ok, url} ->
        if activity_id do
          activity = Judiciary.Court.get_activity!(activity_id)
          Judiciary.Court.update_activity(activity, %{recording_url: url, status: "completed"})
        end
        
        json(conn, %{status: "ok", url: url})

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{status: "error", message: "Upload failed"})
    end
  end

  def upload(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{status: "error", message: "Invalid parameters"})
  end
end
