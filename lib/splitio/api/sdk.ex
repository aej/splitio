defmodule Splitio.Api.SDK do
  @moduledoc """
  SDK API client for fetching splits and segments.
  """

  alias Splitio.Api.Client
  alias Splitio.Config

  @doc """
  Fetch split changes from SDK API.

  Options:
  - since: Change number to fetch from (default: -1)
  - till: Target change number for CDN bypass
  - sets: Flag sets to filter by
  """
  @spec fetch_split_changes(Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_split_changes(%Config{} = config, opts \\ []) do
    since = Keyword.get(opts, :since, -1)
    till = Keyword.get(opts, :till)
    sets = Keyword.get(opts, :sets)

    query =
      [since: since]
      |> maybe_add_param(:till, till)
      |> maybe_add_param(:sets, format_sets(sets))
      |> maybe_add_param(:s, "1.3")

    cache_control = if till, do: "no-cache", else: nil

    Client.get(config, config.sdk_url, "/splitChanges",
      query: query,
      cache_control: cache_control
    )
  end

  @doc """
  Fetch segment changes from SDK API.

  Options:
  - since: Change number to fetch from (default: -1)
  - till: Target change number for CDN bypass
  """
  @spec fetch_segment_changes(Config.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def fetch_segment_changes(%Config{} = config, segment_name, opts \\ []) do
    since = Keyword.get(opts, :since, -1)
    till = Keyword.get(opts, :till)

    query =
      [since: since]
      |> maybe_add_param(:till, till)

    cache_control = if till, do: "no-cache", else: nil

    Client.get(config, config.sdk_url, "/segmentChanges/#{segment_name}",
      query: query,
      cache_control: cache_control
    )
  end

  @doc """
  Fetch large segment definition.
  """
  @spec fetch_large_segment(Config.t(), String.t(), integer()) :: {:ok, map()} | {:error, term()}
  def fetch_large_segment(%Config{} = config, segment_name, since \\ -1) do
    Client.get(config, config.sdk_url, "/largeSegmentDefinition/#{segment_name}",
      query: [since: since]
    )
  end

  @doc """
  Download file from URL (for large segments).
  """
  @spec download_file(String.t(), map()) :: {:ok, binary()} | {:error, term()}
  def download_file(url, headers \\ %{}) do
    header_list = Enum.map(headers, fn {k, v} -> {k, v} end)
    http_client().get(url, headers: header_list, decode_json: false)
  end

  defp maybe_add_param(query, _key, nil), do: query
  defp maybe_add_param(query, key, value), do: Keyword.put(query, key, value)

  defp format_sets(nil), do: nil
  defp format_sets([]), do: nil
  defp format_sets(sets), do: Enum.join(sets, ",")

  defp http_client do
    case Process.get(:splitio_http_client) do
      nil -> Application.get_env(:splitio, :http_client, Splitio.Api.HTTP.Tesla)
      client -> client
    end
  end
end
