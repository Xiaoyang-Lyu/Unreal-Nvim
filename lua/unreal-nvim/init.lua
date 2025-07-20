---@diagnostic disable: undefined-global
local UE = {}

local has_lspconfig, lspconfig = pcall(require, "lspconfig")
local has_telescope, telescope = pcall(require, "telescope.builtin")

local UNREAL_EXCLUDE_GLOBS = {
	"--glob", "!**/.git/**",
	"--glob", "!**/Intermediate/**",
	"--glob", "!**/Binaries/**",
	"--glob", "!**/DerivedDataCache/**",
	"--glob", "!**/Saved/**",
	"--glob", "!**/Build/**",
	"--glob", "!**/Content/**",
	"--glob", "!**/.{vscode,idea,vs,cache}/**",
	"--glob", "!**/*.{dll,exe,so,dylib,lib,a,o,obj,pdb,rsp,idx,clangd}",
	"--glob", "!**/*.{uasset,umap}",
	"--glob", "!**/*.{png,jpg,jpeg,gif,svg,webp,bmp,psd,tga,tif,tiff}",
}

local config = { engine_path = nil, auto_register_clangd = false }
local cached_engine_root, cached_project_path

local function find_in_parents(start, glob)
	local dir = vim.loop.fs_realpath(start or vim.fn.getcwd()) or vim.fn.getcwd()
	while dir and dir ~= "" do
		local files = vim.fn.globpath(dir, glob, false, true)
		if #files > 0 then
			return files[1]
		end
		local parent = vim.fn.fnamemodify(dir, ":h")
		if parent == dir then break end
		dir = parent
	end
	return nil
end

local function find_uproject()
	if cached_project_path then
		return cached_project_path
	end
	local proj = find_in_parents(nil, "*.uproject")
	if proj then
		cached_project_path = proj
	end
	return proj
end

local function find_engine_root()
	local dir = vim.loop.fs_realpath(vim.fn.getcwd()) or vim.fn.getcwd()
	while dir and dir ~= "" do
		local src = dir .. "/Engine/Source"
		if vim.loop.fs_stat(src) then
			return dir
		end
		local parent = vim.fn.fnamemodify(dir, ":h")
		if parent == dir then break end
		dir = parent
	end
	return nil
end

local function is_valid_engine_path(p)
	return p and vim.loop.fs_stat(p .. "/Engine/Build/BatchFiles") ~= nil
end

local function save_engine_path(path, uproj)
	cached_engine_root = path
	if uproj then
		local project_folder = vim.fn.fnamemodify(uproj, ":h")
		local file = project_folder .. "/.ueinfo"
		local fd = io.open(file, "w")
		if fd then
			fd:write("UEPath=" .. path)
			fd:close()
		end
	end
	return path
end

local function get_engine_root(callback)
	if config.engine_path and is_valid_engine_path(config.engine_path) then
		return callback(config.engine_path)
	elseif cached_engine_root then
		return callback(cached_engine_root)
	end
	local uproj = find_uproject()
	if uproj then
		local project_folder = vim.fn.fnamemodify(uproj, ":h")
		local info_file = project_folder .. "/.ueinfo"
		local fd = io.open(info_file, "r")
		if fd then
			local line = fd:read("*l")
			fd:close()
			local p = line:match("^UEPath=(.+)")
			if is_valid_engine_path(p) then
				cached_engine_root = p
				return callback(p)
			end
		end
	end
	local env = os.getenv("UE_ENGINE_PATH")
	if is_valid_engine_path(env) then
		return callback(save_engine_path(env, uproj))
	end
	local auto = find_engine_root()
	if is_valid_engine_path(auto) then
		return callback(save_engine_path(auto, uproj))
	end
	vim.ui.input({ prompt = "Enter Unreal Engine path:" }, function(input)
		if not input or input == "" then
			vim.notify("[Unreal] Engine path selection cancelled.", vim.log.levels.WARN)
			return callback(nil)
		end
		local real = vim.loop.fs_realpath(input)
		if is_valid_engine_path(real) then
			return callback(save_engine_path(real, uproj))
		else
			vim.notify("[Unreal] Invalid engine path: " .. input, vim.log.levels.ERROR)
			return callback(nil)
		end
	end)
