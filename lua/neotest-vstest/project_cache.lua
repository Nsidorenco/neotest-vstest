local nio = require("nio")
local lib = require("neotest.lib")
local files = require("neotest-vstest.files")

---Keeps msbuild project evaluations across sessions.
---Evaluating a project is the slowest part of discovery, so a saved evaluation is reused
---until the project, its restore output or one of the files msbuild picks up around it changes.
local M = {}

---@class neotest-vstest.ProjectCacheEntry
---@field signature string see `signature()`
---@field project DotnetProjectInfo
---@field compile_items string[]

local cache_file = vim.fs.joinpath(vim.fn.stdpath("cache"), "neotest-vstest", "projects.json")

-- files that msbuild picks up from the project directory or any directory above it
local implicit_inputs = {
  "Directory.Build.props",
  "Directory.Build.targets",
  "Directory.Build.rsp",
  "Directory.Packages.props",
  "global.json",
  "NuGet.Config",
  "NuGet.config",
  "nuget.config",
}

---@type table<string, neotest-vstest.ProjectCacheEntry>? loaded from `cache_file` on first use
local entries
local save_scheduled = false

---@async
---@return table<string, neotest-vstest.ProjectCacheEntry>
local function load()
  if not entries then
    local read_ok, content = pcall(lib.files.read, cache_file)
    local decode_ok, decoded = pcall(vim.json.decode, read_ok and content or "")
    entries = decode_ok and type(decoded) == "table" and decoded or {}
  end
  return entries
end

local function save_soon()
  if save_scheduled then
    return
  end
  -- projects are evaluated in bursts, so they are saved together
  save_scheduled = true
  vim.defer_fn(function()
    save_scheduled = false
    vim.fn.mkdir(vim.fs.dirname(cache_file), "p")
    vim.fn.writefile({ vim.json.encode(entries) }, cache_file)
  end, 1000)
end

---@async
---@param proj_file string
---@param assets_file string
---@param build_args string[]
---@return string signature changes whenever the build args or one of the evaluation inputs change
local function signature(proj_file, assets_file, build_args)
  local parts = { table.concat(build_args, " ") }
  local function add(path)
    local _, stat = nio.uv.fs_stat(path)
    if stat then
      parts[#parts + 1] = path .. "=" .. stat.mtime.sec
    end
  end

  add(proj_file)
  add(assets_file)
  for dir in vim.fs.parents(proj_file) do
    for _, name in ipairs(implicit_inputs) do
      add(vim.fs.joinpath(dir, name))
    end
  end
  return table.concat(parts, ";")
end

---returns the saved evaluation of the project, if nothing it depends on has changed since
---@async
---@param proj_file string
---@param build_args string[]
---@return DotnetProjectInfo? project
---@return string[]? compile_items
function M.get(proj_file, build_args)
  local entry = load()[proj_file]
  -- the cache file can come from an older version, so anything malformed counts as a miss
  local is_valid = type(entry) == "table"
    and type(entry.project) == "table"
    and type(entry.project.assets_file) == "string"
    and type(entry.compile_items) == "table"
  if
    not is_valid or entry.signature ~= signature(proj_file, entry.project.assets_file, build_args)
  then
    return nil
  end
  return entry.project, entry.compile_items
end

---saves the evaluation of a project for later sessions
---@async
---@param proj_file string
---@param build_args string[]
---@param project DotnetProjectInfo
---@param compile_items string[]
function M.set(proj_file, build_args, project, compile_items)
  -- before a restore the package props are missing, so such an evaluation is not worth keeping
  if not project.assets_file or not files.get_path_last_modified(project.assets_file) then
    return
  end
  load()[proj_file] = {
    signature = signature(proj_file, project.assets_file, build_args),
    project = project,
    compile_items = compile_items,
  }
  save_soon()
end

return M
