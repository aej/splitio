defmodule Splitio.Sync.Backoff do
  @moduledoc """
  Exponential backoff with jitter for retries.
  """

  @type t :: %__MODULE__{
          base_ms: pos_integer(),
          max_ms: pos_integer(),
          max_retries: non_neg_integer(),
          attempt: non_neg_integer()
        }

  defstruct base_ms: 10_000,
            max_ms: 60_000,
            max_retries: 10,
            attempt: 0

  @doc "Create new backoff state"
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      base_ms: Keyword.get(opts, :base_ms, 10_000),
      max_ms: Keyword.get(opts, :max_ms, 60_000),
      max_retries: Keyword.get(opts, :max_retries, 10),
      attempt: 0
    }
  end

  @doc "Get next wait time and increment attempt"
  @spec next(t()) :: {non_neg_integer(), t()}
  def next(%__MODULE__{} = backoff) do
    wait_ms = calculate_wait(backoff)
    {wait_ms, %{backoff | attempt: backoff.attempt + 1}}
  end

  @doc "Reset backoff state"
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = backoff) do
    %{backoff | attempt: 0}
  end

  @doc "Check if max retries exceeded"
  @spec exhausted?(t()) :: boolean()
  def exhausted?(%__MODULE__{attempt: attempt, max_retries: max}) do
    attempt >= max
  end

  defp calculate_wait(%__MODULE__{base_ms: base, max_ms: max, attempt: attempt}) do
    # Exponential backoff: base * 2^attempt
    wait = (base * :math.pow(2, attempt)) |> trunc()

    # Add jitter: ±25%
    jitter = div(wait, 4)
    wait = wait + :rand.uniform(jitter * 2) - jitter

    # Cap at max
    min(wait, max)
  end
end
