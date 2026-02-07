--- prism.nvim event module tests
--- @module tests.unit.event_spec

describe("prism.event", function()
  local event

  before_each(function()
    -- Reset module state before each test
    package.loaded["prism.event"] = nil
    event = require("prism.event")
    event.clear()
  end)

  describe("emit and on", function()
    it("calls subscriber when event is emitted", function()
      local called = false
      local received_payload = nil

      event.on("test:event", function(payload)
        called = true
        received_payload = payload
      end)

      event.emit("test:event", { data = "value" })

      assert.is_true(called)
      assert.is_table(received_payload)
      assert.equals("value", received_payload.data)
    end)

    it("calls multiple subscribers", function()
      local call_count = 0

      event.on("test:event", function()
        call_count = call_count + 1
      end)

      event.on("test:event", function()
        call_count = call_count + 1
      end)

      event.emit("test:event")

      assert.equals(2, call_count)
    end)

    it("passes event name to subscriber", function()
      local received_event = nil

      event.on("test:event", function(payload, evt_name)
        received_event = evt_name
      end)

      event.emit("test:event", {})

      assert.equals("test:event", received_event)
    end)

    it("handles nil payload", function()
      local called = false

      event.on("test:event", function(payload)
        called = true
        assert.is_nil(payload)
      end)

      event.emit("test:event")

      assert.is_true(called)
    end)

    it("does not call subscribers for different events", function()
      local called = false

      event.on("test:event", function()
        called = true
      end)

      event.emit("other:event")

      assert.is_false(called)
    end)
  end)

  describe("off", function()
    it("removes subscriber", function()
      local call_count = 0

      local callback = function()
        call_count = call_count + 1
      end

      event.on("test:event", callback)
      event.emit("test:event")
      assert.equals(1, call_count)

      local removed = event.off("test:event", callback)
      assert.is_true(removed)

      event.emit("test:event")
      assert.equals(1, call_count) -- Should not increment
    end)

    it("returns false when subscriber not found", function()
      local callback = function() end

      local removed = event.off("test:event", callback)
      assert.is_false(removed)
    end)

    it("only removes specific subscriber", function()
      local calls = { a = 0, b = 0 }

      local callback_a = function()
        calls.a = calls.a + 1
      end

      local callback_b = function()
        calls.b = calls.b + 1
      end

      event.on("test:event", callback_a)
      event.on("test:event", callback_b)

      event.off("test:event", callback_a)
      event.emit("test:event")

      assert.equals(0, calls.a)
      assert.equals(1, calls.b)
    end)
  end)

  describe("unsubscribe function", function()
    it("on returns unsubscribe function", function()
      local call_count = 0

      local unsubscribe = event.on("test:event", function()
        call_count = call_count + 1
      end)

      assert.is_function(unsubscribe)

      event.emit("test:event")
      assert.equals(1, call_count)

      unsubscribe()

      event.emit("test:event")
      assert.equals(1, call_count)
    end)
  end)

  describe("once", function()
    it("calls subscriber only once", function()
      local call_count = 0

      event.once("test:event", function()
        call_count = call_count + 1
      end)

      event.emit("test:event")
      event.emit("test:event")
      event.emit("test:event")

      assert.equals(1, call_count)
    end)

    it("receives payload correctly", function()
      local received = nil

      event.once("test:event", function(payload)
        received = payload
      end)

      event.emit("test:event", { value = 42 })

      assert.equals(42, received.value)
    end)

    it("returns unsubscribe function", function()
      local called = false

      local unsubscribe = event.once("test:event", function()
        called = true
      end)

      unsubscribe()
      event.emit("test:event")

      assert.is_false(called)
    end)
  end)

  describe("wildcard subscriber", function()
    it("receives all events", function()
      local events_received = {}

      event.on("*", function(payload, evt_name)
        table.insert(events_received, evt_name)
      end)

      event.emit("event:one")
      event.emit("event:two")
      event.emit("event:three")

      assert.equals(3, #events_received)
      assert.same({ "event:one", "event:two", "event:three" }, events_received)
    end)

    it("does not receive wildcard event recursively", function()
      local count = 0

      event.on("*", function(payload, evt_name)
        count = count + 1
      end)

      event.emit("*", {}) -- Should not trigger wildcard subscriber

      assert.equals(0, count)
    end)
  end)

  describe("history", function()
    it("logs emitted events", function()
      event.emit("test:one", { a = 1 })
      event.emit("test:two", { b = 2 })

      local history = event.history()

      assert.equals(2, #history)
      assert.equals("test:one", history[1].event)
      assert.equals(1, history[1].payload.a)
      assert.equals("test:two", history[2].event)
      assert.equals(2, history[2].payload.b)
    end)

    it("assigns sequential IDs", function()
      event.emit("test:one")
      event.emit("test:two")
      event.emit("test:three")

      local history = event.history()

      assert.equals(1, history[1].id)
      assert.equals(2, history[2].id)
      assert.equals(3, history[3].id)
    end)

    it("includes timestamps", function()
      event.emit("test:event")

      local history = event.history()

      assert.is_number(history[1].timestamp)
      assert.is_true(history[1].timestamp > 0)
    end)

    it("filters by event name", function()
      event.emit("test:one")
      event.emit("test:two")
      event.emit("test:one")

      local history = event.history({ event = "test:one" })

      assert.equals(2, #history)
      assert.equals("test:one", history[1].event)
      assert.equals("test:one", history[2].event)
    end)

    it("filters by limit", function()
      event.emit("test:one")
      event.emit("test:two")
      event.emit("test:three")
      event.emit("test:four")

      local history = event.history({ limit = 2 })

      assert.equals(2, #history)
      -- Should return most recent (from end)
      assert.equals("test:three", history[1].event)
      assert.equals("test:four", history[2].event)
    end)

    it("returns copy of history", function()
      event.emit("test:event", { value = 1 })

      local history1 = event.history()
      local history2 = event.history()

      history1[1].payload.value = 999

      assert.equals(1, history2[1].payload.value)
    end)
  end)

  describe("clear", function()
    it("clears subscribers and log by default", function()
      local called = false

      event.on("test:event", function()
        called = true
      end)
      event.emit("test:event")

      event.clear()

      event.emit("test:event")
      local history = event.history()

      -- New emit should not call old subscriber
      assert.is_true(called) -- Was called before clear
      assert.equals(0, #history)
    end)

    it("clears only subscribers when specified", function()
      event.emit("test:event")
      event.clear({ subscribers = true, log = false })

      local history = event.history()
      assert.equals(1, #history)
    end)

    it("clears only log when specified", function()
      local call_count = 0

      event.on("test:event", function()
        call_count = call_count + 1
      end)

      event.emit("test:event")
      event.clear({ subscribers = false, log = true })
      event.emit("test:event")

      assert.equals(2, call_count)
      assert.equals(1, #event.history())
    end)
  end)

  describe("subscriber_count", function()
    it("returns count for specific event", function()
      event.on("test:event", function() end)
      event.on("test:event", function() end)
      event.on("other:event", function() end)

      assert.equals(2, event.subscriber_count("test:event"))
      assert.equals(1, event.subscriber_count("other:event"))
    end)

    it("returns total count when no event specified", function()
      event.on("test:one", function() end)
      event.on("test:two", function() end)
      event.once("test:three", function() end)

      assert.equals(3, event.subscriber_count())
    end)

    it("includes once subscribers in count", function()
      event.on("test:event", function() end)
      event.once("test:event", function() end)

      assert.equals(2, event.subscriber_count("test:event"))
    end)

    it("returns 0 for event with no subscribers", function()
      assert.equals(0, event.subscriber_count("nonexistent"))
    end)
  end)

  describe("replay", function()
    it("replays events in order", function()
      local replayed = {}

      event.on("test:event", function(payload)
        table.insert(replayed, payload.value)
      end)

      local entries = {
        { event = "test:event", payload = { value = 1 } },
        { event = "test:event", payload = { value = 2 } },
        { event = "test:event", payload = { value = 3 } },
      }

      event.replay(entries)

      assert.same({ 1, 2, 3 }, replayed)
    end)

    it("logs replayed events", function()
      event.replay({
        { event = "test:one", payload = {} },
        { event = "test:two", payload = {} },
      })

      local history = event.history()
      assert.equals(2, #history)
    end)
  end)

  describe("predefined events", function()
    it("has terminal events", function()
      assert.equals("terminal:opened", event.events.TERMINAL_OPENED)
      assert.equals("terminal:closed", event.events.TERMINAL_CLOSED)
      assert.equals("terminal:output", event.events.TERMINAL_OUTPUT)
    end)

    it("has message events", function()
      assert.equals("message:sent", event.events.MESSAGE_SENT)
      assert.equals("message:received", event.events.MESSAGE_RECEIVED)
      assert.equals("message:error", event.events.MESSAGE_ERROR)
    end)

    it("has session events", function()
      assert.equals("session:started", event.events.SESSION_STARTED)
      assert.equals("session:ended", event.events.SESSION_ENDED)
      assert.equals("session:resumed", event.events.SESSION_RESUMED)
    end)

    it("has diff events", function()
      assert.equals("diff:created", event.events.DIFF_CREATED)
      assert.equals("diff:accepted", event.events.DIFF_ACCEPTED)
      assert.equals("diff:rejected", event.events.DIFF_REJECTED)
    end)
  end)

  describe("error handling", function()
    it("continues calling other subscribers after error", function()
      local calls = { a = false, b = false }

      event.on("test:event", function()
        calls.a = true
        error("intentional error")
      end)

      event.on("test:event", function()
        calls.b = true
      end)

      -- Should not throw
      event.emit("test:event")

      assert.is_true(calls.a)
      assert.is_true(calls.b)
    end)

    it("throws error when callback is not a function", function()
      assert.has_error(function()
        event.on("test:event", "not a function")
      end)
    end)
  end)
end)
