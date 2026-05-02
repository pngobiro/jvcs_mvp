defmodule JudiciaryWeb.MediaController do
  use JudiciaryWeb, :controller

  require Logger
  alias Judiciary.Media.Storage

  def upload(conn, %{"file" => %Plug.Upload{} = upload, "filename" => filename} = params) do
    activity_id = params["activity_id"]
    Logger.info("Received upload request for activity #{activity_id}: #{filename} (type: #{upload.content_type})")

    case Storage.upload_recording(upload.path, filename, upload.content_type) do
      {:ok, url} ->
        Logger.info("File uploaded successfully to R2: #{url}")
        if activity_id do
          activity = Judiciary.Court.get_activity!(activity_id)
          
          # Only update recording_url if it's not the audio-only version, or if we want audio-only for transcription
          # For now, let's just log and update.
          Judiciary.Court.update_activity(activity, %{recording_url: url, status: "completed"})
          
          # Trigger transcription in background
          %{activity_id: activity_id, recording_url: url}
          |> Judiciary.Workers.Transcriber.new()
          |> Oban.insert()
        end
        
        json(conn, %{status: "ok", url: url})

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{status: "error", message: "Upload failed"})
    end
  end

  def upload(conn, params) do
    Logger.warning("Invalid upload parameters: #{inspect(Map.keys(params))}")
    conn
    |> put_status(:bad_request)
    |> json(%{status: "error", message: "Invalid parameters"})
  end
end
