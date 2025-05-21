local nio = require("nio")
local lib = require("neotest.lib")
local logger = require("neotest.logging")
local cli_wrapper = require("neotest-vstest.vstest.cli_wrapper")

local M = {}

---runs tests identified by ids.
---@param project DotnetProjectInfo
---@param ids string|string[]
---@return string wait_file_path, string result_stream_file_path, string result_file_path
function M.run_tests(project, ids)
  local process_output_path = nio.fn.tempname()
  lib.files.write(process_output_path, "")

  local result_path = nio.fn.tempname()

  local result_stream_path = nio.fn.tempname()
  lib.files.write(result_stream_path, "")

  local command = vim
    .iter({
      "run-tests",
      result_stream_path,
      result_path,
      process_output_path,
      ids,
    })
    :flatten()
    :join(" ")
  cli_wrapper.invoke_test_runner(project, command)

  return process_output_path, result_stream_path, result_path
end

--- Uses the vstest console to spawn a test process for the debugger to attach to.
---@param project DotnetProjectInfo
---@param attached_path string
---@param stream_path string
---@param output_path string
---@param ids string|string[]
---@return string? pid
function M.debug_tests(project, attached_path, stream_path, output_path, ids)
  local process_output = nio.fn.tempname()

  local pid_path = nio.fn.tempname()

  local command = vim
    .iter({
      "debug-tests",
      pid_path,
      attached_path,
      stream_path,
      output_path,
      process_output,
      ids,
    })
    :flatten()
    :join(" ")
  logger.debug("neotest-vstest: starting test in debug mode using:")
  logger.debug(command)

  cli_wrapper.invoke_test_runner(project, command)

  logger.debug("neotest-vstest: Waiting for pid file to populate...")

  local max_wait = 30 * 1000 -- 30 sec

  return cli_wrapper.spin_lock_wait_file(pid_path, max_wait)
end

return M
