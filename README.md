<p align="center">
<a href="https://github.com/nsidorenco/neotest-vstest/releases">
  <img alt="GitHub release (latest SemVer)" src="https://img.shields.io/github/v/release/nsidorenco/neotest-vstest?style=for-the-badge">
</a>
<a href="https://luarocks.org/modules/nsidorenco/neotest-vstest">
  <img alt="LuaRocks Package" src="https://img.shields.io/luarocks/v/nsidorenco/neotest-vstest?logo=lua&color=purple&style=for-the-badge">
</a>
</p>

# Neotest VSTest

Neotest adapter for dotnet

- Based on the VSTest for dotnet allowing test functionality similar to those found in IDEs like Rider and Visual Studio.
  - Will use the new [Microsoft.Testing.Platform](https://learn.microsoft.com/en-us/dotnet/core/testing/microsoft-testing-platform-intro?tabs=dotnetcli) when available for newer projects.
- Supports all testing frameworks.
- DAP strategy for attaching debug adapter to test execution.
- Supports `C#` and `F#`.
- No external dependencies, only the `dotnet sdk` required.
- Can run tests on many groupings including:
  - All tests
  - Test projects
  - Test files
  - Test all methods in class
  - Test individual cases of parameterized tests

## Pre-requisites

neotest-vstest makes a number of assumptions about your environment:

1. The `dotnet sdk`, and the `dotnet` cli executable in the users runtime path.
2. (For Debugging) `netcoredbg` is installed and `nvim-dap` plugin has been configured for `netcoredbg` (see debug config for more details)
3. (recommended) treesitter parser for either `C#` or `F#` allowing run test in file functionality.
4. `neovim v0.10.0` or later

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```
{
  "nsidorenco/neotest-vstest"
}
```

## Usage

```lua
require("neotest").setup({
  adapters = {
    require("neotest-vstest")
  }
})
```

The adapter optionally supports extra settings:

```lua
require("neotest").setup({
  adapters = {
    require("neotest-vstest")({
      -- Path to dotnet sdk path.
      -- Used in cases where the sdk path cannot be auto discovered.
      sdk_path = "/usr/local/dotnet/sdk/9.0.101/",
      -- table is passed directly to DAP when debugging tests.
      dap_settings = {
        type = "netcoredbg",
      }
      -- If multiple solutions exists the adapter will ask you to choose one.
      -- If you have a different heuristic for choosing a solution you can provide a function here.
      solution_selector = function(solutions)
        return nil -- return the solution you want to use or nil to let the adapter choose.
      end
    })
  }
})
```

## Debugging adapter

- Install `netcoredbg` to a location of your choosing and configure `nvim-dap` to point to the correct path

This adapter uses that standard dap strategy in `neotest`. Run it like so:

- `lua require("neotest").run.run({strategy = "dap"})`

## Acknowledgements

- [Issafalcon](https://github.com/Issafalcon) for the original [neotest-dotnet](https://github.com/Issafalcon/neotest-dotnet) adapter which inspired this adapter.
- [Wayne Bowie](https://github.com/waynebowie99) for helping test and troubleshoot the adapter.
- [Dynge](https://github.com/Dynge) for testing and contributing to the adapter.
