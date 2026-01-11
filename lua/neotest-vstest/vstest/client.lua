local nio = require("nio")
local lib = require("neotest.lib")
local logger = require("neotest.logging")
local cli_wrapper = require("neotest-vstest.vstest.cli_wrapper")

local M = {}

---@param project_dir string
---@return string? path to .runsettings file to use or nil
function M.find_runsettings_for_project(project_dir)
  local settings = vim.fs.find(function(name, _)
    return name:match("%.runsettings$")
  end, {
    upward = false,
    type = "file",
    path = project_dir,
    limit = math.huge,
  })

  for _, set in pairs(settings) do
    logger.debug(string.format("neotest-vstest: Found .runsettings: %s", set))
  end

  local setting
  if #settings > 0 then
    local settings_future = nio.control.future()

    if #settings == 1 then
      setting = settings[1]
      settings_future.set(setting)
      logger.info(string.format("neotest-vstest: selected .runsetting file: %s", setting))
    else
      vim.schedule(function()
        nio.run(function()
          vim.ui.select(settings, {
            prompt = "Multiple .runsettings exists. Select a .runsettings file: ",
          }, function(selected)
            if selected then
              setting = selected
              logger.info(string.format("neotest-vstest: selected .runsetting file: %s", setting))
              settings_future.set(setting)
            else
              settings_future.set("nil")
            end
          end)
        end)
      end)
    end

    if settings_future.wait() and setting then
      return setting
    end
  end
  logger.info(string.format("neotest-vstest: Found no .runsettings files"))
  return nil
end

---@param runner function
---@param project DotnetProjectInfo
---@return table?
function M.discover_tests_in_project(runner, settings, project)
  local tests_in_files = {}

  local wait_file = nio.fn.tempname()
  local output_file = nio.fn.tempname()

  local command = vim
    .iter({
      "discover",
      output_file,
      wait_file,
      settings or "nil",
      { project.dll_file },
    })
    :flatten()
    :join(" ")

  logger.debug("neotest-vstest: Discovering tests using:")
  logger.debug(command)

  runner(command)

  logger.debug("neotest-vstest: Waiting for result file to populated...")

  local config = require("neotest-vstest.config").get_config()

  if cli_wrapper.spin_lock_wait_file(wait_file, config.timeout_ms) then
    cli_wrapper.spin_lock_wait_file(output_file, config.timeout_ms)
    local lines = lib.files.read_lines(output_file)

    logger.debug("neotest-vstest: file has been populated. Extracting test cases...")

    for _, line in ipairs(lines) do
      ---@type { File: string, Test: table }
      local decoded = vim.json.decode(line, { luanil = { object = true } }) or {}
      local file = vim.fs.normalize(decoded.File or "")
      local tests = tests_in_files[file] or {}

      local test = {
        [decoded.Test.Id] = {
          CodeFilePath = decoded.Test.CodeFilePath,
          DisplayName = decoded.Test.DisplayName,
          LineNumber = decoded.Test.LineNumber,
          FullyQualifiedName = decoded.Test.FullyQualifiedName,
        },
      }

      tests_in_files[file] = vim.tbl_extend("force", tests, test)
    end

    -- DisplayName may be almost equal to FullyQualifiedName of a test
    -- In this case the DisplayName contains a lot of redundant information in the neotest tree.
    -- Thus we want to detect this for the test cases and if a match is found
    -- we can shorten the display name to the section after the last period
    local short_test_names = {}
    for path, test_cases in pairs(tests_in_files) do
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
function M.run_tests(runner, settings, ids)
  local process_output_path = nio.fn.tempname()
  lib.files.write(process_output_path, "")

  local result_path = nio.fn.tempname()

  local result_stream_path = nio.fn.tempname()
  lib.files.write(result_stream_path, "")

  local output_dir_path = nio.fn.tempname()
  local mkdir_err, _ = nio.uv.fs_mkdir(output_dir_path, 493) -- tonumber('755', 8)
  assert(not mkdir_err, mkdir_err)

  local command = vim
    .iter({
      "run-tests",
      result_stream_path,
      result_path,
      process_output_path,
      output_dir_path,
      settings or "nil",
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
function M.debug_tests(runner, settings, ids)
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

  local output_dir_path = nio.fn.tempname()
  local mkdir_err, _ = nio.uv.fs_mkdir(output_dir_path, 493) -- tonumber('755', 8)
  assert(not mkdir_err, mkdir_err)

  local pid_path = nio.fn.tempname()

  local command = vim
    .iter({
      "debug-tests",
      pid_path,
      attached_path,
      result_stream_path,
      result_path,
      process_output_path,
      output_dir_path,
      settings or "nil",
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
