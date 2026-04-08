defmodule Splitio.Sync.Manager do
  @moduledoc """
  Sync state machine managing streaming and polling modes.

  States:
  - :initializing - Initial bootstrap
  - :streaming - SSE connected, real-time updates
  - :polling - Periodic HTTP fetch (fallback)
  """

  use GenServer

  alias Splitio.Config
  alias Splitio.Sync.{Splits, Segments, Backoff}

  require Logger

  @type mode :: :initializing | :streaming | :polling

  defstruct [
    :config,
    :mode,
    :poll_timer,
    :backoff,
    ready: false
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc "Check if SDK is ready"
  @spec ready?() :: boolean()
  def ready? do
    GenServer.call(__MODULE__, :ready?)
  end

  @doc "Block until ready or timeout"
  @spec block_until_ready(non_neg_integer()) :: :ok | {:error, :timeout}
  def block_until_ready(timeout_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_block_until_ready(deadline)
  end

  defp do_block_until_ready(deadline) do
    if ready?() do
      :ok
    else
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining > 0 do
        Process.sleep(min(100, remaining))
        do_block_until_ready(deadline)
      else
        {:error, :timeout}
      end
    end
  end

  @doc "Trigger a manual sync"
  @spec sync_all() :: :ok
  def sync_all do
    GenServer.cast(__MODULE__, :sync_all)
  end

  @doc "Switch to polling mode"
  @spec start_polling() :: :ok
  def start_polling do
    GenServer.cast(__MODULE__, :start_polling)
  end

  @doc "Switch to streaming mode"
  @spec start_streaming() :: :ok
  def start_streaming do
    GenServer.cast(__MODULE__, :start_streaming)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(%Config{} = config) do
    state = %__MODULE__{
      config: config,
      mode: :initializing,
      backoff: Backoff.new()
    }

    # Start initial sync
    send(self(), :initial_sync)

    {:ok, state}
  end

  @impl true
  def handle_call(:ready?, _from, state) do
    {:reply, state.ready, state}
  end

  @impl true
  def handle_cast(:sync_all, state) do
    do_sync_all(state.config)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:start_polling, state) do
    state = cancel_poll_timer(state)
    disconnect_streaming()
    state = schedule_poll(state)
    {:noreply, %{state | mode: :polling}}
  end

  @impl true
  def handle_cast(:start_streaming, state) do
    state = cancel_poll_timer(state)
    connect_streaming()
    {:noreply, %{state | mode: :streaming, backoff: Backoff.reset(state.backoff)}}
  end

  @impl true
  def handle_info(:initial_sync, state) do
    case state.config.mode do
      :localhost ->
        Logger.info("Localhost mode ready")
        notify_ready()
        {:noreply, %{state | ready: true, mode: :polling}}

      _ ->
        case do_sync_all(state.config) do
          :ok ->
            Logger.info("Initial sync complete")

            notify_ready()

            state =
              if state.config.streaming_enabled do
                connect_streaming()
                %{state | mode: :streaming, ready: true}
              else
                schedule_poll(%{state | mode: :polling, ready: true})
              end

            {:noreply, state}

          {:error, reason} ->
            Logger.error("Initial sync failed: #{inspect(reason)}")
            {wait_ms, backoff} = Backoff.next(state.backoff)
            Process.send_after(self(), :initial_sync, wait_ms)
            {:noreply, %{state | backoff: backoff}}
        end
    end
  end

  @impl true
  def handle_info(:poll, state) do
    do_sync_all(state.config)
    state = schedule_poll(state)
    {:noreply, state}
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp do_sync_all(config) do
    case Splits.sync(config) do
      {:ok, new_segment_names} ->
        # Sync both newly discovered segments and previously known segments
        # This ensures segment membership changes are detected even when
        # splits haven't changed
        existing_segment_names = Splitio.Storage.get_segment_names()

        all_segment_names =
          MapSet.new(new_segment_names)
          |> MapSet.union(MapSet.new(existing_segment_names))
          |> MapSet.to_list()

        Segments.sync_segments(config, all_segment_names)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp schedule_poll(state) do
    interval_ms = state.config.features_refresh_rate * 1000
    timer = Process.send_after(self(), :poll, interval_ms)
    %{state | poll_timer: timer}
  end

  defp cancel_poll_timer(%{poll_timer: nil} = state), do: state

  defp cancel_poll_timer(%{poll_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | poll_timer: nil}
  end

  defp connect_streaming do
    if Process.whereis(Splitio.Push.SSE) do
      Splitio.Push.SSE.connect()
    else
      start_polling()
    end
  end

  defp disconnect_streaming do
    if Process.whereis(Splitio.Push.SSE) do
      Splitio.Push.SSE.disconnect()
    else
      :ok
    end
  end

  defp notify_ready do
    # Broadcast SDK_READY event
    :telemetry.execute([:splitio, :sdk, :ready], %{}, %{})
  end
end
