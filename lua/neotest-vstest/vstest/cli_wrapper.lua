local nio = require("nio")
local lib = require("neotest.lib")
local logger = require("neotest.logging")
local dotnet_utils = require("neotest-vstest.dotnet_utils")

local M = {}

---@async
---@return string?
local function find_vstest_path()
  local config = require("neotest-vstest.config").get_config()
  local path_to_search = config.sdk_path

  if not path_to_search then
    local default_sdk_path
    if vim.fn.has("win32") == 1 then
      default_sdk_path = "C:/Program Files/dotnet/sdk/"
    else
      default_sdk_path = "/usr/local/share/dotnet/sdk/"
    end

    local _, obj = dotnet_utils.run_dotnet({ "--info" }, { no_build_args = true })

    local out = obj.stdout
    local info = dotnet_utils.parse_dotnet_info(out or "")
    if info.sdk_path then
      path_to_search = info.sdk_path
      logger.info(string.format("neotest-vstest: detected sdk path: %s", path_to_search))
    else
      path_to_search = default_sdk_path
      local log_string = string.format(
        "neotest-vstest: failed to detect sdk path. falling back to %s",
        path_to_search
      )
      logger.info(log_string)
      nio.scheduler()
      vim.notify_once(log_string)
    end
  end

  if not lib.files.is_dir(path_to_search) then
    logger.warn("neotest-vstest: sdk path does not exist: " .. path_to_search)
    return nil
  end

  return vim.iter(lib.files.find(vim.fs.normalize(path_to_search))):find(function(file)
    return vim.fs.basename(file) == "vstest.console.dll"
  end)
end

---@type nio.control.Future?
local vstest_path

---@async
---@return string?
function M.get_vstest_path()
  -- every project's client asks for this at once, so they share one search
  if not vstest_path then
    vstest_path = nio.control.future()
    local ok, path = pcall(find_vstest_path)
    if ok then
      vstest_path.set(path)
    else
      vstest_path.set_error(path)
    end
  end
  return vstest_path.wait()
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

---@type nio.control.Future? the test runner process shared by all projects
local shared_process

---the runner prints errors the user should see on lines with this prefix
local error_prefix = "neotest-vstest-error: "

---@return fun(err: string?, data: string?)
local function runner_stdout_handler()
  local pending = ""
  return function(err, data)
    if err then
      logger.trace("neotest-vstest " .. err)
    end
    if not data then
      return
    end
    logger.trace("neotest-vstest:", data)

    -- output arrives in arbitrary chunks, so only complete lines are checked
    -- plain finds keep this linear; a pattern would rescan an unfinished line from every position
    pending = pending .. data
    local line_start = 1
    while true do
      local line_end = pending:find("\n", line_start, true)
      if not line_end then
        break
      end
      if pending:sub(line_start, line_start + #error_prefix - 1) == error_prefix then
        local message = "neotest-vstest: "
          .. vim.trim(pending:sub(line_start + #error_prefix, line_end - 1))
        logger.error(message)
        vim.schedule(function()
          vim.notify_once(message, vim.log.levels.ERROR)
        end)
      end
      line_start = line_end + 1
    end
    pending = pending:sub(line_start)
    -- an unfinished line is only kept while it could still become an error line
    if #pending > #error_prefix and not vim.startswith(pending, error_prefix) then
      pending = ""
    end
  end
end

---starting the runner compiles its script, which takes seconds, so every project shares one
---@async
---@param process_future nio.control.Future
---@return vim.SystemObj
local function start_runner_process(process_future)
  local test_discovery_script = get_script("run_tests.fsx")
  nio.scheduler()
  local testhost_dll = M.get_vstest_path()

  logger.debug("neotest-vstest: found discovery script: " .. test_discovery_script)
  logger.debug("neotest-vstest: found testhost dll: " .. testhost_dll)

  local vstest_command =
    { dotnet_utils.get_dotnet_executable(), "fsi", test_discovery_script, testhost_dll }
  nio.scheduler()

  logger.info("neotest-vstest: starting vstest console with:")
  logger.info(vstest_command)

  local process = vim.system(vstest_command, {
    detach = false,
    stdin = true,
    stdout = runner_stdout_handler(),
  }, function(obj)
    -- the next command of any project starts a new runner
    if shared_process == process_future then
      shared_process = nil
    end
    vim.schedule(function()
      vim.notify_once(
        "neotest-vstest: vstest process exited unexpectedly. It will be restarted when needed.",
        vim.log.levels.ERROR
      )
    end)
    logger.warn("neotest-vstest: vstest process died :(")
    logger.warn(obj.code)
    logger.warn(obj.signal)
    logger.warn(obj.stdout)
    logger.warn(obj.stderr)
  end)

  nio.scheduler()
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("neotest_vstest_server_shutdown", { clear = false }),
    desc = "Shutdown dotnet VSTest client process on Neovim exit",
    callback = function()
      -- the process may already have died and been replaced
      pcall(process.kill, process, vim.uv.constants.SIGKILL)
    end,
  })

  logger.info(string.format("neotest-vstest: spawned vstest process with pid: %s", process.pid))

  return process
end

---@async
---@return nio.control.Future process_future the running runner, started if there is none
local function get_runner_process()
  if not shared_process then
    local process_future = nio.control.future()
    shared_process = process_future
    local ok, process = pcall(start_runner_process, process_future)
    if ok then
      process_future.set(process)
    else
      shared_process = nil
      process_future.set_error(process)
    end
  end
  return shared_process
end

local session_count = 0

---@async
---@param project DotnetProjectInfo
---@return { execute: async fun(content: string), stop: async fun() }
function M.create_test_runner(project)
  local process_future = get_runner_process()
  process_future.wait()

  -- the runner keeps a vstest console per session, so each project gets its own
  session_count = session_count + 1
  local session = tostring(session_count)
  logger.info(
    string.format("neotest-vstest: using vstest session %s for %s", session, project.dll_file)
  )

  ---@type string? the last discover command, replayed when the runner is restarted
  local last_discovery

  local function write(line)
    process_future.wait():write(line .. "\n")
  end

  return {
    execute = function(content)
      local command, args = content:match("^(%S+)(.*)$")
      local line = command .. " " .. session .. args

      if process_future ~= shared_process then
        logger.info("neotest-vstest: restarting vstest runner for session " .. session)
        process_future = get_runner_process()
        -- the new runner knows no tests until it discovers them, and it finishes a session's
        -- discoveries before running anything sent after them
        if command ~= "discover" and last_discovery then
          write(last_discovery)
        end
      end

      if command == "discover" then
        last_discovery = line
      end
      write(line)
    end,
    stop = function()
      if process_future == shared_process then
        write("end-session " .. session)
      end
    end,
  }
end

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
      file_exists = true
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
