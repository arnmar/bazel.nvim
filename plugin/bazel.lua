-- plugin/bazel.lua
-- Entry point. Guard prevents double-loading.
if vim.g.loaded_bazel then
  return
end
vim.g.loaded_bazel = 1

-- Auto-setup with defaults on VimEnter if the user never calls setup() explicitly.
vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    if not vim.g.bazel_setup_done then
      require("bazel").setup()
    end
  end,
})
