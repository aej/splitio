defmodule Splitio.Api.Client do
  @moduledoc """
  HTTP client wrapper for Split API requests.

  Uses Req for HTTP requests with proper headers and error handling.
  """

  alias Splitio.Config

  @sdk_version "elixir-splitio-1.0.0"

  @type response :: {:ok, map() | binary()} | {:error, term()}

  @doc "Make a GET request to Split API"
  @spec get(Config.t(), String.t(), String.t(), keyword()) :: response()
  def get(%Config{} = config, base_url, path, opts \\ []) do
    url = base_url <> path
    headers = build_headers(config, opts)
    query = Keyword.get(opts, :query, [])

    req_opts = [
      headers: headers,
      params: query,
      receive_timeout: config.read_timeout,
      connect_options: [timeout: config.connection_timeout]
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

  @doc "Make a POST request to Split API"
  @spec post(Config.t(), String.t(), String.t(), term(), keyword()) :: response()
  def post(%Config{} = config, base_url, path, body, opts \\ []) do
    url = base_url <> path
    headers = build_headers(config, opts)

    req_opts = [
      headers: headers,
      json: body,
      receive_timeout: config.read_timeout,
      connect_options: [timeout: config.connection_timeout]
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

  defp build_headers(%Config{} = config, opts) do
    base_headers = [
      {"authorization", "Bearer #{config.api_key}"},
      {"content-type", "application/json"},
      {"accept-encoding", "gzip"},
      {"splitsdkversion", @sdk_version}
    ]

    # Add optional headers
    base_headers
    |> maybe_add_header("splitsdkmachineip", get_machine_ip(config))
    |> maybe_add_header("splitsdkmachinename", get_machine_name(config))
    |> maybe_add_header("splitsdkimpressionsmode", Keyword.get(opts, :impressions_mode))
    |> maybe_add_header("cache-control", Keyword.get(opts, :cache_control))
  end

  defp maybe_add_header(headers, _key, nil), do: headers
  defp maybe_add_header(headers, _key, "NA"), do: headers
  defp maybe_add_header(headers, key, value), do: [{key, to_string(value)} | headers]

  defp get_machine_ip(%Config{ip_addresses_enabled: false}), do: nil

  defp get_machine_ip(_config) do
    case :inet.getif() do
      {:ok, [{ip, _, _} | _]} -> format_ip(ip)
      _ -> nil
    end
  end

  defp get_machine_name(%Config{ip_addresses_enabled: false}), do: nil

  defp get_machine_name(_config) do
    case :inet.gethostname() do
      {:ok, hostname} -> to_string(hostname)
      _ -> nil
    end
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(_), do: nil
end
