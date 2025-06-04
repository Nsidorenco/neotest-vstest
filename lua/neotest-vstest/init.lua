local nio = require("nio")
local lib = require("neotest.lib")
local types = require("neotest.types")
local logger = require("neotest.logging")

local utilities = require("neotest-vstest.utilities")
local test_discovery = require("neotest-vstest.vstest.discovery")
local cli_wrapper = require("neotest-vstest.vstest.cli_wrapper")
local vstest_strategy = require("neotest-vstest.strategies.vstest")
local vstest_debug_strategy = require("neotest-vstest.strategies.vstest_debugger")
local dotnet_utils = require("neotest-vstest.dotnet_utils")

--- @type dap.Configuration
local dap_settings = {
  type = "netcoredbg",
  name = "netcoredbg - attach",
  request = "attach",
  env = {
    DOTNET_ENVIRONMENT = "Development",
  },
  justMyCode = false,
}

local solution

---@package
---@type neotest.Adapter
---@diagnostic disable-next-line: missing-fields
local DotnetNeotestAdapter = { name = "neotest-vstest" }

function DotnetNeotestAdapter.root(path)
  local solution_dir = lib.files.match_root_pattern("*.sln")(path)
    or lib.files.match_root_pattern("*.slnx")(path)

  if solution_dir then
    test_discovery.discover_solution_tests(solution_dir)
    solution = solution_dir
  end

  return solution_dir or lib.files.match_root_pattern("*.[cf]sproj")(path)
end

function DotnetNeotestAdapter.is_test_file(file_path)
  local isTestFile = (vim.endswith(file_path, ".csproj") or vim.endswith(file_path, ".fsproj"))
    or (vim.endswith(file_path, ".cs") or vim.endswith(file_path, ".fs"))

  if not isTestFile then
    return false
  end

  local project = dotnet_utils.get_proj_info(file_path)
  local client = test_discovery.get_client_for_project(project, solution)

  local tests = (client and client:discover_tests_for_path(file_path)) or {}

  local n = 0
  if tests then
    n = #vim.tbl_values(tests)
  end

  return tests and n > 0
end

function DotnetNeotestAdapter.filter_dir(name)
  if name == "bin" or name == "obj" then
    return false
  end

  return true
end

local function get_match_type(captured_nodes)
  if captured_nodes["test.name"] then
    return "test"
  end
  if captured_nodes["namespace.name"] then
    return "namespace"
  end
end

