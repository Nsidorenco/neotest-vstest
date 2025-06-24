local logger = require("neotest.logging")
local mtp_client = require("neotest-vstest.mtp.client")

--- @class neotest-vstest.mtp-client: neotest-vstest.Client
--- @field project DotnetProjectInfo
--- @field private last_discovered integer
local Client = {}
Client.__index = Client

---@param project DotnetProjectInfo
function Client:new(project)
  logger.info("neotest-vstest: Creating new (MTP) client for: " .. vim.inspect(project))
  local client = {
    project = project,
    test_cases = {},
    last_discovered = 0,
  }
  setmetatable(client, self)

  return client
end

local function map_test_cases(project, test_nodes)
  local test_cases = {}
  for _, node in ipairs(test_nodes) do
    local location = node["location.file"] or project.proj_file
    location = location and vim.fs.normalize(location)
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

function Client:discover_tests()
  self.test_nodes = mtp_client.discovery_tests(self.project.dll_file)
  self.test_cases = map_test_cases(self.project, self.test_nodes)

  return self.test_cases
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
