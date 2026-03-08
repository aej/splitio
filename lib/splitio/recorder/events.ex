defmodule Splitio.Recorder.Events do
  @moduledoc """
  Event recorder - queues and flushes track events to API.
  """

  use GenServer

  alias Splitio.Api.Events, as: EventsApi
  alias Splitio.Config
  alias Splitio.Models.Event

  require Logger

  defstruct [
    :config,
    :queue,
    :flush_timer
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc "Record an event"
  @spec record(Event.t()) :: :ok | {:error, :queue_full}
  def record(%Event{} = event) do
    GenServer.call(__MODULE__, {:record, event})
  end

  @doc "Flush all queued events"
  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush, 30_000)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(%Config{} = config) do
    state = %__MODULE__{
      config: config,
      queue: :queue.new()
    }

    state = schedule_flush(state)
    {:ok, state}
  end

  @impl true
  def handle_call({:record, event}, _from, state) do
    queue_size = :queue.len(state.queue)

    if queue_size >= state.config.events_queue_size do
      Logger.warning("Event queue full, dropping event")
      {:reply, {:error, :queue_full}, state}
    else
      state = %{state | queue: :queue.in(event, state.queue)}

      # Check if we should flush
      state =
        if :queue.len(state.queue) >= state.config.events_bulk_size do
          do_flush(state)
        else
          state
        end

      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    state = do_flush(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:flush, state) do
    state = do_flush(state)
    state = schedule_flush(state)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    do_flush(state)
    :ok
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp do_flush(%{queue: queue, config: config} = state) do
    events = :queue.to_list(queue)

    if length(events) > 0 do
      payload = Enum.map(events, &Event.to_api_format/1)

      case EventsApi.post_events(config, payload) do
        {:ok, _} ->
          Logger.debug("Flushed #{length(events)} events")

        {:error, reason} ->
          Logger.error("Failed to flush events: #{inspect(reason)}")
      end
    end

    %{state | queue: :queue.new()}
  end

  defp schedule_flush(state) do
    interval_ms = state.config.events_refresh_rate * 1000
    timer = Process.send_after(self(), :flush, interval_ms)
    %{state | flush_timer: timer}
  end
end
