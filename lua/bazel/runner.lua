-- lua/bazel/runner.lua
-- Async job engine: streams output to a scratch buffer and parses errors
-- into the quickfix list.
local M = {}

local util = require("bazel.util")

-- Single reusable output buffer / window, created lazily.
local _output_buf = nil
local _output_win = nil
local _current_job = nil  -- job id of the running bazel process

--- Get or create the scratch output buffer.
---@return number bufnr
local function get_output_buf()
  if _output_buf and vim.api.nvim_buf_is_valid(_output_buf) then
    return _output_buf
  end
  local buf = vim.api.nvim_create_buf(false, true) -- unlisted, scratch
  vim.api.nvim_buf_set_name(buf, "[Bazel Output]")
  vim.api.nvim_set_option_value("buftype",  "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "hide",  { buf = buf })
  vim.api.nvim_set_option_value("swapfile",  false,   { buf = buf })
  vim.api.nvim_set_option_value("filetype",  "bazel_output", { buf = buf })
  _output_buf = buf
  return buf
end

--- Open (or focus) the output window based on config.
---@param buf number
local function open_output_win(buf)
  local cfg = require("bazel").config

  -- If window is already open and valid, just use it.
  if _output_win and vim.api.nvim_win_is_valid(_output_win) then
    return
  end

  if cfg.output_buf_pos == "float" then
    local width  = math.floor(vim.o.columns * 0.8)
    local height = math.floor(vim.o.lines   * 0.5)
    local row    = math.floor((vim.o.lines   - height) / 2)
    local col    = math.floor((vim.o.columns - width)  / 2)
    local defaults = {
      relative = "editor",
      row = row, col = col,
      width = width, height = height,
      style = "minimal",
      border = "rounded",
      title = " Bazel Output ",
      title_pos = "center",
    }
    _output_win = vim.api.nvim_open_win(
      buf, false,
      vim.tbl_extend("force", defaults, cfg.float_opts or {})
    )
  else
    local pos = cfg.output_buf_pos or "botright"
    vim.cmd(pos .. " sbuffer " .. buf)
    _output_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_height(_output_win, 15)
  end
end

--- Append lines to the output buffer, safely scheduled on the main thread.
---@param buf number
---@param lines string[]
local function append_lines(buf, lines)
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
    -- Auto-scroll if window is open
    if _output_win and vim.api.nvim_win_is_valid(_output_win) then
      local count = vim.api.nvim_buf_line_count(buf)
      vim.api.nvim_win_set_cursor(_output_win, { count, 0 })
    end
  end)
end

--- Parse output lines into quickfix items.
---@param lines string[]
---@param workspace_root string
---@return table[]
local function parse_errors(lines, workspace_root)
  local items = {}

  local function make_abs(path)
    if path:sub(1, 1) == "/" then return path end
    return workspace_root .. "/" .. path
  end

  -- Patterns: { pat, type, has_col }
  -- Captures are always (filename, lnum[, col], text)
  local patterns = {
    -- Bazel BUILD/Starlark errors with col:
    -- ERROR: path/to/BUILD.bazel:12:5: message
    { pat = "^ERROR:%s+(.+%.bazel?):(%d+):(%d+):%s*(.+)$",     type = "E", col = true },
    -- Starlark error without ERROR: prefix, with col:
    -- path/to/BUILD.bazel:5:10: name 'x' is not defined
    { pat = "^(.+%.bazel?):(%d+):(%d+):%s*(.+)$",               type = "E", col = true },
    -- C/C++ error with col
    { pat = "^(.+%.[ch][chpx+]*):(%d+):(%d+):%s*error:%s*(.+)$",   type = "E", col = true },
    -- C/C++ warning with col
    { pat = "^(.+%.[ch][chpx+]*):(%d+):(%d+):%s*warning:%s*(.+)$", type = "W", col = true },
    -- Java / generic error without col
    { pat = "^(.+%.java):(%d+):%s*error:%s*(.+)$",               type = "E", col = false },
    { pat = "^(.+%.java):(%d+):%s*warning:%s*(.+)$",             type = "W", col = false },
    -- Python
    { pat = "^(.+%.py):(%d+):%s*(.+)$",                         type = "E", col = false },
    -- Rust
    { pat = "^(.+%.rs):(%d+):(%d+):%s*error%[.-%]:%s*(.+)$",    type = "E", col = true },
    { pat = "^(.+%.rs):(%d+):(%d+):%s*warning%[.-%]:%s*(.+)$",  type = "W", col = true },
    -- Go
    { pat = "^(.+%.go):(%d+):(%d+):%s*(.+)$",                   type = "E", col = true },
  }

  for _, line in ipairs(lines) do
    -- Strip ANSI escape codes before matching
    local clean = line:gsub("\27%[[%d;]*m", "")
    for _, p in ipairs(patterns) do
      if p.col then
        local f, l, c, txt = clean:match(p.pat)
        if f then
          table.insert(items, {
            filename = make_abs(f),
            lnum     = tonumber(l),
            col      = tonumber(c),
            text     = txt,
            type     = p.type,
          })
          break
        end
      else
        local f, l, txt = clean:match(p.pat)
        if f then
          table.insert(items, {
            filename = make_abs(f),
            lnum     = tonumber(l),
            col      = 0,
            text     = txt,
            type     = p.type,
          })
          break
        end
      end
    end
  end

  return items
