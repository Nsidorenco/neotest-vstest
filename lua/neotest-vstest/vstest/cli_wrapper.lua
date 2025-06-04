local nio = require("nio")
local lib = require("neotest.lib")
local logger = require("neotest.logging")
local dotnet_utils = require("neotest-vstest.dotnet_utils")

local M = {}

M.sdk_path = nil

local function get_vstest_path()
  if not M.sdk_path then
    local process = nio.process.run({
      cmd = "dotnet",
      args = { "--info" },
    })

    local default_sdk_path
    if vim.fn.has("win32") then
      default_sdk_path = "C:/Program Files/dotnet/sdk/"
    else
      default_sdk_path = "/usr/local/share/dotnet/sdk/"
    end

    if not process then
      M.sdk_path = default_sdk_path
      local log_string =
        string.format("neotest-vstest: failed to detect sdk path. falling back to %s", M.sdk_path)

      logger.info(log_string)
      nio.scheduler()
      vim.notify_once(log_string)
    else
      local out = process.stdout.read()
      local info = dotnet_utils.parse_dotnet_info(out or "")
      if info.sdk_path then
        M.sdk_path = info.sdk_path
        logger.info(string.format("neotest-vstest: detected sdk path: %s", M.sdk_path))
      else
        M.sdk_path = default_sdk_path
        local log_string =
          string.format("neotest-vstest: failed to detect sdk path. falling back to %s", M.sdk_path)
        logger.info(log_string)
        nio.scheduler()
        vim.notify_once(log_string)
      end
      process.close()
    end
  end

  return vim.fs.find("vstest.console.dll", { upward = false, type = "file", path = M.sdk_path })[1]
end

local function get_script(script_name)
  local script_paths = vim.api.nvim_get_runtime_file(vim.fs.joinpath("scripts", script_name), true)
  logger.debug("neotest-vstest: possible scripts:")
  logger.debug(script_paths)
  for _, path in ipairs(script_paths) do
    if path:match("neotest%-vstest") ~= nil then
      return path
    end
  end
end

local test_runner_map = {}
local test_runner_semaphore = nio.control.semaphore(1)
local command_semaphore = {}

---@param project DotnetProjectInfo
---@param command any
function M.invoke_test_runner(project, command)
  local semaphore
  test_runner_semaphore.with(function()
    if command[project.proj_file] then
      semaphore = command_semaphore[project.proj_file]
    else
      command_semaphore[project.proj_file] = nio.control.semaphore(1)
      semaphore = command_semaphore[project.proj_file]
    end
  end)

  semaphore.with(function()
    if test_runner_map[project.dll_file] ~= nil then
      return
    end

    local test_discovery_script = get_script("run_tests.fsx")
    local testhost_dll = get_vstest_path()

    logger.debug("neotest-vstest: found discovery script: " .. test_discovery_script)
    logger.debug("neotest-vstest: found testhost dll: " .. testhost_dll)

    local vstest_command = { "dotnet", "fsi", test_discovery_script, testhost_dll }

    logger.info("neotest-vstest: starting vstest console with for " .. project.dll_file .. " with:")
    logger.info(vstest_command)

    local process = vim.system(vstest_command, {
      stdin = true,
      stdout = function(err, data)
        if data then
          logger.trace("neotest-vstest: " .. data)
        end
        if err then
          logger.trace("neotest-vstest " .. err)
        end
      end,
    }, function(obj)
      vim.schedule(function()
        vim.notify_once("neotest-vstest: vstest process exited unexpectedly.", vim.log.levels.ERROR)
      end)
      logger.warn("neotest-vstest: vstest process died :(")
      logger.warn(obj.code)
      logger.warn(obj.signal)
      logger.warn(obj.stdout)
      logger.warn(obj.stderr)
    end)

    logger.info(string.format("neotest-vstest: spawned vstest process with pid: %s", process.pid))

    test_runner_map[project.dll_file] = function(content)
      process:write(content .. "\n")
    end
  end)

  return test_runner_map[project.dll_file](command)
end

local spin_lock = nio.control.semaphore(1)

---Repeatly tries to read content. Repeats until the file is non-empty or operation times out.
---@param file_path string
---@param max_wait integer maximal time to wait for the file to populated in milliseconds.
---@return boolean
function M.spin_lock_wait_file(file_path, max_wait)
  local sleep_time = 25 -- scan every 25 ms
  local tries = 1
  local file_exists = false

  while not file_exists and tries * sleep_time < max_wait do
    if lib.files.exists(file_path) then
      spin_lock.with(function()
        file_exists = true
      end)
    else
      tries = tries + 1
      nio.sleep(sleep_time)
    end
  end

  if not file_exists then
    logger.warn(string.format("neotest-vstest: timed out reading content of file %s", file_path))
  end

  return file_exists
end

return M
