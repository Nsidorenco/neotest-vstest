local nio = require("nio")
local lib = require("neotest.lib")
local logger = require("neotest.logging")
local dotnet_utils = require("neotest-vstest.dotnet_utils")
local vstest = require("neotest-vstest.vstest")
local files = require("neotest-vstest.files")
local utilities = require("neotest-vstest.utilities")
local mtp_client = require("neotest-vstest.mtp.client")

---@class neotest-vstest.Client.RunResult
---@field output_stream fun(): string[]
---@field result_stream async fun(): any
---@field result_future nio.control.Future
---@field stop fun()
---
---@class neotest-vstest.Client.DebugResult
---@field pid string
---@field on_attach fun(): nil
---@field output_stream fun(): string[]
---@field result_stream async fun(): any
---@field result_future nio.control.Future
---@field stop fun()

---@class neotest-vstest.Client
---@field run_tests fun(self: neotest-vstest.Client, ids: string|string[]): neotest-vstest.Client.RunResult
---@field discover_tests fun(self: neotest-vstest.Client): table<string, table>
---@field discover_tests_for_path fun(self: neotest-vstest.Client, path: string): table<string, table>
---@field debug_tests fun(self: neotest-vstest.Client, ids: string|string[]): neotest-vstest.Client.DebugResult

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

local function map_test_cases(test_nodes)
  local test_cases = {}
  for _, node in ipairs(test_nodes) do
    local existing = test_cases[node["location.file"]] or {}
    test_cases[node["location.file"]] = vim.tbl_extend("force", existing, {
      [node.uid] = {
        CodeFilePath = node["location.file"],
        DisplayName = node["display-name"],
        LineNumber = node["location.line-start"],
        FullyQualifiedName = node["location.method"],
      },
    })
  end

  return test_cases
end

function Client:discover_tests()
  self.semaphore.with(function()
    local last_modified = dotnet_utils.get_project_last_modified(self.project)
    if last_modified and last_modified > self.last_discovered then
      last_modified = dotnet_utils.get_project_last_modified(self.project)
      self.last_discovered = last_modified or 0
      self.test_nodes = mtp_client.discovery_tests(self.project.dll_file)
      self.test_cases = map_test_cases(self.test_nodes)
      logger.debug("neotest-vstest: Discovered tests for project " .. self.project)
      logger.debug(self.test_cases)
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
      self.test_nodes = mtp_client.discovery_tests(self.project.dll_file)
      self.test_cases = map_test_cases(self.test_nodes)
    end
  end)

  return self.test_cases[path]
end

---@async
---@param ids string[] list of test ids to run
---@return neotest-vstest.Client.RunResult
function Client:run_tests(ids)
  logger.debug("neotest-vstest: Running tests with ids: " .. vim.inspect(ids))
  logger.debug(self)
  local nodes = {}
  for _, node in ipairs(self.test_nodes) do
    if vim.tbl_contains(ids, node.uid) then
      nodes[#nodes + 1] = node
    end
  end
  return mtp_client.run_tests(self.project.dll_file, nodes)
end

---@async
---@param ids string[] list of test ids to run
---@return neotest-vstest.Client.RunResult
function Client:debug_tests(ids)
  return
end

return Client
