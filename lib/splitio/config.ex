defmodule Splitio.Config do
  @moduledoc "SDK configuration"

  @type mode :: :standalone | :consumer | :localhost
  @type impressions_mode :: :optimized | :debug | :none
  @type listener :: (map() -> any()) | {module(), atom(), [term()]}
  @type fallback_entry :: %{required(:treatment) => String.t(), optional(:config) => String.t() | nil}
  @type fallback_treatment :: %{
          optional(:global) => fallback_entry(),
          optional(:by_flag) => %{String.t() => fallback_entry()}
        }

  @type t :: %__MODULE__{
          api_key: String.t(),
          mode: mode(),
          streaming_enabled: boolean(),
          features_refresh_rate: pos_integer(),
          segments_refresh_rate: pos_integer(),
          impressions_mode: impressions_mode(),
          impressions_refresh_rate: pos_integer(),
          impressions_queue_size: pos_integer(),
          impressions_bulk_size: pos_integer(),
          events_refresh_rate: pos_integer(),
          events_queue_size: pos_integer(),
          events_bulk_size: pos_integer(),
          connection_timeout: pos_integer(),
          read_timeout: pos_integer(),
          sdk_url: String.t(),
          events_url: String.t(),
          auth_url: String.t(),
          streaming_url: String.t(),
          telemetry_url: String.t(),
          split_file: String.t() | nil,
          segment_directory: String.t() | nil,
          localhost_refresh_enabled: boolean(),
          flag_sets_filter: [String.t()] | nil,
          labels_enabled: boolean(),
          ip_addresses_enabled: boolean(),
          impression_listener: listener() | nil,
          fallback_treatment: fallback_treatment() | nil
        }

  @enforce_keys [:api_key]
  defstruct [
    :api_key,
    :split_file,
    :segment_directory,
    :flag_sets_filter,
    :impression_listener,
    :fallback_treatment,
    mode: :standalone,
    streaming_enabled: true,
    features_refresh_rate: 30,
    segments_refresh_rate: 30,
    impressions_mode: :optimized,
    impressions_refresh_rate: 300,
    impressions_queue_size: 10_000,
    impressions_bulk_size: 5_000,
    events_refresh_rate: 60,
    events_queue_size: 10_000,
    events_bulk_size: 5_000,
    connection_timeout: 10_000,
    read_timeout: 60_000,
    sdk_url: "https://sdk.split.io/api",
    events_url: "https://events.split.io/api",
    auth_url: "https://auth.split.io/api",
    streaming_url: "https://streaming.split.io",
    telemetry_url: "https://telemetry.split.io/api",
    localhost_refresh_enabled: false,
    labels_enabled: true,
    ip_addresses_enabled: true
  ]

  @doc """
  Read config from Application environment.

  Reads all configuration from `config :splitio, ...` in your config files.
  Returns `nil` if `:api_key` is not configured.
  """
  @spec from_env() :: {:ok, t()} | nil
  def from_env do
    opts = Application.get_all_env(:splitio)
    api_key = Keyword.get(opts, :api_key)

    if is_nil(api_key) or api_key == "" do
      nil
    else
      new(opts)
    end
  end

  @doc "Create config from keyword list"
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    api_key = Keyword.get(opts, :api_key)

    if is_nil(api_key) or api_key == "" do
      {:error, :api_key_required}
    else
      config = %__MODULE__{
        api_key: api_key,
        mode: resolve_mode(api_key, Keyword.get(opts, :mode, :standalone)),
        streaming_enabled: Keyword.get(opts, :streaming_enabled, true),
        features_refresh_rate: Keyword.get(opts, :features_refresh_rate, 30),
        segments_refresh_rate: Keyword.get(opts, :segments_refresh_rate, 30),
        impressions_mode: Keyword.get(opts, :impressions_mode, :optimized),
        impressions_refresh_rate: Keyword.get(opts, :impressions_refresh_rate, 300),
        impressions_queue_size: Keyword.get(opts, :impressions_queue_size, 10_000),
        impressions_bulk_size: Keyword.get(opts, :impressions_bulk_size, 5_000),
        events_refresh_rate: Keyword.get(opts, :events_refresh_rate, 60),
        events_queue_size: Keyword.get(opts, :events_queue_size, 10_000),
        events_bulk_size: Keyword.get(opts, :events_bulk_size, 5_000),
        connection_timeout: Keyword.get(opts, :connection_timeout, 10_000),
        read_timeout: Keyword.get(opts, :read_timeout, 60_000),
        sdk_url: Keyword.get(opts, :sdk_url, "https://sdk.split.io/api"),
        events_url: Keyword.get(opts, :events_url, "https://events.split.io/api"),
        auth_url: Keyword.get(opts, :auth_url, "https://auth.split.io/api"),
        streaming_url: Keyword.get(opts, :streaming_url, "https://streaming.split.io"),
        telemetry_url: Keyword.get(opts, :telemetry_url, "https://telemetry.split.io/api"),
        split_file: Keyword.get(opts, :split_file),
        segment_directory: Keyword.get(opts, :segment_directory),
        localhost_refresh_enabled: Keyword.get(opts, :localhost_refresh_enabled, false),
        flag_sets_filter: normalize_flag_sets(Keyword.get(opts, :flag_sets_filter)),
        labels_enabled: Keyword.get(opts, :labels_enabled, true),
        ip_addresses_enabled: Keyword.get(opts, :ip_addresses_enabled, true),
        impression_listener: Keyword.get(opts, :impression_listener),
        fallback_treatment: normalize_fallback_treatment(Keyword.get(opts, :fallback_treatment))
      }

      {:ok, config}
    end
  end

  @doc "Check if a URL is overridden from default"
  @spec url_overridden?(t(), atom()) :: boolean()
  def url_overridden?(%__MODULE__{} = config, :sdk),
    do: config.sdk_url != "https://sdk.split.io/api"

  def url_overridden?(%__MODULE__{} = config, :events),
    do: config.events_url != "https://events.split.io/api"

  def url_overridden?(%__MODULE__{} = config, :auth),
    do: config.auth_url != "https://auth.split.io/api"

  def url_overridden?(%__MODULE__{} = config, :streaming),
    do: config.streaming_url != "https://streaming.split.io"

  def url_overridden?(%__MODULE__{} = config, :telemetry),
    do: config.telemetry_url != "https://telemetry.split.io/api"

  # Normalize flag sets: trim, lowercase, validate format
  defp normalize_flag_sets(nil), do: nil
  defp normalize_flag_sets([]), do: nil

  defp normalize_flag_sets(sets) when is_list(sets) do
    sets
    |> Enum.map(&normalize_flag_set/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      normalized -> Enum.uniq(normalized)
    end
  end

  defp normalize_flag_set(set) when is_binary(set) do
    normalized = set |> String.trim() |> String.downcase()

    if valid_flag_set?(normalized) do
      normalized
    else
      nil
    end
  end

  defp normalize_flag_set(_), do: nil

  # Flag set validation: must start with letter, then alphanumeric + underscore
  # Regex: ^[a-z][_a-z0-9]{0,49}$
  defp valid_flag_set?(set) do
    Regex.match?(~r/^[a-z][_a-z0-9]{0,49}$/, set)
  end

  defp resolve_mode("localhost", _mode), do: :localhost
  defp resolve_mode(_api_key, mode), do: mode

  defp normalize_fallback_treatment(nil), do: nil

  defp normalize_fallback_treatment(fallback) when is_map(fallback) do
    global =
      (Map.get(fallback, :global) || Map.get(fallback, "global"))
      |> normalize_fallback_entry()

    by_flag =
      (Map.get(fallback, :by_flag) || Map.get(fallback, "by_flag"))
      |> normalize_fallback_by_flag()

    case %{global: global, by_flag: by_flag} do
      %{global: nil, by_flag: nil} -> nil
      normalized -> normalized
    end
  end

  defp normalize_fallback_treatment(_), do: nil

  defp normalize_fallback_by_flag(nil), do: nil

  defp normalize_fallback_by_flag(by_flag) when is_map(by_flag) do
    by_flag
    |> Enum.reduce(%{}, fn {flag_name, entry}, acc ->
      case normalize_fallback_entry(entry) do
        nil -> acc
        normalized -> Map.put(acc, to_string(flag_name), normalized)
      end
    end)
    |> case do
      map when map_size(map) == 0 -> nil
      map -> map
    end
  end

  defp normalize_fallback_by_flag(_), do: nil

  defp normalize_fallback_entry(nil), do: nil

  defp normalize_fallback_entry(entry) when is_binary(entry) do
    %{treatment: entry}
  end

  defp normalize_fallback_entry(entry) when is_map(entry) do
    treatment = Map.get(entry, :treatment) || Map.get(entry, "treatment")
    config = Map.get(entry, :config) || Map.get(entry, "config")

    if is_binary(treatment) and treatment != "" do
      %{treatment: treatment, config: normalize_fallback_config(config)}
    else
      nil
    end
  end

  defp normalize_fallback_entry(_), do: nil

  defp normalize_fallback_config(nil), do: nil
  defp normalize_fallback_config(config) when is_binary(config), do: config
  defp normalize_fallback_config(config), do: Jason.encode!(config)
end
