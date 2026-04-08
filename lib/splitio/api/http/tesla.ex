defmodule Splitio.Api.HTTP.Tesla do
  @moduledoc """
  Tesla-based HTTP client implementation.
  """

  @behaviour Splitio.Api.HTTP

  @finch_name __MODULE__.Finch

  @spec finch_name() :: atom()
  def finch_name, do: @finch_name

  @impl true
  def get(url, opts \\ []) do
    client = client(decode_json: Keyword.get(opts, :decode_json, true))

    case Tesla.get(client, url, request_opts(opts)) do
      {:ok, %Tesla.Env{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Tesla.Env{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def post(url, body, opts \\ []) do
    client = client(decode_json: true)

    case Tesla.post(client, url, body, request_opts(opts)) do
      {:ok, %Tesla.Env{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %Tesla.Env{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp client(opts) do
    middleware =
      if Keyword.get(opts, :decode_json, true) do
        [{Tesla.Middleware.JSON, engine: Jason}]
      else
        []
      end

    Tesla.client(middleware, {Tesla.Adapter.Finch, name: finch_name()})
  end

  defp request_opts(opts) do
    headers = Keyword.get(opts, :headers, [])
    query = Keyword.get(opts, :params, [])
    receive_timeout = Keyword.get(opts, :receive_timeout, 60_000)
    connect_timeout = Keyword.get(opts, :connect_timeout, 10_000)

    [
      headers: headers,
      query: query,
      opts: [adapter: [receive_timeout: receive_timeout, pool_timeout: connect_timeout]]
    ]
  end
end
