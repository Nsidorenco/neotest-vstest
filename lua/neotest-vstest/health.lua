local M = {}
M.check = function()
  vim.health.start("neotest-vstest healthcheck")

  vim.health.info("checking for dependencies...")

  local has_nio = pcall(require("nio"))
  if not has_nio then
    vim.health.error("nio is not installed. Please install nio to use neotest-vstest.")
  else
    vim.health.ok("nio is installed.")
  end

  local has_neotest = pcall(require("neotest"))
  if not has_neotest then
    vim.health.error("neotest is not installed. Please install neotest to use neotest-vstest.")
  else
    vim.health.ok("neotest is installed.")
  end

  vim.health.info("Checking neotest-vstest configuration...")

  vim.health.info("Checking for vstest.console.dll...")
  local cli_wrapper = require("neotest-vstest.vstest.cli_wrapper")
  local vstest_path = cli_wrapper.get_vstest_path()

  -- make sure setup function parameters are ok
  if not vstest_path then
    vim.health.error(
      "Could not determine location of vstest.console.dll. Please set vim.g.neotest_vstest.sdk_path to the dotnet sdk path."
    )
  else
    vim.health.ok("Found vstest.console.dll at: " .. vstest_path)
  end
end
return M
