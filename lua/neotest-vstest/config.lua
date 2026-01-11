local M = {}

---@class neotest-vstest.Config
---@field sdk_path? string path to dotnet sdk. Example: /usr/local/share/dotnet/sdk/9.0.101/
---@field build_opts? BuildOpts
---@field dap_settings? dap.Configuration dap settings for debugging
---@field solution_selector? fun(solutions: string[]): string|nil
---@field settings_selector? fun(project_dir: string): string|nil function to find the .runsettings/testconfig.json in the project dir
---@field timeout_ms? number milliseconds to wait before timing out connection with test runner

---@type neotest-vstest.Config
local default_config = {
  timeout_ms = 5 * 30 * 1000,
}

---@return neotest-vstest.Config
function M.get_config()
  return vim.tbl_deep_extend("force", default_config, vim.g.neotest_vstest or {})
end

return M
