defmodule Splitio.Models.Segment do
  @moduledoc "User segment with incremental updates"

  @type t :: %__MODULE__{
          name: String.t(),
          keys: MapSet.t(String.t()),
          change_number: integer()
        }

  @enforce_keys [:name]
  defstruct [
    :name,
    keys: MapSet.new(),
    change_number: -1
  ]

  @spec from_json(map()) :: t()
  def from_json(%{"name" => name} = json) do
    keys =
      (json["added"] || [])
      |> MapSet.new()

    %__MODULE__{
      name: name,
      keys: keys,
      change_number: json["till"] || -1
    }
  end

  @spec contains?(t(), String.t()) :: boolean()
  def contains?(%__MODULE__{keys: keys}, key), do: MapSet.member?(keys, key)

  @spec update(t(), [String.t()], [String.t()], integer()) :: t()
  def update(%__MODULE__{keys: keys} = segment, to_add, to_remove, change_number) do
    keys =
      keys
      |> MapSet.union(MapSet.new(to_add))
      |> MapSet.difference(MapSet.new(to_remove))

    %{segment | keys: keys, change_number: change_number}
  end

  @spec key_count(t()) :: non_neg_integer()
  def key_count(%__MODULE__{keys: keys}), do: MapSet.size(keys)
end
