defmodule Splitio.ConfigTest do
  use ExUnit.Case, async: true

  alias Splitio.Config

  describe "new/1" do
    test "creates config with required api_key" do
      assert {:ok, config} = Config.new(api_key: "test-key")
      assert config.api_key == "test-key"
    end

    test "returns error without api_key" do
      assert {:error, :api_key_required} = Config.new([])
      assert {:error, :api_key_required} = Config.new(api_key: "")
    end

    test "applies defaults" do
      {:ok, config} = Config.new(api_key: "test")

      assert config.mode == :standalone
      assert config.streaming_enabled == true
      assert config.impressions_mode == :optimized
      assert config.features_refresh_rate == 30
      assert config.impressions_queue_size == 10_000
    end

    test "overrides defaults" do
      {:ok, config} =
        Config.new(
          api_key: "test",
          mode: :localhost,
          streaming_enabled: false,
          impressions_mode: :debug,
          features_refresh_rate: 60
        )

      assert config.mode == :localhost
      assert config.streaming_enabled == false
      assert config.impressions_mode == :debug
      assert config.features_refresh_rate == 60
    end

    test "normalizes flag sets" do
      {:ok, config} =
        Config.new(
          api_key: "test",
          flag_sets_filter: ["  Frontend  ", "BACKEND", "mobile"]
        )

      assert "frontend" in config.flag_sets_filter
      assert "backend" in config.flag_sets_filter
      assert "mobile" in config.flag_sets_filter
    end

    test "validates flag sets format" do
      {:ok, config} =
        Config.new(
          api_key: "test",
          flag_sets_filter: ["valid_set", "Invalid-Set!", "123start"]
        )

      # Invalid sets are filtered out
      assert "valid_set" in config.flag_sets_filter
      refute "invalid-set!" in config.flag_sets_filter
      refute "123start" in config.flag_sets_filter
    end
  end

  describe "url_overridden?/2" do
    test "detects default URLs" do
      {:ok, config} = Config.new(api_key: "test")
      refute Config.url_overridden?(config, :sdk)
      refute Config.url_overridden?(config, :events)
    end

    test "detects overridden URLs" do
      {:ok, config} = Config.new(api_key: "test", sdk_url: "https://custom.split.io/api")
      assert Config.url_overridden?(config, :sdk)
      refute Config.url_overridden?(config, :events)
    end
  end
end
