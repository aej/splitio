defmodule Splitio.Engine.Matchers.SemverTest do
  use ExUnit.Case, async: true

  alias Splitio.Engine.Matchers.Semver

  describe "parse/1" do
    test "parses simple version" do
      assert {:ok, %Semver{major: 1, minor: 2, patch: 3}} = Semver.parse("1.2.3")
    end

    test "parses version with prerelease" do
      assert {:ok, %Semver{major: 1, minor: 0, patch: 0, prerelease: ["alpha"]}} =
               Semver.parse("1.0.0-alpha")

      assert {:ok, %Semver{major: 1, minor: 0, patch: 0, prerelease: ["alpha", "1"]}} =
               Semver.parse("1.0.0-alpha.1")
    end

    test "strips metadata" do
      assert {:ok, %Semver{major: 1, minor: 2, patch: 3, prerelease: []}} =
               Semver.parse("1.2.3+build.123")

      assert {:ok, %Semver{major: 1, minor: 0, patch: 0, prerelease: ["alpha"]}} =
               Semver.parse("1.0.0-alpha+build")
    end

    test "returns error for invalid versions" do
      assert :error = Semver.parse("1.2")
      assert :error = Semver.parse("1.2.3.4")
      assert :error = Semver.parse("invalid")
      assert :error = Semver.parse("")
    end
  end

  describe "compare/2" do
    test "compares major versions" do
      {:ok, v1} = Semver.parse("1.0.0")
      {:ok, v2} = Semver.parse("2.0.0")
      assert Semver.compare(v1, v2) == :lt
      assert Semver.compare(v2, v1) == :gt
    end

    test "compares minor versions" do
      {:ok, v1} = Semver.parse("1.1.0")
      {:ok, v2} = Semver.parse("1.2.0")
      assert Semver.compare(v1, v2) == :lt
    end

    test "compares patch versions" do
      {:ok, v1} = Semver.parse("1.0.1")
      {:ok, v2} = Semver.parse("1.0.2")
      assert Semver.compare(v1, v2) == :lt
    end

    test "equal versions" do
      {:ok, v1} = Semver.parse("1.2.3")
      {:ok, v2} = Semver.parse("1.2.3")
      assert Semver.compare(v1, v2) == :eq
    end

    test "prerelease is less than release" do
      {:ok, v1} = Semver.parse("1.0.0-alpha")
      {:ok, v2} = Semver.parse("1.0.0")
      assert Semver.compare(v1, v2) == :lt
      assert Semver.compare(v2, v1) == :gt
    end

    test "compares prerelease identifiers" do
      {:ok, v1} = Semver.parse("1.0.0-alpha")
      {:ok, v2} = Semver.parse("1.0.0-beta")
      assert Semver.compare(v1, v2) == :lt

      {:ok, v3} = Semver.parse("1.0.0-alpha.1")
      {:ok, v4} = Semver.parse("1.0.0-alpha.2")
      assert Semver.compare(v3, v4) == :lt
    end

    test "numeric prerelease identifiers compared numerically" do
      {:ok, v1} = Semver.parse("1.0.0-1")
      {:ok, v2} = Semver.parse("1.0.0-10")
      assert Semver.compare(v1, v2) == :lt
    end
  end

  describe "gte?/2, lte?/2, between?/3" do
    test "gte?" do
      {:ok, v1} = Semver.parse("2.0.0")
      {:ok, v2} = Semver.parse("1.0.0")
      assert Semver.gte?(v1, v2)
      assert Semver.gte?(v1, v1)
      refute Semver.gte?(v2, v1)
    end

    test "lte?" do
      {:ok, v1} = Semver.parse("1.0.0")
      {:ok, v2} = Semver.parse("2.0.0")
      assert Semver.lte?(v1, v2)
      assert Semver.lte?(v1, v1)
      refute Semver.lte?(v2, v1)
    end

    test "between?" do
      {:ok, v} = Semver.parse("1.5.0")
      {:ok, start_v} = Semver.parse("1.0.0")
      {:ok, end_v} = Semver.parse("2.0.0")
      assert Semver.between?(v, start_v, end_v)

      {:ok, below} = Semver.parse("0.5.0")
      refute Semver.between?(below, start_v, end_v)

      {:ok, above} = Semver.parse("2.5.0")
      refute Semver.between?(above, start_v, end_v)
    end
  end
end
