defmodule Judiciary.Media.PeerConnection do
  @moduledoc """
  GenServer managing an individual peer WebRTC connection.
  
  Handles:
  - Signaling state machine (new → offer → answer → connected)
  - ICE candidate collection and delivery
  - Connection state transitions
  - Automatic recovery on failure
  """

  use GenServer
  require Logger

  @signal_timeout 10_000

  def start_link([room_id, peer_id, metadata]) do
    GenServer.start_link(__MODULE__, {room_id, peer_id, metadata})
  end

  def handle_signal(pid, from_peer_id, payload) do
    try do
      GenServer.call(pid, {:handle_signal, from_peer_id, payload}, @signal_timeout)
    catch
      :exit, {:timeout, _} ->
        Logger.error("Timeout handling signal for peer")
        {:error, :timeout}

      :exit, reason ->
        Logger.error("Peer process died: #{inspect(reason)}")
        {:error, :peer_disconnected}
    end
  end

  def add_ice_candidate(pid, candidate) do
    GenServer.cast(pid, {:add_ice_candidate, candidate})
  end

  def get_state(pid) do
    try do
      GenServer.call(pid, :get_state, 5_000)
    catch
      :exit, _ -> {:error, :peer_disconnected}
    end
  end

  @impl true
  def init({room_id, peer_id, metadata}) do
    Logger.info("Initializing PeerConnection for #{peer_id} in room #{room_id}")

    {:ok,
     %{
       room_id: room_id,
       peer_id: peer_id,
       metadata: metadata,
       state: :new,
       local_description: nil,
       remote_description: nil,
       ice_candidates: [],
       pending_signals: [],
       created_at: System.monotonic_time(:millisecond),
       last_activity: System.monotonic_time(:millisecond)
     }}
  end

  @impl true
  def handle_call({:handle_signal, from_peer_id, payload}, _from, state) do
    Logger.debug("Handling signal from #{from_peer_id} for #{state.peer_id}, state: #{state.state}")

    case payload do
      %{"type" => "offer"} ->
        handle_offer(state, from_peer_id, payload)

      %{"type" => "answer"} ->
        handle_answer(state, from_peer_id, payload)

      %{"candidate" => _} ->
        handle_ice_candidate(state, from_peer_id, payload)

      _ ->
        Logger.warning("Unknown signal type: #{inspect(payload)}")
        {:reply, {:error, :unknown_signal}, state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply,
     %{
       peer_id: state.peer_id,
       connection_state: state.state,
       last_activity: state.last_activity,
       ice_candidates: length(state.ice_candidates)
     }, state}
  end

  @impl true
  def handle_cast({:add_ice_candidate, candidate}, state) do
    Logger.debug("Adding ICE candidate for #{state.peer_id}")

    if state.state in [:offer_sent, :answer_received, :connected] do
      new_state = %{state | ice_candidates: [candidate | state.ice_candidates]}
      {:noreply, update_activity(new_state)}
    else
      # Queue for later
      new_state = %{state | pending_signals: [candidate | state.pending_signals]}
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_info(:cleanup_timeout, state) do
    Logger.info("Peer #{state.peer_id} connection timeout, closing")
    {:stop, :normal, state}
  end

  ## Helpers

  defp handle_offer(state, from_peer_id, payload) do
    Logger.info("Peer #{state.peer_id} received offer from #{from_peer_id}")

    case state.state do
      :new ->
        new_state = %{
          state
          | state: :offer_received,
            remote_description: payload,
            last_activity: System.monotonic_time(:millisecond)
        }

        {:reply, :ok, new_state}

      other_state ->
        Logger.warning(
          "Received offer in unexpected state #{other_state} for peer #{state.peer_id}"
        )

        {:reply, {:error, :invalid_state}, state}
    end
  end

  defp handle_answer(state, from_peer_id, payload) do
    Logger.info("Peer #{state.peer_id} received answer from #{from_peer_id}")

    case state.state do
      :offer_sent ->
        new_state = %{
          state
          | state: :answer_received,
            remote_description: payload,
            last_activity: System.monotonic_time(:millisecond)
        }

        {:reply, :ok, new_state}

      _ ->
        Logger.warning("Received answer in unexpected state for peer #{state.peer_id}")
        {:reply, {:error, :invalid_state}, state}
    end
  end

  defp handle_ice_candidate(state, _from_peer_id, payload) do
    Logger.debug("Peer #{state.peer_id} received ICE candidate")

    if state.state in [:offer_sent, :answer_received, :connected] do
      new_state = %{
        state
        | ice_candidates: [payload | state.ice_candidates],
          last_activity: System.monotonic_time(:millisecond)
      }

      {:reply, :ok, new_state}
    else
      Logger.warning("Received ICE candidate in state #{state.state}, queuing")

      new_state = %{state | pending_signals: [payload | state.pending_signals]}

      {:reply, {:error, :not_ready_for_candidates}, new_state}
    end
  end

  defp update_activity(state) do
    %{state | last_activity: System.monotonic_time(:millisecond)}
  end
end
