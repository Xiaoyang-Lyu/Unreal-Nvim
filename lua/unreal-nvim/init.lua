-- File: lua/unreal-nvim/init.lua
local UE_Nvim = {}
local config = {
  engine_path = nil, -- User-configurable engine path
  auto_register_clangd = false,
}

-- Finds the root .uproject file by searching upwards from a starting directory
local function find_uproject(start_dir)
  local dir = vim.fn.fnamemodify(start_dir or vim.fn.getcwd(), ':p')
  dir = vim.loop.fs_realpath(dir) or dir
  while dir do
    local candidates = vim.fn.glob(dir .. '/*.uproject', false, true)
    if #candidates > 0 then
      return candidates[1]
    end
    local parent = vim.fn.fnamemodify(dir, ':h')
    if parent == nil or parent == '' or parent == dir then
      break
    end
    dir = parent
  end
  return nil
end

-- Finds all target names from .Target.cs files in the project's Source directory
local function find_target_names(uproject_path)
  if not uproject_path then
    return {}
  end

  local project_dir = vim.fn.fnamemodify(uproject_path, ':h')
  local source_dir = project_dir .. '/Source'

  -- Check if Source directory exists
  if vim.fn.isdirectory(source_dir) ~= 1 then
    vim.notify('[Unreal] Source directory not found at: ' .. source_dir, vim.log.levels.WARN)
    return {}
  end

  -- Find all .Target.cs files in the Source directory
  local target_files = vim.fn.glob(source_dir .. '/*.Target.cs', false, true)
  if #target_files == 0 then
    vim.notify('[Unreal] No .Target.cs files found in: ' .. source_dir, vim.log.levels.WARN)
    return {}
  end

  local targets = {}
  for _, file_path in ipairs(target_files) do
    -- Extract the filename without path and extension
    local target_name = vim.fn.fnamemodify(file_path, ':t:r')
    -- Remove the .Target suffix to get the actual target name
    target_name = target_name:gsub('%.Target$', '')
    table.insert(targets, target_name)
  end

  return targets
end

local cached_engine_base = nil

-- Asynchronously determines the Unreal Engine base path.
-- Tries config, cache, .uproject hints, standard paths, env var, then prompts user.
-- Calls the provided callback with the found path (string) or nil on failure/cancellation.
local function get_engine_base(uproject_path, callback)
  -- Check user-set config path first
  if config.engine_path and config.engine_path ~= '' then
    local real_path = vim.loop.fs_realpath(config.engine_path)
    if real_path then
      callback(real_path)
      return
    end
  end

  -- Check cache
  if cached_engine_base then
    callback(cached_engine_base)
    return
  end

  local engine_base = nil

  -- TODO: Implement sync checks: .uproject parsing, standard paths
  -- Placeholder for sync checks
  -- if engine_base then
  --   cached_engine_base = engine_base
  --   callback(engine_base)
  --   return
  -- end

  -- Try environment variable
  engine_base = os.getenv 'UE_ENGINE_PATH'
  if engine_base and vim.loop.fs_stat(engine_base .. '/Engine/Build/BatchFiles') then
    cached_engine_base = engine_base
    callback(engine_base)
    return
  end

  -- Prompt user as last resort
  vim.ui.input({ prompt = 'Unreal Engine path not found. Please enter the path to the Engine directory:' }, function(input_path)
    if input_path and input_path ~= '' then
      local real_path = vim.loop.fs_realpath(input_path)
      if real_path and vim.loop.fs_stat(real_path .. '/Engine/Build/BatchFiles') then
        config.engine_path = real_path -- Store for this session only if prompted
        cached_engine_base = real_path
        vim.notify('[Unreal] Engine path set to: ' .. real_path)
        callback(real_path)
      else
        vim.notify('[Unreal] Invalid engine path provided: ' .. input_path, vim.log.levels.ERROR)
        cached_engine_base = nil
        callback(nil)
      end
    else
      vim.notify('[Unreal] Engine path selection cancelled.', vim.log.levels.WARN)
      cached_engine_base = nil
      callback(nil)
    end
  end)
end

