---@diagnostic disable: undefined-global

local UE = {}

-- Configuration defaults
local config = {
	engine_path = nil,
	auto_register_clangd = false,
}
local cached_engine_root = nil

-- Supported modes and build configurations
local MODES = { BUILD = "build", HEADER = "header", COMPILE = "compile" }
local CONFIGS = { "DebugGame", "Development", "Shipping", "Debug", "Test" }

-- Search upwards for a matching file pattern
local function find_in_parents(start_dir, pattern)
	local dir = vim.loop.fs_realpath(start_dir or vim.fn.getcwd()) or vim.fn.getcwd()
	while dir and dir ~= "" do
		local matches = vim.fn.glob(dir .. "/" .. pattern, false, true)
		if #matches > 0 then
			return matches[1]
		end
		local parent = vim.fn.fnamemodify(dir, ":h")
		if parent == dir then
			break
		end
		dir = parent
	end
	return nil
end

-- Locate .uproject file
local function find_uproject()
	return find_in_parents(nil, "*.uproject")
end

-- Locate Unreal Engine root via /Engine/Source directory
local function find_engine_root()
	local dir = vim.loop.fs_realpath(vim.fn.getcwd()) or vim.fn.getcwd()
	local sep = package.config:sub(1, 1)
	local drive_root = dir:match("^%a:[/\\]$")
	while dir and dir ~= "" do
		-- Normalize slashes
		dir = dir:gsub("[/\\]+$", "")
		local test_path = dir .. sep .. "Engine" .. sep .. "Source"
		if vim.loop.fs_stat(test_path) then
			return dir
		end
		local parent = vim.fn.fnamemodify(dir, ":h")
		if parent == dir or drive_root then
			break
		end
		dir = parent
		drive_root = dir:match("^%a:[/\\]$")
	end
	return nil
end

local function is_valid_engine_path(path)
	return path and vim.loop.fs_stat(path .. "/Engine/Build/BatchFiles") ~= nil
end

-- Save engine path to cache and optionally to .ueinfo file
local function save_engine_path(path, uproj)
	cached_engine_root = path

	-- Save to .ueinfo if we have a project file
	if uproj then
		local info_path = vim.fn.fnamemodify(uproj, ":h") .. "/.ueinfo"
		local fd = io.open(info_path, "w")
		if fd then
			fd:write("UEPath=" .. path)
			fd:close()
			vim.notify("[Unreal] Saved engine path to .ueinfo", vim.log.levels.INFO)
		end
	end

	return path
end

-- Get and cache engine root, optionally save to .ueinfo
local function get_engine_root(callback)
	-- Check explicit 'engine_path' in config or cache
	if config.engine_path and is_valid_engine_path(config.engine_path) then
		return callback(config.engine_path)
	elseif cached_engine_root then
		return callback(cached_engine_root)
	end

	local uproj = find_uproject() or nil

	-- Project-specific lookup via .ueinfo
	if uproj then
		local info = vim.fn.fnamemodify(uproj, ":h") .. "/.ueinfo"
		local fd = io.open(info, "r")
		if fd then
			local path = fd:read("*l"):match("^UEPath=(.+)")
			fd:close()
			if is_valid_engine_path(path) then
				cached_engine_root = path
				-- No need to save .ueinfo again.
				return callback(path)
			end
		end
	end

	-- Check UE_ENGINE_PATH environment variable
	local env_path = os.getenv("UE_ENGINE_PATH")
	if is_valid_engine_path(env_path) then
		save_engine_path(env_path, uproj)
		return callback(env_path)
	end

	-- Locate engine root by searching parent dirs
	local root = find_engine_root()
	if is_valid_engine_path(root) then
		save_engine_path(root, uproj)
		return callback(root)
	end

	-- Prompt user for engine path
	vim.ui.input({ prompt = "Enter Unreal Engine path:" }, function(input)
		if not input or input == "" then
			vim.notify("[Unreal] Engine path selection cancelled.", vim.log.levels.WARN)
			return callback(nil)
		end
		local real = vim.loop.fs_realpath(input)
		if is_valid_engine_path(real) then
			save_engine_path(real, uproj)
			return callback(real)
		end
		vim.notify("[Unreal] Invalid engine path: " .. input, vim.log.levels.ERROR)
		return callback(nil)
	end)
end

