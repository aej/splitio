defmodule Splitio.Models.ExcludedSegment do
  @moduledoc "Reference to excluded segment in rule-based segments"

  @type segment_type :: :standard | :rule_based | :large

  @type t :: %__MODULE__{
          name: String.t(),
          type: segment_type()
        }

  @enforce_keys [:name, :type]
  defstruct [:name, :type]

  @spec from_json(map()) :: t()
  def from_json(json) do
    %__MODULE__{
      name: json["name"],
      type: parse_type(json["type"])
    }
  end

  defp parse_type("standard"), do: :standard
  defp parse_type("rule-based"), do: :rule_based
  defp parse_type("large"), do: :large
  defp parse_type(_), do: :standard
end
