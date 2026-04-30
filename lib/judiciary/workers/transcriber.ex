defmodule Judiciary.Workers.Transcriber do
  use Oban.Worker, queue: :transcription

  require Logger
  alias Judiciary.Court

  @deepgram_api_url "https://api.deepgram.com/v1/listen"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"activity_id" => activity_id, "recording_url" => url}}) do
    Logger.info("Starting transcription for activity #{activity_id}")

    # Deepgram request with diarization enabled (essential for legal transcripts)
    case Req.post(@deepgram_api_url,
      headers: [
        {"Authorization", "Token #{System.get_env("DEEPGRAM_API_KEY")}"},
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
      {:ok, %{status: 200, body: %{"results" => results}}} ->
        transcript = get_transcript_text(results)
        
        # Save transcript to R2
        transcript_filename = "transcripts/activity-#{activity_id}.txt"
        {:ok, transcript_url} = Judiciary.Media.Storage.upload_binary(transcript, transcript_filename, "text/plain")
        
        # Update activity with transcript URL
        activity = Court.get_activity!(activity_id)
        Court.update_activity(activity, %{transcript_url: transcript_url})
        
        Logger.info("Transcription completed for activity #{activity_id}")
        :ok

      {:error, reason} ->
        Logger.error("Deepgram transcription failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp get_transcript_text(results) do
    get_in(results, ["channels", Access.at(0), "alternatives", Access.at(0), "transcript"])
  end
end