-- Construct UnrealBuildTool command
local function make_ubt_cmd(mode, uproj, target, plat, conf, eng_root)
	local is_win = vim.fn.has("win32") == 1
	local script = eng_root
		.. (
			is_win and "/Engine/Build/BatchFiles/Build.bat"
			or (
				vim.loop.os_uname().sysname == "Darwin" and "/Engine/Build/BatchFiles/Mac/Build.sh"
				or "/Engine/Build/BatchFiles/Linux/Build.sh"
			)
		)
	local parts = { vim.fn.shellescape(script), target, plat, conf }
	if uproj then
		table.insert(parts, (is_win and "-Project=" or "-project=") .. vim.fn.shellescape(uproj))
	end
	if mode == MODES.HEADER then
		table.insert(parts, "-SkipBuild")
	elseif mode == MODES.COMPILE then
		local outdir
		if uproj then
			outdir = vim.fn.fnamemodify(uproj, ":p:h") -- Get directory containing .uproject
		else
			outdir = eng_root -- Use engine root directly
		end
		vim.list_extend(parts, {
			"-Mode=GenerateClangDatabase",
			"-OutputDir=" .. vim.fn.shellescape(outdir),
			"-game",
			"-engine",
			"-NoHotReload",
		})
	end
	return table.concat(parts, " ")
end

-- Build output window
local function ensure_output_window()
	if UE.win and vim.api.nvim_win_is_valid(UE.win) then
		vim.api.nvim_buf_set_lines(UE.buf, 0, -1, false, {})
		return
	end
	UE.buf = vim.api.nvim_create_buf(false, true)
	UE.win = vim.api.nvim_open_win(UE.buf, true, {
		relative = "editor",
		width = math.floor(vim.o.columns * 0.8),
		height = math.floor(vim.o.lines * 0.6),
		row = math.floor((vim.o.lines - vim.o.lines * 0.6) / 2),
		col = math.floor((vim.o.columns - vim.o.columns * 0.8) / 2),
		style = "minimal",
		border = "single",
	})
end

local function append_output(lines)
	if not (UE.buf and vim.api.nvim_buf_is_valid(UE.buf)) then
		return
	end
	-- strip Windows CR (shows as ^M) from each line
	for i, l in ipairs(lines) do
		lines[i] = l:gsub("\r$", "")
	end
	vim.api.nvim_buf_set_lines(UE.buf, -1, -1, false, lines)
	if UE.win and vim.api.nvim_win_is_valid(UE.win) then
		vim.api.nvim_win_set_cursor(UE.win, { vim.api.nvim_buf_line_count(UE.buf), 0 })
	end
end

-- Invoke UnrealBuildTool
local function run_ubt(scope, mode)
	local uproj = (scope == "Project") and find_uproject() or nil
	if scope == "Project" and not uproj then
		return vim.notify("[Unreal][Project] .uproject not found", vim.log.levels.ERROR)
	end

	get_engine_root(function(root)
		if not root then
			return vim.notify(string.format("[Unreal][%s] engine path missing", scope), vim.log.levels.ERROR)
		end
		local base = (scope == "Project") and vim.fn.fnamemodify(uproj, ":h") or root
		local pat = (scope == "Project") and "/Source/*.Target.cs" or "/Engine/Source/**/*.Target.cs"
		local files = vim.fn.glob(base .. pat, true, true)
		local targets = {}
		for _, f in ipairs(files) do
			local name = vim.fn.fnamemodify(f, ":t:r"):gsub("%.Target$", "")
			table.insert(targets, name)
		end
		if #targets == 0 then
			local d = vim.fn.fnamemodify(uproj or root, ":t:r")
			targets = { d .. (scope == "Project" and "Editor" or "") }
			vim.notify(string.format("[Unreal][%s] defaulting to %s", scope, targets[1]), vim.log.levels.WARN)
		end

		local plat = vim.fn.has("win32") == 1 and "Win64"
			or (vim.loop.os_uname().sysname == "Darwin" and "Mac" or "Linux")
		vim.notify(string.format("[Unreal][%s] platform: %s", scope, plat), vim.log.levels.INFO)

		vim.ui.select(targets, { prompt = "Target (" .. scope .. "):" }, function(t)
			if not t then
				return
			end
			vim.ui.select(CONFIGS, { prompt = "Configuration:" }, function(c)
				if not c then
					return
				end
				local cmd = make_ubt_cmd(mode, uproj, t, plat, c, root)
				ensure_output_window()
				append_output({ "Starting UBT:", cmd, "" })
				vim.fn.jobstart(cmd, {
					cwd = base,
					on_stdout = function(_, d)
						append_output(d)
					end,
					on_stderr = function(_, d)
						append_output(d)
					end,
					on_exit = function(_, code)
						append_output({ "", "Exit code: " .. code })
						vim.notify(
							string.format("[Unreal][%s] done (%d)", scope, code),
							code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR
						)
						if code == 0 then
							vim.cmd("LspRestart clangd")
						end
					end,
				})
			end)
		end)
	end)
end

