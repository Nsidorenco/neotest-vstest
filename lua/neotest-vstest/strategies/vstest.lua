local nio = require("nio")
local lib = require("neotest.lib")
local logger = require("neotest.logging")
local vstest = require("neotest-vstest.vstest")
local dotnet_utils = require("neotest-vstest.dotnet_utils")
local cli_wrapper = require("neotest-vstest.vstest.cli_wrapper")

---@async
---@param spec neotest.RunSpec
---@return neotest.Process
return function(spec)
  local process_output = nio.fn.tempname()
  lib.files.write(process_output, "")

  logger.debug("Running vstest with output to: " .. process_output)
  logger.debug(spec)

  if spec.context.solution then
    dotnet_utils.build_path(spec.context.solution)
  else
    for _, project in ipairs(spec.context.projects) do
      dotnet_utils.build_project(project)
    end
  end

  local wait_file = vstest.run_tests(
    spec.context.stream_path,
    spec.context.result_path,
    process_output,
    spec.context.ids
  )

  local result_future = nio.control.future()

  nio.run(function()
    cli_wrapper.spin_lock_wait_file(wait_file, 5 * 30 * 1000)
    result_future:set()
  end)

  local stream_data, stop_stream = lib.files.stream_lines(process_output)

  return {
    is_complete = function()
      return result_future.is_set()
    end,
    output = function()
      return process_output
    end,
    stop = function()
      stop_stream()
    end,
    output_stream = function()
      return function()
        local lines = stream_data()
        return table.concat(lines, "\n")
      end
    end,
    attach = function() end,
    result = function()
      result_future:wait()
      return 1
    end,
  }
end
