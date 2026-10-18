local nio = require("nio")
local lib = require("neotest.lib")
local logger = require("neotest.logging")
local files = require("neotest-vstest.files")
local project_cache = require("neotest-vstest.project_cache")

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

---@type nio.control.Future?
local dotnet_executable

---vim.system looks up executables on the main thread, which takes hundreds of milliseconds with
---a long PATH.
---@async
---@return string path to dotnet, or "dotnet" if it is not on the PATH
function dotnet_utils.get_dotnet_executable()
  if not dotnet_executable then
    dotnet_executable = nio.control.future()
    local is_windows = vim.uv.os_uname().sysname:find("Windows") ~= nil
    local name = is_windows and "dotnet.exe" or "dotnet"
    local path = "dotnet"
    for dir in vim.gsplit(vim.uv.os_getenv("PATH") or "", is_windows and ";" or ":") do
      local candidate = vim.fs.joinpath(dir, name)
      local _, stat = nio.uv.fs_stat(candidate)
      if dir ~= "" and stat and stat.type == "file" then
        path = candidate
        break
      end
    end
    dotnet_executable.set(path)
  end
  return dotnet_executable.wait()
end

---runs the dotnet cli, with the configured build args appended unless `opts.no_build_args` is set
---@async
---@param args string[] arguments after `dotnet`
---@param opts? { no_build_args?: boolean }
---@return integer exit_code, table output
function dotnet_utils.run_dotnet(args, opts)
  local cmd = { dotnet_utils.get_dotnet_executable() }
  vim.list_extend(cmd, args)
  if not (opts and opts.no_build_args) then
    vim.list_extend(cmd, dotnet_utils.opts.additional_args or {})
  end
  return lib.process.run(cmd, { stdout = true, stderr = true })
end

-- each evaluation is its own msbuild process, so a large solution would otherwise start
-- one per project at once
local evaluation_semaphore = nio.control.semaphore(math.max(1, vim.uv.available_parallelism()))

---@async
---@param args string[] arguments after `dotnet msbuild`
---@return integer exit_code, table output
local function run_msbuild(args)
  local code, res
  evaluation_semaphore.with(function()
    code, res = dotnet_utils.run_dotnet(vim.list_extend({ "msbuild" }, args))
  end)
  return code, res
end

