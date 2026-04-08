defmodule Splitio.Push.SSE do
  @moduledoc """
  SSE client using Mint for streaming connection to Ably.

  Handles:
  - Connection establishment
  - Keepalive timeout detection
  - Reconnection with backoff
  - Message parsing and dispatch
  """

  use GenServer

  alias Splitio.Config
  alias Splitio.Push.{Parser, Processor, Auth}
  alias Splitio.Sync.Backoff

  require Logger

  @keepalive_timeout_ms 70_000

  defstruct [
    :config,
    :conn,
    :request_ref,
    :buffer,
    :status,
    :keepalive_timer,
    :backoff
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc "Connect to streaming"
  @spec connect() :: :ok
  def connect do
    GenServer.cast(__MODULE__, :connect)
  end

  @doc "Disconnect from streaming"
  @spec disconnect() :: :ok
  def disconnect do
    GenServer.cast(__MODULE__, :disconnect)
  end

  @doc "Check if connected"
  @spec connected?() :: boolean()
  def connected? do
    GenServer.call(__MODULE__, :connected?)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(%Config{} = config) do
    state = %__MODULE__{
      config: config,
      buffer: "",
      status: :disconnected,
      backoff: Backoff.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, state.status == :connected, state}
  end

  @impl true
  def handle_cast(:connect, state) do
    state = do_connect(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:disconnect, state) do
    state = do_disconnect(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp, _socket, data}, state) do
    state = process_raw_data(data, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:ssl, _socket, data}, state) do
    state = process_raw_data(data, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp_closed, _socket}, state) do
    Logger.warning("SSE connection closed")
    state = handle_disconnect(:tcp_closed, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:ssl_closed, _socket}, state) do
    Logger.warning("SSE connection closed (SSL)")
    state = handle_disconnect(:ssl_closed, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp_error, _socket, reason}, state) do
    Logger.error("SSE TCP error: #{inspect(reason)}")
    state = handle_disconnect(reason, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:ssl_error, _socket, reason}, state) do
    Logger.error("SSE SSL error: #{inspect(reason)}")
    state = handle_disconnect(reason, state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:keepalive_timeout, state) do
    Logger.warning("SSE keepalive timeout")
    state = handle_disconnect(:keepalive_timeout, state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:reconnect, state) do
    state = do_connect(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    # Handle Mint HTTP messages
    case state.conn do
      nil ->
        {:noreply, state}

      conn ->
        case Mint.HTTP.stream(conn, msg) do
          :unknown ->
            {:noreply, state}

          {:ok, conn, responses} ->
            state = %{state | conn: conn}
            state = process_responses(responses, state)
            {:noreply, state}

          {:error, conn, reason, _responses} ->
            Logger.error("SSE stream error: #{inspect(reason)}")
            state = %{state | conn: conn}
            state = handle_disconnect(reason, state)
            {:noreply, state}
        end
    end
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp do_connect(state) do
    state = cancel_keepalive(state)

    case Auth.get_token() do
      {:ok, token, channels} ->
        connect_with_token(state, token, channels)

      {:disabled, :push_disabled} ->
        Logger.info("Streaming disabled by server, using polling")
        Splitio.Sync.Manager.start_polling()
        %{state | status: :disabled}

      {:error, reason} ->
        Logger.error("Cannot connect SSE: no auth token - #{inspect(reason)}")
        schedule_reconnect(state)
    end
  end

  defp connect_with_token(state, token, channels) do
    url = build_sse_url(state.config.streaming_url, token, channels)
    uri = URI.parse(url)

    scheme = if uri.scheme == "https", do: :https, else: :http
    port = uri.port || if(scheme == :https, do: 443, else: 80)

    case Mint.HTTP.connect(scheme, uri.host, port) do
      {:ok, conn} ->
        path = "#{uri.path}?#{uri.query}"

        headers = [
          {"accept", "text/event-stream"},
          {"cache-control", "no-cache"}
        ]

        case Mint.HTTP.request(conn, "GET", path, headers, nil) do
          {:ok, conn, request_ref} ->
            Logger.info("SSE connected to #{uri.host}")

            %{
              state
              | conn: conn,
                request_ref: request_ref,
                status: :connecting,
                buffer: "",
                backoff: Backoff.reset(state.backoff)
            }
            |> reset_keepalive()

          {:error, conn, reason} ->
            Logger.error("SSE request failed: #{inspect(reason)}")
            Mint.HTTP.close(conn)
            schedule_reconnect(state)
        end

      {:error, reason} ->
        Logger.error("SSE connect failed: #{inspect(reason)}")
        schedule_reconnect(state)
    end
  end

  defp build_sse_url(base_url, token, channels) do
    # Format channels for Ably
    channel_param =
      channels
      |> Enum.map(fn ch ->
        if String.contains?(ch, "control") do
          "[?occupancy=metrics.publishers]#{ch}"
        else
          ch
        end
      end)
      |> Enum.join(",")

    "#{base_url}/event-stream?channels=#{URI.encode(channel_param)}&accessToken=#{URI.encode(token)}&v=1.1"
  end

  defp process_responses(responses, state) do
    Enum.reduce(responses, state, fn response, state ->
      process_response(response, state)
    end)
  end

  defp process_response({:status, _ref, status}, state) when status in 200..299 do
    %{state | status: :connected}
  end

  defp process_response({:status, _ref, status}, state) do
    Logger.error("SSE bad status: #{status}")
    %{state | status: :error}
  end

  defp process_response({:headers, _ref, _headers}, state) do
    state
  end

  defp process_response({:data, _ref, data}, state) do
    state = reset_keepalive(state)
    buffer = state.buffer <> data

    {events, remaining} = Parser.parse(buffer)

    # Process each event
    Enum.each(events, &Processor.handle_event/1)

    %{state | buffer: remaining}
  end

  defp process_response({:done, _ref}, state) do
    Logger.info("SSE stream ended")
    handle_disconnect(:stream_ended, state)
  end

  defp process_response({:error, _ref, reason}, state) do
    Logger.error("SSE error: #{inspect(reason)}")
    handle_disconnect(reason, state)
  end

  defp do_disconnect(state) do
    state = cancel_keepalive(state)

    if state.conn do
      Mint.HTTP.close(state.conn)
    end

    %{state | conn: nil, request_ref: nil, status: :disconnected, buffer: ""}
  end

  defp handle_disconnect(reason, state) do
    state = do_disconnect(state)

    # Check if retryable
    if retryable_error?(reason) and not Backoff.exhausted?(state.backoff) do
      schedule_reconnect(state)
    else
      Logger.error("SSE permanent failure, switching to polling")
      Splitio.Sync.Manager.start_polling()
      state
    end
  end

  defp retryable_error?(:tcp_closed), do: true
  defp retryable_error?(:ssl_closed), do: true
  defp retryable_error?(:keepalive_timeout), do: true
  defp retryable_error?(:stream_ended), do: true
  defp retryable_error?({:error, _}), do: true
  defp retryable_error?(_), do: false

  defp schedule_reconnect(state) do
    {wait_ms, backoff} = Backoff.next(state.backoff)
    Logger.info("SSE reconnecting in #{wait_ms}ms")
    Process.send_after(self(), :reconnect, wait_ms)
    %{state | backoff: backoff, status: :reconnecting}
  end

  defp reset_keepalive(state) do
    state = cancel_keepalive(state)
    timer = Process.send_after(self(), :keepalive_timeout, @keepalive_timeout_ms)
    %{state | keepalive_timer: timer}
  end

  defp cancel_keepalive(%{keepalive_timer: nil} = state), do: state

  defp cancel_keepalive(%{keepalive_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | keepalive_timer: nil}
  end

  # Handle raw TCP/SSL data
  defp process_raw_data(data, state) do
    state = reset_keepalive(state)
    buffer = state.buffer <> data

    {events, remaining} = Parser.parse(buffer)

    # Process each event
    Enum.each(events, &Processor.handle_event/1)

    %{state | buffer: remaining}
  end
end
