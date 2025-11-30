local nio = require("nio")
local lib = require("neotest.lib")
local logger = require("neotest.logging")
local cli_wrapper = require("neotest-vstest.vstest.cli_wrapper")
local utilities = require("neotest-vstest.utilities")
local vstest_client = require("neotest-vstest.vstest.client")

--- @class neotest-vstest.vstest-client: neotest-vstest.Client
--- @field project DotnetProjectInfo
--- @field settings string? path to .runsettings file or nil
--- @field private test_runner { execute: function, stop: function }
local Client = {}
Client.__index = Client
Client.__gc = function(self)
  if self.test_runner then
    self.test_runner.stop()
  end
end

---@param project DotnetProjectInfo
function Client:new(project)
  logger.info("neotest-vstest: Creating new (vstest) client for: " .. vim.inspect(project))
  local findSettings = function()
    local settings = nil
    if vim.g.neotest_vstest.find_settings then
      settings = vim.g.neotest_vstest.find_settings(project.proj_dir)
    end
    if settings ~= nil then
      return settings
    else
      return vstest_client.find_runsettings_for_project(project.proj_dir)
    end
  end
  local client = {
    project = project,
    test_cases = {},
    last_discovered = 0,
    test_runner = cli_wrapper.create_test_runner(project),
    settings = findSettings(),
  }
  setmetatable(client, self)

  return client
end

function Client:discover_tests()
  self.test_cases = vstest_client.discover_tests_in_project(
    self.test_runner.execute,
    self.settings,
    self.project
  ) or {}

  return self.test_cases
end

---@async
---@param ids string[] list of test ids to run
---@return neotest-vstest.Client.RunResult
function Client:run_tests(ids)
  local result_future = nio.control.future()
  local process_output_file, stream_file, result_file =
    vstest_client.run_tests(self.test_runner.execute, self.settings, ids)

  local result_stream_data, result_stop_stream = lib.files.stream_lines(stream_file)
  local output_stream_data, output_stop_stream = lib.files.stream_lines(process_output_file)

  local result_stream = utilities.stream_queue()

  nio.run(function()
    local stream = result_stream_data()
    for _, line in ipairs(stream) do
      local success, result = pcall(vim.json.decode, line)
      assert(success, "neotest-vstest: failed to decode result stream: " .. line)
      result_stream.write(result)
    end
  end)

  local stop_stream = function()
    output_stop_stream()
    result_stop_stream()
  end

  nio.run(function()
    cli_wrapper.spin_lock_wait_file(result_file, vim.g.neotest_vstest.timeout_ms)
    local parsed = {}
    local results = lib.files.read_lines(result_file)
    for _, line in ipairs(results) do
      local success, result = pcall(vim.json.decode, line)
      assert(success, "neotest-vstest: failed to decode result file: " .. line)
      parsed[result.id] = result.result
    end
    result_future.set(parsed)
  end)

  return {
    result_future = result_future,
    result_stream = result_stream.get,
    output_stream = output_stream_data,
    stop = stop_stream,
  }
end

---@async
---@param ids string[] list of test ids to run
---@return neotest-vstest.Client.RunResult
function Client:debug_tests(ids)
  local result_future = nio.control.future()
  local pid, on_attach, process_output_file, stream_file, result_file =
    vstest_client.debug_tests(self.test_runner.execute, self.settings, ids)

  local result_stream_data, result_stop_stream = lib.files.stream_lines(stream_file)
  local output_stream_data, output_stop_stream = lib.files.stream_lines(process_output_file)

  local result_stream = utilities.stream_queue()

  nio.run(function()
    local stream = result_stream_data()
    for _, line in ipairs(stream) do
      local success, result = pcall(vim.json.decode, line)
      assert(success, "neotest-vstest: failed to decode result stream: " .. line)
      result_stream.write(result)
    end
  end)

  local stop_stream = function()
    output_stop_stream()
    result_stop_stream()
  end

  nio.run(function()
    local parsed = {}
    local file_exists =
      cli_wrapper.spin_lock_wait_file(result_file, vim.g.neotest_vstest.timeout_ms)
    assert(
      file_exists,
      "neotest-vstest: (possible timeout, check logs) result file does not exist: " .. result_file
    )
    local results = lib.files.read_lines(result_file)
    for _, line in ipairs(results) do
      local success, result = pcall(vim.json.decode, line)
      assert(success, "neotest-vstest: failed to decode result file: " .. line)
      parsed[result.id] = result.result
    end
    result_future.set(parsed)
  end)

  assert(pid, "neotest-vstest: failed to get pid from debug tests")

  return {
    pid = pid,
    on_attach = on_attach,
    result_future = result_future,
    output_stream = output_stream_data,
    result_stream = result_stream.get,
    stop = stop_stream,
  }
end

return Client
