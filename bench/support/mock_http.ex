defmodule Splitio.Bench.MockHTTP do
  @moduledoc """
  HTTP transport used by load tests.

  Requests are delegated to `Splitio.Bench.MockServer` so the SDK still crosses
  the configured HTTP boundary while remaining fully deterministic in CI.
  """

  @behaviour Splitio.Api.HTTP

  @impl true
  def get(url, opts) do
    Splitio.Bench.MockServer.get(url, opts)
  end

  @impl true
  def post(url, body, opts) do
    Splitio.Bench.MockServer.post(url, body, opts)
  end
end
