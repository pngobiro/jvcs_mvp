defmodule Judiciary.Workers.Transcriber do
  use Oban.Worker, queue: :transcription

  require Logger
  alias Judiciary.Court

  @deepgram_api_url "https://api.deepgram.com/v1/listen"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"activity_id" => activity_id, "recording_url" => url}}) do
    Logger.info("Starting transcription for activity #{activity_id}")
    
    api_key = System.get_env("DEEPGRAM_API_KEY")
    if is_nil(api_key) or api_key == "" do
      Logger.error("DEEPGRAM_API_KEY is not set!")
    end

    # Deepgram request with diarization enabled (essential for legal transcripts)
    case Req.post(@deepgram_api_url,
      headers: [
        {"Authorization", "Token #{api_key}"},
        {"Content-Type", "application/json"}
      ],
      json: %{
        url: url
      },
      params: [
        model: "nova-2",
        diarize: true,
        smart_format: true,
        punctuate: true
      ]
    ) do
      {:ok, %{status: 200, body: %{"results" => results} = body}} ->
        Logger.info("Deepgram raw response for activity #{activity_id}: #{inspect(body)}")
        transcript = get_transcript_text(results)
        
        if is_nil(transcript) or String.trim(transcript) == "" do
          Logger.warning("Deepgram returned an empty transcript for activity #{activity_id}. Skipping R2 upload.")
          :ok
        else
          Logger.info("Extracted transcript for activity #{activity_id} (length: #{String.length(transcript)})")
          
          # Save transcript to R2
          transcript_filename = "transcripts/activity-#{activity_id}.txt"
          case Judiciary.Media.Storage.upload_binary(transcript, transcript_filename, "text/plain") do
            {:ok, transcript_url} ->
              # Update activity with transcript URL
              activity = Court.get_activity!(activity_id)
              Court.update_activity(activity, %{transcript_url: transcript_url})
              
              Logger.info("Transcription completed and uploaded for activity #{activity_id}")
              :ok
            {:error, reason} ->
              Logger.error("Failed to upload transcript to R2: #{inspect(reason)}")
              {:error, reason}
          end
        end

      {:error, reason} ->
        Logger.error("Deepgram transcription failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp get_transcript_text(results) do
    get_in(results, ["channels", Access.at(0), "alternatives", Access.at(0), "transcript"])
  end
end
