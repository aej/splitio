defmodule Mix.Tasks.Loadtest do
  @moduledoc """
  Run load tests for the Splitio SDK.

  ## Usage

      mix loadtest [options]

  ## Options

      --quick         Run quick benchmark (shorter warmup/time)
      --sustained     Run only the sustained load test
      --processes N   Number of processes for sustained test (default: 100)
      --duration N    Duration in seconds for sustained test (default: 10)
      --impressions M Impressions mode: none, optimized (default), debug
      --ci            CI mode: check thresholds and exit non-zero on failure

  """

  use Mix.Task

  require Logger

  @shortdoc "Run Splitio SDK load tests"

  @impl Mix.Task
  def run(args) do
    # Parse arguments
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          quick: :boolean,
          sustained: :boolean,
          processes: :integer,
          duration: :integer,
          impressions: :string,
          ci: :boolean
        ]
      )

    # Ensure dependencies are compiled
    Mix.Task.run("compile")

    # Start required applications
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:logger)

    # Suppress noisy logs during benchmarks
    Logger.configure(level: :error)

    # Compile bench support files
    Code.compile_file("bench/support/mock_http.ex")
    Code.compile_file("bench/support/fixtures.ex")

    # Setup
    setup_environment(opts)

    # Run appropriate benchmarks and collect results
    result =
      cond do
        opts[:sustained] ->
          run_sustained_only(opts)

        opts[:quick] ->
          run_quick_benchmarks(opts)

        true ->
          run_full_benchmarks(opts)
      end

    # In CI mode, check thresholds
    if opts[:ci] do
      check_thresholds(result, opts)
    end
  end

  defp setup_environment(opts) do
    IO.puts("Setting up load test environment...")

    impressions_mode =
      case opts[:impressions] do
        "none" -> :none
        "debug" -> :debug
        _ -> :optimized
      end

    IO.puts("  Impressions mode: #{impressions_mode}")

    # Configure mock HTTP client
    Application.put_env(:splitio, :http_client, Splitio.Bench.MockHTTP)
    Application.put_env(:splitio, :api_key, "bench-api-key")
    Application.put_env(:splitio, :streaming_enabled, false)
    Application.put_env(:splitio, :impressions_mode, impressions_mode)

    # Start the SDK
    {:ok, _pid} = Splitio.start_link()
    Process.sleep(100)

    # Populate test data
    IO.puts("Populating test data: 100 splits, 10 segments x 1000 keys...")

    Splitio.Bench.Fixtures.populate(
      num_splits: 100,
      num_segments: 10,
      segment_size: 1000
    )

    IO.puts("Data populated.\n")
  end

  defp run_quick_benchmarks(opts) do
    IO.puts("Running quick benchmarks...\n")

    user_keys = Splitio.Bench.Fixtures.user_keys(1000)
    split_names = for i <- 1..100, do: "feature_#{i}"

    Benchee.run(
      %{
        "get_treatment" => fn ->
          Splitio.get_treatment(Enum.random(user_keys), Enum.random(split_names))
        end,
        "track" => fn ->
          Splitio.track(Enum.random(user_keys), "user", "click")
        end
      },
      warmup: 1,
      time: 2,
      print: [configuration: false]
    )

    # Return results for threshold checking
    %{type: :quick, impressions_mode: opts[:impressions] || "optimized"}
  end

  defp run_full_benchmarks(opts) do
    IO.puts("Running full benchmarks...\n")

    user_keys = Splitio.Bench.Fixtures.user_keys(10_000)
    split_names = for i <- 1..100, do: "feature_#{i}"
    batch_splits = Enum.take(split_names, 10)
    attrs_with_age = %{"age" => 25}

    # Single-process benchmarks
    IO.puts("=" |> String.duplicate(70))
    IO.puts("SINGLE-PROCESS BENCHMARKS")
    IO.puts("=" |> String.duplicate(70))

    Benchee.run(
      %{
        "get_treatment (simple)" => fn ->
          Splitio.get_treatment(Enum.random(user_keys), "feature_1")
        end,
        "get_treatment (segment)" => fn ->
          Splitio.get_treatment(Enum.random(user_keys), "feature_4")
        end,
        "get_treatment (with attrs)" => fn ->
          Splitio.get_treatment(Enum.random(user_keys), "feature_6", attrs_with_age)
        end,
        "get_treatment (random)" => fn ->
          Splitio.get_treatment(Enum.random(user_keys), Enum.random(split_names))
        end,
        "get_treatments (10 splits)" => fn ->
          Splitio.get_treatments(Enum.random(user_keys), batch_splits)
        end,
        "track" => fn ->
          Splitio.track(Enum.random(user_keys), "user", "click")
        end
      },
      warmup: 2,
      time: 5,
      print: [configuration: false]
    )

    # Multi-process benchmarks
    IO.puts("\n")
    IO.puts("=" |> String.duplicate(70))
    IO.puts("MULTI-PROCESS BENCHMARKS (100 concurrent processes)")
    IO.puts("=" |> String.duplicate(70))

    Benchee.run(
      %{
        "get_treatment (100p)" => fn ->
          tasks =
            for _ <- 1..100 do
              Task.async(fn ->
                Splitio.get_treatment(Enum.random(user_keys), Enum.random(split_names))
              end)
            end

          Task.await_many(tasks, 5000)
        end,
        "get_treatments x10 (100p)" => fn ->
          tasks =
            for _ <- 1..100 do
              Task.async(fn ->
                Splitio.get_treatments(Enum.random(user_keys), batch_splits)
              end)
            end

          Task.await_many(tasks, 5000)
        end
      },
      warmup: 1,
      time: 3,
      print: [configuration: false]
    )

    # Sustained load
    IO.puts("\n")
    sustained_result = run_sustained_only(Keyword.merge([duration: 10, processes: 100], opts))

    %{
      type: :full,
      sustained: sustained_result,
      impressions_mode: opts[:impressions] || "optimized"
    }
  end

  defp run_sustained_only(opts) do
    duration_s = opts[:duration] || 10
    num_processes = opts[:processes] || 100

    IO.puts("Running sustained load test...")
    IO.puts("  Processes: #{num_processes}")
    IO.puts("  Duration: #{duration_s}s\n")

    user_keys = Splitio.Bench.Fixtures.user_keys(10_000)
    split_names = for i <- 1..100, do: "feature_#{i}"

    {time_us, {total_ops, errors}} =
      :timer.tc(fn ->
        run_sustained_test(user_keys, split_names, num_processes, duration_s * 1000)
      end)

    time_s = time_us / 1_000_000
    ops_per_second = total_ops / time_s

    IO.puts("\nResults:")
    IO.puts("  Duration: #{Float.round(time_s, 2)}s")
    IO.puts("  Total operations: #{total_ops}")
    IO.puts("  Errors: #{errors}")
    IO.puts("  Throughput: #{Float.round(ops_per_second, 0)} ops/sec")
    IO.puts("  Per process: #{Float.round(ops_per_second / num_processes, 0)} ops/sec")

    %{
      ops_per_second: ops_per_second,
      total_ops: total_ops,
      errors: errors,
      duration_s: time_s,
      impressions_mode: Application.get_env(:splitio, :impressions_mode, :optimized)
    }
  end

  defp run_sustained_test(user_keys, split_names, num_processes, duration_ms) do
    ops_counter = :atomics.new(1, signed: false)
    error_counter = :atomics.new(1, signed: false)
    stop_flag = :atomics.new(1, signed: false)

    workers =
      for _ <- 1..num_processes do
        spawn_link(fn ->
          worker_loop(user_keys, split_names, ops_counter, error_counter, stop_flag)
        end)
      end

    Process.sleep(duration_ms)
    :atomics.put(stop_flag, 1, 1)
    Process.sleep(100)

    Enum.each(workers, fn pid ->
      Process.exit(pid, :shutdown)
    end)

    {:atomics.get(ops_counter, 1), :atomics.get(error_counter, 1)}
  end

  defp worker_loop(user_keys, split_names, ops_counter, error_counter, stop_flag) do
    if :atomics.get(stop_flag, 1) == 0 do
      key = Enum.random(user_keys)
      split = Enum.random(split_names)

      try do
        Splitio.get_treatment(key, split)
        :atomics.add(ops_counter, 1, 1)
      rescue
        _ -> :atomics.add(error_counter, 1, 1)
      end

      worker_loop(user_keys, split_names, ops_counter, error_counter, stop_flag)
    end
  end

  defp check_thresholds(result, opts) do
    thresholds_file = "bench/thresholds.json"

    unless File.exists?(thresholds_file) do
      IO.puts("\nWarning: #{thresholds_file} not found, skipping threshold check")
      System.halt(0)
    end

    thresholds = thresholds_file |> File.read!() |> Jason.decode!()

    IO.puts("\n")
    IO.puts("=" |> String.duplicate(70))
    IO.puts("THRESHOLD CHECK")
    IO.puts("=" |> String.duplicate(70))

    failures = check_sustained_threshold(result, thresholds, opts)

    if failures == [] do
      IO.puts("\nAll thresholds PASSED")
      System.halt(0)
    else
      IO.puts("\nThreshold FAILURES:")
      Enum.each(failures, fn f -> IO.puts("  - #{f}") end)
      System.halt(1)
    end
  end

  defp check_sustained_threshold(result, thresholds, opts) do
    case result do
      %{sustained: sustained} when is_map(sustained) ->
        check_sustained_result(sustained, thresholds)

      %{type: :sustained, ops_per_second: ops} ->
        impressions_mode = opts[:impressions] || "optimized"
        check_sustained_ops(ops, impressions_mode, thresholds)

      _ ->
        []
    end
  end

  defp check_sustained_result(%{ops_per_second: ops, impressions_mode: mode}, thresholds) do
    mode_str = to_string(mode)
    check_sustained_ops(ops, mode_str, thresholds)
  end

  defp check_sustained_ops(ops, mode_str, thresholds) do
    threshold_key =
      case mode_str do
        "none" -> "impressions_none"
        _ -> "impressions_optimized"
      end

    case get_in(thresholds, ["sustained_100p", threshold_key, "min_total_ops_sec"]) do
      nil ->
        IO.puts("  No threshold defined for sustained_100p.#{threshold_key}")
        []

      min_ops ->
        if ops >= min_ops do
          IO.puts(
            "  sustained (#{threshold_key}): #{Float.round(ops, 0)} ops/sec >= #{min_ops} PASS"
          )

          []
        else
          IO.puts(
            "  sustained (#{threshold_key}): #{Float.round(ops, 0)} ops/sec < #{min_ops} FAIL"
          )

          ["sustained #{threshold_key}: #{Float.round(ops, 0)} < #{min_ops}"]
        end
    end
  end
end
