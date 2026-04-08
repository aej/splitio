defmodule Splitio.Api.Client do
  @moduledoc """
  HTTP client wrapper for Split API requests.

  Routes through configurable HTTP backend (defaults to Tesla).
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

    http_opts = [
      headers: headers,
      params: query,
      receive_timeout: config.read_timeout,
      connect_timeout: config.connection_timeout
    ]

    http_client().get(url, http_opts)
  end

  @doc "Make a POST request to Split API"
  @spec post(Config.t(), String.t(), String.t(), term(), keyword()) :: response()
  def post(%Config{} = config, base_url, path, body, opts \\ []) do
    url = base_url <> path
    headers = build_headers(config, opts)

    http_opts = [
      headers: headers,
      receive_timeout: config.read_timeout,
      connect_timeout: config.connection_timeout
    ]

    http_client().post(url, body, http_opts)
  end

  defp http_client do
    case Process.get(:splitio_http_client) do
      nil -> Application.get_env(:splitio, :http_client, Splitio.Api.HTTP.Tesla)
      client -> client
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
