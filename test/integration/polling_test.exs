defmodule Splitio.Integration.PollingTest do
  use Splitio.Integration.Case, async: false

  alias Splitio.Integration.{AdminApi, Helpers}

  @moduletag :integration
  # 3 minutes - polling tests are slow
  @moduletag timeout: 180_000

  describe "polling sync" do
    test "detects new flag created after SDK start", %{admin: admin, test_id: test_id} do
      flag_name = "poll_new_flag_#{test_id}"

      try do
        # Start SDK first (with fast polling)
        {:ok, _} = Helpers.start_sdk(streaming_enabled: false, features_refresh_rate: 5)

        # Verify flag doesn't exist yet
        assert Splitio.Manager.split(flag_name) == nil

        # Create flag via Admin API
        definition = AdminApi.simple_rollout("created_after_start")
        :ok = AdminApi.create_flag_with_definition(admin, flag_name, definition)

        # Wait for polling to pick it up (up to 30s)
        assert :ok =
                 Helpers.wait_until(
                   fn -> Splitio.Manager.split(flag_name) != nil end,
                   timeout: 30_000
                 )

        # Verify evaluation works
        assert Splitio.get_treatment("user", flag_name) == "created_after_start"
      after
        Helpers.stop_sdk()
        AdminApi.remove_flag_definition(admin, flag_name)
        AdminApi.delete_flag(admin, flag_name)
      end
    end

    test "detects flag update after SDK start", %{admin: admin, test_id: test_id} do
      flag_name = "poll_update_flag_#{test_id}"

      # Create initial flag
      definition = AdminApi.simple_rollout("initial_value")
      :ok = AdminApi.create_flag_with_definition(admin, flag_name, definition)
      Process.sleep(3000)

      try do
        # Start SDK
        {:ok, _} = Helpers.start_sdk(streaming_enabled: false, features_refresh_rate: 5)

        # Verify initial value
        assert Splitio.get_treatment("user", flag_name) == "initial_value"

        # Update flag via Admin API
        new_definition = AdminApi.simple_rollout("updated_value")
        :ok = AdminApi.update_flag_definition(admin, flag_name, new_definition)

        # Wait for polling to pick up the change
        assert :ok =
                 Helpers.wait_until(
                   fn -> Splitio.get_treatment("user", flag_name) == "updated_value" end,
                   timeout: 30_000
                 )
      after
        Helpers.stop_sdk()
        AdminApi.remove_flag_definition(admin, flag_name)
        AdminApi.delete_flag(admin, flag_name)
      end
    end

    test "detects flag removal (archive)", %{admin: admin, test_id: test_id} do
      flag_name = "poll_remove_flag_#{test_id}"

      # Create flag
      definition = AdminApi.simple_rollout("will_be_removed")
      :ok = AdminApi.create_flag_with_definition(admin, flag_name, definition)
      Process.sleep(3000)

      try do
        # Start SDK
        {:ok, _} = Helpers.start_sdk(streaming_enabled: false, features_refresh_rate: 5)

        # Verify flag exists
        assert Splitio.Manager.split(flag_name) != nil

        # Remove flag definition from environment
        :ok = AdminApi.remove_flag_definition(admin, flag_name)

        # Wait for polling to detect removal
        assert :ok =
                 Helpers.wait_until(
                   fn -> Splitio.Manager.split(flag_name) == nil end,
                   timeout: 30_000
                 )

        # Should return control now
        assert Splitio.get_treatment("user", flag_name) == "control"
      after
        Helpers.stop_sdk()
        AdminApi.delete_flag(admin, flag_name)
      end
    end

    test "detects segment membership changes", %{admin: admin, test_id: test_id} do
      segment_name = "poll_segment_#{test_id}"
      flag_name = "poll_segment_flag_#{test_id}"

      # Create segment WITHOUT the test user
      :ok = AdminApi.create_segment_with_keys(admin, segment_name, ["other_user"])

      # Create flag using segment
      definition = AdminApi.segment_rule(segment_name, "member")
      :ok = AdminApi.create_flag_with_definition(admin, flag_name, definition)
      Process.sleep(3000)

      try do
        # Start SDK
        {:ok, _} = Helpers.start_sdk(streaming_enabled: false, segments_refresh_rate: 5)

        # User not in segment should get default
        assert Splitio.get_treatment("test_user", flag_name) == "off"

        # Add user to segment
        :ok = AdminApi.update_segment_keys(admin, segment_name, ["test_user", "other_user"])

        # Wait for segment sync
        assert :ok =
                 Helpers.wait_until(
                   fn -> Splitio.get_treatment("test_user", flag_name) == "member" end,
                   timeout: 30_000
                 )
      after
        Helpers.stop_sdk()
        AdminApi.remove_flag_definition(admin, flag_name)
        AdminApi.delete_flag(admin, flag_name)
        AdminApi.deactivate_segment(admin, segment_name)
        AdminApi.delete_segment(admin, segment_name)
      end
    end
  end
end
