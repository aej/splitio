defmodule Splitio.Integration.AdminApi do
  @moduledoc """
  Split Admin API client for managing test fixtures.

  Used to create, modify, and delete feature flags and segments
  during integration tests.
  """

  @base_url "https://api.split.io/internal/api/v2"

  defstruct [:admin_key, :workspace_id, :environment_id, :environment_name, :traffic_type]

  @type t :: %__MODULE__{
          admin_key: String.t(),
          workspace_id: String.t(),
          environment_id: String.t(),
          environment_name: String.t(),
          traffic_type: String.t()
        }

  @doc "Create client from environment variables"
  @spec from_env() :: {:ok, t()} | {:error, :missing_env}
  def from_env do
    with {:ok, admin_key} <- fetch_env("SPLIT_ADMIN_KEY"),
         {:ok, workspace_id} <- fetch_env("SPLIT_WORKSPACE_ID"),
         {:ok, environment_id} <- fetch_env("SPLIT_ENVIRONMENT_ID"),
         {:ok, environment_name} <- fetch_env("SPLIT_ENVIRONMENT_NAME") do
      {:ok,
       %__MODULE__{
         admin_key: admin_key,
         workspace_id: workspace_id,
         environment_id: environment_id,
         environment_name: environment_name,
         traffic_type: System.get_env("SPLIT_TRAFFIC_TYPE", "user")
       }}
    end
  end

  defp fetch_env(name) do
    case System.get_env(name) do
      nil -> {:error, :missing_env}
      "" -> {:error, :missing_env}
      value -> {:ok, value}
    end
  end

  # ============================================================================
  # Feature Flags
  # ============================================================================

  @doc "Create a feature flag (without definition)"
  @spec create_flag(t(), String.t(), keyword()) :: :ok | {:error, term()}
  def create_flag(%__MODULE__{} = client, name, opts \\ []) do
    description = Keyword.get(opts, :description, "Integration test flag")

    url = "#{@base_url}/splits/ws/#{client.workspace_id}/trafficTypes/#{client.traffic_type}"

    body = %{
      "name" => name,
      "description" => description
    }

    case post(client, url, body) do
      {:ok, _} -> :ok
      # Already exists
      {:error, %{status: 409}} -> :ok
      error -> error
    end
  end

  @doc "Create flag definition in environment (enables the flag)"
  @spec create_flag_definition(t(), String.t(), map()) :: :ok | {:error, term()}
  def create_flag_definition(%__MODULE__{} = client, name, definition) do
    url =
      "#{@base_url}/splits/ws/#{client.workspace_id}/#{name}/environments/#{client.environment_name}"

    case post(client, url, definition) do
      {:ok, _} -> :ok
      # Already exists
      {:error, %{status: 409}} -> :ok
      error -> error
    end
  end

  @doc "Update flag definition in environment"
  @spec update_flag_definition(t(), String.t(), map()) :: :ok | {:error, term()}
  def update_flag_definition(%__MODULE__{} = client, name, definition) do
    url =
      "#{@base_url}/splits/ws/#{client.workspace_id}/#{name}/environments/#{client.environment_name}"

    case put(client, url, definition) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc "Kill a feature flag"
  @spec kill_flag(t(), String.t()) :: :ok | {:error, term()}
  def kill_flag(%__MODULE__{} = client, name) do
    url =
      "#{@base_url}/splits/ws/#{client.workspace_id}/#{name}/environments/#{client.environment_name}/kill"

    case put(client, url, %{}) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc "Restore a killed feature flag"
  @spec restore_flag(t(), String.t()) :: :ok | {:error, term()}
  def restore_flag(%__MODULE__{} = client, name) do
    url =
      "#{@base_url}/splits/ws/#{client.workspace_id}/#{name}/environments/#{client.environment_name}/restore"

    case put(client, url, %{}) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc "Remove flag definition from environment"
  @spec remove_flag_definition(t(), String.t()) :: :ok | {:error, term()}
  def remove_flag_definition(%__MODULE__{} = client, name) do
    url =
      "#{@base_url}/splits/ws/#{client.workspace_id}/#{name}/environments/#{client.environment_name}"

    case delete(client, url) do
      {:ok, _} -> :ok
      # Already gone
      {:error, %{status: 404}} -> :ok
      error -> error
    end
  end

  @doc "Delete a feature flag entirely"
  @spec delete_flag(t(), String.t()) :: :ok | {:error, term()}
  def delete_flag(%__MODULE__{} = client, name) do
    url = "#{@base_url}/splits/ws/#{client.workspace_id}/#{name}"

    case delete(client, url) do
      {:ok, _} -> :ok
      # Already gone
      {:error, %{status: 404}} -> :ok
      error -> error
    end
  end

  @doc "Create a flag with full definition in one call"
  @spec create_flag_with_definition(t(), String.t(), map()) :: :ok | {:error, term()}
  def create_flag_with_definition(%__MODULE__{} = client, name, definition) do
    with :ok <- create_flag(client, name),
         :ok <- create_flag_definition(client, name, definition) do
      :ok
    end
  end

  # ============================================================================
  # Segments
  # ============================================================================

  @doc "Create a segment"
  @spec create_segment(t(), String.t(), keyword()) :: :ok | {:error, term()}
  def create_segment(%__MODULE__{} = client, name, opts \\ []) do
    description = Keyword.get(opts, :description, "Integration test segment")

    url = "#{@base_url}/segments/#{client.workspace_id}/trafficTypes/#{client.traffic_type}"

    body = %{
      "name" => name,
      "description" => description
    }

    case post(client, url, body) do
      {:ok, _} -> :ok
      # Already exists
      {:error, %{status: 409}} -> :ok
      error -> error
    end
  end

  @doc "Enable segment in environment"
  @spec enable_segment(t(), String.t()) :: :ok | {:error, term()}
  def enable_segment(%__MODULE__{} = client, name) do
    url =
      "#{@base_url}/segments/#{client.workspace_id}/#{name}/environments/#{client.environment_name}"

    case post(client, url, %{}) do
      {:ok, _} -> :ok
      # Already enabled
      {:error, %{status: 409}} -> :ok
      error -> error
    end
  end

  @doc "Update segment keys (add members)"
  @spec update_segment_keys(t(), String.t(), [String.t()], keyword()) :: :ok | {:error, term()}
  def update_segment_keys(%__MODULE__{} = client, name, keys, opts \\ []) do
    replace = Keyword.get(opts, :replace, false)

    url =
      "#{@base_url}/segments/#{client.environment_id}/#{name}/uploadKeys?replace=#{replace}"

    body = %{
      "keys" => keys,
      "comment" => "Integration test update"
    }

    case put(client, url, body) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc "Remove keys from segment"
  @spec remove_segment_keys(t(), String.t(), [String.t()]) :: :ok | {:error, term()}
  def remove_segment_keys(%__MODULE__{} = client, name, keys) do
    url = "#{@base_url}/segments/#{client.environment_id}/#{name}/removeKeys"

    body = %{
      "keys" => keys,
      "comment" => "Integration test removal"
    }

    case put(client, url, body) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc "Deactivate segment in environment"
  @spec deactivate_segment(t(), String.t()) :: :ok | {:error, term()}
  def deactivate_segment(%__MODULE__{} = client, name) do
    url =
      "#{@base_url}/segments/#{client.workspace_id}/#{name}/environments/#{client.environment_name}"

    case delete(client, url) do
      {:ok, _} -> :ok
      {:error, %{status: 404}} -> :ok
      error -> error
    end
  end

  @doc "Delete a segment entirely"
  @spec delete_segment(t(), String.t()) :: :ok | {:error, term()}
  def delete_segment(%__MODULE__{} = client, name) do
    url = "#{@base_url}/segments/#{client.workspace_id}/#{name}"

    case delete(client, url) do
      {:ok, _} -> :ok
      {:error, %{status: 404}} -> :ok
      error -> error
    end
  end

  @doc "Create segment with keys in one call"
  @spec create_segment_with_keys(t(), String.t(), [String.t()]) :: :ok | {:error, term()}
  def create_segment_with_keys(%__MODULE__{} = client, name, keys) do
    with :ok <- create_segment(client, name),
         :ok <- enable_segment(client, name),
         :ok <- update_segment_keys(client, name, keys) do
      :ok
    end
  end

  # ============================================================================
  # Flag Definition Helpers
  # ============================================================================

  @doc "Build a simple 100% rollout definition"
  def simple_rollout(treatment, opts \\ []) do
    default_treatment = Keyword.get(opts, :default_treatment, "off")
    config = Keyword.get(opts, :config)

    treatments =
      [
        %{"name" => treatment, "configurations" => config},
        %{"name" => default_treatment}
      ]
      |> Enum.reject(fn t -> t["name"] == treatment and is_nil(config) end)
      |> Enum.uniq_by(& &1["name"])

    %{
      "treatments" => treatments,
      "defaultTreatment" => default_treatment,
      "rules" => [],
      "defaultRule" => [%{"treatment" => treatment, "size" => 100}]
    }
  end

  @doc "Build a percentage rollout definition"
  def percentage_rollout(on_pct, opts \\ []) do
    on_treatment = Keyword.get(opts, :on_treatment, "on")
    off_treatment = Keyword.get(opts, :off_treatment, "off")

    %{
      "treatments" => [
        %{"name" => on_treatment},
        %{"name" => off_treatment}
      ],
      "defaultTreatment" => off_treatment,
      "rules" => [],
      "defaultRule" => [
        %{"treatment" => on_treatment, "size" => on_pct},
        %{"treatment" => off_treatment, "size" => 100 - on_pct}
      ]
    }
  end

  @doc "Build a whitelist rule definition"
  def whitelist_rule(keys, treatment, opts \\ []) do
    default_treatment = Keyword.get(opts, :default_treatment, "off")

    %{
      "treatments" => [
        %{"name" => treatment},
        %{"name" => default_treatment}
      ],
      "defaultTreatment" => default_treatment,
      "rules" => [
        %{
          "buckets" => [%{"treatment" => treatment, "size" => 100}],
          "condition" => %{
            "combiner" => "AND",
            "matchers" => [
              %{
                "type" => "WHITELIST",
                "strings" => keys
              }
            ]
          }
        }
      ],
      "defaultRule" => [%{"treatment" => default_treatment, "size" => 100}]
    }
  end

  @doc "Build an in-segment rule definition"
  def segment_rule(segment_name, treatment, opts \\ []) do
    default_treatment = Keyword.get(opts, :default_treatment, "off")

    %{
      "treatments" => [
        %{"name" => treatment},
        %{"name" => default_treatment}
      ],
      "defaultTreatment" => default_treatment,
      "rules" => [
        %{
          "buckets" => [%{"treatment" => treatment, "size" => 100}],
          "condition" => %{
            "combiner" => "AND",
            "matchers" => [
              %{
                "type" => "IN_SEGMENT",
                "userDefinedSegment" => segment_name
              }
            ]
          }
        }
      ],
      "defaultRule" => [%{"treatment" => default_treatment, "size" => 100}]
    }
  end

  @doc "Build an attribute matcher rule"
  def attribute_rule(attribute, matcher_type, value, treatment, opts \\ []) do
    default_treatment = Keyword.get(opts, :default_treatment, "off")

    matcher =
      case matcher_type do
        :starts_with ->
          %{"type" => "STARTS_WITH", "attribute" => attribute, "strings" => List.wrap(value)}

        :gte ->
          %{"type" => "GREATER_THAN_OR_EQUAL_TO", "attribute" => attribute, "number" => value}

        :lte ->
          %{"type" => "LESS_THAN_OR_EQUAL_TO", "attribute" => attribute, "number" => value}

        :eq ->
          %{"type" => "EQUAL_TO", "attribute" => attribute, "number" => value}

        :between ->
          {min, max} = value

          %{
            "type" => "BETWEEN",
            "attribute" => attribute,
            "between" => %{"from" => min, "to" => max}
          }
      end

    %{
      "treatments" => [
        %{"name" => treatment},
        %{"name" => default_treatment}
      ],
      "defaultTreatment" => default_treatment,
      "rules" => [
        %{
          "buckets" => [%{"treatment" => treatment, "size" => 100}],
          "condition" => %{
            "combiner" => "AND",
            "matchers" => [matcher]
          }
        }
      ],
      "defaultRule" => [%{"treatment" => default_treatment, "size" => 100}]
    }
  end

  # ============================================================================
  # HTTP Helpers
  # ============================================================================

  defp post(client, url, body) do
    request(:post, client, url, body)
  end

  defp put(client, url, body) do
    request(:put, client, url, body)
  end

  defp delete(client, url) do
    request(:delete, client, url, nil)
  end

  defp request(method, client, url, body) do
    headers = [
      {"Authorization", "Bearer #{client.admin_key}"},
      {"Content-Type", "application/json"}
    ]

    opts = [headers: headers]

    result =
      case method do
        :get -> Req.get(url, opts)
        :post -> Req.post(url, Keyword.put(opts, :json, body))
        :put -> Req.put(url, Keyword.put(opts, :json, body))
        :delete -> Req.delete(url, opts)
      end

    case result do
      {:ok, %{status: status} = resp} when status in 200..299 ->
        {:ok, resp.body}

      {:ok, %{status: status} = resp} ->
        {:error, %{status: status, body: resp.body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
