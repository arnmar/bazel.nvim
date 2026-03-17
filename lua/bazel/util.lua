-- lua/bazel/util.lua
-- Shared helpers used across submodules.
local M = {}

local PREFIX = "[bazel] "

---@param msg string
---@param level? number  vim.log.levels constant
function M.notify(msg, level)
  vim.notify(PREFIX .. msg, level or vim.log.levels.INFO)
end

--- Build a flat shell command string from a list of argv parts.
---@param parts string[]
---@return string
function M.build_cmd(parts)
  local escaped = {}
  for _, p in ipairs(parts) do
    table.insert(escaped, vim.fn.shellescape(p))
  end
  return table.concat(escaped, " ")
end

--- Return the path of the currently open file (absolute).
---@return string
function M.current_file()
  return vim.api.nvim_buf_get_name(0)
end

--- Check if bazel is on PATH.
---@param bazel_cmd string
---@return boolean
function M.bazel_available(bazel_cmd)
  return vim.fn.executable(bazel_cmd) == 1
end

--- Trim leading/trailing whitespace.
---@param s string
---@return string
function M.trim(s)
  return s:match("^%s*(.-)%s*$")
end

return M
