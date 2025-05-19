local nio = require("nio")
local lib = require("neotest.lib")
local dotnet_utils = require("neotest-vstest.dotnet_utils")
local vstest = require("neotest-vstest.vstest")
local cli_wrapper = require("neotest-vstest.vstest.cli_wrapper")
local files = require("neotest-vstest.files")
local utilities = require("neotest-vstest.utilities")

local Client = {}
Client.__index = Client

---@param project DotnetProjectInfo
function Client:new(project)
  local client = {
    project = project,
    test_cases = {},
    last_discovered = 0,
    semaphore = nio.control.semaphore(1),
  }
  setmetatable(client, self)
  return client
end

function Client:discover_tests()
  self.semaphore.with(function()
    local last_modified = dotnet_utils.get_project_last_modified(self.project)
    if last_modified and last_modified > self.last_discovered then
      last_modified = dotnet_utils.get_project_last_modified(self.project)
      self.last_discovered = last_modified or 0
      self.test_cases = vstest.discover_tests_in_project(self.project) or {}
    end
  end)

  return self.test_cases
end

function Client:discover_tests_for_path(path)
  self.semaphore.with(function()
    local path_last_modified = files.get_path_last_modified(path)
    if path_last_modified and path_last_modified > self.last_discovered then
      dotnet_utils.build_project(self.project)
      local last_modified = dotnet_utils.get_project_last_modified(self.project)
      self.last_discovered = last_modified
      self.test_cases = vstest.discover_tests_in_project(self.project) or {}
    end
  end)

  return self.test_cases[path]
end

---@async
---@param ids string[] list of test ids to run
---@return neotest-vstest.Client.RunResult
function Client:run_tests(ids)
  local result_future = nio.control.future()
  local process_output_file, stream_file, result_file = vstest.run_tests(self.project, ids)

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
    cli_wrapper.spin_lock_wait_file(result_file, 5 * 30 * 1000)
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
    output_stream = output_stream_data,
    result_stream = result_stream.get,
    stop = stop_stream,
  }
end

---@async
---@param ids string[] list of test ids to run
---@return neotest-vstest.Client.RunResult
function Client:debug_tests(ids)
  local result_future = nio.control.future()
  local pid, on_attach, process_output_file, stream_file, result_file =
    vstest.debug_tests(self.project, ids)

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
    cli_wrapper.spin_lock_wait_file(result_file, 5 * 30 * 1000)
    local parsed = {}
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
