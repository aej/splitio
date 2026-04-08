defmodule Splitio.RuntimeParityTest do
  use ExUnit.Case, async: false

  alias Splitio.Config
  alias Splitio.Localhost.Loader
  alias Splitio.Models.{Condition, Impression, Matcher, MatcherGroup, Partition, Split}
  alias Splitio.Recorder.{Impressions, UniqueKeys}
  alias Splitio.Storage
  alias Splitio.Sync.Manager

  setup do
    original_http_client = Application.get_env(:splitio, :http_client)
    original_config = Application.get_env(:splitio, :config)

    on_exit(fn ->
      Splitio.TestHTTP.clear_handler()

      if pid = Process.whereis(Manager) do
        GenServer.stop(pid, :normal)
      end

      for name <- [
            Splitio.Push.SSE,
            Impressions,
            UniqueKeys,
            Splitio.Impressions.Counter,
            Splitio.Impressions.UniqueKeys
          ] do
        if pid = Process.whereis(name) do
          Process.exit(pid, :kill)
        end
      end

      clear_storage()

      restore_env(:http_client, original_http_client)
      restore_env(:config, original_config)
    end)

    :ok
  end

  test "missing split uses configured fallback treatment" do
    {:ok, config} =
      Config.new(
        api_key: "test-api-key",
        fallback_treatment: %{
          global: %{treatment: "off", config: %{source: "fallback"}},
          by_flag: %{"special_flag" => %{treatment: "safe", config: "{\"reason\":\"flag\"}"}}
        }
      )

    Application.put_env(:splitio, :config, config)

    assert Splitio.get_treatment("user-1", "missing_flag") == "off"
    assert Splitio.get_treatment("user-1", "special_flag") == "safe"

    assert {"safe", "{\"reason\":\"flag\"}"} =
             Splitio.get_treatment_with_config("user-1", "special_flag")
  end

  test "impression listener receives impressions even in none mode" do
    parent = self()

    {:ok, config} =
      Config.new(
        api_key: "test-api-key",
        impressions_mode: :none,
        impression_listener: fn payload -> send(parent, {:impression, payload}) end
      )

    Application.put_env(:splitio, :config, config)
    Storage.put_split(always_on_split("listener_flag"))

    assert Splitio.get_treatment("user-1", "listener_flag") == "on"

    assert_receive {:impression, %{impression: impression, attributes: %{}}}, 1_000
    assert impression.feature == "listener_flag"
    assert impression.key == "user-1"
    assert impression.treatment == "on"
  end

  test "sync manager connects streaming after initial sync" do
    Application.put_env(:splitio, :http_client, Splitio.TestHTTP)

    Splitio.TestHTTP.set_handler(fn method, url, _body, _opts ->
      cond do
        method == :get and is_binary(url) and String.contains?(url, "/splitChanges") ->
          {:ok, %{"since" => -1, "till" => -1, "splits" => []}}

        method == :get ->
          {:ok, %{}}

        true ->
          {:ok, %{}}
      end
    end)

    caller = self()

    sse_pid =
      spawn(fn ->
        receive do
          {:"$gen_cast", :connect} -> send(caller, :sse_connected)
        end
      end)

    true = Process.register(sse_pid, Splitio.Push.SSE)

    {:ok, config} = Config.new(api_key: "test-api-key", streaming_enabled: true)
    Application.put_env(:splitio, :config, config)

    assert {:ok, _pid} = Manager.start_link(config)
    assert :ok = Manager.block_until_ready(1_000)
    assert_receive :sse_connected, 1_000
  end

  test "localhost loader loads splits and segments from json files" do
    tmp_dir = temp_dir!("localhost_loader")
    split_file = Path.join(tmp_dir, "splits.json")
    segment_dir = Path.join(tmp_dir, "segments")
    File.mkdir_p!(segment_dir)

    File.write!(split_file, localhost_splits_json())
    File.write!(Path.join(segment_dir, "segment_1.json"), localhost_segment_json())

    assert {:ok, %{splits: 2, segments: 1}} = Loader.load(split_file, segment_dir)
    assert Storage.segment_contains?("segment_1", "example1")
    assert Splitio.get_treatment("example1", "feature_flag_2") == "some_treatment"
    assert Splitio.get_treatment("other", "feature_flag_2") == "on"
  end

  test "unique keys are posted in none mode" do
    Application.put_env(:splitio, :http_client, Splitio.TestHTTP)
    parent = self()

    Splitio.TestHTTP.set_handler(fn method, url, body, _opts ->
      if method == :post and String.contains?(url, "/keys/ss") do
        send(parent, {:unique_keys_payload, body})
      end

      {:ok, %{}}
    end)

    {:ok, config} = Config.new(api_key: "test-api-key", impressions_mode: :none)
    Application.put_env(:splitio, :config, config)

    start_supervised!({Splitio.Impressions.Counter, []})
    start_supervised!({Splitio.Impressions.UniqueKeys, []})
    start_supervised!({Impressions, config})
    start_supervised!({UniqueKeys, config})

    assert :ok = Impressions.record(impression("flag-a", "user-1"))
    assert :ok = Impressions.record(impression("flag-a", "user-2"))
    assert :ok = Impressions.record(impression("flag-a", "user-1"))

    assert :ok = UniqueKeys.flush()

    assert_receive {:unique_keys_payload, %{"keys" => [%{"f" => "flag-a", "ks" => keys}]}}, 1_000
    assert Enum.sort(keys) == ["user-1", "user-2"]
  end

  test "manager exposes block_until_ready" do
    {:ok, config} = Config.new(api_key: "localhost", split_file: write_localhost_yaml())
    Application.put_env(:splitio, :config, config)

    assert {:ok, _pid} =
             start_supervised({Splitio.Localhost.FileWatcher, path: config.split_file})

    assert {:ok, _pid} = Manager.start_link(config)
    assert :ok = Splitio.Manager.block_until_ready(1_000)
  end

  defp always_on_split(name) do
    %Split{
      name: name,
      default_treatment: "off",
      change_number: 1,
      seed: 11,
      algo: :murmur,
      traffic_allocation: 100,
      conditions: [
        %Condition{
          condition_type: :rollout,
          matcher_group: %MatcherGroup{
            combiner: :and,
            matchers: [%Matcher{matcher_type: :all_keys}]
          },
          partitions: [%Partition{treatment: "on", size: 100}],
          label: "default rule"
        }
      ]
    }
  end

  defp impression(feature, key) do
    %Impression{
      feature: feature,
      key: key,
      bucketing_key: key,
      treatment: "on",
      label: "default rule",
      change_number: 1,
      time: System.system_time(:millisecond)
    }
  end

  defp clear_storage do
    Enum.each(Storage.get_split_names(), &Storage.delete_split/1)
    Enum.each(Storage.get_segment_names(), &Storage.delete_segment/1)
    Storage.set_splits_change_number(-1)
    Storage.set_rule_based_segments_change_number(-1)
  end

  defp restore_env(key, nil), do: Application.delete_env(:splitio, key)
  defp restore_env(key, value), do: Application.put_env(:splitio, key, value)

  defp localhost_splits_json do
    ~s({"ff":{"d":[{"changeNumber":1660326991072,"trafficTypeName":"user","name":"feature_flag_1","trafficAllocation":100,"trafficAllocationSeed":-1364119282,"seed":-605938843,"status":"ACTIVE","killed":false,"defaultTreatment":"off","algo":2,"conditions":[{"conditionType":"ROLLOUT","matcherGroup":{"combiner":"AND","matchers":[{"keySelector":{"trafficType":"user","attribute":null},"matcherType":"ALL_KEYS","negate":false,"userDefinedSegmentMatcherData":null,"whitelistMatcherData":null,"unaryNumericMatcherData":null,"betweenMatcherData":null,"dependencyMatcherData":null,"booleanMatcherData":null,"stringMatcherData":null}]},"partitions":[{"treatment":"on","size":100},{"treatment":"off","size":0}],"label":"default rule"}],"configurations":{}},{"changeNumber":1683928900842,"trafficTypeName":"user","name":"feature_flag_2","trafficAllocation":100,"trafficAllocationSeed":-29637986,"seed":651776645,"status":"ACTIVE","killed":false,"defaultTreatment":"off","algo":2,"conditions":[{"conditionType":"WHITELIST","matcherGroup":{"combiner":"AND","matchers":[{"keySelector":null,"matcherType":"IN_SEGMENT","negate":false,"userDefinedSegmentMatcherData":{"segmentName":"segment_1"},"whitelistMatcherData":null,"unaryNumericMatcherData":null,"betweenMatcherData":null,"dependencyMatcherData":null,"booleanMatcherData":null,"stringMatcherData":null}]},"partitions":[{"treatment":"some_treatment","size":100}],"label":"whitelisted segment"},{"conditionType":"ROLLOUT","matcherGroup":{"combiner":"AND","matchers":[{"keySelector":{"trafficType":"user","attribute":null},"matcherType":"ALL_KEYS","negate":false,"userDefinedSegmentMatcherData":null,"whitelistMatcherData":null,"unaryNumericMatcherData":null,"betweenMatcherData":null,"dependencyMatcherData":null,"booleanMatcherData":null,"stringMatcherData":null}]},"partitions":[{"treatment":"on","size":100},{"treatment":"off","size":0},{"treatment":"some_treatment","size":0}],"label":"default rule"}],"configurations":{"off":"{\\"color\\":\\"blue\\"}","on":"{\\"color\\":\\"red\\"}","some_treatment":"{\\"color\\":\\"white\\"}"}}],"s":-1,"t":300}})
  end

  defp localhost_segment_json do
    ~s({"name":"segment_1","added":["example1","example2"],"removed":[],"since":-1,"till":1585948850110})
  end

  defp write_localhost_yaml do
    path = Path.join(temp_dir!("localhost_yaml"), "splits.yaml")

    File.write!(
      path,
      """
      - my_feature:
          treatment: "on"
      """
    )

    path
  end

  defp temp_dir!(prefix) do
    dir =
      Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive, :monotonic])}")

    File.mkdir_p!(dir)
    dir
  end
end
