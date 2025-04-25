-- Plugin loader for unreal-nvim
-- For compatibility with traditional plugin managers

-- Prevent loading the plugin multiple times
if vim.g.loaded_unreal_nvim == 1 then
  return
end
vim.g.loaded_unreal_nvim = 1

-- Define user commands
vim.api.nvim_create_user_command("UEBuild", function() require("unreal-nvim").run_build("build") end, {})
vim.api.nvim_create_user_command("UEHeader", function() require("unreal-nvim").run_build("header") end, {})
vim.api.nvim_create_user_command("UECompileCommands", function() require("unreal-nvim").run_build("compile") end, {})
vim.api.nvim_create_user_command("UEClangdConfig", function() require("unreal-nvim").write_clangd_config() end, {})