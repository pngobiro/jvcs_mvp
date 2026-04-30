defmodule Judiciary.Media.Storage do
  @moduledoc """
  Handles media storage operations, specifically for Cloudflare R2.
  """

  require Logger
  alias ExAws.S3

  @doc """
  Uploads a file to the configured R2 bucket.
  """
  def upload_recording(file_path, filename, content_type \\ nil) do
    bucket = get_bucket()
    opts = if content_type, do: [content_type: content_type], else: []
    
    file_path
    |> S3.Upload.stream_file()
    |> S3.upload(bucket, "recordings/#{filename}", opts)
    |> ExAws.request()
    |> case do
      {:ok, _result} ->
        public_url = get_public_url()
        {:ok, "#{public_url}/recordings/#{filename}"}

      {:error, reason} ->
        Logger.error("Failed to upload to R2: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Uploads binary data directly to the configured R2 bucket.
  """
  def upload_binary(binary, filename, content_type \\ "video/webm") do
    bucket = get_bucket()
    
    bucket
    |> S3.put_object("recordings/#{filename}", binary, content_type: content_type)
    |> ExAws.request()
    |> case do
      {:ok, _result} ->
        public_url = get_public_url()
        {:ok, "#{public_url}/recordings/#{filename}"}

      {:error, reason} ->
        Logger.error("Failed to upload binary to R2: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp get_bucket do
    Application.get_env(:judiciary, :r2)[:bucket]
  end

  defp get_public_url do
    Application.get_env(:judiciary, :r2)[:public_url]
  end
end