local function build_structure(positions, namespaces, opts)
  ---@type neotest.Position
  local parent = table.remove(positions, 1)
  if not parent then
    return nil
  end
  parent.id = parent.type == "file" and parent.path or opts.position_id(parent, namespaces)
  local current_level = { parent }
  local child_namespaces = vim.list_extend({}, namespaces)
  if
    parent.type == "namespace"
    or parent.type == "parameterized"
    or (opts.nested_tests and parent.type == "test")
  then
    child_namespaces[#child_namespaces + 1] = parent
  end
  if not parent.range then
    return current_level
  end
  while true do
    local next_pos = positions[1]
    if not next_pos or (next_pos.range and not lib.positions.contains(parent, next_pos)) then
      -- Don't preserve empty namespaces
      if #current_level == 1 and parent.type == "namespace" then
        return nil
      end
      if opts.require_namespaces and parent.type == "test" and #namespaces == 0 then
        return nil
      end
      return current_level
    end

    if parent.type == "parameterized" then
      local pos = table.remove(positions, 1)
      current_level[#current_level + 1] = pos
    else
      local sub_tree = build_structure(positions, child_namespaces, opts)
      if opts.nested_tests or parent.type ~= "test" then
        current_level[#current_level + 1] = sub_tree
      end
    end
  end
end

---@param source string
---@param captured_nodes any
---@param tests_in_file table<string, TestCase>
---@param path string
---@return nil | neotest.Position | neotest.Position[]
local function build_position(source, captured_nodes, tests_in_file, path)
  local match_type = get_match_type(captured_nodes)
  if match_type then
    local definition = captured_nodes[match_type .. ".definition"]

    ---@type neotest.Position[]
    local positions = {}

    if match_type == "test" then
      for id, test in pairs(tests_in_file) do
        if
          definition:start() <= test.LineNumber - 1 and test.LineNumber - 1 <= definition:end_()
        then
          table.insert(positions, {
            id = id,
            type = match_type,
            path = path,
            name = test.DisplayName,
            qualified_name = test.FullyQualifiedName,
            range = { definition:range() },
          })
          tests_in_file[id] = nil
        end
      end
    else
      local name = vim.treesitter.get_node_text(captured_nodes[match_type .. ".name"], source)
      table.insert(positions, {
        type = match_type,
        path = path,
        name = string.gsub(name, "``", ""),
        range = { definition:range() },
      })
    end

    if #positions > 1 then
      local pos = positions[1]
      table.insert(positions, 1, {
        type = "parameterized",
        path = pos.path,
        -- remove parameterized part of test name
        name = pos.name:gsub("<.*>", ""):gsub("%(.*%)", ""),
        range = pos.range,
      })
    end

    return positions
  end
end

--- Some adapters do not provide the file which the test is defined in.
--- In those cases we nest the test cases under the solution file.
---@param project DotnetProjectInfo
local function get_top_level_tests(project)
  if not project then
    return {}
  end

  local client = test_discovery.get_client_for_project(project, solution)

  local tests_in_file = (client and client:discover_tests()) or {}

  logger.debug(string.format("neotest-vstest: top-level tests in file: %s", project.dll_file))

  if not tests_in_file or next(tests_in_file) == nil then
    return
  end

  local n = #tests_in_file

  local nodes = {
    {
      type = "file",
      path = project.proj_file,
      name = vim.fs.basename(project.proj_file),
      range = { 0, 0, n + 1, -1 },
    },
  }

  local i = 0

  -- add tests which does not have a matching tree-sitter node.
  for id, test in pairs(tests_in_file) do
    nodes[#nodes + 1] = {
      id = id,
      type = "test",
      path = project.proj_file,
      name = test.DisplayName,
      qualified_name = test.FullyQualifiedName,
      range = { i, 0, i + 1, -1 },
    }
    i = i + 1
  end

  local structure = assert(build_structure(nodes, {}, {
    nested_tests = false,
    require_namespaces = false,
    position_id = function(position, parents)
      return position.id
        or vim
          .iter({
            position.path,
            vim.tbl_map(function(pos)
              return pos.name
            end, parents),
            position.name,
          })
          :flatten()
          :join("::")
    end,
  }))

  return types.Tree.from_list(structure, function(pos)
    return pos.id
  end)
end

function DotnetNeotestAdapter.discover_positions(path)
  logger.info(string.format("neotest-vstest: scanning %s for tests...", path))

  local project = dotnet_utils.get_proj_info(path)
  local client = test_discovery.get_client_for_project(project, solution)

  if not client then
    return
  end

  if project and (vim.endswith(path, ".csproj") or vim.endswith(path, ".fsproj")) then
    return get_top_level_tests(project)
  end

  local filetype = (vim.endswith(path, ".fs") and "fsharp") or "c_sharp"

  local tests_in_file = client:discover_tests_for_path(path)

  if not tests_in_file or next(tests_in_file) == nil then
    return
  end

  local tree

  if tests_in_file then
    local content = lib.files.read(path)
    nio.scheduler()
    tests_in_file = vim.fn.deepcopy(tests_in_file)
    local lang_tree =
      vim.treesitter.get_string_parser(content, filetype, { injections = { [filetype] = "" } })

    local root = lib.treesitter.fast_parse(lang_tree):root()

    local query = lib.treesitter.normalise_query(
      filetype,
      filetype == "fsharp" and require("neotest-vstest.queries.fsharp")
        or require("neotest-vstest.queries.c_sharp")
    )

    local sep = lib.files.sep
    local path_elems = vim.split(path, sep, { plain = true })
    local nodes = {
      {
        type = "file",
        path = path,
        name = path_elems[#path_elems],
        range = { root:range() },
      },
    }
    for _, match in query:iter_matches(root, content, nil, nil, { all = false }) do
      local captured_nodes = {}
      for i, capture in ipairs(query.captures) do
        captured_nodes[capture] = match[i]
      end
      local res = build_position(content, captured_nodes, tests_in_file, path)
      if res then
        for _, pos in ipairs(res) do
          nodes[#nodes + 1] = pos
        end
      end
    end

    -- add tests which does not have a matching tree-sitter node.
    for id, test in pairs(tests_in_file) do
      nodes[#nodes + 1] = {
        id = id,
        type = "test",
        path = path,
        name = test.DisplayName,
        qualified_name = test.FullyQualifiedName,
        range = { test.LineNumber - 1, 0, test.LineNumber - 1, -1 },
      }
    end

    for _, node in ipairs(nodes) do
      node.client = client
    end

    local structure = assert(build_structure(nodes, {}, {
      nested_tests = false,
      require_namespaces = false,
      position_id = function(position, parents)
        return position.id
          or vim
            .iter({
              position.path,
              vim.tbl_map(function(pos)
                return pos.name
              end, parents),
              position.name,
            })
            :flatten()
            :join("::")
      end,
    }))

    tree = types.Tree.from_list(structure, function(pos)
      return pos.id
    end)
  end

  logger.info(string.format("neotest-vstest: done scanning %s for tests", path))

  return tree
end

function DotnetNeotestAdapter.build_spec(args)
  local tree = args.tree
  if not tree then
    return
  end

  local projects = {}

  for _, position in tree:iter() do
    if position.type == "test" then
      logger.debug(position)
      local tests = projects[position.client] or {}
      projects[position.client] = vim.list_extend(tests, { position.id })
    end
  end

  local stream_path = nio.fn.tempname()
  lib.files.write(stream_path, "")
  local stream = utilities.stream_queue()

  return {
    context = {
      client_id_map = projects,
      solution = solution,
      results = {},
      write_stream = stream.write,
    },
    stream = function()
      return function()
        local new_results = stream.get()
        local ok, parsed = pcall(vim.json.decode, new_results, { luanil = { object = true } })

        if not ok or not parsed then
          return {}
        end

        return { [parsed.id] = parsed.result }
      end
    end,
    strategy = (args.strategy == "dap" and vstest_debug_strategy(dap_settings)) or vstest_strategy,
  }
end

function DotnetNeotestAdapter.results(spec, result, _tree)
  logger.info("neotest-vstest: waiting for test results")
  logger.debug(spec)
  logger.debug(result)
  ---@type table<string, neotest.Result>
  local results = spec.context.results or {}

  if not results then
    for _, id in ipairs(vim.tbl_values(spec.context.projects_id_map)) do
      results[id] = {
        status = types.ResultStatus.failed,
        output = spec.context.result_path,
        errors = {
          { message = result.output },
          { message = "failed to read result file" },
        },
      }
    end
    return results
  end

  logger.debug(results)

  return results
end

---@class neotest-vstest.Config
---@field sdk_path? string path to dotnet sdk. Example: /usr/local/share/dotnet/sdk/9.0.101/
---@field dap_settings? dap.Configuration dap settings for debugging

---@param opts neotest-vstest.Config
local function apply_user_settings(_, opts)
  cli_wrapper.sdk_path = opts.sdk_path
  dap_settings = vim.tbl_extend("force", dap_settings, opts.dap_settings or {})
  return DotnetNeotestAdapter
end

setmetatable(DotnetNeotestAdapter, {
  __call = apply_user_settings,
})

return DotnetNeotestAdapter
