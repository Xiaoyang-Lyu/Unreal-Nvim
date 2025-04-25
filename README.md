DiG hacked it together.  
We use it at [PlayKigai](https://discord.gg/PlayKigai).
Come say hi!

---

A Neovim plugin for Unreal Engine C++ that gives you build commands, header generation, and clangd LSP integration.  
Tested on Windows 11, Unreal 5.5.

## Usage

- `:UEBuild` — Build your Unreal project (pick target/config/platform). Auto targets detection.
- `:UEHeader` — Generate headers only (UHT)
- `:UECompileCommands` — Generate `compile_commands.json` for clangd in the project root.
- `:UEClangdConfig` — Write a `.clangd` config file (optional, helps clangd parse Unreal macros and disables some noisy diagnostics).
- You must set up the clangd LSP server in Neovim (e.g. via nvim-lspconfig).

## Setup

- Install [clangd](https://clangd.llvm.org/)  
  Windows: `winget install LLVM.LLVM`  
- Neovim 0.8+  
- Unreal Engine 5.0+  
- Add to your lazy.nvim plugins:
  ```lua
  {
    'PlayKigai/Unreal-Nvim',
    ft = {'cpp', 'c', 'h', 'hpp'},
    config = function()
      require('unreal-nvim').setup({
        -- engine_path = "C:/Program Files/Epic Games/UE_5.5", -- optional
        auto_lsp = true -- auto_lsp: if true, tries to auto-configure clangd for Unreal (needs nvim-lspconfig)
      })
    end,
  }
  ```
  > Note: `auto_lsp` tries to auto-configure clangd using nvim-lspconfig if available.  
  > You can always set up clangd manually if you prefer.

## How it works

- Finds your `.uproject` and UE install automatically
- Detects build targets from `.Target.cs` files (or falls back to project name)
- Lets you pick build targets/configs
- Runs Unreal Build Tool in a floating window
- Generates `compile_commands.json` for clangd LSP
- Optionally makes a `.clangd` config file to suppress some warnings and help clangd parse Unreal macros
- Optionally auto-registers clangd LSP (if `auto_lsp = true` and nvim-lspconfig is installed)

## Totally unbiased best things about this plugin

- **Automatic project and engine detection** 
- *Tentatively* **Cross-platform** (Windows, Linux, macOS)
- **Auto-detects build targets and platforms**
- **One command to generate LSP config and compile database**
- **Minimal config, should work out of the box for most setups**
- **Do whatever you want with it license.**