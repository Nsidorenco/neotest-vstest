local nio = require("nio")
local logger = require("neotest.logging")
local mtp_client = require("neotest-vstest.mtp")
local vstest_client = require("neotest-vstest.vstest")
local dotnet_utils = require("neotest-vstest.dotnet_utils")

local client_discovery = {}

local clients = {}

---@param project DotnetProjectInfo?
---@param solution string? path to the solution file
---@return neotest-vstest.Client?
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
  local solution_projects = solution and dotnet_utils.get_solution_projects(solution)
  if solution_projects and #solution_projects.projects > 0 then
    if not vim.list_contains(solution_projects.projects, project) then
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

  ---@type neotest-vstest.Client
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

  clients[project.proj_file] = client
  return client
end

local solution_cache
local solution_semaphore = nio.control.semaphore(1)

function client_discovery.discover_solution_tests(root)
  if solution_cache then
    return solution_cache
  end

  solution_semaphore.acquire()

  local res = dotnet_utils.get_solution_projects(root)

  dotnet_utils.build_path(root)

  local project_clients = {}

  for _, project in ipairs(res.projects) do
    if project.is_test_project or project.is_mtp_project then
      project_clients[project.proj_file] = client_discovery.get_client_for_project(project, root)
    end
  end

  logger.debug("neotest-vstest: discovered projects:")
  logger.debug(res.projects)

  for _, client in ipairs(project_clients) do
    local project_tests = client:discover_tests()
    vim.tbl_extend("force", solution_cache, project_tests)
  end

  solution_semaphore.release()

  return solution_cache
end

return client_discovery
