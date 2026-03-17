-- lua/bazel/workspace.lua
-- Workspace root detection and BUILD file navigation.
local M = {}

-- Sentinels that mark the Bazel workspace root (checked in order).
local WORKSPACE_SENTINELS = { "MODULE.bazel", "WORKSPACE.bazel", "WORKSPACE" }
-- BUILD file names to look for.
local BUILD_FILES = { "BUILD.bazel", "BUILD" }

-- Per-directory workspace root cache: { [dir] = root|false }
local _root_cache = {}

--- Walk upward from `start_dir` until a sentinel file is found.
---@param start_dir string  Absolute directory path
---@return string|nil
local function find_root(start_dir)
  local dir = start_dir
  for _ = 1, 64 do
    for _, sentinel in ipairs(WORKSPACE_SENTINELS) do
      if vim.fn.filereadable(dir .. "/" .. sentinel) == 1 then
        return dir
      end
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then break end -- reached filesystem root
    dir = parent
  end
  return nil
end

--- Return workspace root for the given file path (cached per directory).
---@param file_path string
---@return string|nil
function M.get_root(file_path)
  local dir = vim.fn.fnamemodify(file_path, ":p:h")
  if _root_cache[dir] ~= nil then
    return _root_cache[dir] or nil
  end
  local root = find_root(dir)
  _root_cache[dir] = root or false
  return root
end

--- Find the nearest BUILD or BUILD.bazel file between `start_dir` and `root`.
---@param start_dir string
---@param root string
---@return string|nil
function M.find_build_file(start_dir, root)
  -- Normalise: ensure trailing slash for comparison
  local dir = vim.fn.fnamemodify(start_dir, ":p")
  root = vim.fn.fnamemodify(root, ":p")

  for _ = 1, 64 do
    for _, name in ipairs(BUILD_FILES) do
      local candidate = dir .. name
      if vim.fn.filereadable(candidate) == 1 then
        return candidate
      end
    end
    if dir == root then break end
    local parent = vim.fn.fnamemodify(dir:sub(1, -2), ":h") .. "/"
    if parent == dir then break end
    dir = parent
  end
  return nil
end

--- Parse `build:xxx` config names from .bazelrc in the workspace root.
---@param root string
---@return string[]
function M.get_bazelrc_configs(root)
  local f = io.open(root .. "/.bazelrc", "r")
  if not f then return {} end

  local configs = {}
  local seen = {}
  for line in f:lines() do
    local config = line:match("^build:(%S+)%s")
    if config and not seen[config] then
      seen[config] = true
      table.insert(configs, config)
    end
  end
  f:close()
  return configs
end

return M