end

local function ensure_output_window()
	if UE.win and vim.api.nvim_win_is_valid(UE.win) then
		vim.api.nvim_buf_set_lines(UE.buf, 0, -1, false, {})
		return
	end
	UE.buf = vim.api.nvim_create_buf(false, true)
	local cols, lines = vim.o.columns, vim.o.lines
	local w, h = math.floor(cols * 0.5), math.floor(lines * 0.3)
	-- Top right floating window
	UE.win = vim.api.nvim_open_win(UE.buf, false, {
		relative  = "editor",
		anchor    = "NE",
		row       = 0,
		col       = cols,
		width     = w,
		height    = h,
		style     = "minimal",
		border    = "rounded",
		focusable = true,
		zindex    = 50,
	})
	vim.api.nvim_win_set_option(UE.win, "winblend", 10)
	vim.api.nvim_win_set_option(UE.win, "wrap", true)
	vim.api.nvim_win_set_option(UE.win, "mouse", "a")
	vim.api.nvim_buf_set_option(UE.buf, "filetype", "unreal_output")
	vim.api.nvim_buf_set_option(UE.buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(UE.buf, "modifiable", true)
	vim.api.nvim_buf_set_option(UE.buf, "readonly", false)
	-- Easily close the output window
	vim.api.nvim_buf_set_keymap(UE.buf, "n", "q", "<cmd>q<CR>", { noremap = true, silent = true, desc = "Close Unreal Output" })
	vim.api.nvim_buf_set_keymap(UE.buf, "n", "<Esc>", "<cmd>q<CR>", { noremap = true, silent = true, desc = "Close Unreal Output" })
end

local function append_output(lines)
	if not (UE.buf and vim.api.nvim_buf_is_valid(UE.buf)) then return end
	for i, l in ipairs(lines) do
		lines[i] = l:gsub("%s+$", "")
	end
	vim.api.nvim_buf_set_lines(UE.buf, -1, -1, false, lines)
	if UE.win and vim.api.nvim_win_is_valid(UE.win) then
		vim.api.nvim_win_set_cursor(UE.win, { vim.api.nvim_buf_line_count(UE.buf), 0 })
	end
end

local MODES = { BUILD = "build", HEADER = "header", COMPILE = "compile" }
local CONFIGS = { "DebugGame", "Development", "Shipping", "Debug", "Test" }

local function make_ubt_cmd(mode, uproj, target, plat, conf, eng)
	local is_win = vim.fn.has("win32") == 1
	local script = eng ..
	"/Engine/Build/BatchFiles/" ..
	(is_win and "Build.bat" or (vim.loop.os_uname().sysname == "Darwin" and "Mac/Build.sh" or "Linux/Build.sh"))
	local parts = { vim.fn.shellescape(script), target, plat, conf }
	if uproj then
		parts[#parts + 1] = (is_win and "-Project=" or "-project=") .. vim.fn.shellescape(uproj)
	end
	if mode == MODES.HEADER then
		parts[#parts + 1] = "-SkipBuild"
	elseif mode == MODES.COMPILE then
		local out = uproj and vim.fn.fnamemodify(uproj, ":p:h") or eng
		vim.list_extend(parts,
			{ "-Mode=GenerateClangDatabase", "-OutputDir=" .. vim.fn.shellescape(out), "-game", "-engine", "-NoHotReload" })
	end
	return table.concat(parts, " ")
end

local function run_ubt(scope, mode)
	local uproj = scope == "Project" and find_uproject()
	if scope == "Project" and not uproj then
		return vim.notify("[Unreal][Project] .uproject not found", vim.log.levels.ERROR)
	end
	get_engine_root(function(root)
		if not root then
			return vim.notify(string.format("[Unreal][%s] engine path missing", scope), vim.log.levels.ERROR)
		end
		local base = (scope == "Project" and vim.fn.fnamemodify(uproj, ":h") or root)
		local pat = base .. (scope == "Project" and "/Source/*.Target.cs" or "/Engine/Source/**/*.Target.cs")
		local files = vim.fn.glob(pat, true, true)
		local targets = {}
		for _, f in ipairs(files) do
			targets[#targets + 1] = vim.fn.fnamemodify(f, ":t:r"):gsub("%.Target$", "")
		end
		if #targets == 0 then
			local name = vim.fn.fnamemodify(uproj or root, ":t:r")
			targets = { name .. (scope == "Project" and "Editor" or "") }
			vim.notify(string.format("[Unreal][%s] defaulting to %s", scope, targets[1]), vim.log.levels.WARN)
		end
		local plat = vim.fn.has("win32") == 1 and "Win64" or
		(vim.loop.os_uname().sysname == "Darwin" and "Mac" or "Linux")
		vim.notify(string.format("[Unreal][%s] platform: %s", scope, plat), vim.log.levels.INFO)

		vim.ui.select(targets, { prompt = "Target (" .. scope .. "):" }, function(t)
			if not t then return end
			vim.ui.select(CONFIGS, { prompt = "Configuration:" }, function(c)
				if not c then return end
				local cmd = make_ubt_cmd(mode, uproj, t, plat, c, root)
				ensure_output_window()
				append_output({ "Starting UBT:", cmd, "" })
				vim.fn.jobstart(cmd, {
					cwd       = base,
					on_stdout = function(_, d) append_output(d) end,
					on_stderr = function(_, d) append_output(d) end,
					on_exit   = function(_, code)
						append_output({ "", "Exit code: " .. code })
						vim.notify(
							string.format("[Unreal][%s] done (%d)", scope, code),
							code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR
						)
						if code == 0 then vim.cmd("LspRestart clangd") end
					end,
				})
			end)
		end)
	end)
end

local function write_clangd(root)
	local path = root and (root .. "/.clangd")
	if not path then
		return vim.notify("[Unreal] .clangd root not found", vim.log.levels.ERROR)
	end
	local fd = io.open(path, "w")
	if not fd then
		return vim.notify("[Unreal] Failed to write .clangd", vim.log.levels.ERROR)
	end
	fd:write(table.concat({
		"CompileFlags:",
		'  Add: ["-std=c++17", "--background-index", "--clang-tidy"]',
		"Index:",
		"  Background: true",
		"Diagnostics:",
		'  Suppress: ["unused-variable", "unused-parameter"]',
		"ClangTidy:",
		'  Add: ["modernize*", "performance*"]',
	}, "\n") .. "\n")
	fd:close()
	vim.notify("[Unreal] Generated .clangd at " .. path, vim.log.levels.INFO)
	vim.cmd("LspRestart clangd")
end

function UE.setup(opts)
	config.engine_path = opts.engine_path or config.engine_path
	config.auto_register_clangd = opts.auto_register_clangd or config.auto_register_clangd

	if config.auto_register_clangd and has_lspconfig and lspconfig.clangd then
		lspconfig.clangd.setup({
			cmd = { "clangd", "--background-index", "--clang-tidy", "--header-insertion=iwyu", "--completion-style=detailed" },
			on_attach = function(_, buf) vim.bo[buf].omnifunc = "v:lua.vim.lsp.omnifunc" end,
			root_dir = lspconfig.util.root_pattern("*.uproject", "compile_commands.json", ".git"),
			init_options = { compilationDatabasePath = ".", fallbackFlags = { "-std=c++17" } },
		})
	end

	for _, scope in ipairs({ "Project", "Engine" }) do
		vim.api.nvim_create_user_command("UEBuild" .. scope, function() run_ubt(scope, MODES.BUILD) end, {})
		vim.api.nvim_create_user_command("UEHeader" .. scope, function() run_ubt(scope, MODES.HEADER) end, {})
		vim.api.nvim_create_user_command("UECompileCommands" .. scope, function() run_ubt(scope, MODES.COMPILE) end, {})
		vim.api.nvim_create_user_command("UEClangdConfig" .. scope, function()
			if scope == "Project" then
				local u = find_uproject()
				if u then write_clangd(vim.fn.fnamemodify(u, ":h")) end
			else
				get_engine_root(function(r) if r then write_clangd(r) end end)
			end
		end, {})
	end

	vim.api.nvim_create_user_command("UECwdProject", function()
		local u = find_uproject()
		if u then
			local root = vim.fn.fnamemodify(u, ":h")
			vim.cmd("cd " .. vim.fn.fnameescape(root))
			vim.notify("[Unreal] CWD→Project: " .. root, vim.log.levels.INFO)
		else
			vim.notify("[Unreal] Project root not found.", vim.log.levels.ERROR)
		end
	end, {})

	vim.api.nvim_create_user_command("UECwdEngine", function()
		get_engine_root(function(r)
			if r then
				vim.cmd("cd " .. vim.fn.fnameescape(r))
				vim.notify("[Unreal] CWD→Engine: " .. r, vim.log.levels.INFO)
			end
		end)
	end, {})

	local function map(lhs, rhs, desc)
		vim.keymap.set("n", lhs, rhs, { desc = desc, silent = true })
	end

	map("<leader>ub", "<cmd>UEBuildProject<CR>", "Unreal Build Project")
	map("<leader>uB", "<cmd>UEBuildEngine<CR>", "Unreal Build Engine")
	map("<leader>uh", "<cmd>UEHeaderProject<CR>", "Unreal Header Project")
	map("<leader>uH", "<cmd>UEHeaderEngine<CR>", "Unreal Header Engine")
	map("<leader>uc", "<cmd>UECompileCommandsProject<CR>", "Unreal CompCommands Project")
	map("<leader>uC", "<cmd>UECompileCommandsEngine<CR>", "Unreal CompCommands Engine")
	map("<leader>ux", "<cmd>UEClangdConfigProject<CR>", "Unreal ClangdConfig Project")
	map("<leader>uX", "<cmd>UEClangdConfigEngine<CR>", "Unreal ClangdConfig Engine")
	map("<leader>up", "<cmd>UECwdProject<CR>", "Unreal CWD→Project")
	map("<leader>ue", "<cmd>UECwdEngine<CR>", "Unreal CWD→Engine")

	if has_telescope then
		local find_cmd = { "rg", "--files", "--hidden" }
		find_cmd = vim.tbl_flatten({ find_cmd, UNREAL_EXCLUDE_GLOBS })
		local grep_args = vim.tbl_flatten({ { "--hidden" }, UNREAL_EXCLUDE_GLOBS })

		vim.api.nvim_create_user_command("TelescopeUnrealFind", function()
			local roots = {}
			local u = find_uproject()
			if u then table.insert(roots, vim.fn.fnamemodify(u, ":h")) end
			get_engine_root(function(r)
				if r then table.insert(roots, r) end
				telescope.find_files({ prompt_title = "Unreal Find", search_dirs = roots, find_command = find_cmd })
			end)
		end, {})

		vim.api.nvim_create_user_command("TelescopeUnrealGrep", function()
			local roots = {}
			local u = find_uproject()
			if u then table.insert(roots, vim.fn.fnamemodify(u, ":h")) end
			get_engine_root(function(r)
				if r then table.insert(roots, r) end
				telescope.live_grep({ prompt_title = "Unreal Grep", search_dirs = roots, additional_args = grep_args })
			end)
		end, {})

		map("<leader>uf", "<cmd>TelescopeUnrealFind<CR>", "Unreal Find")
		map("<leader>ug", "<cmd>TelescopeUnrealGrep<CR>", "Unreal Grep")
	end
end

return UE
