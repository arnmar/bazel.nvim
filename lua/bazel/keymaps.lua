-- lua/bazel/keymaps.lua
local M = {}

local bindings = {
  build            = { cmd = "BazelBuild",           desc = "Bazel: build target" },
  test             = { cmd = "BazelTest",            desc = "Bazel: test target" },
  run              = { cmd = "BazelRun",             desc = "Bazel: run target" },
  clean            = { cmd = "BazelClean",           desc = "Bazel: clean output tree" },
  pick             = { cmd = "BazelPick",            desc = "Bazel: pick target" },
  jump_build       = { cmd = "BazelJumpToBuild",     desc = "Bazel: jump to BUILD file" },
  info             = { cmd = "BazelInfo",            desc = "Bazel: show bazel info" },
  output           = { cmd = "BazelOutput",          desc = "Bazel: open output window" },
  select_config    = { cmd = "BazelSelectConfig",    desc = "Bazel: select build config" },
  select_platform  = { cmd = "BazelSelectPlatform",  desc = "Bazel: select platform" },
  status           = { cmd = "BazelStatus",          desc = "Bazel: show current state" },
  compile_commands = { cmd = "BazelCompileCommands", desc = "Bazel: refresh compile_commands" },
  query_tests      = { cmd = "BazelQueryTests",      desc = "Bazel: query test targets" },
  stop             = { cmd = "BazelStop",            desc = "Bazel: stop running job" },
}

---@param maps table<string, string|false>
function M.register(maps)
  local opts = { noremap = true, silent = true }
  for key, spec in pairs(bindings) do
    local lhs = maps[key]
    if lhs and lhs ~= false then
      vim.keymap.set("n", lhs,
        "<cmd>" .. spec.cmd .. "<cr>",
        vim.tbl_extend("force", opts, { desc = spec.desc })
      )
    end
  end
end

return M
