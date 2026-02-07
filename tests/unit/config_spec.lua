--- prism.nvim config module tests
--- @module tests.unit.config_spec

describe("prism.config", function()
  local config

  before_each(function()
    -- Reset module state before each test
    package.loaded["prism.config"] = nil
    config = require("prism.config")
    config.reset()
  end)

  describe("defaults", function()
    it("returns default configuration", function()
      local defaults = config.defaults()
      assert.is_table(defaults)
      assert.is_table(defaults.terminal)
      assert.is_table(defaults.mcp)
      assert.is_table(defaults.ui)
    end)

    it("returns a copy of defaults", function()
      local defaults1 = config.defaults()
      local defaults2 = config.defaults()

      defaults1.terminal.provider = "changed"

      assert.are_not.equal(defaults1.terminal.provider, defaults2.terminal.provider)
    end)

    it("has correct default terminal settings", function()
      local defaults = config.defaults()

      assert.equals("native", defaults.terminal.provider)
      assert.equals("vertical", defaults.terminal.position)
      assert.equals(0.4, defaults.terminal.width)
      assert.equals(0.3, defaults.terminal.height)
      assert.equals("claude", defaults.terminal.cmd)
      assert.is_false(defaults.terminal.auto_start)
    end)

    it("has correct default MCP settings", function()
      local defaults = config.defaults()

      assert.is_true(defaults.mcp.auto_start)
      assert.is_table(defaults.mcp.port_range)
      assert.equals(9100, defaults.mcp.port_range[1])
      assert.equals(9199, defaults.mcp.port_range[2])
    end)

    it("has correct default selection settings", function()
      local defaults = config.defaults()

      assert.is_true(defaults.selection.enabled)
      assert.equals(150, defaults.selection.debounce_ms)
    end)
  end)

  describe("setup", function()
    it("returns merged configuration", function()
      local result = config.setup({
        terminal = { provider = "toggleterm" },
      })

      assert.is_table(result)
      assert.equals("toggleterm", result.terminal.provider)
    end)

    it("merges user config with defaults", function()
      config.setup({
        terminal = { provider = "floaterm" },
      })

      local cfg = config.get()

      -- User value should be applied
      assert.equals("floaterm", cfg.terminal.provider)
      -- Default values should still exist
      assert.equals("vertical", cfg.terminal.position)
      assert.equals(0.4, cfg.terminal.width)
    end)

    it("deeply merges nested tables", function()
      config.setup({
        ui = {
          icons = {
            claude = "TEST",
          },
        },
      })

      local cfg = config.get()

      -- User value should be applied
      assert.equals("TEST", cfg.ui.icons.claude)
      -- Other nested defaults should remain
      assert.equals("", cfg.ui.icons.terminal)
      assert.equals("", cfg.ui.icons.diff)
    end)

    it("preserves defaults when setup called with empty table", function()
      config.setup({})

      local cfg = config.get()
      local defaults = config.defaults()

      assert.equals(defaults.terminal.provider, cfg.terminal.provider)
      assert.equals(defaults.mcp.auto_start, cfg.mcp.auto_start)
    end)

    it("preserves defaults when setup called with nil", function()
      config.setup(nil)

      local cfg = config.get()

      assert.equals("native", cfg.terminal.provider)
    end)
  end)

  describe("get", function()
    it("returns full config when no path specified", function()
      config.setup({})
      local cfg = config.get()

      assert.is_table(cfg)
      assert.is_table(cfg.terminal)
      assert.is_table(cfg.mcp)
    end)

    it("returns specific value with dot-path", function()
      config.setup({})

      assert.equals("native", config.get("terminal.provider"))
      assert.equals(0.4, config.get("terminal.width"))
      assert.is_true(config.get("mcp.auto_start"))
    end)

    it("returns nested value with deep path", function()
      config.setup({})

      assert.equals("󰚩", config.get("ui.icons.claude"))
      assert.is_table(config.get("ui.icons.spinner"))
    end)

    it("returns nil for non-existent path", function()
      config.setup({})

      assert.is_nil(config.get("nonexistent"))
      assert.is_nil(config.get("terminal.nonexistent"))
      assert.is_nil(config.get("a.b.c.d"))
    end)

    it("works before setup is called", function()
      -- Don't call setup, just reset
      config.reset()

      local cfg = config.get()
      assert.is_table(cfg)
      assert.equals("native", config.get("terminal.provider"))
    end)
  end)

  describe("validate", function()
    it("passes valid configuration", function()
      local valid, err = config.validate({
        terminal = {
          provider = "native",
          position = "vertical",
          width = 0.5,
          height = 0.3,
        },
      })

      assert.is_true(valid)
      assert.is_nil(err)
    end)

    it("fails on invalid terminal provider", function()
      local valid, err = config.validate({
        terminal = { provider = "invalid" },
      })

      assert.is_false(valid)
      assert.is_string(err)
      assert.matches("provider", err)
    end)

    it("fails on invalid terminal position", function()
      local valid, err = config.validate({
        terminal = { position = "invalid" },
      })

      assert.is_false(valid)
      assert.matches("position", err)
    end)

    it("fails on invalid terminal width", function()
      local valid, err = config.validate({
        terminal = { width = 1.5 },
      })

      assert.is_false(valid)
      assert.matches("width", err)
    end)

    it("fails on negative terminal width", function()
      local valid, err = config.validate({
        terminal = { width = -0.5 },
      })

      assert.is_false(valid)
      assert.matches("width", err)
    end)

    it("fails on invalid port range", function()
      local valid, err = config.validate({
        mcp = { port_range = { 9200, 9100 } }, -- max < min
      })

      assert.is_false(valid)
      assert.matches("port_range", err)
    end)

    it("fails on invalid permission mode", function()
      local valid, err = config.validate({
        claude = { permission_mode = "invalid" },
      })

      assert.is_false(valid)
      assert.matches("permission_mode", err)
    end)

    it("allows nil permission mode", function()
      local valid, err = config.validate({
        claude = { permission_mode = nil },
      })

      assert.is_true(valid)
      assert.is_nil(err)
    end)

    it("fails on invalid diff layout", function()
      local valid, err = config.validate({
        diff = { layout = "diagonal" },
      })

      assert.is_false(valid)
      assert.matches("layout", err)
    end)

    it("fails on invalid log level", function()
      local valid, err = config.validate({
        log_level = "verbose",
      })

      assert.is_false(valid)
      assert.matches("log_level", err)
    end)
  end)

  describe("reset", function()
    it("restores defaults after modification", function()
      config.setup({
        terminal = { provider = "toggleterm" },
      })

      assert.equals("toggleterm", config.get("terminal.provider"))

      config.reset()

      assert.equals("native", config.get("terminal.provider"))
    end)
  end)
end)
