local nio = require("nio")
local logger = require("neotest.logging")
local dotnet_utils = require("neotest-vstest.dotnet_utils")

---@async
---@param spec neotest.RunSpec
---@return neotest.Process
return function(spec)
  if vim.tbl_count(spec.context.client_id_map) > 0 then
    if spec.context.solution then
      dotnet_utils.build_path(spec.context.solution)
    else
      for client, _ in pairs(spec.context.client_id_map) do
        dotnet_utils.build_project(client.project)
      end
    end
  end

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
