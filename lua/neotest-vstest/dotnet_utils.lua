local nio = require("nio")
local lib = require("neotest.lib")
local logger = require("neotest.logging")
local files = require("neotest-vstest.files")

local dotnet_utils = {}

---@type { solution: string?, projects:string[]}?
local project_cache

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
  local code, res = lib.process.run({
    "dotnet",
    "msbuild",
    proj_file,
    "-getProperty:TargetFramework",
    "-getProperty:TargetFrameworks",
  }, {
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
---@field is_test_project boolean
---@field is_mtp_project boolean is project compiler use Microsoft.Testting.Platform

---@type table<string, DotnetProjectInfo>
local proj_info_cache = {}

local file_to_project_map = {}

local project_semaphore = {}

---collects project information based on file
---@async
---@param path string
---@return DotnetProjectInfo?
function dotnet_utils.get_proj_info(path)
  path = vim.fs.normalize(path)
  logger.debug("neotest-vstest: getting project info for " .. path)

  local proj_file

  if file_to_project_map[path] then
    proj_file = file_to_project_map[path]
  elseif vim.endswith(path, ".csproj") or vim.endswith(path, ".fsproj") then
    proj_file = path
  else
    proj_file = vim.fs.find(function(name, _)
      return name:match("%.[cf]sproj$")
    end, { upward = true, type = "file", path = vim.fs.dirname(path) })[1]

    if not project_cache then
      file_to_project_map[path] = proj_file
    else
      if
        not vim.iter(project_cache.projects):any(function(proj)
          if proj == proj_file then
            file_to_project_map[path] = proj_file
            return true
          end
          return false
        end)
      then
        return nil
      end
    end
  end

  if not proj_file then
    return nil
  end

  --- Simple check before acquiring the semaphore to avoid unnecessary waits.
  if proj_info_cache[proj_file] then
    return proj_info_cache[proj_file]
  end

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
    semaphore.release()
    return proj_info_cache[proj_file]
  end

  local target_framework = get_target_frameworks(proj_file)

  if not target_framework then
    semaphore.release()
    return nil
  end

  local command = {
    "dotnet",
    "msbuild",
    proj_file,
    "-getItem:Compile",
    "-getProperty:TargetPath",
    "-getProperty:MSBuildProjectDirectory",
    "-getProperty:IsTestProject",
    "-getProperty:IsTestingPlatformApplication",
    "-getProperty:DisableTestingPlatformServerCapability",
    "-property:TargetFramework=" .. target_framework,
  }

  local _, res = lib.process.run(command, {
    stderr = false,
    stdout = true,
  })

  local output = nio.fn.json_decode(res.stdout)
  local properties = output.Properties

  logger.debug("neotest-vstest: msbuild properties for " .. proj_file .. ":")
  logger.debug(properties)

  local is_mtp_disabled = properties.DisableTestingPlatformServerCapability == "true"

  ---@class DotnetProjectInfo
  local proj_data = {
    proj_file = vim.fs.normalize(proj_file),
    dll_file = properties.TargetPath,
    proj_dir = properties.MSBuildProjectDirectory,
    is_test_project = properties.IsTestProject == "true",
    is_mtp_project = not is_mtp_disabled and properties.IsTestingPlatformApplication == "true",
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

  proj_info_cache[proj_data.proj_file] = proj_data

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

local solution_discovery_semaphore = nio.control.semaphore(1)

---lists all projects in solution.
---Falls back to listing all project in directory.
---@async
---@param solution_path string
---@return { solution: string?, projects: DotnetProjectInfo[] }
function dotnet_utils.get_solution_projects(solution_path)
  solution_discovery_semaphore.acquire()
  if project_cache then
    solution_discovery_semaphore.release()
    return project_cache
  end

  local solution_dir = vim.fs.dirname(solution_path)

  local projects = {}

  if solution_path then
    local _, res = lib.process.run({
      "dotnet",
      "sln",
      solution_path,
      "list",
    }, {
      stderr = false,
      stdout = true,
    })

    logger.debug("neotest-vstest: dotnet sln " .. solution_path .. " list output:")
    logger.debug(res.stdout)

    local relative_path_projects = vim.list_slice(nio.fn.split(res.stdout, "\n"), 3)
    for _, project in ipairs(relative_path_projects) do
      projects[#projects + 1] = vim.fs.joinpath(solution_dir, project)
    end
  else
    logger.info("found no solution file in " .. solution_path)
    projects = vim.fs.find(function(name, _)
      return name:match("%.[cf]sproj$")
    end, { upward = false, type = "file", path = solution_path })
  end

  local test_projects = {}

  for _, project in ipairs(projects) do
    local project_info = dotnet_utils.get_proj_info(project)
    if project_info and project_info.is_test_project then
      test_projects[#test_projects + 1] = project_info
    end
  end

  logger.info("found test projects in " .. solution_dir)
  logger.info(test_projects)

  local res = { solution = solution_path, projects = test_projects }

  project_cache = res

  solution_discovery_semaphore.release()

  return res
end

---return the unix timestamp of when the project dll file was last modified
---@async
---@param project DotnetProjectInfo
---@return integer?
function dotnet_utils.get_project_last_modified(project)
  return files.get_path_last_modified(project.dll_file)
end

---@async
---@param path string
---@return boolean success if build was successful
function dotnet_utils.build_path(path)
  logger.debug("neotest-vstest: building path " .. path)
  local exitCode, out = lib.process.run(
    { "dotnet", "build", path },
    { stdout = true, stderr = true }
  )

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
