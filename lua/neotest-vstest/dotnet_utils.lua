local nio = require("nio")
local lib = require("neotest.lib")
local logger = require("neotest.logging")
local files = require("neotest-vstest.files")

--- @class BuildOpts
--- @field additional_args? string[]

---@class DotnetUtils
---@field private opts BuildOpts
local dotnet_utils = { opts = {} }

---@param opts BuildOpts
function dotnet_utils.add_opts(opts)
  dotnet_utils.opts = vim.tbl_extend("force", dotnet_utils.opts, opts)
end

---parses output of running `dotnet --info`
---@param input string?
---@return { sdk_path: string? }
function dotnet_utils.parse_dotnet_info(input)
  if input == nil then
    return { sdk_path = nil }
  end

  local match = input:match("Base Path:%s*([^\r\n]+)")
  return { sdk_path = match and vim.trim(match) }
end

---@param proj_file string
---@return string? target_framework
local function get_target_frameworks(proj_file)
  local msbuild_cmd = {
    "dotnet",
    "msbuild",
    proj_file,
    "-getProperty:TargetFramework",
    "-getProperty:TargetFrameworks",
  }
  for _, arg in ipairs(dotnet_utils.opts.additional_args or {}) do
    table.insert(msbuild_cmd, arg)
  end
  local code, res = lib.process.run(msbuild_cmd, {
    stderr = true,
    stdout = true,
  })

  logger.debug("neotest-vstest: msbuild target frameworks for " .. proj_file .. ":")
  logger.debug(res.stdout)

  if code ~= 0 then
    logger.error("neotest-vstest: failed to get msbuild target framework for " .. proj_file)
    logger.error(res.stderr)

    nio.scheduler()
    vim.notify(
      "Failed to get msbuild target framework for " .. proj_file .. " with error: " .. res.stderr,
      vim.log.levels.ERROR
    )
    return nil
  end

  local ok, parsed = pcall(nio.fn.json_decode, res.stdout)

  if not ok then
    logger.error("neotest-vstest: failed to parse msbuild target framework for " .. proj_file)
    logger.error(parsed)

    nio.scheduler()
    vim.notify(
      "Failed to parse msbuild target framework for " .. proj_file .. " with error: " .. parsed,
      vim.log.levels.ERROR
    )

    return nil
  end

  local framework_info = parsed.Properties
  local target_framework

  if framework_info.TargetFramework == "" then
    local frameworks =
      vim.split(vim.trim(framework_info.TargetFrameworks or ""), ";", { trimempty = true })
    table.sort(frameworks, function(a, b)
      return a > b
    end)
    target_framework = frameworks[1]
  else
    target_framework = vim.trim(framework_info.TargetFramework or "")
  end

  if not target_framework or target_framework == "" then
    logger.error("neotest-vstest: failed to get target framework for " .. proj_file)
    logger.error(framework_info)

    nio.scheduler()
    vim.notify(
      "Failed to get target framework for "
        .. proj_file
        .. " with error: "
        .. vim.inspect(framework_info),
      vim.log.levels.ERROR
    )

    return nil
  end

  return target_framework
end

---@class DotnetProjectInfo
---@field proj_file string
---@field dll_file string
---@field proj_dir string
---@field last_discovered integer
---@field is_test_project boolean
---@field is_mtp_project boolean is project compiled using Microsoft.Testting.Platform

---@type table<string, DotnetProjectInfo>
local proj_info_cache = {}

---@type table<string, string>
local file_to_project_map = {}

local project_semaphore = {}