-- Write .clangd configuration
local function write_clangd(root)
	if not root then
		return vim.notify("[Unreal] .clangd root not found", vim.log.levels.ERROR)
	end
	local path = root .. "/.clangd"
	local fd = io.open(path, "w")
	if not fd then
		return vim.notify("[Unreal] Failed to write .clangd", vim.log.levels.ERROR)
	end
	local lines = {
		"CompileFlags:",
		'  Add: ["-std=c++17", "--background-index", "--clang-tidy"]',
		"Index:",
		"  Background: true",
		"Diagnostics:",
		'  Suppress: ["unused-variable", "unused-parameter"]',
		"ClangTidy:",
		'  Add: ["modernize*", "performance*"]',
	}
	fd:write(table.concat(lines, "\n") .. "\n")
	fd:close()
	vim.notify("[Unreal] Generated .clangd at " .. path, vim.log.levels.INFO)
	vim.cmd("LspRestart clangd")
end

-- Setup function and commands
function UE.setup(opts)
	config.engine_path = opts.engine_path or config.engine_path
	config.auto_register_clangd = opts.auto_register_clangd or config.auto_register_clangd

	-- Clangd auto-registration
	if config.auto_register_clangd then
		local ok, lspconfig = pcall(require, "lspconfig")
		if ok and lspconfig.clangd then
			lspconfig.clangd.setup({
				cmd = {
					"clangd",
					"--background-index",
					"--clang-tidy",
					"--header-insertion=iwyu",
					"--completion-style=detailed",
				},
				on_attach = function(_, buf)
					vim.bo[buf].omnifunc = "v:lua.vim.lsp.omnifunc"
				end,
				root_dir = lspconfig.util.root_pattern("*.uproject", "compile_commands.json", ".git"),
				init_options = { compilationDatabasePath = ".", fallbackFlags = { "-std=c++17" } },
			})
			vim.notify("[Unreal] clangd configured", vim.log.levels.INFO)
		else
			vim.notify("[Unreal] nvim-lspconfig or clangd missing", vim.log.levels.WARN)
		end
	end

	-- Create commands for each scope and mode
	for _, scope in ipairs({ "Project", "Engine" }) do
		vim.api.nvim_create_user_command("UEBuild" .. scope, function()
			run_ubt(scope, MODES.BUILD)
		end, {})
		vim.api.nvim_create_user_command("UEHeader" .. scope, function()
			run_ubt(scope, MODES.HEADER)
		end, {})
		vim.api.nvim_create_user_command("UECompileCommands" .. scope, function()
			run_ubt(scope, MODES.COMPILE)
		end, {})
		vim.api.nvim_create_user_command("UEClangdConfig" .. scope, function()
			if scope == "Project" then
				local uproj_path = find_uproject()
				if not uproj_path then
					vim.notify("[Unreal][Project] .uproject not found for Clangd config.", vim.log.levels.ERROR)
					return
				end
				write_clangd(vim.fn.fnamemodify(uproj_path, ":h"))
			else -- Engine scope
				get_engine_root(function(engine_root_path)
					if not engine_root_path then
						vim.notify("[Unreal][Engine] Engine path not found for Clangd config.", vim.log.levels.ERROR)
						return
					end
					write_clangd(engine_root_path)
				end)
			end
		end, {})
	end

	-- Setup optional Telescope integration for engine source browsing
	if pcall(require, "telescope") then
		local telescope = require("telescope.builtin")
		vim.api.nvim_create_user_command("TelescopeUnrealSource", function()
			get_engine_root(function(engine_root)
				if not engine_root then
					return vim.notify("[Unreal][Engine] Engine path not found for browsing.", vim.log.levels.ERROR)
				end
				telescope.find_files({
					prompt_title = "Unreal Engine Source",
					cwd = engine_root,
					find_command = {
						"rg",
						"--files",
						"--hidden",
						"--glob",
						"!**/.git/**",
						"--glob",
						"!**/Intermediate/**",
						"--glob",
						"!**/Binaries/**",
						"--glob",
						"!**/DerivedDataCache/**",
						"--glob",
						"!**/Saved/**",
						"--glob",
						"!**/Build/**",
						"--glob",
						"!**/Content/**",
						"--glob",
						"!**/*.{dll,exe,so,dylib,lib,a,o,obj,pdb,rsp}",
						"--glob",
						"!**/*.{uasset,umap}",
						"--glob",
						"!**/*.{png,jpg,jpeg,gif,svg,webp,bmp,psd,tga,tif,tiff}",
					},
				})
			end)
		end, {})
		vim.api.nvim_set_keymap(
			"n",
			"<leader>su",
			":TelescopeUnrealSource<CR>",
			{ noremap = true, silent = true, desc = "Telescope Unreal Engine Source" }
		)
	else
		vim.notify("[Unreal] Telescope not found, engine source browsing disabled.", vim.log.levels.WARN)
	end
end

return UE
