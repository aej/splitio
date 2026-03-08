defmodule Splitio.Models.Event do
  @moduledoc "Custom tracking event"

  @type t :: %__MODULE__{
          key: String.t(),
          traffic_type: String.t(),
          event_type: String.t(),
          value: number() | nil,
          timestamp: non_neg_integer(),
          properties: map() | nil
        }

  @enforce_keys [:key, :traffic_type, :event_type, :timestamp]
  defstruct [
    :key,
    :traffic_type,
    :event_type,
    :value,
    :timestamp,
    :properties
  ]

  @max_properties_size 32_768
  @max_property_count 300

  @spec new(String.t(), String.t(), String.t(), number() | nil, map() | nil) ::
          {:ok, t()} | {:error, atom()}
  def new(key, traffic_type, event_type, value \\ nil, properties \\ nil) do
    with :ok <- validate_properties(properties) do
      {:ok,
       %__MODULE__{
         key: key,
         traffic_type: traffic_type,
         event_type: event_type,
         value: value,
         timestamp: System.system_time(:millisecond),
         properties: properties
       }}
    end
  end

  @doc "Convert to API format"
  @spec to_api_format(t()) :: map()
  def to_api_format(%__MODULE__{} = event) do
    base = %{
      "key" => event.key,
      "trafficTypeName" => event.traffic_type,
      "eventTypeId" => event.event_type,
      "timestamp" => event.timestamp
    }

    base
    |> maybe_put("value", event.value)
    |> maybe_put("properties", event.properties)
  end

  defp validate_properties(nil), do: :ok

  defp validate_properties(props) when is_map(props) do
    cond do
      map_size(props) > @max_property_count ->
        {:error, :too_many_properties}

      byte_size(Jason.encode!(props)) > @max_properties_size ->
        {:error, :properties_too_large}

      true ->
        :ok
    end
  end

  defp validate_properties(_), do: {:error, :invalid_properties}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
