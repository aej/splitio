defmodule Splitio.Integration.InitialSyncTest do
  use Splitio.Integration.Case, async: false

  alias Splitio.Integration.{AdminApi, Helpers}

  @moduletag :integration

  describe "initial sync" do
    test "SDK starts and becomes ready with existing flags", %{admin: admin, test_id: test_id} do
      flag_name = "init_sync_#{test_id}"

      # Create a flag
      definition = AdminApi.simple_rollout("on")
      :ok = AdminApi.create_flag_with_definition(admin, flag_name, definition)

      # Wait for propagation
      Process.sleep(3000)

      try do
        # Start SDK and wait for ready
        assert {:ok, _pid} = Helpers.start_sdk(streaming_enabled: false)
        assert Splitio.ready?()

        # Flag should be available
        assert Splitio.Manager.split(flag_name) != nil
      after
        Helpers.stop_sdk()
        AdminApi.remove_flag_definition(admin, flag_name)
        AdminApi.delete_flag(admin, flag_name)
      end
    end

    test "SDK fetches multiple flags", %{admin: admin, test_id: test_id} do
      flags =
        for i <- 1..3 do
          name = "multi_flag_#{test_id}_#{i}"
          definition = AdminApi.simple_rollout("on")
          :ok = AdminApi.create_flag_with_definition(admin, name, definition)
          name
        end

      Process.sleep(3000)

      try do
        assert {:ok, _pid} = Helpers.start_sdk(streaming_enabled: false)

        # All flags should be present
        split_names = Splitio.Manager.split_names()

        for flag <- flags do
          assert flag in split_names, "Expected #{flag} in #{inspect(split_names)}"
        end
      after
        Helpers.stop_sdk()

        for flag <- flags do
          AdminApi.remove_flag_definition(admin, flag)
          AdminApi.delete_flag(admin, flag)
        end
      end
    end

    test "SDK fetches segments referenced by flags", %{admin: admin, test_id: test_id} do
      segment_name = "test_segment_#{test_id}"
      flag_name = "segment_flag_#{test_id}"

      # Create segment with test keys
      :ok = AdminApi.create_segment_with_keys(admin, segment_name, ["user_in_segment"])

      # Create flag that uses the segment
      definition = AdminApi.segment_rule(segment_name, "on")
      :ok = AdminApi.create_flag_with_definition(admin, flag_name, definition)

      Process.sleep(3000)

      try do
        assert {:ok, _pid} = Helpers.start_sdk(streaming_enabled: false)

        # User in segment should get "on"
        assert Splitio.get_treatment("user_in_segment", flag_name) == "on"

        # User not in segment should get default
        assert Splitio.get_treatment("user_not_in_segment", flag_name) == "off"
      after
        Helpers.stop_sdk()
        AdminApi.remove_flag_definition(admin, flag_name)
        AdminApi.delete_flag(admin, flag_name)
        AdminApi.deactivate_segment(admin, segment_name)
        AdminApi.delete_segment(admin, segment_name)
      end
    end

    test "SDK handles empty environment", %{admin: _admin, test_id: _test_id} do
      # Don't create any fixtures - just start SDK
      # Note: Other tests may have created fixtures, so we can't guarantee empty
      # Instead, verify SDK starts successfully even if no test-specific fixtures

      try do
        assert {:ok, _pid} = Helpers.start_sdk(streaming_enabled: false)
        assert Splitio.ready?()
      after
        Helpers.stop_sdk()
      end
    end
  end
end
