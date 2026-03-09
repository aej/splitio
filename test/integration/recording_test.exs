defmodule Splitio.Integration.RecordingTest do
  use Splitio.Integration.Case, async: false

  alias Splitio.Integration.{AdminApi, Helpers}

  @moduletag :integration

  describe "event recording" do
    test "impressions are queued without error", %{admin: admin, test_id: test_id} do
      flag_name = "recording_flag_#{test_id}"

      definition = AdminApi.simple_rollout("on")
      :ok = AdminApi.create_flag_with_definition(admin, flag_name, definition)
      Process.sleep(3000)

      try do
        {:ok, _} = Helpers.start_sdk(streaming_enabled: false, impressions_mode: :optimized)

        # Generate many impressions
        for i <- 1..100 do
          treatment = Splitio.get_treatment("user_#{i}", flag_name)
          assert treatment == "on"
        end

        # No errors should occur - impressions are queued
        # We can't easily verify they reach Split without their reporting API
        # but the SDK should handle this gracefully
      after
        Helpers.stop_sdk()
        AdminApi.remove_flag_definition(admin, flag_name)
        AdminApi.delete_flag(admin, flag_name)
      end
    end

    test "track events are accepted", %{admin: _admin, test_id: _test_id} do
      try do
        {:ok, _} = Helpers.start_sdk(streaming_enabled: false)

        # Track various events
        assert Splitio.track("user_1", "user", "purchase", 99.99, %{item: "widget"})
        assert Splitio.track("user_2", "user", "click")
        assert Splitio.track("user_3", "user", "signup", nil, %{source: "google"})

        # All should be accepted (return true)
      after
        Helpers.stop_sdk()
      end
    end

    test "impressions mode none still evaluates correctly", %{admin: admin, test_id: test_id} do
      flag_name = "none_mode_#{test_id}"

      definition = AdminApi.simple_rollout("on")
      :ok = AdminApi.create_flag_with_definition(admin, flag_name, definition)
      Process.sleep(3000)

      try do
        {:ok, _} = Helpers.start_sdk(streaming_enabled: false, impressions_mode: :none)

        # Should still evaluate correctly even with no impressions
        assert Splitio.get_treatment("user", flag_name) == "on"
      after
        Helpers.stop_sdk()
        AdminApi.remove_flag_definition(admin, flag_name)
        AdminApi.delete_flag(admin, flag_name)
      end
    end
  end
end
