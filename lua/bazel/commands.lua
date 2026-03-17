-- lua/bazel/commands.lua
-- All :Bazel* user commands.
local M = {}

local util      = require("bazel.util")
local runner    = require("bazel.runner")
local targets   = require("bazel.targets")
local picker    = require("bazel.picker")
local workspace = require("bazel.workspace")
local state     = require("bazel.state")

local function cfg() return require("bazel").config end

--- Resolve workspace root with a user-friendly error on failure.
---@return string|nil
local function require_workspace()
  local file = util.current_file()
  local start = file ~= "" and file or vim.fn.getcwd()
  local root = workspace.get_root(start)
  if not root then
    util.notify(
      "Could not find workspace root (no WORKSPACE/MODULE.bazel above current file)",
      vim.log.levels.ERROR
    )
  end
  return root
end

--- Build and run a bazel sub-command for a concrete target.
--- State flags (config, platform) are injected automatically.
---@param subcmd string
---@param target string
---@param extra_flags string[]
local function run_target(subcmd, target, extra_flags)
  local c = cfg()
  local root = require_workspace()
  if not root then return end

  c.last_target = target
  targets.save_last_target(target)
  targets.push_history(target)

  -- State flags come first so .bazelrc can still be overridden by extra_flags
  local cmd_parts = { c.bazel_cmd, subcmd }
  vim.list_extend(cmd_parts, state.get_flags())
  for _, f in ipairs(extra_flags or {}) do table.insert(cmd_parts, f) end
  table.insert(cmd_parts, target)

  local desc = state.describe()
  local title = "Bazel " .. subcmd .. " " .. target
  if desc ~= "default" then title = title .. "  [" .. desc .. "]" end

  runner.run(cmd_parts, {
    title     = title,
    workspace = root,
  })
end

--- Open the picker over `items`, with history entries bubbled to the top.
---@param items string[]
---@param prompt string
---@param callback fun(choice: string)
local function pick_with_history(items, prompt, callback)
  local history = targets.get_history()
  local seen = {}
  local sorted = {}

  -- History first (most recent first), deduplicated
  for _, t in ipairs(history) do
    if not seen[t] then
      seen[t] = true
      table.insert(sorted, t)
    end
  end
  -- Then remaining items
  for _, t in ipairs(items) do
    if not seen[t] then
      seen[t] = true
      table.insert(sorted, t)
    end
  end

  local history_set = {}
  for _, t in ipairs(history) do history_set[t] = true end

  picker.select(sorted, {
    prompt = prompt,
    format = function(t)
      return history_set[t] and ("» " .. t) or t
    end,
  }, callback)
end

