defmodule Mix.Tasks.R2.Verify do
  @moduledoc """
  Verifies Cloudflare R2 configuration and connectivity.
  
  Run with: mix r2.verify
  """
  use Mix.Task

  @requirements ["app.config"]

  def run(_args) do
    IO.puts("==> Verifying Cloudflare R2 Configuration...")

    # 1. Check Environment Variables
    vars = [
      {"R2_ACCOUNT_ID", System.get_env("R2_ACCOUNT_ID")},
      {"R2_ACCESS_KEY_ID", System.get_env("R2_ACCESS_KEY_ID")},
      {"R2_SECRET_ACCESS_KEY", System.get_env("R2_SECRET_ACCESS_KEY")},
      {"R2_BUCKET", System.get_env("R2_BUCKET")}
    ]

    missing = Enum.filter(vars, fn {_, val} -> is_nil(val) || val == "" end)

    if Enum.any?(missing) do
      IO.puts("\n\e[31m[ERROR] Missing environment variables:\e[0m")
      Enum.each(missing, fn {name, _} -> IO.puts("  - #{name}") end)
      IO.puts("\nPlease set these in your .env file or environment.")
      exit({:shutdown, 1})
    end

    # 2. Check ExAws Configuration
    IO.puts("\n[INFO] Configuration detected:")
    IO.puts("  - Bucket: #{System.get_env("R2_BUCKET")}")
    IO.puts("  - Host: #{Application.get_env(:ex_aws, :s3)[:host]}")

    # 3. Test Connectivity (List Objects)
    IO.puts("\n[INFO] Attempting to connect to R2...")
    
    # Ensure hackney and ex_aws are started
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:ex_aws)
    
    bucket = System.get_env("R2_BUCKET")
    
    ExAws.S3.list_objects(bucket)
    |> ExAws.request()
    |> case do
      {:ok, %{body: %{contents: contents}}} ->
        IO.puts("\e[32m[SUCCESS] Successfully connected to R2!\e[0m")
        IO.puts("  - Found #{length(contents)} objects in bucket '#{bucket}'")
        
      {:error, {:http_error, status, %{body: body}}} ->
        IO.puts("\n\e[31m[ERROR] Connection failed with status #{status}:\e[0m")
        IO.puts("  Body: #{inspect(body)}")
        
      {:error, reason} ->
        IO.puts("\n\e[31m[ERROR] Connection failed:\e[0m")
        IO.puts("  Reason: #{inspect(reason)}")
    end
  end
end
