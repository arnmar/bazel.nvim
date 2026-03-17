-- lua/bazel/state.lua
-- Persistent build state: selected config and platform.
-- Applied to all build/test/run invocations until cleared.
local M = {}

local _config   = nil  -- e.g. "debug", "debug-asan"
local _platform = nil  -- e.g. "//platforms:linux"

function M.get_config()   return _config   end
function M.get_platform() return _platform end

function M.set_config(c)   _config   = c end
function M.set_platform(p) _platform = p end

function M.reset()
  _config   = nil
  _platform = nil
end

--- Flags to inject into bazel invocations based on current state.
---@return string[]
function M.get_flags()
  local flags = {}
  if _config   then table.insert(flags, "--config="    .. _config)   end
  if _platform then table.insert(flags, "--platforms=" .. _platform) end
  return flags
end

--- Short description of current state for display.
---@return string
function M.describe()
  local parts = {}
  if _config   then table.insert(parts, "config:"   .. _config)   end
  if _platform then table.insert(parts, "platform:" .. _platform) end
  return #parts > 0 and table.concat(parts, "  ") or "default"
end

return M
