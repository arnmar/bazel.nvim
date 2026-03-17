-- lua/bazel/targets.lua
-- Asynchronous target querying with per-workspace in-memory TTL cache.
local M = {}

local util = require("bazel.util")

-- { [workspace_root] = { targets = string[], ts = number, dirty = bool } }
local _cache = {}

local _data_dir     = vim.fn.stdpath("data")
local _persist_path = _data_dir .. "/bazel_nvim_last_target.txt"
local _history_path      = _data_dir .. "/bazel_nvim_history.txt"
local _plat_history_path = _data_dir .. "/bazel_nvim_platform_history.txt"
local _cfg_history_path  = _data_dir .. "/bazel_nvim_config_history.txt"

local HISTORY_MAX = 20

-- In-memory history (most recent first)
local _history      = nil
local _plat_history = nil
local _cfg_history  = nil

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
    "--keep_going",
    "--noshow_progress",
    "--ui_event_filters=-INFO",
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

--- Load build history from file.
--- File format: one entry per line, tab-separated: target\tconfig\tplatform
---@return table[]  list of { target, config, platform } (config/platform may be nil)
local function load_history(path)
  local f = io.open(path, "r")
  if not f then return {} end
  local items = {}
  for line in f:lines() do
    local t = util.trim(line)
    if t ~= "" then
      local parts = vim.split(t, "\t", { plain = true })
      table.insert(items, {
        target   = parts[1] or "",
        config   = (parts[2] and parts[2] ~= "") and parts[2] or nil,
        platform = (parts[3] and parts[3] ~= "") and parts[3] or nil,
      })
    end
  end
  f:close()
  return items
end

--- Save build history to file.
---@param path string
---@param items table[]
local function save_history(path, items)
  local f = io.open(path, "w")
  if not f then return end
  for _, entry in ipairs(items) do
    f:write(table.concat({
      entry.target,
      entry.config   or "",
      entry.platform or "",
    }, "\t") .. "\n")
  end
  f:close()
end

--- Load a simple string list from a file (one entry per line).
---@param path string
---@return string[]
local function load_list(path)
  local f = io.open(path, "r")
  if not f then return {} end
  local items = {}
  for line in f:lines() do
    local t = util.trim(line)
    if t ~= "" then table.insert(items, t) end
  end
  f:close()
  return items
end

--- Save a simple string list to a file.
---@param path string
---@param items string[]
local function save_list(path, items)
  local f = io.open(path, "w")
  if not f then return end
  for _, item in ipairs(items) do f:write(item .. "\n") end
  f:close()
end

--- Push a build entry to history. Deduplicates by target+config+platform.
---@param target string
---@param config string|nil
---@param platform string|nil
function M.push_history(target, config, platform)
  if not _history then _history = load_history(_history_path) end
  -- Remove existing entry with same target+config+platform
  for i, e in ipairs(_history) do
    if e.target == target and e.config == config and e.platform == platform then
      table.remove(_history, i)
      break
    end
  end
  table.insert(_history, 1, { target = target, config = config, platform = platform })
  if #_history > HISTORY_MAX then _history[HISTORY_MAX + 1] = nil end
  save_history(_history_path, _history)
end

--- Return build history (most recent first).
--- Each entry: { target: string, config: string|nil, platform: string|nil }
---@return table[]
function M.get_history()
  if not _history then _history = load_history(_history_path) end
  return _history
end

--- Push a config to config history.
---@param config string
function M.push_config_history(config)
  if not _cfg_history then _cfg_history = load_list(_cfg_history_path) end
  for i, c in ipairs(_cfg_history) do
    if c == config then table.remove(_cfg_history, i); break end
  end
  table.insert(_cfg_history, 1, config)
  if #_cfg_history > HISTORY_MAX then _cfg_history[HISTORY_MAX + 1] = nil end
  save_list(_cfg_history_path, _cfg_history)
end

--- Return the config history (most recent first).
---@return string[]
function M.get_config_history()
  if not _cfg_history then _cfg_history = load_list(_cfg_history_path) end
  return _cfg_history
end

--- Push a platform to platform history.
---@param platform string
function M.push_platform_history(platform)
  if not _plat_history then _plat_history = load_list(_plat_history_path) end
  for i, p in ipairs(_plat_history) do
    if p == platform then table.remove(_plat_history, i); break end
  end
  table.insert(_plat_history, 1, platform)
  if #_plat_history > HISTORY_MAX then _plat_history[HISTORY_MAX + 1] = nil end
  save_list(_plat_history_path, _plat_history)
end

--- Return the platform history (most recent first).
---@return string[]
function M.get_platform_history()
  if not _plat_history then _plat_history = load_list(_plat_history_path) end
  return _plat_history
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
