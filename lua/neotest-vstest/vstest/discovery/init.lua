local nio = require("nio")
local logger = require("neotest.logging")
local dotnet_utils = require("neotest-vstest.dotnet_utils")
local Client = require("neotest-vstest.client")
local mtp_client = require("neotest-vstest.mtp")

local M = {}

local client_creation_semaphore = nio.control.semaphore(1)
local clients = {}

---@param project DotnetProjectInfo?
---@return neotest-vstest.Client?
function M.get_client_for_project(project)
  if not project then
    return nil
  end

  local client
  client_creation_semaphore.with(function()
    if clients[project.proj_file] then
      client = clients[project.proj_file]
    else
      if project.is_mtp_project then
        logger.debug(
          "neotest-vstest: Creating mtp client for project "
            .. project.proj_file
            .. " and "
            .. project.dll_file
        )
        client = mtp_client:new(project)
      elseif project.is_test_project then
        client = Client:new(project)
      end
      clients[project.proj_file] = client
    end
  end)
  return client
end

local solution_cache
local solution_semaphore = nio.control.semaphore(1)

function M.discover_solution_tests(root)
  if solution_cache then
    return solution_cache
  end

  solution_semaphore.acquire()

  local res = dotnet_utils.get_solution_projects(root)

  dotnet_utils.build_path(root)

  local project_clients = {}

  for _, project in ipairs(res.projects) do
    if project.is_test_project or project.is_mtp_project then
      project_clients[project.proj_file] = M.get_client_for_project(project)
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

return M
