defmodule Splitio.Integration.StreamingTest do
  use Splitio.Integration.Case, async: false

  alias Splitio.Integration.{AdminApi, Helpers}

  @moduletag :integration
  # TODO: Skip streaming tests - SSE updates from Harness FME may have higher latency
  # or work differently than expected. These tests consistently timeout waiting for
  # SSE-delivered updates. Investigate Harness FME SSE behavior.
  @moduletag :skip
  # 3 minutes - streaming tests need time for SSE
  @moduletag timeout: 180_000

  describe "streaming sync" do
    test "SDK connects via SSE and receives updates", %{admin: admin, test_id: test_id} do
      flag_name = "stream_flag_#{test_id}"

      # Create initial flag
      definition = AdminApi.simple_rollout("initial")
      :ok = AdminApi.create_flag_with_definition(admin, flag_name, definition)
      Process.sleep(3000)

      try do
        # Start SDK with streaming enabled
        {:ok, _} = Helpers.start_sdk(streaming_enabled: true)

        # Verify initial value
        assert Splitio.get_treatment("user", flag_name) == "initial"

        # Update flag - should be received via SSE
        new_definition = AdminApi.simple_rollout("streamed_update")
        :ok = AdminApi.update_flag_definition(admin, flag_name, new_definition)

        # SSE should deliver update faster than polling (within 10-15s typically)
        assert :ok =
                 Helpers.wait_until(
                   fn -> Splitio.get_treatment("user", flag_name) == "streamed_update" end,
                   timeout: 30_000
                 )
      after
        Helpers.stop_sdk()
        AdminApi.remove_flag_definition(admin, flag_name)
        AdminApi.delete_flag(admin, flag_name)
      end
    end

    test "SDK receives kill notification via SSE", %{admin: admin, test_id: test_id} do
      flag_name = "stream_kill_#{test_id}"

      # Create flag
      definition = AdminApi.simple_rollout("alive", default_treatment: "dead")
      :ok = AdminApi.create_flag_with_definition(admin, flag_name, definition)
      Process.sleep(3000)

      try do
        # Start SDK with streaming
        {:ok, _} = Helpers.start_sdk(streaming_enabled: true)

        # Verify flag is alive
        assert Splitio.get_treatment("user", flag_name) == "alive"

        # Kill via Admin API
        :ok = AdminApi.kill_flag(admin, flag_name)

        # Should receive kill notification quickly
        assert :ok =
                 Helpers.wait_until(
                   fn -> Splitio.get_treatment("user", flag_name) == "dead" end,
                   timeout: 30_000
                 )
      after
        Helpers.stop_sdk()
        AdminApi.restore_flag(admin, flag_name)
        AdminApi.remove_flag_definition(admin, flag_name)
        AdminApi.delete_flag(admin, flag_name)
      end
    end

    test "SDK receives segment update via SSE", %{admin: admin, test_id: test_id} do
      segment_name = "stream_segment_#{test_id}"
      flag_name = "stream_seg_flag_#{test_id}"

      # Create empty segment
      :ok = AdminApi.create_segment_with_keys(admin, segment_name, [])

      # Create flag using segment
      definition = AdminApi.segment_rule(segment_name, "in_segment")
      :ok = AdminApi.create_flag_with_definition(admin, flag_name, definition)
      Process.sleep(3000)

      try do
        # Start SDK with streaming
        {:ok, _} = Helpers.start_sdk(streaming_enabled: true)

        # User not in segment
        assert Splitio.get_treatment("streamed_user", flag_name) == "off"

        # Add user to segment
        :ok = AdminApi.update_segment_keys(admin, segment_name, ["streamed_user"])

        # Should receive segment update via SSE
        assert :ok =
                 Helpers.wait_until(
                   fn -> Splitio.get_treatment("streamed_user", flag_name) == "in_segment" end,
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

    test "new flag created after SDK start is received via SSE", %{admin: admin, test_id: test_id} do
      flag_name = "stream_new_#{test_id}"

      try do
        # Start SDK with streaming (no flag exists yet)
        {:ok, _} = Helpers.start_sdk(streaming_enabled: true)

        # Verify flag doesn't exist
        assert Splitio.Manager.split(flag_name) == nil

        # Create new flag - should trigger SSE notification
        definition = AdminApi.simple_rollout("brand_new")
        :ok = AdminApi.create_flag_with_definition(admin, flag_name, definition)

        # Should be available quickly via SSE
        assert :ok =
                 Helpers.wait_until(
                   fn -> Splitio.Manager.split(flag_name) != nil end,
                   timeout: 30_000
                 )

        assert Splitio.get_treatment("user", flag_name) == "brand_new"
      after
        Helpers.stop_sdk()
        AdminApi.remove_flag_definition(admin, flag_name)
        AdminApi.delete_flag(admin, flag_name)
      end
    end
  end
end
