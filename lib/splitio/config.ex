defmodule Splitio.Config do
  @moduledoc "SDK configuration"

  @type mode :: :standalone | :consumer | :localhost
  @type impressions_mode :: :optimized | :debug | :none

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
          localhost_refresh_enabled: boolean(),
          flag_sets_filter: [String.t()] | nil,
          labels_enabled: boolean(),
          ip_addresses_enabled: boolean()
        }

  @enforce_keys [:api_key]
  defstruct [
    :api_key,
    :split_file,
    :flag_sets_filter,
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

  @doc "Create config from keyword list"
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    api_key = Keyword.get(opts, :api_key)

    if is_nil(api_key) or api_key == "" do
      {:error, :api_key_required}
    else
      config = %__MODULE__{
        api_key: api_key,
        mode: Keyword.get(opts, :mode, :standalone),
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
        localhost_refresh_enabled: Keyword.get(opts, :localhost_refresh_enabled, false),
        flag_sets_filter: normalize_flag_sets(Keyword.get(opts, :flag_sets_filter)),
        labels_enabled: Keyword.get(opts, :labels_enabled, true),
        ip_addresses_enabled: Keyword.get(opts, :ip_addresses_enabled, true)
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
end
