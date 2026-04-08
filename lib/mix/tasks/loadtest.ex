defmodule Mix.Tasks.Loadtest do
  @moduledoc """
  Run end-to-end SDK load tests against a mocked Split/Harness boundary.

  The SDK is started as it would be inside a real Elixir application:
  as a child in a supervision tree. Network traffic is mocked at the HTTP
  boundary so sync, evaluation, impressions, and event flushing still cross
  the same public runtime edges used in production.

  ## Usage

      mix loadtest [options]

  ## Options

      --quick                  Run a shorter, lighter profile
      --sustained              Accepted for compatibility; sustained is the default mode
      --processes N            Number of worker processes (default: 100)
      --duration N             Duration in seconds (default: 10)
      --impressions MODE       Impressions mode: none, optimized (default), debug
      --ci                     Check thresholds and exit non-zero on failure
      --json-output PATH       Write structured JSON results
      --markdown-output PATH   Write markdown summary for CI comments
  """

  use Mix.Task

  require Logger

  @shortdoc "Run Splitio end-to-end load tests"
  @thresholds_file "bench/thresholds.json"
  @default_processes 100
  @default_duration_s 10
  @default_user_count 20_000

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          quick: :boolean,
          sustained: :boolean,
          processes: :integer,
          duration: :integer,
          impressions: :string,
          ci: :boolean,
          json_output: :string,
          markdown_output: :string
        ]
      )

    Mix.Task.run("compile")
    Application.ensure_all_started(:logger)
    Application.ensure_all_started(:telemetry)
    Logger.configure(level: :error)

    profile = build_profile(opts)
    result = run_profile(profile)

    write_outputs(result, opts)

    if opts[:ci] do
      check_thresholds!(result)
    end
  end

  defp build_profile(opts) do
    quick? = opts[:quick] || false

    %{
      processes: opts[:processes] || if(quick?, do: 25, else: @default_processes),
      duration_s: opts[:duration] || if(quick?, do: 5, else: @default_duration_s),
      impressions_mode: parse_impressions_mode(opts[:impressions]),
      user_count: if(quick?, do: 5_000, else: @default_user_count),
      num_splits: if(quick?, do: 60, else: 120),
      num_segments: if(quick?, do: 8, else: 12),
      segment_size: if(quick?, do: 750, else: 1_500)
    }
  end

  defp run_profile(profile) do
    dataset =
      Splitio.Bench.Fixtures.dataset(
        num_splits: profile.num_splits,
        num_segments: profile.num_segments,
        segment_size: profile.segment_size
      )

    users = Splitio.Bench.Fixtures.workload_users(profile.user_count)

    {:ok, _mock_server} = Splitio.Bench.MockServer.start_link(dataset: dataset)

    configure_runtime(profile)

    {bootstrap_us, harness_sup} =
      :timer.tc(fn ->
        {:ok, harness_sup} = start_harness_supervisor()
        :ok = Splitio.block_until_ready(15_000)
        harness_sup
      end)

    sustained =
      run_sustained_load(
        users,
        dataset.split_names,
        profile.processes,
        profile.duration_s
      )

    flush_recorders()
    mock_stats = Splitio.Bench.MockServer.stats()

    stop_harness_supervisor(harness_sup)
    stop_mock_server()

    %{
      schema_version: 1,
      suite: "splitio_loadtest",
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      mode: Atom.to_string(profile.impressions_mode),
      bootstrap: %{
        ready_ms: round(bootstrap_us / 1_000),
        split_fetches: mock_stats.split_fetches,
        segment_fetches: mock_stats.segment_fetches
      },
      sustained: sustained,
      mock: mock_stats
    }
  end

  defp configure_runtime(profile) do
    Application.put_env(:splitio, :http_client, Splitio.Bench.MockHTTP)
    Application.put_env(:splitio, :api_key, "bench-api-key")
    Application.put_env(:splitio, :streaming_enabled, false)
    Application.put_env(:splitio, :impressions_mode, profile.impressions_mode)
    Application.put_env(:splitio, :features_refresh_rate, 60)
    Application.put_env(:splitio, :segments_refresh_rate, 60)
    Application.put_env(:splitio, :impressions_refresh_rate, 1)
    Application.put_env(:splitio, :impressions_bulk_size, 250)
    Application.put_env(:splitio, :impressions_queue_size, 100_000)
    Application.put_env(:splitio, :events_refresh_rate, 1)
    Application.put_env(:splitio, :events_bulk_size, 250)
    Application.put_env(:splitio, :events_queue_size, 100_000)
    Application.delete_env(:splitio, :config)
  end

  defp start_harness_supervisor do
    children = [
      Splitio,
      {Task.Supervisor, name: Splitio.Bench.TaskSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  defp stop_harness_supervisor(harness_sup) do
    Supervisor.stop(harness_sup, :normal, 30_000)
    Application.delete_env(:splitio, :config)
  end

  defp stop_mock_server do
    if pid = Process.whereis(Splitio.Bench.MockServer) do
      GenServer.stop(pid, :normal, 30_000)
    end
  end

  defp run_sustained_load(users, split_names, worker_count, duration_s) do
    users_tuple = List.to_tuple(users)
    split_names_tuple = List.to_tuple(split_names)
    batch_groups_tuple = split_names |> Enum.chunk_every(5, 5, :discard) |> List.to_tuple()

    counters = %{
      total_ops: :atomics.new(1, signed: false),
      errors: :atomics.new(1, signed: false),
      get_treatment_ops: :atomics.new(1, signed: false),
      get_treatments_ops: :atomics.new(1, signed: false),
      track_ops: :atomics.new(1, signed: false)
    }

    stop_ref = make_ref()
    parent = self()

    workers =
      for worker_id <- 0..(worker_count - 1) do
        Task.Supervisor.start_child(Splitio.Bench.TaskSupervisor, fn ->
          worker_loop(
            parent,
            stop_ref,
            worker_id,
            users_tuple,
            split_names_tuple,
            batch_groups_tuple,
            counters
          )
        end)
      end

    worker_pids = Enum.map(workers, fn {:ok, pid} -> pid end)

    started_at = System.monotonic_time(:microsecond)
    Process.sleep(duration_s * 1_000)
    Enum.each(worker_pids, &send(&1, stop_ref))
    await_workers(worker_pids)
    ended_at = System.monotonic_time(:microsecond)

    elapsed_s = (ended_at - started_at) / 1_000_000
    total_ops = :atomics.get(counters.total_ops, 1)
    errors = :atomics.get(counters.errors, 1)

    %{
      duration_s: Float.round(elapsed_s, 2),
      workers: worker_count,
      total_ops: total_ops,
      ops_per_second: total_ops / elapsed_s,
      errors: errors,
      operation_mix: %{
        get_treatment: :atomics.get(counters.get_treatment_ops, 1),
        get_treatments: :atomics.get(counters.get_treatments_ops, 1),
        track: :atomics.get(counters.track_ops, 1)
      }
    }
  end

  defp worker_loop(parent, stop_ref, worker_id, users, split_names, batch_groups, counters) do
    Process.flag(:trap_exit, true)
    do_worker_loop(parent, stop_ref, worker_id, users, split_names, batch_groups, counters, worker_id)
  end

  defp do_worker_loop(parent, stop_ref, worker_id, users, split_names, batch_groups, counters, iteration) do
    receive do
      ^stop_ref ->
        send(parent, {:worker_done, self()})

      {:EXIT, _pid, _reason} ->
        send(parent, {:worker_done, self()})
    after
      0 ->
        user = elem(users, rem(iteration, tuple_size(users)))
        split_name = elem(split_names, rem(iteration + worker_id, tuple_size(split_names)))
        attrs = if(rem(iteration, 3) == 0, do: user.attrs, else: %{})

        try do
          case rem(iteration, 10) do
            selector when selector in [0, 1] ->
              batch = elem(batch_groups, rem(iteration, tuple_size(batch_groups)))
              _ = Splitio.get_treatments(user.key, batch, attrs)
              incr(counters.get_treatments_ops)

            2 ->
              tracked? =
                Splitio.track(
                  user.key,
                  "user",
                  "load_test_event",
                  rem(iteration, 100),
                  %{"worker" => worker_id}
                )

              if tracked? do
                incr(counters.track_ops)
              else
                incr(counters.errors)
              end

            _ ->
              _ = Splitio.get_treatment(user.key, split_name, attrs)
              incr(counters.get_treatment_ops)
          end

          incr(counters.total_ops)
        rescue
          _ ->
            incr(counters.errors)
        end

        do_worker_loop(parent, stop_ref, worker_id, users, split_names, batch_groups, counters, iteration + 1)
    end
  end

  defp await_workers([]), do: :ok

  defp await_workers(worker_pids) do
    receive do
      {:worker_done, pid} ->
        await_workers(List.delete(worker_pids, pid))
    after
      5_000 ->
        Enum.each(worker_pids, &Process.exit(&1, :kill))
        :ok
    end
  end

  defp flush_recorders do
    safe_flush(Splitio.Recorder.Impressions)
    safe_flush(Splitio.Recorder.Events)
    safe_flush(Splitio.Recorder.ImpressionCounts)
  end

  defp safe_flush(module) do
    if Process.whereis(module) do
      apply(module, :flush, [])
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp write_outputs(result, opts) do
    if path = opts[:json_output] do
      write_file(path, Jason.encode_to_iodata!(result, pretty: true))
    end

    if path = opts[:markdown_output] do
      write_file(path, markdown_summary(result))
    end

    if opts[:json_output] || opts[:markdown_output] do
      :ok
    else
      IO.puts(markdown_summary(result))
    end
  end

  defp write_file(path, contents) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, contents)
  end

  defp markdown_summary(result) do
    """
    ## #{String.upcase(result.mode)} Load Test

    | Metric | Value |
    | --- | ---: |
    | Bootstrap to ready | #{result.bootstrap.ready_ms} ms |
    | Split fetches | #{result.bootstrap.split_fetches} |
    | Segment fetches | #{result.bootstrap.segment_fetches} |
    | Duration | #{result.sustained.duration_s} s |
    | Workers | #{result.sustained.workers} |
    | Total operations | #{result.sustained.total_ops} |
    | Throughput | #{Float.round(result.sustained.ops_per_second, 0)} ops/sec |
    | Errors | #{result.sustained.errors} |

    ### Operation Mix

    | Operation | Calls |
    | --- | ---: |
    | `get_treatment` | #{result.sustained.operation_mix.get_treatment} |
    | `get_treatments` | #{result.sustained.operation_mix.get_treatments} |
    | `track` | #{result.sustained.operation_mix.track} |

    ### Mocked Network Activity

    | Endpoint | Requests | Items |
    | --- | ---: | ---: |
    | `/splitChanges` | #{result.mock.split_fetches} | - |
    | `/segmentChanges/*` | #{result.mock.segment_fetches} | - |
    | `/events/bulk` | #{result.mock.event_posts} | #{result.mock.event_items} |
    | `/testImpressions/bulk` | #{result.mock.impression_posts} | #{result.mock.impression_items} |
    | `/testImpressions/count` | #{result.mock.impression_count_posts} | #{result.mock.impression_count_items} |
    | `/keys/ss` | #{result.mock.unique_key_posts} | #{result.mock.unique_key_items} |
    """
  end

  defp check_thresholds!(result) do
    unless File.exists?(@thresholds_file) do
      IO.puts("Warning: #{@thresholds_file} not found, skipping threshold check")
      System.halt(0)
    end

    thresholds = @thresholds_file |> File.read!() |> Jason.decode!()
    failures = threshold_failures(result, thresholds)

    if failures == [] do
      IO.puts("Threshold check passed")
      System.halt(0)
    else
      IO.puts("Threshold check failed:")
      Enum.each(failures, &IO.puts("  - #{&1}"))
      System.halt(1)
    end
  end

  defp threshold_failures(result, thresholds) do
    mode_thresholds = get_in(thresholds, ["runtime", result.mode]) || %{}

    []
    |> maybe_fail(
      result.bootstrap.ready_ms <= get_in(thresholds, ["bootstrap", "max_ready_ms"]),
      "bootstrap ready time #{result.bootstrap.ready_ms}ms exceeded max #{get_in(thresholds, ["bootstrap", "max_ready_ms"])}ms"
    )
    |> maybe_fail(
      result.bootstrap.split_fetches >= get_in(thresholds, ["bootstrap", "min_split_fetches"]),
      "expected at least #{get_in(thresholds, ["bootstrap", "min_split_fetches"])} split fetch"
    )
    |> maybe_fail(
      result.sustained.ops_per_second >= Map.get(mode_thresholds, "min_ops_sec", 0),
      "throughput #{Float.round(result.sustained.ops_per_second, 0)} ops/sec below #{Map.get(mode_thresholds, "min_ops_sec", 0)}"
    )
    |> maybe_fail(
      result.sustained.errors <= Map.get(mode_thresholds, "max_errors", 0),
      "errors #{result.sustained.errors} exceeded #{Map.get(mode_thresholds, "max_errors", 0)}"
    )
    |> maybe_fail(
      result.mock.event_posts >= Map.get(mode_thresholds, "min_event_posts", 0),
      "event flushes #{result.mock.event_posts} below #{Map.get(mode_thresholds, "min_event_posts", 0)}"
    )
    |> maybe_fail(
      result.mock.impression_posts >= Map.get(mode_thresholds, "min_impression_posts", 0),
      "impression flushes #{result.mock.impression_posts} below #{Map.get(mode_thresholds, "min_impression_posts", 0)}"
    )
    |> maybe_fail(
      result.mock.impression_posts <= Map.get(mode_thresholds, "max_impression_posts", result.mock.impression_posts),
      "impression flushes #{result.mock.impression_posts} exceeded #{Map.get(mode_thresholds, "max_impression_posts", result.mock.impression_posts)}"
    )
    |> maybe_fail(
      result.mock.impression_count_posts >= Map.get(mode_thresholds, "min_impression_count_posts", 0),
      "impression count flushes #{result.mock.impression_count_posts} below #{Map.get(mode_thresholds, "min_impression_count_posts", 0)}"
    )
    |> maybe_fail(
      result.mock.post_failures <= Map.get(mode_thresholds, "max_post_failures", 0),
      "mock post failures #{result.mock.post_failures} exceeded #{Map.get(mode_thresholds, "max_post_failures", 0)}"
    )
  end

  defp maybe_fail(failures, true, _message), do: failures
  defp maybe_fail(failures, false, message), do: [message | failures]

  defp parse_impressions_mode("none"), do: :none
  defp parse_impressions_mode("debug"), do: :debug
  defp parse_impressions_mode(_), do: :optimized

  defp incr(counter) do
    :atomics.add(counter, 1, 1)
  end
end
