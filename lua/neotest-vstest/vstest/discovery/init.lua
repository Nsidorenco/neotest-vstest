local nio = require("nio")
local lib = require("neotest.lib")
local logger = require("neotest.logging")
local files = require("neotest-vstest.files")
local dotnet_utils = require("neotest-vstest.dotnet_utils")
local discovery_cache = require("neotest-vstest.vstest.discovery.cache")
local cli_wrapper = require("neotest-vstest.vstest.cli_wrapper")

local M = {}

local project_semaphore = nio.control.semaphore(1)
local project_semaphores = {}

---@param projects DotnetProjectInfo[]
---@return table?
local function discover_tests_in_projects(projects)
  local tests_in_files

  local wait_file = nio.fn.tempname()
  local output_file = nio.fn.tempname()

  local dlls = {}

  for _, project in ipairs(projects) do
    dlls[#dlls + 1] = project.dll_file
  end

  local command = vim
    .iter({
      "discover",
      output_file,
      wait_file,
      dlls,
    })
    :flatten()
    :join(" ")

  logger.debug("neotest-vstest: Discovering tests using:")
  logger.debug(command)

  cli_wrapper.invoke_test_runner(command)

  logger.debug("neotest-vstest: Waiting for result file to populated...")

  local max_wait = 60 * 1000 -- 60 sec

  if cli_wrapper.spin_lock_wait_file(wait_file, max_wait) then
    local content = cli_wrapper.spin_lock_wait_file(output_file, max_wait)

    logger.debug("neotest-vstest: file has been populated. Extracting test cases...")

    tests_in_files = (content and vim.json.decode(content, { luanil = { object = true } })) or {}

    -- DisplayName may be almost equal to FullyQualifiedName of a test
    -- In this case the DisplayName contains a lot of redundant information in the neotest tree.
    -- Thus we want to detect this for the test cases and if a match is found
    -- we can shorten the display name to the section after the last period
    short_test_names = {}
    for path, test_cases in pairs(tests_in_files) do
      short_test_names[path] = {}
      for id, test in pairs(test_cases) do
        short_name = test.DisplayName
        if vim.startswith(test.DisplayName, test.FullyQualifiedName) then
          short_name = string.gsub(test.DisplayName, "[^(]+%.", "", 1)
        end
        short_test_names[path][id] = vim.tbl_extend("force", test, { DisplayName = short_name })
      end
    end
    tests_in_files = short_test_names

    logger.trace("neotest-vstest: done decoding test cases:")
    logger.trace(tests_in_files)
  end

  return tests_in_files
end

---@param project DotnetProjectInfo
---@param path string path to file to extract tests from
---@return table<string, TestCase> | nil test_cases map from id -> test case
function M.discover_project_tests(project, path)
  if not project.is_test_project then
    logger.info(string.format("neotest-vstest: %s is not a test project. Skipping.", path))
    return
  end

  if project.proj_file == "" then
    logger.warn(string.format("neotest-vstest: failed to find project file for %s", path))
    return
  end

  if project.dll_file == "" then
    logger.warn(string.format("neotest-vstest: failed to find dll file for %s", path))
    return
  end

  local semaphore

  project_semaphore.with(function()
    if project_semaphores[project.proj_file] then
      semaphore = project_semaphores[project.proj_file]
    else
      project_semaphores[project.proj_file] = nio.control.semaphore(1)
      semaphore = project_semaphores[project.proj_file]
    end
  end)

  semaphore.acquire()
  logger.debug("acquired semaphore for " .. project.proj_file .. " on path: " .. path)

  local project_last_modified = dotnet_utils.get_project_last_modified(project)
  local path_last_modified = files.get_path_last_modified(path)

  local rebuilt = false

  if
    project_last_modified
    and path_last_modified
    and (project_last_modified < path_last_modified)
  then
    rebuilt = dotnet_utils.build_project(project)
  end

  local cache_entry = discovery_cache.get_cache_entry(project, path)

  if cache_entry and cache_entry.LastModified and not rebuilt then
    semaphore.release()
    logger.debug(
      string.format(
        "released semaphore for %s on path: %s due to cache hit. last modified: %s last discovery: %s:",
        project.proj_file,
        path,
        project_last_modified,
        cache_entry.LastModified
      )
    )
    logger.debug(cache_entry.TestCases)

    return cache_entry.TestCases
  end

  local json = discover_tests_in_projects({ project })

  if json then
    discovery_cache.populate_discovery_cache(
      project,
      json,
      dotnet_utils.get_project_last_modified(project)
    )
  end

  semaphore.release()
  logger.debug("released semaphore for " .. project.proj_file .. " on path: " .. path)

  return (json and json[path]) or {}
end

---@param path string
---@return table<string, TestCase> | nil test_cases map from id -> test case
function M.discover_tests(path)
  local project = dotnet_utils.get_proj_info(path)
  if not project then
    logger.warn(string.format("neotest-vstest: failed to find project for %s", path))
    return {}
  end

  return M.discover_project_tests(project, path)
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

  local project_paths = {}

  for _, project in ipairs(res.projects) do
    project_paths[#project_paths + 1] = project.proj_file
  end

  solution_cache = project_paths

  logger.debug("neotest-vstest: discovered projects:")
  logger.debug(res.projects)

  local json = discover_tests_in_projects(res.projects)

  if json then
    for _, project in ipairs(res.projects) do
      discovery_cache.populate_discovery_cache(
        project,
        json,
        dotnet_utils.get_project_last_modified(project)
      )
    end
  end

  solution_semaphore.release()

  return solution_cache
end

return M
