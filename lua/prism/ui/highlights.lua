--- prism.nvim highlight groups
--- @module prism.ui.highlights

local M = {}

--- Default highlight definitions
--- @type table<string, table>
local highlight_defs = {
  -- Base UI elements
  PrismBorder = { link = "FloatBorder" },
  PrismTitle = { link = "Title", bold = true },
  PrismNormal = { link = "NormalFloat" },
  PrismCursorLine = { link = "CursorLine" },
  PrismSelection = { link = "Visual" },

  -- Diff highlights
  PrismDiffAdd = { link = "DiffAdd" },
  PrismDiffDelete = { link = "DiffDelete" },
  PrismDiffChange = { link = "DiffChange" },
  PrismDiffText = { link = "DiffText" },
  PrismDiffAddSign = { fg = "#98c379", bold = true },
  PrismDiffDeleteSign = { fg = "#e06c75", bold = true },
  PrismDiffChangeSign = { fg = "#e5c07b", bold = true },

  -- Cost indicator colors
  PrismCostLow = { fg = "#98c379" }, -- Green - cheap
  PrismCostMed = { fg = "#e5c07b" }, -- Yellow - moderate
  PrismCostHigh = { fg = "#e06c75" }, -- Red - expensive

  -- Status indicators
  PrismStatusConnected = { fg = "#98c379", bold = true },
  PrismStatusDisconnected = { fg = "#e06c75", bold = true },
  PrismStatusPending = { fg = "#e5c07b", italic = true },
  PrismStatusProcessing = { fg = "#61afef", italic = true },

  -- Icons and labels
  PrismActionIcon = { fg = "#61afef" },
  PrismModelName = { fg = "#c678dd", bold = true },
  PrismSessionName = { fg = "#56b6c2" },

  -- Chat highlights
  PrismChatUser = { fg = "#98c379", bold = true },
  PrismChatAssistant = { fg = "#61afef", bold = true },
  PrismChatSystem = { fg = "#abb2bf", italic = true },
  PrismChatError = { fg = "#e06c75", bold = true },
  PrismChatCode = { link = "Comment" },

  -- Palette highlights
  PrismPaletteIcon = { fg = "#c678dd" },
  PrismPaletteLabel = { link = "Normal" },
  PrismPaletteHint = { link = "Comment" },
  PrismPaletteMatch = { fg = "#e5c07b", bold = true },

  -- Model picker
  PrismModelOpus = { fg = "#c678dd", bold = true },
  PrismModelSonnet = { fg = "#61afef", bold = true },
  PrismModelHaiku = { fg = "#56b6c2", bold = true },
  PrismModelCost = { fg = "#abb2bf", italic = true },

  -- Special elements
  PrismSpinner = { fg = "#61afef" },
  PrismKeyHint = { fg = "#5c6370", italic = true },
  PrismSeparator = { fg = "#3e4452" },
  PrismMuted = { fg = "#5c6370" },
}

--- Setup highlight groups
--- @param user_highlights table|nil User highlight overrides
function M.setup(user_highlights)
  user_highlights = user_highlights or {}

  -- Merge user highlights with defaults
  local highlights = vim.tbl_deep_extend("force", highlight_defs, user_highlights)

  -- Create highlight groups
  for name, def in pairs(highlights) do
    -- Handle linked highlights
    if def.link then
      vim.api.nvim_set_hl(0, name, { link = def.link })
    else
      -- Ensure we have valid highlight attributes
      local hl = {}
      if def.fg then hl.fg = def.fg end
      if def.bg then hl.bg = def.bg end
      if def.sp then hl.sp = def.sp end
      if def.bold then hl.bold = def.bold end
      if def.italic then hl.italic = def.italic end
      if def.underline then hl.underline = def.underline end
      if def.undercurl then hl.undercurl = def.undercurl end
      if def.strikethrough then hl.strikethrough = def.strikethrough end
      if def.reverse then hl.reverse = def.reverse end
      if def.nocombine then hl.nocombine = def.nocombine end

      vim.api.nvim_set_hl(0, name, hl)
    end
  end
end

--- Get a highlight group name
--- @param name string Short name (without Prism prefix)
--- @return string Full highlight group name
function M.get(name)
  return "Prism" .. name
end

--- Get all highlight definitions
--- @return table<string, table>
function M.list()
  return vim.deepcopy(highlight_defs)
end

return M