---@param proj_file string
---@return string? target_framework
local function get_target_frameworks(proj_file)
  local code, res = run_msbuild({
    proj_file,
    "-getProperty:TargetFramework",
    "-getProperty:TargetFrameworks",
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
---@field assets_file string? path to project.assets.json

---@type table<string, DotnetProjectInfo>
local proj_info_cache = {}

---@type table<string, string>
local file_to_project_map = {}

local project_semaphore = {}

---@param proj_data DotnetProjectInfo
---@param compile_items string[]
---@return DotnetProjectInfo?
local function register_project(proj_data, compile_items)
  setmetatable(proj_data, {
    __eq = function(a, b)
      return vim.fs.normalize(a.proj_file or "") == vim.fs.normalize(b.proj_file or "")
    end,
  })

  proj_info_cache[vim.fs.normalize(proj_data.proj_file)] = proj_data

  for _, item in ipairs(compile_items) do
    file_to_project_map[vim.fs.normalize(item)] = proj_data.proj_file
  end

  return (
    proj_data.dll_file ~= ""
    and proj_data.proj_file ~= ""
    and (proj_data.is_test_project or proj_data.is_mtp_project)
    and proj_data
  ) or nil
end

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

  local build_args = dotnet_utils.opts.additional_args or {}
  local cached_project, cached_compile_items = project_cache.get(proj_file, build_args)
  if cached_project then
    logger.debug("neotest-vstest: using disk cached project info for " .. proj_file)
    local project = register_project(cached_project, cached_compile_items)
    semaphore.release()
    return project
  end

  local target_framework = get_target_frameworks(proj_file)

  if not target_framework then
    semaphore.release()
    return nil
  end

  local _, res = run_msbuild({
    proj_file,
    "-getItem:Compile",
    "-getProperty:TargetPath",
    "-getProperty:ProjectAssetsFile",
    "-getProperty:MSBuildProjectDirectory",
    "-getProperty:MSBuildProjectFullPath",
    "-getProperty:IsTestProject",
    "-getProperty:IsTestingPlatformApplication",
    "-getProperty:DisableTestingPlatformServerCapability",
    "-property:TargetFramework=" .. target_framework,
  })

  -- a failed evaluation prints errors instead of json, which must not leave the semaphore held
  local ok, output = pcall(nio.fn.json_decode, res.stdout)
  if not ok or type(output) ~= "table" or type(output.Properties) ~= "table" then
    logger.warn("neotest-vstest: failed to evaluate project " .. proj_file)
    logger.warn(res.stdout)
    semaphore.release()
    return nil
  end
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
    assets_file = properties.ProjectAssetsFile ~= "" and vim.fs.normalize(
      properties.ProjectAssetsFile
    ) or nil,
  }

  if proj_data.dll_file == "" then
    logger.debug("neotest-vstest: failed to find dll file for " .. proj_file)
    logger.debug(path)
    logger.debug(res.stdout)
  end

  local compile_items = vim.tbl_map(function(item)
    return item.FullPath
  end, (output.Items or {}).Compile or {})

  project_cache.set(proj_file, build_args, proj_data, compile_items)

  local project = register_project(proj_data, compile_items)
  semaphore.release()
  return project
end

---@param solution_path string
---@return string[]
local function list_projects(solution_path)
  local _, res = dotnet_utils.run_dotnet({ "sln", solution_path, "list" }, { no_build_args = true })

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
    if project and (project.is_test_project or project.is_mtp_project) then
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
---@param name? string what is being built, for messages. Defaults to `path`
---@return boolean success if build was successful
function dotnet_utils.build_path(path, name)
  name = name or path
  local exitCode, out
  build_semaphore.with(function()
    logger.debug("neotest-vstest: building path " .. path)
    exitCode, out = dotnet_utils.run_dotnet({ "build", path })
  end)

  if exitCode ~= 0 then
    nio.scheduler()
    logger.error("neotest-vstest: failed to build path " .. name)
    logger.error(out.stdout)
    logger.error(out.stderr)
    vim.notify_once("neotest-vstest: failed to build project " .. name, vim.log.levels.ERROR)
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

---builds only the given projects and what they reference, instead of a whole solution
---@async
---@param solution string? path to the solution the projects belong to
---@param projects DotnetProjectInfo[]
---@return boolean success if every build was successful
function dotnet_utils.build_projects(solution, projects)
  local solution_dir = solution and vim.fs.dirname(vim.fs.normalize(solution))
  -- a solution filter lists projects relative to the solution's directory
  local relative_paths = {}
  local all_in_solution_dir = solution_dir ~= nil
  for _, project in ipairs(projects) do
    local relative_path = solution_dir
      and vim.fs.relpath(solution_dir, vim.fs.normalize(project.proj_file))
    all_in_solution_dir = all_in_solution_dir and relative_path ~= nil
    relative_paths[#relative_paths + 1] = relative_path or nil
  end

  -- building projects one at a time would rebuild the projects they share once for each of them,
  -- so several projects are built together through a solution filter listing just them
  if #projects > 1 and all_in_solution_dir then
    local filter = nio.fn.tempname() .. ".slnf"
    lib.files.write(
      filter,
      vim.json.encode({ solution = { path = solution, projects = relative_paths } })
    )
    local names = vim.tbl_map(function(project)
      return vim.fs.basename(project.proj_file)
    end, projects)
    local success = dotnet_utils.build_path(filter, table.concat(names, ", "))
    nio.uv.fs_unlink(filter)
    return success
  end

  local success = true
  for _, project in ipairs(projects) do
    success = dotnet_utils.build_project(project) and success
  end
  return success
end

return dotnet_utils
