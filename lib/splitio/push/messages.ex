defmodule Splitio.Push.Messages do
  @moduledoc """
  SSE message types for streaming updates.
  """

  defmodule SplitUpdate do
    @moduledoc "Split update notification"
    @type t :: %__MODULE__{
            change_number: non_neg_integer(),
            previous_change_number: non_neg_integer() | nil,
            definition: String.t() | nil,
            compression: :none | :gzip | :zlib
          }
    defstruct [:change_number, :previous_change_number, :definition, compression: :none]
  end

  defmodule SplitKill do
    @moduledoc "Split kill notification"
    @type t :: %__MODULE__{
            change_number: non_neg_integer(),
            split_name: String.t(),
            default_treatment: String.t()
          }
    @enforce_keys [:change_number, :split_name, :default_treatment]
    defstruct [:change_number, :split_name, :default_treatment]
  end

  defmodule SegmentUpdate do
    @moduledoc "Segment update notification"
    @type t :: %__MODULE__{
            change_number: non_neg_integer(),
            segment_name: String.t()
          }
    @enforce_keys [:change_number, :segment_name]
    defstruct [:change_number, :segment_name]
  end

  defmodule RuleBasedSegmentUpdate do
    @moduledoc "Rule-based segment update notification"
    @type t :: %__MODULE__{
            change_number: non_neg_integer(),
            previous_change_number: non_neg_integer() | nil,
            definition: String.t() | nil,
            compression: :none | :gzip | :zlib
          }
    defstruct [:change_number, :previous_change_number, :definition, compression: :none]
  end

  defmodule LargeSegmentUpdate do
    @moduledoc "Large segment update notification"
    @type t :: %__MODULE__{
            name: String.t(),
            notification_type: :new_definition | :empty,
            change_number: non_neg_integer(),
            spec_version: String.t() | nil,
            rfd: map() | nil
          }
    @enforce_keys [:name, :notification_type, :change_number]
    defstruct [:name, :notification_type, :change_number, :spec_version, :rfd]
  end

  defmodule Control do
    @moduledoc "Streaming control message"
    @type control_type :: :streaming_enabled | :streaming_paused | :streaming_disabled
    @type t :: %__MODULE__{control_type: control_type()}
    @enforce_keys [:control_type]
    defstruct [:control_type]
  end

  defmodule Occupancy do
    @moduledoc "Channel occupancy notification"
    @type t :: %__MODULE__{
            channel: String.t(),
            publishers: non_neg_integer()
          }
    @enforce_keys [:channel, :publishers]
    defstruct [:channel, :publishers]
  end
end