-- Constructs the Unreal Build Tool (UBT) command string.
local function make_ubt_command(mode, uproject, target, platform, config_, engine_path)
  local eng_base = engine_path
  local is_win = vim.fn.has 'win32' == 1

  local script
  if is_win then
    script = eng_base .. [[\Engine\Build\BatchFiles\Build.bat]]
  else
    local uname = vim.loop.os_uname().sysname
    if uname == 'Darwin' then
      script = eng_base .. '/Engine/Build/BatchFiles/Mac/Build.sh'
    else -- Assume Linux otherwise
      script = eng_base .. '/Engine/Build/BatchFiles/Linux/Build.sh'
    end
  end

  -- Escape the script path to handle spaces or special characters
  local cmd_parts = { vim.fn.shellescape(script) }
  table.insert(cmd_parts, target) -- e.g., MyProjectEditor
  table.insert(cmd_parts, platform) -- e.g., Win64, Mac, Linux
  table.insert(cmd_parts, config_) -- e.g., Development, Shipping
  -- UBT uses different argument prefixes for project path depending on OS
  table.insert(cmd_parts, (is_win and '-Project=' or '-project=') .. vim.fn.shellescape(uproject))

  if mode == 'header' then
    -- Generate IntelliSense data without a full build
    table.insert(cmd_parts, '-SkipBuild')
  elseif mode == 'compile' then
    -- Generate compile_commands.json for clangd
    table.insert(cmd_parts, '-Mode=GenerateClangDatabase')
    local proj_dir = vim.fn.fnamemodify(uproject, ':h')
    table.insert(cmd_parts, '-OutputDir=' .. vim.fn.shellescape(proj_dir)) -- Place compile_commands.json in project root
    table.insert(cmd_parts, '-game') -- Include game modules
    table.insert(cmd_parts, '-engine') -- Include engine modules
    table.insert(cmd_parts, '-NoHotReload') -- Avoid hot reload conflicts
  end
  -- Note: Other modes (like 'build') don't need extra flags here

  return table.concat(cmd_parts, ' ')
end

-- Output window management
local output_bufnr = nil
local output_winid = nil

-- Ensures the output window exists and is ready.
local function ensure_output_window()
  -- If window exists and is valid, just clear its buffer and return
  if output_winid and vim.api.nvim_win_is_valid(output_winid) then
    vim.api.nvim_buf_set_lines(output_bufnr, 0, -1, false, {}) -- Clear buffer content
    return
  end

  -- Create a new buffer for the output
  output_bufnr = vim.api.nvim_create_buf(false, true) -- false = not listed, true = scratch buffer
  vim.api.nvim_buf_set_option(output_bufnr, 'bufhidden', 'wipe') -- Wipe buffer when hidden
  vim.api.nvim_buf_set_option(output_bufnr, 'buftype', 'nofile') -- Not related to a file
  vim.api.nvim_buf_set_option(output_bufnr, 'swapfile', false) -- No swap file needed
  vim.api.nvim_buf_set_option(output_bufnr, 'modifiable', true) -- Allow writing output to it
  vim.api.nvim_buf_set_name(output_bufnr, 'Unreal Build Output') -- Set buffer name

  -- Floating window configuration
  local width = math.floor(vim.o.columns * 0.8) -- 80% of editor width
  local height = math.floor(vim.o.lines * 0.6) -- 60% of editor height
  local row = math.floor((vim.o.lines - height) / 2) -- Center vertically
  local col = math.floor((vim.o.columns - width) / 2) -- Center horizontally

  -- Open the floating window
  output_winid = vim.api.nvim_open_win(output_bufnr, true, { -- true = enter the window
    relative = 'editor', -- Position relative to the editor grid
    width = width,
    height = height,
    row = row,
    col = col,
    style = 'minimal', -- No number column, etc.
    border = 'single', -- Use single-line border
  })
  -- Set highlight group for the floating window border
  vim.api.nvim_win_set_option(output_winid, 'winhl', 'Normal:Normal,FloatBorder:FloatBorder')
end