end

--- Core job runner.
---
---@param cmd_parts string[]    Argv list: { "bazel", "build", "//foo:bar", ... }
---@param opts table
---  opts.title       string    Quickfix title
---  opts.workspace   string    Workspace root (for absolute paths)
---  opts.show_output boolean?  Default true; set false to hide the output window
---  opts.on_exit     fun(code: number)?
function M.run(cmd_parts, opts)
  opts = opts or {}
  local title     = opts.title     or "Bazel"
  local workspace = opts.workspace or vim.fn.getcwd()
  local cfg       = require("bazel").config

  if not util.bazel_available(cfg.bazel_cmd) then
    util.notify("'" .. cfg.bazel_cmd .. "' not found on PATH", vim.log.levels.ERROR)
    return
  end

  local buf = get_output_buf()

  -- Clear and write header
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "# " .. title,
    "# cmd: " .. table.concat(cmd_parts, " "),
    "",
  })

  -- Open the output window
  if opts.show_output ~= false then
    vim.schedule(function() open_output_win(buf) end)
  end

  -- Clear quickfix for this run
  vim.fn.setqflist({}, "r", { title = title, items = {} })

  local all_lines = {}

  local cmd_str = util.build_cmd(cmd_parts)

  -- Stop any currently running job before starting a new one
  if _current_job and _current_job > 0 then
    vim.fn.jobstop(_current_job)
    _current_job = nil
  end

  local job_id = vim.fn.jobstart(cmd_str, {
    cwd             = workspace,
    stdout_buffered = false,
    stderr_buffered = false,

    on_stdout = function(_, data)
      if not data then return end
      local new = {}
      for _, line in ipairs(data) do
        if line ~= "" then
          table.insert(all_lines, line)
          table.insert(new, line)
        end
      end
      if #new > 0 then append_lines(buf, new) end
    end,

    on_stderr = function(_, data)
      if not data then return end
      local new = {}
      for _, line in ipairs(data) do
        if line ~= "" then
          table.insert(all_lines, line)
          table.insert(new, line)
        end
      end
      if #new > 0 then append_lines(buf, new) end
    end,

    on_exit = function(_, exit_code)
      _current_job = nil
      vim.schedule(function()
        local qf_items = parse_errors(all_lines, workspace)

        vim.fn.setqflist({}, "r", { title = title, items = qf_items })

        local error_count = 0
        for _, item in ipairs(qf_items) do
          if item.type == "E" then error_count = error_count + 1 end
        end

        if exit_code == 0 then
          util.notify(title .. ": SUCCESS", vim.log.levels.INFO)
          require("bazel.targets").invalidate(workspace)
          if cfg.auto_close_qf and error_count == 0 then
            vim.cmd("cclose")
          end
        else
          util.notify(
            string.format("%s: FAILED (exit %d, %d error(s))", title, exit_code, error_count),
            vim.log.levels.ERROR
          )
          if cfg.auto_open_qf then
            vim.cmd("copen")
            if error_count > 0 then vim.cmd("cfirst") end
          end
        end

        if opts.on_exit then opts.on_exit(exit_code) end
      end)
    end,
  })

  if job_id <= 0 then
    util.notify("Failed to start: " .. cmd_str, vim.log.levels.ERROR)
  else
    _current_job = job_id
  end
end

--- Stop the currently running bazel job, if any.
function M.stop()
  if _current_job and _current_job > 0 then
    vim.fn.jobstop(_current_job)
    _current_job = nil
    util.notify("Build stopped", vim.log.levels.WARN)
  else
    util.notify("No build running", vim.log.levels.INFO)
  end
end

--- Return true if a job is currently running.
function M.is_running()
  return _current_job ~= nil and _current_job > 0
end

--- Open the output window without starting a job (useful for reviewing last output).
function M.open_output()
  local buf = get_output_buf()
  open_output_win(buf)
end

return M