---collects project information based on file
---@async
---@param path string
---@return DotnetProjectInfo?
function dotnet_utils.get_proj_info(path)
  local normalized_path = vim.fs.normalize(path)
  logger.debug("neotest-vstest: getting project info for " .. path)

  local proj_file

  if file_to_project_map[normalized_path] then
    proj_file = file_to_project_map[normalized_path]
  elseif vim.endswith(path, ".csproj") or vim.endswith(path, ".fsproj") then
    proj_file = path
  else
    proj_file = vim.fs.find(function(name, _)
      return name:match("%.[cf]sproj$")
    end, { upward = true, type = "file", path = vim.fs.dirname(path) })[1]
  end

  if not proj_file then
    return nil
  end

  proj_file = vim.fs.normalize(proj_file)

  local semaphore

  if project_semaphore[proj_file] then
    semaphore = project_semaphore[proj_file]
  else
    semaphore = nio.control.semaphore(1)
    project_semaphore[proj_file] = semaphore
  end

  semaphore.acquire()

  logger.debug("neotest-vstest: found project file for " .. path .. ": " .. proj_file)

  if proj_info_cache[proj_file] then
    local project = proj_info_cache[proj_file]
    local last_modified = files.get_path_last_modified(project.proj_file)
    if last_modified and last_modified <= project.last_discovered then
      semaphore.release()
      return project
    end
  end

  logger.debug("No cached project info found for " .. proj_file)
  logger.debug(proj_info_cache[proj_file])

  local target_framework = get_target_frameworks(proj_file)

  if not target_framework then
    semaphore.release()
    return nil
  end

  local msbuild_cmd = {
    "dotnet",
    "msbuild",
    proj_file,
    "-getItem:Compile",
    "-getProperty:TargetPath",
    "-getProperty:MSBuildProjectDirectory",
    "-getProperty:MSBuildProjectFullPath",
    "-getProperty:IsTestProject",
    "-getProperty:IsTestingPlatformApplication",
    "-getProperty:DisableTestingPlatformServerCapability",
    "-property:TargetFramework=" .. target_framework,
  }
  for _, arg in ipairs(dotnet_utils.opts.additional_args or {}) do
    table.insert(msbuild_cmd, arg)
  end

  local _, res = lib.process.run(msbuild_cmd, {
    stderr = false,
    stdout = true,
  })

  local output = nio.fn.json_decode(res.stdout)
  local properties = output.Properties

  logger.debug("neotest-vstest: msbuild properties for " .. proj_file .. ":")
  logger.debug(properties)

  local is_mtp_disabled = string.lower(properties.DisableTestingPlatformServerCapability) == "true"

  ---@class DotnetProjectInfo
  local proj_data = {
    proj_file = (properties.MSBuildProjectFullPath ~= "" and properties.MSBuildProjectFullPath)
      or proj_file,
    dll_file = properties.TargetPath,
    proj_dir = properties.MSBuildProjectDirectory,
    last_discovered = files.get_path_last_modified(proj_file) or 0,
    is_test_project = string.lower(properties.IsTestProject) == "true",
    is_mtp_project = not is_mtp_disabled
      and string.lower(properties.IsTestingPlatformApplication) == "true",
  }

  setmetatable(proj_data, {
    __eq = function(a, b)
      return vim.fs.normalize(a.proj_file or "") == vim.fs.normalize(b.proj_file or "")
    end,
  })

  if proj_data.dll_file == "" then
    logger.debug("neotest-vstest: failed to find dll file for " .. proj_file)
    logger.debug(path)
    logger.debug(res.stdout)
  end

  proj_info_cache[vim.fs.normalize(proj_data.proj_file)] = proj_data

  for _, item in ipairs(output.Items.Compile) do
    file_to_project_map[vim.fs.normalize(item.FullPath)] = proj_data.proj_file
  end

  semaphore.release()
  return (
    proj_data.dll_file ~= ""
    and proj_data.proj_file ~= ""
    and (proj_data.is_test_project or proj_data.is_mtp_project)
    and proj_data
  ) or nil
end

