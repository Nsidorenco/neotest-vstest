local nio = require("nio")
local logger = require("neotest.logging")
local dotnet_utils = require("neotest-vstest.dotnet_utils")
local files = require("neotest-vstest.files")
local mtp_client = require("neotest-vstest.mtp.client")

--- @class neotest-vstest.mtp-client: neotest-vstest.Client
--- @field project DotnetProjectInfo
--- @field semaphore nio.control.Semaphore
--- @field last_discovered integer
local Client = {}
Client.__index = Client

local clients = {}

---@param project DotnetProjectInfo
function Client:new(project)
  if clients[project.proj_file] then
    logger.info("neotest-vstest: Reusing existing (MTP) client for: " .. vim.inspect(project))
    return clients[project.proj_file]
  end

  logger.info("neotest-vstest: Creating new (MTP) client for: " .. vim.inspect(project))
  local client = {
    project = project,
    test_cases = {},
    last_discovered = 0,
    semaphore = nio.control.semaphore(1),
  }
  setmetatable(client, self)

  clients[project.proj_file] = client

  return client
end

local function map_test_cases(project, test_nodes)
  local test_cases = {}
  for _, node in ipairs(test_nodes) do
    local location = node["location.file"] or project.proj_file
    local line_number = node["location.line-start"] or node["location.line-end"] or 0
    local fully_qualified_name = node["location.type"]
      or node["location.method"]
      or node["display-name"]
    local existing = test_cases[location] or {}
    if node.uid then
      test_cases[location] = vim.tbl_extend("force", existing, {
        [node.uid] = {
          CodeFilePath = location,
          DisplayName = node["display-name"],
          LineNumber = line_number,
          FullyQualifiedName = fully_qualified_name,
        },
      })
    else
      logger.warn("neotest-vstest: failed to map test case: " .. vim.inspect(node))
    end
  end

  return test_cases
end

function Client:discover_tests(path)
  self.semaphore.acquire()

  local last_modified
  if path then
    last_modified = files.get_path_last_modified(path)
  else
    last_modified = dotnet_utils.get_project_last_modified(self.project)
  end
  if last_modified and last_modified > self.last_discovered then
    logger.debug(
      "neotest-vstest: Discovering tests: "
        .. " last modified at "
        .. last_modified
        .. " last discovered at "
        .. self.last_discovered
    )
    dotnet_utils.build_project(self.project)
    last_modified = dotnet_utils.get_project_last_modified(self.project)
    self.last_discovered = last_modified or 0
    self.test_nodes = mtp_client.discovery_tests(self.project.dll_file)
    self.test_cases = map_test_cases(self.project, self.test_nodes)
    logger.debug(self.test_cases)
  end

  self.semaphore.release()

  return self.test_cases
end

function Client:discover_tests_for_path(path)
  self:discover_tests(path)
  return self.test_cases[path]
end

---@async
---@param ids string[] list of test ids to run
---@return neotest-vstest.Client.RunResult
function Client:run_tests(ids)
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
  local nodes = {}
  for _, node in ipairs(self.test_nodes) do
    if vim.tbl_contains(ids, node.uid) then
      nodes[#nodes + 1] = node
    end
  end
  return mtp_client.debug_tests(self.project.dll_file, nodes)
end

return Client
