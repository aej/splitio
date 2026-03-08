defmodule Splitio.Models.KeySelector do
  @moduledoc "Key selector for matcher - specifies which value to match against"

  @type t :: %__MODULE__{
          traffic_type: String.t() | nil,
          attribute: String.t() | nil
        }

  defstruct [:traffic_type, :attribute]

  @spec from_json(map() | nil) :: t()
  def from_json(nil), do: %__MODULE__{}

  def from_json(json) do
    %__MODULE__{
      traffic_type: json["trafficType"],
      attribute: json["attribute"]
    }
  end
end
