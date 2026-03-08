defmodule Splitio.Models.Impression do
  @moduledoc "Record of a treatment evaluation"

  @type t :: %__MODULE__{
          key: String.t(),
          bucketing_key: String.t() | nil,
          feature: String.t(),
          treatment: String.t(),
          label: String.t(),
          change_number: non_neg_integer(),
          time: non_neg_integer(),
          previous_time: non_neg_integer() | nil,
          properties: map() | nil
        }

  @enforce_keys [:key, :feature, :treatment, :label, :change_number, :time]
  defstruct [
    :key,
    :bucketing_key,
    :feature,
    :treatment,
    :label,
    :change_number,
    :time,
    :previous_time,
    :properties
  ]

  @doc "Convert to API format for bulk send"
  @spec to_api_format(t()) :: map()
  def to_api_format(%__MODULE__{} = imp) do
    base = %{
      "k" => imp.key,
      "t" => imp.treatment,
      "m" => imp.time,
      "c" => imp.change_number,
      "r" => imp.label
    }

    base
    |> maybe_put("b", imp.bucketing_key)
    |> maybe_put("pt", imp.previous_time)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