-- Appends lines of data to the output window.
local function append_to_output(data)
  if not output_bufnr or not vim.api.nvim_buf_is_valid(output_bufnr) then
    return
  end

  local lines = {}
  if data then
    for _, line in ipairs(data) do
      -- Remove trailing carriage return (for Windows job output)
      if line and line ~= '' then
        line = line:gsub('\r$', '')
        table.insert(lines, line)
      end
    end
  end

  if #lines > 0 then
    vim.api.nvim_buf_set_lines(output_bufnr, -1, -1, false, lines)
    -- Auto-scroll
    if output_winid and vim.api.nvim_win_is_valid(output_winid) then
      vim.api.nvim_win_set_cursor(output_winid, { vim.api.nvim_buf_line_count(output_bufnr), 0 })
    end
  end
end

-- Utility to restart clangd LSP server using LspRestart
local function restart_clangd_lsp()
  vim.cmd("LspRestart clangd")
end

-- Main function to initiate a build process (build, header gen, compile db).
local function run_build(mode)
  local buf_path = vim.fn.expand '%:p'
  local start_dir = (buf_path ~= '' and buf_path) or vim.loop.cwd()
  local uproject = find_uproject(start_dir)
  if not uproject then
    vim.notify('[Unreal] .uproject file not found.', vim.log.levels.ERROR)
    return
  end

  -- Get target names from .Target.cs files
  local targets = find_target_names(uproject)

  -- Fallback to default targets if none found
  if #targets == 0 then
    local proj_name = vim.fn.fnamemodify(uproject, ':t:r')
    vim.notify('[Unreal] No target files found, using default targets based on project name', vim.log.levels.WARN)
    targets = { proj_name .. 'Editor', proj_name, proj_name .. 'Server' }
  end

  local proj_dir = vim.fn.fnamemodify(uproject, ':h')
  local configs = { 'DebugGame', 'Development', 'Shipping', 'Debug' }
  local platform
  if vim.fn.has 'win32' == 1 then
    platform = 'Win64'
  else
    local uname = vim.loop.os_uname().sysname
    platform = (uname == 'Darwin' and 'Mac') or 'Linux'
  end
  vim.notify('[Unreal] Auto-detected platform: ' .. platform, vim.log.levels.INFO)

  local mode_desc = {
    build = 'Building',
    header = 'Generating headers for',
    compile = 'Creating compile_commands.json for',
  }

  -- Get engine path (potentially async), then proceed
  get_engine_base(uproject, function(engine_path)
    if not engine_path then
      vim.notify('[Unreal] Could not determine Unreal Engine base path. Build cancelled.', vim.log.levels.ERROR)
      return
    end

    vim.ui.select(targets, { prompt = 'Unreal Build Target:' }, function(choice_target)
      if not choice_target then
        return
      end
      local choice_platform = platform -- Use auto-detected platform
      vim.ui.select(configs, { prompt = 'Build Configuration:' }, function(choice_config)
        if not choice_config then
          return
        end

        local full_cmd = make_ubt_command(mode, uproject, choice_target, choice_platform, choice_config, engine_path)
        if not full_cmd then
          vim.notify('[Unreal] Failed to create build command.', vim.log.levels.ERROR)
          return
        end

        ensure_output_window()
        append_to_output { 'Starting Unreal Build...', 'Command: ' .. full_cmd, '' }

        local action = mode_desc[mode] or 'Running UBT for'
        vim.notify(action .. ' ' .. choice_target .. ' (' .. choice_platform .. ', ' .. choice_config .. ') - See output window')

        -- Run UBT via jobstart, piping output
        vim.fn.jobstart(full_cmd, {
          cwd = proj_dir,
          pty = false, -- Use pipes to avoid terminal escape codes
          on_stdout = function(_, data, _)
            append_to_output(data)
          end,
          on_stderr = function(_, data, _)
            append_to_output(data)
          end,
          on_exit = function(_, code, _)
            local status = (code == 0 and 'completed successfully' or 'failed with code ' .. code)
            append_to_output { '', 'Build ' .. status .. '.' }
            vim.notify('[Unreal] Build ' .. status .. '.', (code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR))
            -- Restart clangd if build succeeded and clangd is running
            if code == 0 then
              restart_clangd_lsp()
            end
          end,
        })
      end)
    end)
  end)
end

UE_Nvim.run_build = run_build

