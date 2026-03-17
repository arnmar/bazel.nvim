-- lua/bazel/targets.lua
-- Asynchronous target querying with per-workspace in-memory TTL cache.
local M = {}

local util = require("bazel.util")

-- { [workspace_root] = { targets = string[], ts = number, dirty = bool } }
local _cache = {}

-- Path for persisting the last used target across sessions.
local _persist_path = vim.fn.stdpath("data") .. "/bazel_nvim_last_target.txt"

--- Return cached targets for `root` if still valid, else nil.
---@param root string
---@return string[]|nil
local function get_cached(root)
  local entry = _cache[root]
  if not entry or entry.dirty then return nil end
  local cfg = require("bazel").config
  if (vim.loop.now() / 1000) - entry.ts > (cfg.cache_ttl or 300) then return nil end
  return entry.targets
end

---@param root string
---@param targets string[]
local function set_cache(root, targets)
  _cache[root] = { targets = targets, ts = vim.loop.now() / 1000, dirty = false }
end

--- Mark the cache for `root` as dirty (triggers re-fetch on next query).
---@param root string
function M.invalidate(root)
  if _cache[root] then
    _cache[root].dirty = true
  end
end

--- Asynchronously fetch all targets under `root`.
--- Calls `callback(targets, err)` when done.
---@param root string
---@param callback fun(targets: string[], err: string|nil)
function M.fetch(root, callback)
  local cached = get_cached(root)
  if cached then
    callback(cached, nil)
    return
  end

  local cfg = require("bazel").config
  local cmd = {
    cfg.bazel_cmd or "bazel",
    "query",
    "//...",
  }

  local lines = {}
  local stderr_lines = {}

  vim.fn.jobstart(cmd, {
    cwd = root,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      if not data then return end
      for _, line in ipairs(data) do
        local t = util.trim(line)
        if t ~= "" and t:sub(1, 2) == "//" then
          table.insert(lines, t)
        end
      end
    end,
    on_stderr = function(_, data)
      if not data then return end
      for _, line in ipairs(data) do
        if line ~= "" then table.insert(stderr_lines, line) end
      end
    end,
    on_exit = function(_, code)
      if #lines > 0 then
        table.sort(lines)
        set_cache(root, lines)
        callback(lines, nil)
      else
        local err = "bazel query returned no targets (exit " .. code .. ")"
        if #stderr_lines > 0 then
          -- Show first meaningful stderr line for diagnosis
          for _, l in ipairs(stderr_lines) do
            if l:find("ERROR") or l:find("error") then
              err = err .. ": " .. l
              break
            end
          end
        end
        callback({}, err)
      end
    end,
  })
end

--- Save last_target to disk.
---@param target string
function M.save_last_target(target)
  local f = io.open(_persist_path, "w")
  if f then
    f:write(target)
    f:close()
  end
end

--- Load last_target from disk.
---@return string|nil
function M.load_last_target()
  local f = io.open(_persist_path, "r")
  if not f then return nil end
  local val = util.trim(f:read("*a") or "")
  f:close()
  return val ~= "" and val or nil
end

return M