--- Fetch targets and open picker, then call `action(target)`.
---@param prompt string
---@param action fun(target: string)
local function pick_then(prompt, action)
  local root = require_workspace()
  if not root then return end

  -- If we have history, show picker immediately with history while fetching
  local history = targets.get_history()
  if #history > 0 then
    util.notify("Fetching targets… (history available)")
  else
    util.notify("Fetching targets…")
  end

  targets.fetch(root, function(target_list, err)
    if err then util.notify("Query warning: " .. err, vim.log.levels.WARN) end

    -- Merge history with fetched targets (history may contain targets not in //...)
    local all = #target_list > 0 and target_list or history
    if #all == 0 then
      util.notify("No targets found in workspace", vim.log.levels.ERROR)
      return
    end

    vim.schedule(function()
      pick_with_history(all, prompt, function(choice)
        if choice then action(choice) end
      end)
    end)
  end)
end

--- Split a raw args string into argv parts.
---@param args string
---@return string[]
local function split_args(args)
  local parts = {}
  for part in (args or ""):gmatch("%S+") do
    table.insert(parts, part)
  end
  return parts
end

-- ─── Command handlers ────────────────────────────────────────────────────────

local function cmd_build(opts)
  local c = cfg()
  local args = split_args(opts.args)
  if #args == 0 then
    pick_then("BazelBuild › select target", function(t)
      run_target("build", t, c.build_flags)
    end)
  else
    local target = args[1]
    local extra  = vim.list_slice(args, 2)
    vim.list_extend(extra, c.build_flags)
    run_target("build", target, extra)
  end
end

local function cmd_test(opts)
  local c = cfg()
  local args = split_args(opts.args)
  if #args == 0 then
    pick_then("BazelTest › select target", function(t)
      run_target("test", t, c.test_flags)
    end)
  else
    local target = args[1]
    local extra  = vim.list_slice(args, 2)
    vim.list_extend(extra, c.test_flags)
    run_target("test", target, extra)
  end
end

local function cmd_run(opts)
  local c = cfg()
  local args = split_args(opts.args)
  if #args == 0 then
    pick_then("BazelRun › select target", function(t)
      run_target("run", t, c.run_flags)
    end)
  else
    local target = args[1]
    local extra  = vim.list_slice(args, 2)
    vim.list_extend(extra, c.run_flags)
    run_target("run", target, extra)
  end
end

local function cmd_clean(opts)
  local c = cfg()
  local root = require_workspace()
  if not root then return end

  local args = split_args(opts.args)
  local cmd_parts = { c.bazel_cmd, "clean" }
  vim.list_extend(cmd_parts, args)

  runner.run(cmd_parts, {
    title     = "Bazel clean",
    workspace = root,
    on_exit   = function(code)
      if code == 0 then targets.invalidate(root) end
    end,
  })
end

local function cmd_query(opts)
  local c = cfg()
  local root = require_workspace()
  if not root then return end

  local expr = util.trim(opts.args or "")
  if expr == "" then
    util.notify("Usage: BazelQuery <query-expression>", vim.log.levels.WARN)
    return
  end

  runner.run({ c.bazel_cmd, "query", expr }, {
    title     = "Bazel query: " .. expr,
    workspace = root,
  })
end

--- BazelQueryTests — shortcut for `bazel query 'tests(//...)'`
local function cmd_query_tests()
  local c = cfg()
  local root = require_workspace()
  if not root then return end
  runner.run({ c.bazel_cmd, "query", "tests(//...)" }, {
    title     = "Bazel query: tests",
    workspace = root,
  })
end

local function cmd_info(opts)
  local c = cfg()
  local root = require_workspace()
  if not root then return end

  local args = split_args(opts.args)
  local cmd_parts = { c.bazel_cmd, "info" }
  vim.list_extend(cmd_parts, args)

  local lines = {}
  local cmd_str = util.build_cmd(cmd_parts)

  vim.fn.jobstart(cmd_str, {
    cwd             = root,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, l in ipairs(data) do
          if l ~= "" then table.insert(lines, l) end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, l in ipairs(data) do
          if l ~= "" then table.insert(lines, l) end
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if #lines == 0 then
          util.notify("bazel info returned no output (exit " .. code .. ")", vim.log.levels.WARN)
          return
        end

        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
        vim.api.nvim_set_option_value("filetype", "bazel_info", { buf = buf })

        local width  = math.min(math.floor(vim.o.columns * 0.7), 120)
        local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.5))
        local row    = math.floor((vim.o.lines   - height) / 2)
        local col    = math.floor((vim.o.columns - width)  / 2)

        local win = vim.api.nvim_open_win(buf, true, {
          relative  = "editor",
          row = row, col = col,
          width = width, height = height,
          style  = "minimal",
          border = "rounded",
          title  = " bazel info ",
          title_pos = "center",
        })

        local function close()
          if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
          end
        end
        vim.keymap.set("n", "q",     close, { buffer = buf, nowait = true, silent = true })
        vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true, silent = true })
      end)
    end,
  })
end

local function cmd_jump_to_build()
  local file = util.current_file()
  if file == "" then
    util.notify("No file in current buffer", vim.log.levels.WARN)
    return
  end

  local root = workspace.get_root(file)
  if not root then
    util.notify("Could not find workspace root", vim.log.levels.ERROR)
    return
  end

  local start_dir = vim.fn.fnamemodify(file, ":p:h")
  local build_file = workspace.find_build_file(start_dir, root)

  if not build_file then
    util.notify(
      "No BUILD or BUILD.bazel found between " .. start_dir .. " and " .. root,
      vim.log.levels.WARN
    )
    return
  end

  vim.cmd("edit " .. vim.fn.fnameescape(build_file))
end

local function cmd_pick(opts)
  local c = cfg()
  local subcmd = util.trim(opts.args or "")
  local valid  = { build = true, test = true, run = true }

  if subcmd ~= "" and not valid[subcmd] then
    util.notify("BazelPick accepts: build, test, run (or no argument)", vim.log.levels.WARN)
    return
  end

  local prompt = subcmd ~= ""
    and ("BazelPick › " .. subcmd .. ":")
    or  "BazelPick › select target:"

  pick_then(prompt, function(target)
    c.last_target = target
    targets.save_last_target(target)
    targets.push_history(target)
    util.notify("Selected: " .. target)
    if subcmd == "build" then
      run_target("build", target, c.build_flags)
    elseif subcmd == "test" then
      run_target("test",  target, c.test_flags)
    elseif subcmd == "run" then
      run_target("run",   target, c.run_flags)
    end
  end)
end

--- BazelSelectConfig — pick a build config from .bazelrc
local function cmd_select_config()
  local root = require_workspace()
  if not root then return end

  local configs = workspace.get_bazelrc_configs(root)
  if #configs == 0 then
    util.notify("No configs found in .bazelrc", vim.log.levels.WARN)
    return
  end

  table.insert(configs, 1, "(none — clear config)")

  picker.select(configs, { prompt = "BazelSelectConfig:" }, function(choice)
    if not choice then return end
    if choice == "(none — clear config)" then
      state.set_config(nil)
      util.notify("Build config cleared")
    else
      state.set_config(choice)
      util.notify("Build config: " .. choice)
    end
  end)
end

