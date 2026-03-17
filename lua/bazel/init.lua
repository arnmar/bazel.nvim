-- lua/bazel/init.lua
local M = {}

---@class BazelConfig
---@field bazel_cmd       string      Bazel executable (default "bazel")
---@field build_flags     string[]    Extra flags for every build
---@field test_flags      string[]    Extra flags for every test
---@field run_flags       string[]    Extra flags for every run
---@field last_target     string|nil  Most-recently used target
---@field auto_open_qf    boolean     Auto-open quickfix on errors
---@field auto_close_qf   boolean     Auto-close quickfix on success
---@field output_buf_pos  string      "botright" | "topleft" | "float"
---@field float_opts      table       nvim_open_win overrides for float
---@field cache_ttl       number      Target list cache TTL in seconds
---@field keymaps         table<string, string|false>

M.config = {
  bazel_cmd      = "bazel",
  build_flags    = {},
  test_flags     = {},
  run_flags      = {},
  last_target    = nil,
  auto_open_qf   = true,
  auto_close_qf  = false,
  output_buf_pos = "botright",
  float_opts     = {},
  cache_ttl      = 300,
  keymaps = {
    build            = "<leader>bb",
    test             = "<leader>bt",
    run              = "<leader>br",
    clean            = "<leader>bc",
    pick             = "<leader>bp",
    jump_build       = "<leader>bj",
    info             = "<leader>bi",
    output           = "<leader>bo",
    select_config    = "<leader>bC",
    select_platform  = "<leader>bP",
    status           = "<leader>bs",
    compile_commands = "<leader>bm",
    query_tests      = "<leader>bT",
  },
}

---@param opts BazelConfig|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  vim.g.bazel_setup_done = true

  -- Restore last_target from disk if not set by user opts
  if not M.config.last_target then
    local saved = require("bazel.targets").load_last_target()
    if saved then M.config.last_target = saved end
  end

  require("bazel.commands").register()
  require("bazel.keymaps").register(M.config.keymaps)
end

return M
