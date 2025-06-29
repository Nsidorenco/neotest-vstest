local nio = require("nio")
local logger = require("neotest.logging")
local mtp_client = require("neotest-vstest.mtp")
local vstest_client = require("neotest-vstest.vstest")
local dotnet_utils = require("neotest-vstest.dotnet_utils")
local files = require("neotest-vstest.files")

--- @class neotest-vstest.wrapper-client: neotest-vstest.Client
--- @field project DotnetProjectInfo
--- @field discover_tests_for_path fun(self: neotest-vstest.Client, path: string): table<string, table<string, neotest-vstest.TestCase>>
--- @field private sub_client neotest-vstest.Client
--- @field private semaphore nio.control.Semaphore
--- @field private last_discovered integer
local TestClient = {}
TestClient.__index = TestClient

function TestClient:new(project, sub_client)
  local client = {
    sub_client = sub_client,
    project = project,
    semaphore = nio.control.semaphore(1),
    last_discovered = nil,
  }

  setmetatable(client, self)
  return client
end

function TestClient:discover_tests(path)
  self.semaphore.acquire()

  local last_modified

  local test_cases = self.sub_client.test_cases or {}

  if self.last_discovered == nil then
    last_modified = dotnet_utils.get_project_last_modified(self.project)
    self.last_discovered = last_modified or 0
    test_cases = self.sub_client:discover_tests()
  else
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
      test_cases = self.sub_client:discover_tests()
    end
  end

  self.semaphore.release()

  return test_cases
end

function TestClient:discover_tests_for_path(path)
  local tests = self:discover_tests(path)
  path = vim.fs.normalize(path)
  return tests[path]
end

function TestClient:run_tests(ids)
  return self.sub_client:run_tests(ids)
end

function TestClient:debug_tests(ids)
  return self.sub_client:debug_tests(ids)
end

local client_discovery = {}

local clients = {}

---@param project DotnetProjectInfo?
---@param solution string? path to the solution file
---@return neotest-vstest.wrapper-client?
function client_discovery.get_client_for_project(project, solution)
  if not project then
    logger.debug("neotest-vstest: No project provided, returning nil client.")
    return nil
  end

  if clients[project.proj_file] ~= nil then
    return clients[project.proj_file] or nil
  end

  -- Check if the project is part of a solution.
  -- If not then do not create a client.
  local solution_projects = solution and dotnet_utils.get_solution_info(solution)
  if solution_projects and #solution_projects.projects > 0 then
    local exists_in_solution = vim.iter(solution_projects.projects):any(function(solution_project)
      return solution_project == project
    end)

    if not exists_in_solution then
      logger.debug(
        "neotest-vstest: project is not part of the solution projects: "
          .. vim.inspect(solution_projects.projects)
          .. ", project: "
          .. vim.inspect(project)
      )
      clients[project.proj_file] = false
      return
    end
  else
    logger.debug(
      "neotest-vstest: no solution projects found for solution: " .. vim.inspect(solution)
    )
  end

  ---@type neotest-vstest.wrapper-client
  local client

  -- Project is part of a solution or standalone, create a client.
  if project.is_mtp_project then
    logger.debug(
      "neotest-vstest: Creating mtp client for project "
        .. project.proj_file
        .. " and "
        .. project.dll_file
    )
    client = mtp_client:new(project)
  elseif project.is_test_project then
    client = vstest_client:new(project)
  else
    logger.warn(
      "neotest-vstest: Project is neither test project nor mtp project, returning nil client for "
        .. project.proj_file
    )
    clients[project.proj_file] = false
    return
  end

  client = TestClient:new(project, client)

  clients[project.proj_file] = client
  return client
end

return client_discovery
