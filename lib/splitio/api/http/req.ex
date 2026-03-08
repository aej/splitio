defmodule Splitio.Api.HTTP.Req do
  @moduledoc """
  Req-based HTTP client implementation.
  """

  @behaviour Splitio.Api.HTTP

  @impl true
  def get(url, opts \\ []) do
    headers = Keyword.get(opts, :headers, [])
    params = Keyword.get(opts, :params, [])
    receive_timeout = Keyword.get(opts, :receive_timeout, 60_000)
    connect_timeout = Keyword.get(opts, :connect_timeout, 10_000)

    req_opts = [
      headers: headers,
      params: params,
      receive_timeout: receive_timeout,
      connect_options: [timeout: connect_timeout]
    ]

    case Req.get(url, req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def post(url, body, opts \\ []) do
    headers = Keyword.get(opts, :headers, [])
    receive_timeout = Keyword.get(opts, :receive_timeout, 60_000)
    connect_timeout = Keyword.get(opts, :connect_timeout, 10_000)

    req_opts = [
      headers: headers,
      json: body,
      receive_timeout: receive_timeout,
      connect_options: [timeout: connect_timeout]
    ]

    case Req.post(url, req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
