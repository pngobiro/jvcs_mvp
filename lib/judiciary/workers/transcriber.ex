defmodule Judiciary.Workers.Transcriber do
  use Oban.Worker, queue: :transcription

  require Logger
  alias Judiciary.Court

  @deepgram_api_url "https://api.deepgram.com/v1/listen"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"activity_id" => activity_id, "recording_url" => url}}) do
    Logger.info("Starting transcription for activity #{activity_id} with URL: #{url}")
    
    api_key = System.get_env("DEEPGRAM_API_KEY")
    if is_nil(api_key) or api_key == "" do
      Logger.error("DEEPGRAM_API_KEY is not set!")
    end

    # Deepgram request with diarization enabled (essential for legal transcripts)
    Logger.info("Sending request to Deepgram...")
    try do
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
        ],
        receive_timeout: 60000
      ) do
        {:ok, %{status: 200, body: %{"results" => results} = body}} ->
          Logger.info("Deepgram raw response for activity #{activity_id}: #{inspect(body)}")
          transcript = get_transcript_text(results)

          final_transcript = if is_nil(transcript) or String.trim(transcript) == "" do
            "[No speech detected in this recording]"
          else
            transcript
          end

          Logger.info("Extracted transcript for activity #{activity_id} (length: #{String.length(final_transcript)})")

          # Save transcript to R2
          transcript_filename = "transcripts/activity-#{activity_id}.txt"
          case Judiciary.Media.Storage.upload_binary(final_transcript, transcript_filename, "text/plain") do
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
        {:ok, response} ->
          Logger.error("Deepgram returned non-200 status: #{response.status}, body: #{inspect(response.body)}")
          {:error, "Deepgram status #{response.status}"}

        {:error, reason} ->
          Logger.error("Deepgram transcription failed (Req error): #{inspect(reason)}")
          {:error, reason}
      end
    rescue
      e ->
        Logger.error("Transcription worker crashed: #{inspect(e)}")
        reraise e, __STACKTRACE__
    end
  end

  defp get_transcript_text(results) do
    # Robust extraction from Deepgram response structure
    with %{"channels" => [channel | _]} <- results,
         %{"alternatives" => [alt | _]} <- channel do
      alt["transcript"]
    else
      _ -> nil
    end
  end
end
