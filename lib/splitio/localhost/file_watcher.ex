defmodule Splitio.Localhost.FileWatcher do
  @moduledoc """
  File watcher for localhost mode.

  Periodically checks for file changes using SHA1 hash comparison.
  """

  use GenServer

  alias Splitio.Localhost.{YamlParser, JsonParser}
  alias Splitio.Storage

  require Logger

  defstruct [
    :path,
    :hash,
    :refresh_rate,
    :timer
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    refresh_rate = Keyword.get(opts, :refresh_rate, 30) * 1000

    state = %__MODULE__{
      path: path,
      hash: nil,
      refresh_rate: refresh_rate
    }

    # Initial load
    state = load_file(state)

    # Schedule periodic check if enabled
    state =
      if Keyword.get(opts, :refresh_enabled, false) do
        schedule_check(state)
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_info(:check, state) do
    state = check_and_reload(state)
    state = schedule_check(state)
    {:noreply, state}
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp load_file(%{path: path} = state) do
    case File.read(path) do
      {:ok, content} ->
        hash = :crypto.hash(:sha, content) |> Base.encode16()

        if hash != state.hash do
          Logger.info("Loading split file: #{path}")
          load_splits(path, content)
          %{state | hash: hash}
        else
          state
        end

      {:error, reason} ->
        Logger.error("Failed to read split file #{path}: #{inspect(reason)}")
        state
    end
  end

  defp check_and_reload(state), do: load_file(state)

  defp load_splits(path, content) do
    result =
      cond do
        String.ends_with?(path, ".yaml") or String.ends_with?(path, ".yml") ->
          YamlParser.parse_string(content)

        String.ends_with?(path, ".json") ->
          JsonParser.parse_string(content)

        true ->
          {:error, :unknown_format}
      end

    case result do
      {:ok, splits} ->
        # Clear existing splits and load new ones
        Enum.each(Storage.get_split_names(), &Storage.delete_split/1)
        Enum.each(splits, &Storage.put_split/1)
        Logger.info("Loaded #{length(splits)} splits from file")

      {:error, reason} ->
        Logger.error("Failed to parse split file: #{inspect(reason)}")
    end
  end

  defp schedule_check(state) do
    timer = Process.send_after(self(), :check, state.refresh_rate)
    %{state | timer: timer}
  end
end
