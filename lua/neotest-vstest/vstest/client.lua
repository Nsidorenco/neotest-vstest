local nio = require("nio")
local lib = require("neotest.lib")
local logger = require("neotest.logging")
local cli_wrapper = require("neotest-vstest.vstest.cli_wrapper")

local M = {}

---@param runner function
---@param project DotnetProjectInfo
---@return table?
function M.discover_tests_in_project(runner, project)
  local tests_in_files = {}

  local wait_file = nio.fn.tempname()
  local output_file = nio.fn.tempname()

  local command = vim
    .iter({
      "discover",
      output_file,
      wait_file,
      { project.dll_file },
    })
    :flatten()
    :join(" ")

  logger.debug("neotest-vstest: Discovering tests using:")
  logger.debug(command)

  runner(command)

  logger.debug("neotest-vstest: Waiting for result file to populated...")

  local max_wait = 60 * 1000 -- 60 sec

  if cli_wrapper.spin_lock_wait_file(wait_file, max_wait) then
    cli_wrapper.spin_lock_wait_file(output_file, max_wait)
    local lines = lib.files.read_lines(output_file)

    logger.debug("neotest-vstest: file has been populated. Extracting test cases...")

    for _, line in ipairs(lines) do
      ---@type { File: string, Test: table }
      local decoded = vim.json.decode(line, { luanil = { object = true } }) or {}
      local tests = tests_in_files[decoded.File] or {}

      local test = {
        [decoded.Test.Id] = {
          CodeFilePath = decoded.Test.CodeFilePath,
          DisplayName = decoded.Test.DisplayName,
          LineNumber = decoded.Test.LineNumber,
          FullyQualifiedName = decoded.Test.FullyQualifiedName,
        },
      }

      tests_in_files[decoded.File] = vim.tbl_extend("force", tests, test)
    end

    -- DisplayName may be almost equal to FullyQualifiedName of a test
    -- In this case the DisplayName contains a lot of redundant information in the neotest tree.
    -- Thus we want to detect this for the test cases and if a match is found
    -- we can shorten the display name to the section after the last period
    local short_test_names = {}
    for path, test_cases in pairs(tests_in_files) do
      path = vim.fs.normalize(path)
      short_test_names[path] = {}
      for id, test in pairs(test_cases) do
        local short_name = test.DisplayName
        if vim.startswith(test.DisplayName, test.FullyQualifiedName) then
          short_name = string.gsub(test.DisplayName, "[^(]+%.", "", 1)
        end
        short_test_names[path][id] = vim.tbl_extend("force", test, { DisplayName = short_name })
      end
    end
    tests_in_files = short_test_names

    logger.trace("neotest-vstest: done decoding test cases:")
    logger.trace(tests_in_files)
  end

  return tests_in_files
end

---runs tests identified by ids.
---@param runner function
---@param ids string|string[]
---@return string process_output_path, string result_stream_file_path, string result_file_path
function M.run_tests(runner, ids)
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

  runner(command)

  return process_output_path, result_stream_path, result_path
end

--- Uses the vstest console to spawn a test process for the debugger to attach to.
---@param runner function
---@param ids string|string[]
---@return string? pid, async fun() on_attach, string process_output_path, string result_stream_file_path, string result_file_path
function M.debug_tests(runner, ids)
  local process_output_path = nio.fn.tempname()
  lib.files.write(process_output_path, "")

  local attached_path = nio.fn.tempname()

  local on_attach = function()
    logger.debug("neotest-vstest: Debugger attached, writing to file: " .. attached_path)
    lib.files.write(attached_path, "1")
  end

  local result_path = nio.fn.tempname()

  local result_stream_path = nio.fn.tempname()
  lib.files.write(result_stream_path, "")

  local pid_path = nio.fn.tempname()

  local command = vim
    .iter({
      "debug-tests",
      pid_path,
      attached_path,
      result_stream_path,
      result_path,
      process_output_path,
      ids,
    })
    :flatten()
    :join(" ")
  logger.debug("neotest-vstest: starting test in debug mode using:")
  logger.debug(command)

  runner(command)

  logger.debug("neotest-vstest: Waiting for pid file to populate...")

  local max_wait = 30 * 1000 -- 30 sec

  cli_wrapper.spin_lock_wait_file(pid_path, max_wait)
  local pid = lib.files.read(pid_path)
  return pid, on_attach, process_output_path, result_stream_path, result_path
end

return M
