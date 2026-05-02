defmodule Judiciary.Media.RoomPipeline do
  @moduledoc """
  Media pipeline for a Court Room session.

  Currently stubbed - will integrate with Membrane Framework for:
  - Recording to WORM storage
  - Transcription pipelines
  - Voice Activity Detection (VAD)

  For now, media routing is handled by WebRTCPeer GenServers.
  """

  # use Membrane.Pipeline  # Disabled until needed

  require Logger

  def start_link(room_id) do
    Logger.info("Media Pipeline stub for Room: #{room_id}")
    # Membrane.Pipeline.start_link(__MODULE__, %{room_id: room_id}, name: name(room_id))
    {:ok, self()}
  end

  def add_peer(_pipeline_pid, peer_id) do
    Logger.debug("Pipeline stub: peer #{peer_id} added")
    :ok
  end

  def remove_peer(_pipeline_pid, peer_id) do
    Logger.debug("Pipeline stub: peer #{peer_id} removed")
    :ok
  end

  # Future: Membrane pipeline implementation
  # def handle_init(_ctx, opts) do
  #   # Initialize Membrane WebRTC Endpoint and required bins
  #   {[], %{room_id: opts.room_id}}
  # end

  # defp name(room_id), do: {:via, Registry, {Judiciary.Media.RoomRegistry, {:pipeline, room_id}}}
end
