---@class TestCase
---@field Id string
---@field CodeFilePath string
---@field DisplayName string
---@field FullyQualifiedName string
---@field LineNumber integer

---@class NeotestDotnetClientAdapter
---@field discover_tests fun(self: NeotestDotnetClient, project: DotnetProjectInfo): table<string, TestCase[]>
---@field run_tests fun(self: NeotestDotnetClient, tests: TestCase[]): table<string, TestCase[]>

local NeotestDotnetClient = {}

---@param project DotnetProjectInfo
function NeotestDotnetClient.discovery_tests(project)
  if project.is_mtp_project then
  else
  end
end

return NeotestDotnetClient