-- Creates a basic .clangd configuration file in the project root.
local function write_clangd_config()
  local uproj = find_uproject(vim.loop.cwd())
  if not uproj then
    vim.notify('[Unreal] .uproject not found for generating .clangd file.', vim.log.levels.ERROR)
    return
  end
  local project_dir = vim.fn.fnamemodify(uproj, ':h')
  local clangd_path = project_dir .. '/.clangd'

  local lines = {
    'CompileFlags:',
    '  Add: [',
    '    "-D__INTELLISENSE__", -- Helps clangd parse UE macros',
    '    "-std=c++17",',
    '    "-Wno-microsoft-cast",',
    '    "-Wno-deprecated-declarations"',
  }

  if vim.fn.has 'win32' == 1 then
    table.insert(lines, '    ,"--driver-mode=cl",')
    table.insert(lines, '    "-fms-compatibility",')
    table.insert(lines, '    "-fdelayed-template-parsing"')
  end

  table.insert(lines, '  ]')
  table.insert(lines, '')
  table.insert(lines, 'Index:')
  table.insert(lines, '  Background: true')
  table.insert(lines, '')
  table.insert(lines, 'Diagnostics:')
  table.insert(lines, '  Suppress: ["unused-variable", "unused-parameter", "unknown-pragmas"]')
  table.insert(lines, '  ClangTidy:')
  table.insert(lines, '    Add: ["modernize*", "performance*"]')
  table.insert(lines, '    Remove: ["modernize-use-trailing-return-type", "modernize-use-auto"]')

  local fd = io.open(clangd_path, 'w')
  if fd then
    fd:write(table.concat(lines, '\n') .. '\n')
    fd:close()
    vim.notify('[Unreal] Generated .clangd at ' .. clangd_path)
    restart_clangd_lsp()
  else
    vim.notify('[Unreal] Failed to write .clangd file.', vim.log.levels.ERROR)
  end
end

UE_Nvim.write_clangd_config = write_clangd_config

-- Plugin setup function, called by user config.
function UE_Nvim.setup(opts)
  opts = opts or {}
  config.engine_path = opts.engine_path -- Allow overriding engine path
  config.auto_register_clangd = opts.auto_lsp or opts.auto_register_clangd

  if config.auto_register_clangd then
    local ok, lspconfig = pcall(require, 'lspconfig')
    if ok and lspconfig.clangd then
      local clangd_opts = {
        cmd = {
          'clangd',
          '--background-index',
          '--clang-tidy',
          '--header-insertion=iwyu',
          '--completion-style=detailed',
          '--function-arg-placeholders',
          '--fallback-style=llvm',
        },
        on_attach = function(client, bufnr)
          vim.api.nvim_set_option_value('omnifunc', 'v:lua.vim.lsp.omnifunc', { buf = bufnr })
        end,
        -- Use .uproject location as root to find compile_commands.json
        root_dir = lspconfig.util.root_pattern('*.uproject', 'compile_commands.json', '.git'),
        init_options = {
          compilationDatabasePath = '.',
          fallbackFlags = { '-std=c++17' },
          clangdFileStatus = true,
        },
      }

      if vim.fn.has 'win32' == 1 then
        table.insert(clangd_opts.cmd, '--query-driver=**/*cl.exe,**/*clang-cl.exe')
        table.insert(clangd_opts.cmd, '--offset-encoding=utf-16')
      end

      lspconfig.clangd.setup(clangd_opts)
      vim.notify('[Unreal] clangd configured for Unreal Engine development', vim.log.levels.INFO)
    else
      vim.notify('[Unreal] nvim-lspconfig not found; cannot auto-register clangd.', vim.log.levels.WARN)
    end
  end
end

-- Register commands only when the file is run directly (e.g., via plugin/unreal.lua)
-- and not when required as a module.
if not package.loaded['unreal-nvim.init'] then -- Check specific module name
  vim.api.nvim_create_user_command('UEBuild', function()
    run_build 'build'
  end, {})
  vim.api.nvim_create_user_command('UEHeader', function()
    run_build 'header'
  end, {})
  vim.api.nvim_create_user_command('UECompileCommands', function()
    run_build 'compile'
  end, {})
  vim.api.nvim_create_user_command('UEClangdConfig', write_clangd_config, {})
end

return UE_Nvim
