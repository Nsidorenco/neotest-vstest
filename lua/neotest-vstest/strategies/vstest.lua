local nio = require("nio")
local logger = require("neotest.logging")
local dotnet_utils = require("neotest-vstest.dotnet_utils")

---@async
---@param spec neotest.RunSpec
---@return neotest.Process
return function(spec)
  local projects = {}
  for client, _ in pairs(spec.context.client_id_map) do
    projects[#projects + 1] = client.project
  end
  dotnet_utils.build_projects(spec.context.solution, projects)

  local resultAccumulator = require("neotest-vstest.utilities").ResultAccumulator:new()

  for client, ids in pairs(spec.context.client_id_map) do
    local run_result = client:run_tests(ids)
    resultAccumulator:add_run_result(run_result, spec.context.write_stream)
  end

  local set_result = function(result)
    spec.context.results = vim.tbl_extend("force", spec.context.results, result)
  end

  return resultAccumulator:build_neotest_result_table(set_result)
end
