-- lua/bazel/picker.lua
-- Unified picker: uses telescope when available, falls back to vim.ui.select.
local M = {}

local util = require("bazel.util")

-- Detect telescope once at module load time.
local _has_telescope = pcall(require, "telescope")

--- Open an interactive picker over `items`.
---
--- opts:
---   prompt  string                    Prompt title.
---   format  fun(s: string): string?   How to display each item.
---
--- callback: fun(choice: string|nil)
---@param items string[]
---@param opts {prompt: string, format?: fun(s: string): string}
---@param callback fun(choice: string|nil)
function M.select(items, opts, callback)
  if #items == 0 then
    util.notify("No targets found", vim.log.levels.WARN)
    callback(nil)
    return
  end

  if _has_telescope then
    M._telescope_select(items, opts, callback)
  else
    vim.ui.select(items, {
      prompt = opts.prompt,
      format_item = opts.format or tostring,
    }, callback)
  end
end

---@param items string[]
---@param opts table
---@param callback fun(choice: string|nil)
function M._telescope_select(items, opts, callback)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf    = require("telescope.config").values
  local actions = require("telescope.actions")
  local state   = require("telescope.actions.state")

  pickers.new({}, {
    prompt_title = opts.prompt or "Bazel Targets",
    finder = finders.new_table({
      results = items,
      entry_maker = function(entry)
        return {
          value   = entry,
          display = opts.format and opts.format(entry) or entry,
          ordinal = entry,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = state.get_selected_entry()
        callback(selection and selection.value or nil)
      end)
      map("i", "<C-c>", function()
        actions.close(prompt_bufnr)
        callback(nil)
      end)
      return true
    end,
  }):find()
end

return M
