defmodule Splitio do
  @moduledoc """
  Split.io feature flag SDK for Elixir.

  ## Quick Start

      # Start the SDK (usually in application.ex)
      Splitio.start(api_key: "your-api-key")

      # Wait for SDK to be ready
      :ok = Splitio.block_until_ready(10_000)

      # Get treatment
      treatment = Splitio.get_treatment("user123", "my_feature")

      # Get treatment with config
      {treatment, config} = Splitio.get_treatment_with_config("user123", "my_feature")

      # Track events
      Splitio.track("user123", "user", "purchase", 99.99, %{item: "widget"})

  ## Configuration Options

  See `Splitio.Config` for all available options.

  ## Operation Modes

  - `:standalone` - Fetches from Split servers, stores in memory (default)
  - `:localhost` - Reads from local YAML/JSON file (development)

  """

  alias Splitio.{Config, Key, Storage}
  alias Splitio.Engine.Evaluator
  alias Splitio.Models.{EvaluationResult, Impression, Event}
  alias Splitio.Sync.Manager, as: SyncManager
  alias Splitio.Recorder.{Impressions, Events}

  @type key :: String.t() | Key.t()
  @type attributes :: map()
  @type evaluation_options :: keyword()

  # ============================================================================
  # Lifecycle
  # ============================================================================

  @doc """
  Start the Split SDK with configuration.

  This starts the SDK supervisor with sync processes.

  ## Options

  - `:api_key` - Required. Your Split SDK key.
  - `:mode` - Operation mode: `:standalone` (default) or `:localhost`
  - `:streaming_enabled` - Enable SSE streaming (default: true)
  - See `Splitio.Config` for all options.

  ## Example

      Splitio.start(api_key: "sdk-xxx", impressions_mode: :optimized)

  """
  @spec start(keyword()) :: :ok | {:error, term()}
  def start(opts) do
    case Config.new(opts) do
      {:ok, config} ->
        # Store config for later use
        Application.put_env(:splitio, :config, config)

        # Start dynamic processes
        children = build_children(config)

        case Supervisor.start_link(children,
               strategy: :one_for_one,
               name: Splitio.DynamicSupervisor
             ) do
          {:ok, _pid} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Check if the SDK is ready for evaluations.
  """
  @spec ready?() :: boolean()
  def ready? do
    try do
      SyncManager.ready?()
    catch
      :exit, _ -> false
    end
  end

  @doc """
  Block until the SDK is ready or timeout.

  Returns `:ok` when ready, `{:error, :timeout}` if timeout exceeded.
  """
  @spec block_until_ready(non_neg_integer()) :: :ok | {:error, :timeout}
  def block_until_ready(timeout_ms \\ 10_000) do
    SyncManager.block_until_ready(timeout_ms)
  end

  @doc """
  Gracefully shut down the SDK.

  Flushes all pending impressions and events.
  """
  @spec destroy() :: :ok
  def destroy do
    # Flush recorders
    try do
      Impressions.flush()
      Events.flush()
    catch
      :exit, _ -> :ok
    end

    # Stop supervisor
    try do
      Supervisor.stop(Splitio.DynamicSupervisor)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  # ============================================================================
  # Evaluation
  # ============================================================================

  @doc """
  Get treatment for a key and feature flag.

  ## Parameters

  - `key` - User key (string or `%Splitio.Key{}`)
  - `split_name` - Name of the feature flag
  - `attributes` - Optional map of attributes for targeting
  - `opts` - Optional evaluation options (e.g., `:properties`)

  ## Returns

  The treatment string (e.g., "on", "off", "control").

  ## Example

      Splitio.get_treatment("user123", "my_feature")
      #=> "on"

      Splitio.get_treatment("user123", "my_feature", %{plan: "premium"})
      #=> "variant_a"

  """
  @spec get_treatment(key(), String.t(), attributes(), evaluation_options()) :: String.t()
  def get_treatment(key, split_name, attributes \\ %{}, opts \\ []) do
    {treatment, _config} = get_treatment_with_config(key, split_name, attributes, opts)
    treatment
  end

  @doc """
  Get treatment with configuration for a key and feature flag.

  ## Returns

  A tuple `{treatment, config}` where config is the JSON string
  associated with the treatment, or nil if none.

  ## Example

      Splitio.get_treatment_with_config("user123", "my_feature")
      #=> {"on", "{\"color\": \"blue\"}"}

  """
  @spec get_treatment_with_config(key(), String.t(), attributes(), evaluation_options()) ::
          {String.t(), String.t() | nil}
  def get_treatment_with_config(key, split_name, attributes \\ %{}, opts \\ []) do
    key = Key.new(key)
    result = Evaluator.evaluate(key, split_name, attributes)

    # Record impression (only if recorder is running)
    unless result.impressions_disabled do
      try do
        record_impression(key, split_name, result, opts)
      catch
        :exit, _ -> :ok
      end
    end

    {result.treatment, result.config}
  end

  @doc """
  Get treatments for multiple feature flags.

  ## Returns

  A map of split names to treatments.

  ## Example

      Splitio.get_treatments("user123", ["feature_a", "feature_b"])
      #=> %{"feature_a" => "on", "feature_b" => "off"}

  """
  @spec get_treatments(key(), [String.t()], attributes(), evaluation_options()) :: %{
          String.t() => String.t()
        }
  def get_treatments(key, split_names, attributes \\ %{}, opts \\ []) do
    split_names
    |> Enum.map(fn name ->
      {name, get_treatment(key, name, attributes, opts)}
    end)
    |> Map.new()
  end

  @doc """
  Get treatments with configurations for multiple feature flags.

  ## Returns

  A map of split names to `{treatment, config}` tuples.
  """
  @spec get_treatments_with_config(key(), [String.t()], attributes(), evaluation_options()) :: %{
          String.t() => {String.t(), String.t() | nil}
        }
  def get_treatments_with_config(key, split_names, attributes \\ %{}, opts \\ []) do
    split_names
    |> Enum.map(fn name ->
      {name, get_treatment_with_config(key, name, attributes, opts)}
    end)
    |> Map.new()
  end

  @doc """
  Get treatments for all flags in a flag set.
  """
  @spec get_treatments_by_flag_set(key(), String.t(), attributes(), evaluation_options()) :: %{
          String.t() => String.t()
        }
  def get_treatments_by_flag_set(key, flag_set, attributes \\ %{}, opts \\ []) do
    splits = Storage.get_splits_by_flag_set(flag_set)
    split_names = Enum.map(splits, & &1.name)
    get_treatments(key, split_names, attributes, opts)
  end

  @doc """
  Get treatments for all flags in multiple flag sets.
  """
  @spec get_treatments_by_flag_sets(key(), [String.t()], attributes(), evaluation_options()) :: %{
          String.t() => String.t()
        }
  def get_treatments_by_flag_sets(key, flag_sets, attributes \\ %{}, opts \\ []) do
    splits = Storage.get_splits_by_flag_sets(flag_sets)
    split_names = Enum.map(splits, & &1.name)
    get_treatments(key, split_names, attributes, opts)
  end

  @doc """
  Get treatments with config for all flags in a flag set.
  """
  @spec get_treatments_with_config_by_flag_set(
          key(),
          String.t(),
          attributes(),
          evaluation_options()
        ) ::
          %{String.t() => {String.t(), String.t() | nil}}
  def get_treatments_with_config_by_flag_set(key, flag_set, attributes \\ %{}, opts \\ []) do
    splits = Storage.get_splits_by_flag_set(flag_set)
    split_names = Enum.map(splits, & &1.name)
    get_treatments_with_config(key, split_names, attributes, opts)
  end

  @doc """
  Get treatments with config for all flags in multiple flag sets.
  """
  @spec get_treatments_with_config_by_flag_sets(
          key(),
          [String.t()],
          attributes(),
          evaluation_options()
        ) ::
          %{String.t() => {String.t(), String.t() | nil}}
  def get_treatments_with_config_by_flag_sets(key, flag_sets, attributes \\ %{}, opts \\ []) do
    splits = Storage.get_splits_by_flag_sets(flag_sets)
    split_names = Enum.map(splits, & &1.name)
    get_treatments_with_config(key, split_names, attributes, opts)
  end

  # ============================================================================
  # Tracking
  # ============================================================================

  @doc """
  Track a custom event.

  ## Parameters

  - `key` - User key
  - `traffic_type` - Traffic type (e.g., "user")
  - `event_type` - Event type (e.g., "purchase")
  - `value` - Optional numeric value
  - `properties` - Optional map of properties

  ## Returns

  `true` if event was queued, `false` if rejected.

  ## Example

      Splitio.track("user123", "user", "purchase", 99.99, %{item: "widget"})
      #=> true

  """
  @spec track(String.t(), String.t(), String.t(), number() | nil, map() | nil) :: boolean()
  def track(key, traffic_type, event_type, value \\ nil, properties \\ nil) do
    case Event.new(key, traffic_type, event_type, value, properties) do
      {:ok, event} ->
        case Events.record(event) do
          :ok -> true
          {:error, _} -> false
        end

      {:error, _} ->
        false
    end
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp build_children(config) do
    base = [
      {Splitio.Impressions.Counter, []},
      {Splitio.Recorder.Impressions, config},
      {Splitio.Recorder.Events, config},
      {Splitio.Recorder.ImpressionCounts, config},
      {Splitio.Sync.Manager, config}
    ]

    # TODO: Add streaming processes when implemented
    base
  end

  defp record_impression(key, split_name, %EvaluationResult{} = result, opts) do
    properties = Keyword.get(opts, :properties)

    impression = %Impression{
      key: Key.matching_key(key),
      bucketing_key: key.bucketing_key,
      feature: split_name,
      treatment: result.treatment,
      label: get_label(result),
      change_number: result.change_number,
      time: System.system_time(:millisecond),
      properties: properties
    }

    Impressions.record(impression)
  end

  defp get_label(%EvaluationResult{label: label}) do
    config = Application.get_env(:splitio, :config)

    if config && config.labels_enabled do
      label
    else
      nil
    end
  end
end
