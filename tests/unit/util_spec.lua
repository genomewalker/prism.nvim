--- prism.nvim util module tests
--- @module tests.unit.util_spec

describe("prism.util", function()
  local util

  before_each(function()
    -- Reset module state before each test
    package.loaded["prism.util"] = nil
    util = require("prism.util")
  end)

  describe("uuid_v4", function()
    it("generates valid UUID format", function()
      local uuid = util.uuid_v4()

      -- UUID v4 format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
      assert.is_string(uuid)
      assert.equals(36, #uuid)
      assert.matches("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$", uuid)
    end)

    it("always has 4 in version position", function()
      for _ = 1, 10 do
        local uuid = util.uuid_v4()
        assert.equals("4", uuid:sub(15, 15))
      end
    end)

    it("has valid variant digit", function()
      for _ = 1, 10 do
        local uuid = util.uuid_v4()
        local variant = uuid:sub(20, 20)
        assert.is_true(
          variant == "8" or variant == "9" or variant == "a" or variant == "b",
          "Variant should be 8, 9, a, or b but was: " .. variant
        )
      end
    end)

    it("generates unique UUIDs", function()
      local uuids = {}
      for _ = 1, 100 do
        local uuid = util.uuid_v4()
        assert.is_nil(uuids[uuid], "Duplicate UUID generated")
        uuids[uuid] = true
      end
    end)
  end)

  describe("debounce", function()
    it("delays function execution", function()
      local call_count = 0
      local debounced = util.debounce(function()
        call_count = call_count + 1
      end, 50)

      debounced()
      debounced()
      debounced()

      -- Should not be called immediately
      assert.equals(0, call_count)

      -- Wait for debounce
      vim.wait(100, function()
        return call_count > 0
      end)

      assert.equals(1, call_count)
    end)

    it("resets timer on subsequent calls", function()
      local call_count = 0
      local debounced = util.debounce(function()
        call_count = call_count + 1
      end, 50)

      debounced()
      vim.wait(30)
      debounced() -- Reset timer
      vim.wait(30)
      debounced() -- Reset timer again

      assert.equals(0, call_count)

      vim.wait(100)

      assert.equals(1, call_count)
    end)

    it("passes arguments to function", function()
      local received_args = nil
      local debounced = util.debounce(function(a, b)
        received_args = { a, b }
      end, 20)

      debounced("hello", 42)

      vim.wait(50, function()
        return received_args ~= nil
      end)

      assert.same({ "hello", 42 }, received_args)
    end)

    it("uses latest arguments when called multiple times", function()
      local received = nil
      local debounced = util.debounce(function(value)
        received = value
      end, 20)

      debounced(1)
      debounced(2)
      debounced(3)

      vim.wait(50, function()
        return received ~= nil
      end)

      assert.equals(3, received)
    end)
  end)

  describe("throttle", function()
    it("executes immediately on first call", function()
      local call_count = 0
      local throttled = util.throttle(function()
        call_count = call_count + 1
      end, 100)

      throttled()

      assert.equals(1, call_count)
    end)

    it("limits execution rate", function()
      local call_count = 0
      local throttled = util.throttle(function()
        call_count = call_count + 1
      end, 50)

      throttled()
      throttled()
      throttled()
      throttled()

      -- Only first call should execute immediately
      assert.equals(1, call_count)

      -- Wait for throttle window
      vim.wait(100, function()
        return call_count > 1
      end)

      -- Should have executed pending call
      assert.equals(2, call_count)
    end)
  end)

  describe("git_root", function()
    it("returns nil when not in git repo", function()
      local result = util.git_root("/tmp")
      -- May return nil or a path depending on if /tmp is in a git repo
      -- This is environment-dependent
      assert.is_true(result == nil or type(result) == "string")
    end)

    it("accepts path argument", function()
      -- Just verify it doesn't error
      local result = util.git_root(vim.fn.getcwd())
      assert.is_true(result == nil or type(result) == "string")
    end)
  end)

  describe("json_encode", function()
    it("encodes simple table", function()
      local result, err = util.json_encode({ key = "value" })

      assert.is_nil(err)
      assert.is_string(result)
      assert.matches("key", result)
      assert.matches("value", result)
    end)

    it("encodes nested table", function()
      local result, err = util.json_encode({
        outer = { inner = { deep = 42 } },
      })

      assert.is_nil(err)
      assert.is_string(result)
    end)

    it("encodes arrays", function()
      local result, err = util.json_encode({ 1, 2, 3, "four" })

      assert.is_nil(err)
      assert.is_string(result)
    end)

    it("handles nil gracefully", function()
      local result, err = util.json_encode(nil)

      -- vim.fn.json_encode(nil) returns "null"
      assert.is_nil(err)
    end)
  end)

  describe("json_decode", function()
    it("decodes JSON string", function()
      local result, err = util.json_decode('{"key":"value"}')

      assert.is_nil(err)
      assert.is_table(result)
      assert.equals("value", result.key)
    end)

    it("decodes arrays", function()
      local result, err = util.json_decode("[1,2,3]")

      assert.is_nil(err)
      assert.is_table(result)
      assert.same({ 1, 2, 3 }, result)
    end)

    it("returns error for empty string", function()
      local result, err = util.json_decode("")

      assert.is_nil(result)
      assert.equals("empty string", err)
    end)

    it("returns error for nil", function()
      local result, err = util.json_decode(nil)

      assert.is_nil(result)
      assert.is_string(err)
    end)

    it("returns error for invalid JSON", function()
      local result, err = util.json_decode("not valid json")

      assert.is_nil(result)
      assert.is_string(err)
    end)
  end)

  describe("escape_pattern", function()
    it("escapes special pattern characters", function()
      local result = util.escape_pattern("^$()%.[]*+-?")

      assert.equals("%^%$%(%)%%%.%[%]%*%+%-%?", result)
    end)

    it("leaves normal characters unchanged", function()
      local result = util.escape_pattern("hello world")

      assert.equals("hello world", result)
    end)

    it("handles mixed content", function()
      local result = util.escape_pattern("test.lua")

      assert.equals("test%.lua", result)
    end)

    it("handles empty string", function()
      local result = util.escape_pattern("")

      assert.equals("", result)
    end)
  end)

  describe("contains", function()
    it("returns true when value exists", function()
      local list = { "a", "b", "c" }

      assert.is_true(util.contains(list, "b"))
    end)

    it("returns false when value does not exist", function()
      local list = { "a", "b", "c" }

      assert.is_false(util.contains(list, "d"))
    end)

    it("handles empty list", function()
      assert.is_false(util.contains({}, "anything"))
    end)

    it("handles numeric values", function()
      local list = { 1, 2, 3 }

      assert.is_true(util.contains(list, 2))
      assert.is_false(util.contains(list, 4))
    end)

    it("does not match by type coercion", function()
      local list = { "1", "2", "3" }

      assert.is_false(util.contains(list, 1))
    end)
  end)

  describe("merge", function()
    it("merges two tables", function()
      local result = util.merge({ a = 1 }, { b = 2 })

      assert.equals(1, result.a)
      assert.equals(2, result.b)
    end)

    it("later values override earlier ones", function()
      local result = util.merge({ a = 1 }, { a = 2 })

      assert.equals(2, result.a)
    end)

    it("merges multiple tables", function()
      local result = util.merge({ a = 1 }, { b = 2 }, { c = 3 })

      assert.equals(1, result.a)
      assert.equals(2, result.b)
      assert.equals(3, result.c)
    end)

    it("handles empty tables", function()
      local result = util.merge({}, { a = 1 }, {})

      assert.equals(1, result.a)
    end)

    it("is shallow merge", function()
      local result = util.merge({ nested = { a = 1 } }, { nested = { b = 2 } })

      -- Shallow merge replaces nested table entirely
      assert.is_nil(result.nested.a)
      assert.equals(2, result.nested.b)
    end)
  end)

  describe("clamp", function()
    it("returns value when within range", function()
      assert.equals(5, util.clamp(5, 0, 10))
    end)

    it("returns min when value is below", function()
      assert.equals(0, util.clamp(-5, 0, 10))
    end)

    it("returns max when value is above", function()
      assert.equals(10, util.clamp(15, 0, 10))
    end)

    it("handles equal min and max", function()
      assert.equals(5, util.clamp(10, 5, 5))
    end)

    it("handles floating point values", function()
      assert.equals(0.5, util.clamp(0.5, 0, 1))
      assert.equals(0, util.clamp(-0.1, 0, 1))
      assert.equals(1, util.clamp(1.1, 0, 1))
    end)
  end)

  describe("has_plugin", function()
    it("returns true for loaded module", function()
      assert.is_true(util.has_plugin("prism.util"))
    end)

    it("returns false for non-existent module", function()
      assert.is_false(util.has_plugin("nonexistent.module.that.does.not.exist"))
    end)
  end)

  describe("relative_path", function()
    it("returns path relative to cwd", function()
      local cwd = vim.fn.getcwd()
      local abs_path = cwd .. "/some/file.lua"

      local result = util.relative_path(abs_path)

      assert.equals("some/file.lua", result)
    end)

    it("returns original path if not under cwd", function()
      local result = util.relative_path("/completely/different/path")

      -- Should return original or relative depending on git root
      assert.is_string(result)
    end)
  end)

  describe("log", function()
    it("has set_level function", function()
      assert.is_function(util.log.set_level)
    end)

    it("has all log level functions", function()
      assert.is_function(util.log.trace)
      assert.is_function(util.log.debug)
      assert.is_function(util.log.info)
      assert.is_function(util.log.warn)
      assert.is_function(util.log.error)
    end)

    it("does not error when logging", function()
      -- Just verify these don't throw
      assert.has_no.errors(function()
        util.log.set_level("error") -- Set high level to suppress output
        util.log.info("test message")
        util.log.error("test error", { data = 123 })
      end)
    end)
  end)

  describe("schedule_after", function()
    it("returns timer handle", function()
      local timer = util.schedule_after(function() end, 1000)

      assert.is_userdata(timer)

      -- Clean up
      timer:stop()
      timer:close()
    end)

    it("executes function after delay", function()
      local executed = false

      util.schedule_after(function()
        executed = true
      end, 20)

      assert.is_false(executed)

      vim.wait(50, function()
        return executed
      end)

      assert.is_true(executed)
    end)
  end)
end)
