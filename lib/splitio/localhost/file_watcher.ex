defmodule Splitio.Localhost.FileWatcher do
  @moduledoc """
  File watcher for localhost mode.

  Periodically checks for file changes using SHA1 hash comparison.
  """

  use GenServer

  alias Splitio.Localhost.Loader

  require Logger

  defstruct [
    :path,
    :segment_directory,
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
    segment_directory = Keyword.get(opts, :segment_directory)
    refresh_rate = Keyword.get(opts, :refresh_rate, 30) * 1000

    state = %__MODULE__{
      path: path,
      segment_directory: segment_directory,
      hash: nil,
      refresh_rate: refresh_rate
    }

    # Initial load
    case load_file(state) do
      {:ok, state} ->
        # Schedule periodic check if enabled
        state =
          if Keyword.get(opts, :refresh_enabled, false) do
            schedule_check(state)
          else
            state
          end

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
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

  defp load_file(%{path: path, segment_directory: segment_directory} = state) do
    case compute_hash(path, segment_directory) do
      {:ok, hash} ->
        if hash != state.hash do
          Logger.info("Loading localhost data from #{path}")

          case Loader.load(path, segment_directory) do
            {:ok, result} ->
              Logger.info(
                "Loaded #{result.splits} splits and #{result.segments} segments from localhost files"
              )

              {:ok, %{state | hash: hash}}

            {:error, reason} ->
              Logger.error("Failed to load localhost data: #{inspect(reason)}")
              {:error, reason}
          end
        else
          {:ok, state}
        end

      {:error, reason} ->
        Logger.error("Failed to compute localhost file hash for #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp check_and_reload(state) do
    case load_file(state) do
      {:ok, updated_state} -> updated_state
      {:error, _reason} -> state
    end
  end

  defp schedule_check(state) do
    timer = Process.send_after(self(), :check, state.refresh_rate)
    %{state | timer: timer}
  end

  defp compute_hash(path, segment_directory) do
    with {:ok, split_content} <- File.read(path),
         {:ok, segment_content} <- read_segment_content(segment_directory) do
      hash =
        :crypto.hash(:sha, split_content <> segment_content)
        |> Base.encode16()

      {:ok, hash}
    end
  end

  defp read_segment_content(nil), do: {:ok, ""}
  defp read_segment_content(""), do: {:ok, ""}

  defp read_segment_content(directory) do
    with {:ok, files} <- File.ls(directory) do
      files
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.sort()
      |> Enum.reduce_while({:ok, ""}, fn file, {:ok, acc} ->
        path = Path.join(directory, file)

        case File.read(path) do
          {:ok, content} -> {:cont, {:ok, acc <> content}}
          {:error, reason} -> {:halt, {:error, {:segment_read_error, path, reason}}}
        end
      end)
    end
  end
end
