defmodule Splitio.Bench.MockHTTP do
  @moduledoc """
  In-memory HTTP implementation for load testing.

  Returns pre-configured responses instantly without network overhead.
  Implements the Splitio.Api.HTTP behaviour.
  """

  @behaviour Splitio.Api.HTTP

  @impl true
  def get(_url, _opts) do
    # Return empty response - splits/segments already loaded via fixtures
    {:ok, %{"splits" => [], "since" => 1000, "till" => 1000}}
  end

  @impl true
  def post(_url, _body, _opts) do
    # Accept all posts (impressions, events, telemetry)
    {:ok, %{}}
  end
end
