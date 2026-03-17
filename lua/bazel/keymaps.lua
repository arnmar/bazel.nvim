-- lua/bazel/keymaps.lua
local M = {}

local bindings = {
  build      = { cmd = "BazelBuild",       desc = "Bazel: build last/pick target" },
  test       = { cmd = "BazelTest",        desc = "Bazel: test last/pick target" },
  run        = { cmd = "BazelRun",         desc = "Bazel: run last/pick target" },
  clean      = { cmd = "BazelClean",       desc = "Bazel: clean output tree" },
  pick       = { cmd = "BazelPick",        desc = "Bazel: pick target interactively" },
  jump_build = { cmd = "BazelJumpToBuild", desc = "Bazel: jump to nearest BUILD file" },
  info       = { cmd = "BazelInfo",        desc = "Bazel: show bazel info" },
  output     = { cmd = "BazelOutput",      desc = "Bazel: open output window" },
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
