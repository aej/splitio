defmodule Splitio.Sync.LargeSegments do
  @moduledoc """
  Large segment synchronization via Remote File Download (RFD).

  Downloads full segment key lists from pre-signed URLs.
  """

  alias Splitio.Api.SDK
  alias Splitio.Config
  alias Splitio.Storage

  require Logger

  @max_concurrent_downloads 5

  @doc """
  Synchronize a large segment.
  """
  @spec sync_large_segment(Config.t(), String.t()) :: :ok | {:error, term()}
  def sync_large_segment(%Config{} = config, segment_name) do
    since = Storage.get_large_segment_change_number(segment_name)

    case SDK.fetch_large_segment(config, segment_name, since) do
      {:ok, response} ->
        process_large_segment_response(segment_name, response)

      {:error, reason} ->
        Logger.error("Failed to fetch large segment #{segment_name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Synchronize multiple large segments with concurrency limit.
  """
  @spec sync_large_segments(Config.t(), [String.t()]) :: :ok
  def sync_large_segments(%Config{} = config, segment_names) do
    segment_names
    |> Task.async_stream(
      fn name -> sync_large_segment(config, name) end,
      max_concurrency: @max_concurrent_downloads,
      timeout: 300_000
    )
    |> Enum.each(fn
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> Logger.warning("Large segment sync failed: #{inspect(reason)}")
      {:exit, reason} -> Logger.error("Large segment sync crashed: #{inspect(reason)}")
    end)

    :ok
  end

  defp process_large_segment_response(segment_name, response) do
    notification_type = response["t"]
    change_number = response["cn"] || -1

    case notification_type do
      "LS_NEW_DEFINITION" ->
        download_and_store(segment_name, response["rfd"], change_number)

      "LS_EMPTY" ->
        Storage.clear_large_segment(segment_name)
        :ok

      _ ->
        Logger.warning("Unknown large segment notification type: #{notification_type}")
        :ok
    end
  end

  defp download_and_store(segment_name, rfd, change_number) when is_map(rfd) do
    params = rfd["p"] || %{}
    url = params["u"]
    headers = params["h"] || %{}

    case SDK.download_file(url, headers) do
      {:ok, content} ->
        keys = parse_csv_content(content)
        Storage.put_large_segment_keys(segment_name, keys, change_number)
        Logger.info("Downloaded large segment #{segment_name} with #{MapSet.size(keys)} keys")
        :ok

      {:error, reason} ->
        Logger.error("Failed to download large segment file: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp download_and_store(_segment_name, _rfd, _change_number), do: :ok

  # Parse CSV content (one key per line)
  defp parse_csv_content(content) do
    content
    |> strip_bom()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.contains?(&1, ",")))
    |> MapSet.new()
  end

  # Strip UTF-8 BOM if present
  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(content), do: content
end
