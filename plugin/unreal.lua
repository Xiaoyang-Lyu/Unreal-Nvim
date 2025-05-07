---@diagnostic disable: undefined-global

-- Plugin loader for unreal-nvim
-- For compatibility with traditional plugin managers

-- Prevent loading the plugin multiple times
if vim.g.loaded_unreal_nvim == 1 then
  return
end
vim.g.loaded_unreal_nvim = 1

local unreal = require('unreal-nvim')
unreal.setup {
  engine_path = vim.g.unreal_nvim_engine_path,
  auto_register_clangd = vim.g.unreal_nvim_auto_register_clangd,
}