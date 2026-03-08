defmodule Splitio.Models.MatcherGroup do
  @moduledoc "Group of matchers combined with AND logic"

  alias Splitio.Models.Matcher

  @type combiner :: :and

  @type t :: %__MODULE__{
          combiner: combiner(),
          matchers: [Matcher.t()]
        }

  @enforce_keys [:matchers]
  defstruct combiner: :and, matchers: []

  @spec from_json(map()) :: t()
  def from_json(json) do
    matchers =
      (json["matchers"] || [])
      |> Enum.map(&Matcher.from_json/1)

    %__MODULE__{
      combiner: :and,
      matchers: matchers
    }
  end
end
