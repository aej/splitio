defmodule Splitio.Integration.Helpers do
  @moduledoc """
  Helper functions for integration tests.
  """

  alias Splitio.Integration.AdminApi

  @doc "Generate a unique name for test fixtures"
  def unique_name(prefix) do
    timestamp = System.system_time(:millisecond)
    random = :rand.uniform(10000)
    "#{prefix}_#{timestamp}_#{random}"
  end

  @doc "Wait for a condition to be true, with timeout"
  def wait_until(condition_fn, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout, 30_000)
    interval_ms = Keyword.get(opts, :interval, 500)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_wait_until(condition_fn, interval_ms, deadline)
  end

  defp do_wait_until(condition_fn, interval_ms, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :timeout}
    else
      case condition_fn.() do
        true ->
          :ok

        {:ok, _} = result ->
          result

        _ ->
          Process.sleep(interval_ms)
          do_wait_until(condition_fn, interval_ms, deadline)
      end
    end
  end

  @doc "Start the SDK with given config and wait for ready"
  def start_sdk(opts \\ []) do
    sdk_key = Keyword.get(opts, :sdk_key, System.get_env("SPLIT_SDK_KEY"))
    streaming = Keyword.get(opts, :streaming_enabled, true)
    ready_timeout = Keyword.get(opts, :ready_timeout, 30_000)

    # Configure SDK
    Application.put_env(:splitio, :api_key, sdk_key)
    Application.put_env(:splitio, :streaming_enabled, streaming)

    Application.put_env(
      :splitio,
      :features_refresh_rate,
      Keyword.get(opts, :features_refresh_rate, 5)
    )

    Application.put_env(
      :splitio,
      :segments_refresh_rate,
      Keyword.get(opts, :segments_refresh_rate, 5)
    )

    Application.put_env(
      :splitio,
      :impressions_mode,
      Keyword.get(opts, :impressions_mode, :optimized)
    )

    # Start SDK
    case Splitio.start_link() do
      {:ok, pid} ->
        # Wait for ready
        case Splitio.block_until_ready(ready_timeout) do
          :ok -> {:ok, pid}
          {:error, :timeout} -> {:error, :sdk_not_ready}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Stop the SDK"
  def stop_sdk do
    if Process.whereis(Splitio.Supervisor) do
      Supervisor.stop(Splitio.Supervisor, :normal)
      # Give it time to clean up
      Process.sleep(100)
    end

    :ok
  end

  @doc "Ensure SDK is stopped before test"
  def ensure_sdk_stopped do
    stop_sdk()
    # Clear any lingering config
    Application.delete_env(:splitio, :config)
    :ok
  end

  @doc "Create test fixtures via Admin API"
  def create_fixtures(%AdminApi{} = admin, fixtures) do
    Enum.each(fixtures, fn
      {:flag, name, definition} ->
        :ok = AdminApi.create_flag_with_definition(admin, name, definition)

      {:segment, name, keys} ->
        :ok = AdminApi.create_segment_with_keys(admin, name, keys)
    end)

    # Wait for Split to propagate changes (CDN/SSE)
    Process.sleep(2000)
    :ok
  end

  @doc "Delete test fixtures via Admin API"
  def delete_fixtures(%AdminApi{} = admin, fixtures) do
    Enum.each(fixtures, fn
      {:flag, name, _} ->
        AdminApi.remove_flag_definition(admin, name)
        AdminApi.delete_flag(admin, name)

      {:segment, name, _} ->
        AdminApi.deactivate_segment(admin, name)
        AdminApi.delete_segment(admin, name)
    end)

    :ok
  end

  @doc "Check if integration tests should run"
  def integration_enabled? do
    case System.get_env("SPLIT_SDK_KEY") do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  @doc "Skip test if integration not configured"
  defmacro skip_unless_integration do
    quote do
      unless Splitio.Integration.Helpers.integration_enabled?() do
        @tag :skip
      end
    end
  end
end
