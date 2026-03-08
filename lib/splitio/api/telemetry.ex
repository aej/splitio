defmodule Splitio.Api.Telemetry do
  @moduledoc """
  Telemetry API client for posting SDK metrics.
  """

  alias Splitio.Api.Client
  alias Splitio.Config

  @doc "Post config telemetry (sent once at init)"
  @spec post_config(Config.t(), map()) :: {:ok, term()} | {:error, term()}
  def post_config(%Config{} = config, telemetry_data) do
    Client.post(config, config.telemetry_url, "/v1/metrics/config", telemetry_data)
  end

  @doc "Post usage telemetry (sent periodically)"
  @spec post_usage(Config.t(), map()) :: {:ok, term()} | {:error, term()}
  def post_usage(%Config{} = config, telemetry_data) do
    Client.post(config, config.telemetry_url, "/v1/metrics/usage", telemetry_data)
  end
end
