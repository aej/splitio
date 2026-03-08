defmodule Splitio.Push.Auth do
  @moduledoc """
  Streaming authentication manager.

  Handles JWT token fetching and refresh for SSE connections.
  """

  use GenServer

  alias Splitio.Api.Auth, as: AuthApi
  alias Splitio.Config

  require Logger

  @token_refresh_grace_ms 10 * 60 * 1000

  defstruct [
    :config,
    :token,
    :channels,
    :push_enabled,
    :expires_at,
    :refresh_timer
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc "Get current auth token"
  @spec get_token() :: {:ok, String.t(), [String.t()]} | {:error, term()}
  def get_token do
    GenServer.call(__MODULE__, :get_token)
  end

  @doc "Check if push is enabled"
  @spec push_enabled?() :: boolean()
  def push_enabled? do
    GenServer.call(__MODULE__, :push_enabled?)
  end

  @doc "Force token refresh"
  @spec refresh() :: :ok
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(%Config{} = config) do
    state = %__MODULE__{config: config}

    # Fetch initial token
    send(self(), :fetch_token)

    {:ok, state}
  end

  @impl true
  def handle_call(:get_token, _from, state) do
    if state.token && state.push_enabled do
      {:reply, {:ok, state.token, state.channels}, state}
    else
      {:reply, {:error, :no_token}, state}
    end
  end

  @impl true
  def handle_call(:push_enabled?, _from, state) do
    {:reply, state.push_enabled == true, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    state = cancel_refresh_timer(state)
    send(self(), :fetch_token)
    {:noreply, state}
  end

  @impl true
  def handle_info(:fetch_token, state) do
    state = fetch_and_schedule(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh_token, state) do
    state = fetch_and_schedule(state)
    {:noreply, state}
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp fetch_and_schedule(state) do
    case AuthApi.get_auth_token(state.config) do
      {:ok, response} ->
        token = response["token"]
        push_enabled = response["pushEnabled"] == true

        if push_enabled and token do
          {channels, expires_at} = parse_token(token)

          state = %{
            state
            | token: token,
              channels: channels,
              push_enabled: true,
              expires_at: expires_at
          }

          schedule_refresh(state)
        else
          Logger.info("Push disabled by server")
          %{state | push_enabled: false, token: nil}
        end

      {:error, reason} ->
        Logger.error("Failed to fetch auth token: #{inspect(reason)}")
        # Retry after delay
        Process.send_after(self(), :fetch_token, 30_000)
        state
    end
  end

  defp parse_token(token) do
    # JWT is base64 encoded: header.payload.signature
    case String.split(token, ".") do
      [_header, payload, _sig] ->
        case Base.decode64(payload, padding: false) do
          {:ok, json} ->
            case Jason.decode(json) do
              {:ok, claims} ->
                channels = parse_channels(claims["x-ably-capability"])
                exp = claims["exp"]
                expires_at = if exp, do: exp * 1000, else: nil
                {channels, expires_at}

              _ ->
                {[], nil}
            end

          _ ->
            {[], nil}
        end

      _ ->
        {[], nil}
    end
  end

  defp parse_channels(nil), do: []

  defp parse_channels(capability) when is_binary(capability) do
    case Jason.decode(capability) do
      {:ok, map} when is_map(map) -> Map.keys(map)
      _ -> []
    end
  end

  defp parse_channels(_), do: []

  defp schedule_refresh(%{expires_at: nil} = state), do: state

  defp schedule_refresh(%{expires_at: expires_at} = state) do
    now = System.system_time(:millisecond)
    refresh_at = expires_at - @token_refresh_grace_ms
    delay = max(refresh_at - now, 60_000)

    timer = Process.send_after(self(), :refresh_token, delay)
    %{state | refresh_timer: timer}
  end

  defp cancel_refresh_timer(%{refresh_timer: nil} = state), do: state

  defp cancel_refresh_timer(%{refresh_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | refresh_timer: nil}
  end
end