--- BazelSelectPlatform — pick a platform via bazel query
local function cmd_select_platform()
  local c = cfg()
  local root = require_workspace()
  if not root then return end

  local platform_history = targets.get_platform_history()

  local lines = {}
  vim.fn.jobstart({ c.bazel_cmd, "query", "kind(platform, //platforms/...)" }, {
    cwd = root,
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          local t = util.trim(line)
          if t ~= "" then table.insert(lines, t) end
        end
      end
    end,
    on_exit = function(_, _)
      vim.schedule(function()
        local all = vim.deepcopy(lines)
        -- Merge platform history (may have entries not in //platforms/...)
        local seen = {}
        for _, p in ipairs(all) do seen[p] = true end
        for _, p in ipairs(platform_history) do
          if not seen[p] then table.insert(all, p) end
        end

        if #all == 0 then
          util.notify("No platforms found", vim.log.levels.WARN)
          return
        end

        table.insert(all, 1, "(none — clear platform)")

        local hist_set = {}
        for _, p in ipairs(platform_history) do hist_set[p] = true end

        picker.select(all, {
          prompt = "BazelSelectPlatform:",
          format = function(p)
            return hist_set[p] and ("» " .. p) or p
          end,
        }, function(choice)
          if not choice then return end
          if choice == "(none — clear platform)" then
            state.set_platform(nil)
            util.notify("Platform cleared")
          else
            state.set_platform(choice)
            targets.push_platform_history(choice)
            util.notify("Platform: " .. choice)
          end
        end)
      end)
    end,
  })
end

--- BazelStatus — show current state
local function cmd_status()
  local c = cfg()
  local lines = {
    "State:       " .. state.describe(),
    "Last target: " .. (c.last_target or "(none)"),
    "Bazel cmd:   " .. c.bazel_cmd,
  }
  local history = targets.get_history()
  if #history > 0 then
    table.insert(lines, "History:     " .. table.concat(history, ", "))
  end
  util.notify(table.concat(lines, "\n"))
end

--- BazelCompileCommands [platform] — run //compile_commands:refresh_<platform>
local function cmd_compile_commands(opts)
  local c = cfg()
  local root = require_workspace()
  if not root then return end

  local arg = util.trim(opts.args or "")
  if arg ~= "" then
    runner.run({ c.bazel_cmd, "run", "//compile_commands:refresh_" .. arg }, {
      title     = "Bazel compile_commands:" .. arg,
      workspace = root,
    })
    return
  end

  -- Query available refresh targets
  vim.fn.jobstart(
    { c.bazel_cmd, "query", "//compile_commands/..." },
    {
      cwd = root,
      stdout_buffered = true,
      on_stdout = function(_, data)
        -- handled in on_exit via closure
        if data then
          for _, line in ipairs(data) do
            local t = util.trim(line)
            if t ~= "" and t:find(":refresh_") then
              -- stored below
            end
          end
        end
      end,
      on_exit = function(_, _) end,
    }
  )

  -- Simpler: just collect synchronously via a buffered job
  local refresh_targets = {}
  vim.fn.jobstart({ c.bazel_cmd, "query", "//compile_commands/..." }, {
    cwd             = root,
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          local t = util.trim(line)
          if t ~= "" and t:find(":refresh") then
            table.insert(refresh_targets, t)
          end
        end
      end
    end,
    on_exit = function(_, _)
      vim.schedule(function()
        if #refresh_targets == 0 then
          util.notify("No //compile_commands:refresh_* targets found", vim.log.levels.WARN)
          return
        end
        picker.select(refresh_targets, { prompt = "BazelCompileCommands:" }, function(choice)
          if choice then
            runner.run({ c.bazel_cmd, "run", choice }, {
              title     = "Bazel " .. choice,
              workspace = root,
            })
          end
        end)
      end)
    end,
  })
end

local function cmd_output()
  runner.open_output()
end

-- ─── Registration ─────────────────────────────────────────────────────────────

function M.register()
  local function def(name, fn, desc, has_args)
    vim.api.nvim_create_user_command(name, fn, {
      desc  = desc,
      nargs = has_args and "*" or 0,
    })
  end

  def("BazelBuild",           cmd_build,            "Build a Bazel target",                     true)
  def("BazelTest",            cmd_test,             "Test a Bazel target",                      true)
  def("BazelRun",             cmd_run,              "Run a Bazel target",                       true)
  def("BazelClean",           cmd_clean,            "Clean the Bazel output tree",              true)
  def("BazelQuery",           cmd_query,            "Run a bazel query expression",             true)
  def("BazelQueryTests",      cmd_query_tests,      "Query all test targets",                   false)
  def("BazelInfo",            cmd_info,             "Show bazel info",                          true)
  def("BazelJumpToBuild",     cmd_jump_to_build,    "Jump to nearest BUILD file",               false)
  def("BazelPick",            cmd_pick,             "Interactively pick a Bazel target",        true)
  def("BazelSelectConfig",    cmd_select_config,    "Select build config from .bazelrc",        false)
  def("BazelSelectPlatform",  cmd_select_platform,  "Select target platform",                   false)
  def("BazelStatus",          cmd_status,           "Show current Bazel state",                 false)
  def("BazelCompileCommands", cmd_compile_commands, "Run compile_commands refresh",             true)
  def("BazelOutput",          cmd_output,           "Open the Bazel output window",             false)
end

return M
