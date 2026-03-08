defmodule Splitio.Api.Events do
  @moduledoc """
  Events API client for posting impressions and events.
  """

  alias Splitio.Api.Client
  alias Splitio.Config

  @doc "Post impressions bulk"
  @spec post_impressions(Config.t(), list(), atom()) :: {:ok, term()} | {:error, term()}
  def post_impressions(%Config{} = config, impressions, mode \\ :optimized) do
    Client.post(config, config.events_url, "/testImpressions/bulk", impressions,
      impressions_mode: format_mode(mode)
    )
  end

  @doc "Post impression counts"
  @spec post_impression_counts(Config.t(), map()) :: {:ok, term()} | {:error, term()}
  def post_impression_counts(%Config{} = config, counts) do
    Client.post(config, config.events_url, "/testImpressions/count", counts)
  end

  @doc "Post events bulk"
  @spec post_events(Config.t(), list()) :: {:ok, term()} | {:error, term()}
  def post_events(%Config{} = config, events) do
    Client.post(config, config.events_url, "/events/bulk", events)
  end

  @doc "Post unique keys (NONE mode)"
  @spec post_unique_keys(Config.t(), map()) :: {:ok, term()} | {:error, term()}
  def post_unique_keys(%Config{} = config, keys) do
    Client.post(config, config.events_url, "/keys/ss", keys)
  end

  defp format_mode(:optimized), do: "OPTIMIZED"
  defp format_mode(:debug), do: "DEBUG"
  defp format_mode(:none), do: "NONE"
end
