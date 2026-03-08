defmodule Splitio.Push.ParserTest do
  use ExUnit.Case, async: true

  alias Splitio.Push.Parser
  alias Splitio.Push.Messages.{SplitUpdate, SplitKill, SegmentUpdate, Control, Occupancy}

  describe "parse/1" do
    test "parses SPLIT_UPDATE message" do
      data = """
      event: message
      data: {"type":"SPLIT_UPDATE","changeNumber":123,"pcn":100}

      """

      {events, buffer} = Parser.parse(data)
      assert buffer == ""
      assert length(events) == 1

      [event] = events
      assert %SplitUpdate{} = event
      assert event.change_number == 123
      assert event.previous_change_number == 100
    end

    test "parses SPLIT_KILL message" do
      data = """
      event: message
      data: {"type":"SPLIT_KILL","changeNumber":456,"splitName":"test_split","defaultTreatment":"off"}

      """

      {events, _buffer} = Parser.parse(data)
      assert length(events) == 1

      [event] = events
      assert %SplitKill{} = event
      assert event.change_number == 456
      assert event.split_name == "test_split"
      assert event.default_treatment == "off"
    end

    test "parses SEGMENT_UPDATE message" do
      data = """
      event: message
      data: {"type":"SEGMENT_UPDATE","changeNumber":789,"segmentName":"beta_users"}

      """

      {events, _buffer} = Parser.parse(data)
      assert length(events) == 1

      [event] = events
      assert %SegmentUpdate{} = event
      assert event.change_number == 789
      assert event.segment_name == "beta_users"
    end

    test "parses CONTROL message" do
      data = """
      event: message
      data: {"type":"CONTROL","controlType":"STREAMING_PAUSED"}

      """

      {events, _buffer} = Parser.parse(data)
      assert length(events) == 1

      [event] = events
      assert %Control{} = event
      assert event.control_type == :streaming_paused
    end

    test "parses occupancy message" do
      data = """
      event: [meta]occupancy
      data: {"metrics":{"publishers":3}}

      """

      {events, _buffer} = Parser.parse(data)
      assert length(events) == 1

      [event] = events
      assert %Occupancy{} = event
      assert event.publishers == 3
    end

    test "handles nested data field" do
      inner = Jason.encode!(%{"type" => "SPLIT_UPDATE", "changeNumber" => 999})

      data = """
      event: message
      data: {"channel":"test","data":"#{String.replace(inner, "\"", "\\\"")}"}

      """

      {events, _buffer} = Parser.parse(data)
      assert length(events) == 1

      [event] = events
      assert %SplitUpdate{} = event
      assert event.change_number == 999
    end

    test "handles multiple events" do
      data = """
      event: message
      data: {"type":"SPLIT_UPDATE","changeNumber":1}

      event: message
      data: {"type":"SPLIT_UPDATE","changeNumber":2}

      """

      {events, _buffer} = Parser.parse(data)
      assert length(events) == 2
    end

    test "preserves incomplete data in buffer" do
      # No trailing newline - simulates data cut mid-stream
      data = "event: message\ndata: {\"type\":\"SPLIT_UP"

      {events, buffer} = Parser.parse(data)
      assert events == []
      assert buffer != ""
      assert String.contains?(buffer, "SPLIT_UP")
    end

    test "ignores comment lines" do
      data = """
      : keepalive
      event: message
      data: {"type":"SPLIT_UPDATE","changeNumber":1}

      """

      {events, _buffer} = Parser.parse(data)
      assert length(events) == 1
    end

    test "parses compression type" do
      data = """
      event: message
      data: {"type":"SPLIT_UPDATE","changeNumber":1,"c":1}

      """

      {events, _buffer} = Parser.parse(data)
      [event] = events
      assert event.compression == :gzip
    end
  end
end
