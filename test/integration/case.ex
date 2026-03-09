defmodule Splitio.Integration.Case do
  @moduledoc """
  Base test case for integration tests.

  Usage:

      defmodule MyIntegrationTest do
        use Splitio.Integration.Case

        test "something" do
          # admin client available as @admin
          # fixtures created/cleaned automatically
        end
      end
  """

  use ExUnit.CaseTemplate

  alias Splitio.Integration.{AdminApi, Helpers}

  using do
    quote do
      import Splitio.Integration.Helpers

      @moduletag :integration
      # 2 minutes per test
      @moduletag timeout: 120_000

      # Track fixtures created during test for cleanup
      @fixtures []

      setup_all do
        case AdminApi.from_env() do
          {:ok, admin} ->
            {:ok, admin: admin}

          {:error, _} ->
            {:ok, admin: nil, skip: true}
        end
      end

      setup %{admin: admin} = context do
        if is_nil(admin) do
          {:ok, skip: true}
        else
          # Ensure SDK is stopped before each test
          Helpers.ensure_sdk_stopped()

          # Generate unique prefix for this test
          test_id = System.unique_integer([:positive])

          {:ok, admin: admin, test_id: test_id}
        end
      end
    end
  end
end
