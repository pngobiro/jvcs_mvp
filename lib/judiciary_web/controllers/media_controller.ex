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
        
        # Only associate with an activity if it's a numeric ID
        case Integer.parse(activity_id || "") do
          {id, ""} ->
            activity = Judiciary.Court.get_activity!(id)
            Judiciary.Court.update_activity(activity, %{recording_url: url, status: "completed"})
            
            # Trigger transcription in background
            %{activity_id: id, recording_url: url}
            |> Judiciary.Workers.Transcriber.new()
            |> Oban.insert()
            
          _ ->
            Logger.info("Upload not associated with a specific case activity (ID: #{activity_id})")
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