---@param solution_path string
---@return string[]
local function list_projects(solution_path)
  local _, res = lib.process.run({
    "dotnet",
    "sln",
    solution_path,
    "list",
  }, {
    stderr = false,
    stdout = true,
  })

  local solution_dir = vim.fs.dirname(solution_path)
  logger.debug("neotest-vstest: dotnet sln " .. solution_path .. " list output:")
  logger.debug(res.stdout)

  local relative_path_projects = vim.list_slice(nio.fn.split(res.stdout, "\n"), 3)
  local projects = {}
  for _, project in ipairs(relative_path_projects) do
    projects[#projects + 1] = vim.fs.joinpath(solution_dir, project)
  end
  return projects
end

---lists all projects in solution.
---Falls back to listing all project in directory.
---@async
---@param solution_path string
---@return DotnetProjectInfo[]
local function get_solution_projects(solution_path)
  local solution_dir = vim.fs.dirname(solution_path)

  local projects = list_projects(solution_path)

  local _test_projects = {}

  for _, project in ipairs(projects) do
    _test_projects[#_test_projects + 1] = function()
      return dotnet_utils.get_proj_info(project)
    end
  end

  local all_projects_info = nio.gather(_test_projects)
  local test_projects = {}
  for _, project in pairs(all_projects_info) do
    if project and project.is_test_project then
      test_projects[#test_projects + 1] = project
    end
  end

  logger.info("found test projects in " .. solution_dir)
  logger.debug(test_projects)
  logger.debug(all_projects_info)

  return test_projects
end

---@class DotnetSolutionInfo
---@field solution_file string
---@field projects DotnetProjectInfo[]
---@field last_updated integer

---@async
---@param solution_info DotnetSolutionInfo
---@return DotnetSolutionInfo
local function get_updated_solution_info(solution_info)
  local last_modified = files.get_path_last_modified(solution_info.solution_file)

  if solution_info.last_updated < last_modified then
    logger.debug("neotest-vstest: updating solution info for " .. solution_info.solution_file)
    local projects = get_solution_projects(solution_info.solution_file)
    return {
      solution_file = solution_info.solution_file,
      projects = projects,
      last_updated = last_modified or 0,
    }
  end

  return solution_info
end

---@type table<string, DotnetSolutionInfo>
local solution_cache = {}

local solution_discovery_semaphore = nio.control.semaphore(1)

---@async
---@param solution_path string
---@return DotnetSolutionInfo?
function dotnet_utils.get_solution_info(solution_path)
  local normalized_path = vim.fs.normalize(solution_path)
  local cached_solution = (normalized_path and solution_cache[normalized_path])
    or {
      solution_file = solution_path,
      last_updated = 0,
    }

  solution_discovery_semaphore.acquire()

  local updated_solution_info = get_updated_solution_info(cached_solution)
  solution_cache[normalized_path] = updated_solution_info
  solution_discovery_semaphore.release()
  return updated_solution_info
end

---return the unix timestamp of when the project dll file was last modified
---@async
---@param project DotnetProjectInfo
---@return integer?
function dotnet_utils.get_project_last_modified(project)
  return files.get_path_last_modified(project.dll_file)
end

local build_semaphore = nio.control.semaphore(1)

---@async
---@param path string
---@return boolean success if build was successful
function dotnet_utils.build_path(path)
  build_semaphore.acquire()

  logger.debug("neotest-vstest: building path " .. path)
  local build_cmd = { "dotnet", "build", path }
  for _, arg in ipairs(dotnet_utils.opts.additional_args or {}) do
    table.insert(build_cmd, arg)
  end
  local exitCode, out = lib.process.run(build_cmd, { stdout = true, stderr = true })

  build_semaphore.release()

  if exitCode ~= 0 then
    nio.scheduler()
    logger.error("neotest-vstest: failed to build path " .. path)
    logger.error(out.stdout)
    logger.error(out.stderr)
    vim.notify_once("neotest-vstest: failed to build project " .. path, vim.log.levels.ERROR)
    return false
  end

  return true
end

---@async
---@param project DotnetProjectInfo
---@return boolean success if build was successful
function dotnet_utils.build_project(project)
  return dotnet_utils.build_path(project.proj_file)
end

return dotnet_utils
