---@return neotest.Adapter
local function create_adapter()
  local dotnet_utils = require("neotest-vstest.dotnet_utils")
  local config = require("neotest-vstest.config").get_config()
  dotnet_utils.add_opts(config.build_opts or {})

  --- @type dap.Configuration
  local dap_settings = vim.tbl_extend("force", {
    type = "netcoredbg",
    name = "netcoredbg - attach",
    request = "attach",
    env = {
      DOTNET_ENVIRONMENT = "Development",
    },
    justMyCode = false,
  }, config.dap_settings or {})

  local solution
  local solution_dir
  local root_semaphore = require("nio").control.semaphore(1)

  ---@package
  ---@type neotest.Adapter
  ---@diagnostic disable-next-line: missing-fields
  local DotnetNeotestAdapter = { name = "neotest-vstest" }

  local function find_root(path)
    local nio = require("nio")
    local lib = require("neotest.lib")
    local logger = require("neotest.logging")

    if solution_dir then
      return solution_dir
    end

    local first_solution = lib.files.match_root_pattern("*.sln", "*.slnx")(path)

    --- Only select solution files not in hidden directories or based on user filter
    --- @type fun(search_path: string): boolean
    local ignore_function = config.discovery_directory_filter
      or function(search_path)
        return search_path:match("/%.")
      end

    local solutions = {}

    --- Lists the solution files git does not ignore, which leaves out build output and other
    --- generated directories without the plugin having to know their names.
    ---@async
    ---@param search_root string
    ---@return string[]? solutions or nil if git could not list them
    local function find_git_solutions(search_root)
      local ok, code, res = pcall(lib.process.run, {
        "git",
        "-C",
        search_root,
        "ls-files",
        "-z",
        "--cached",
        "--others",
        "--exclude-standard",
        "--",
        "*.sln",
        "*.slnx",
      }, { stdout = true })
      if not ok or code ~= 0 then
        return nil
      end
      local found = {}
      for _, rel_path in ipairs(vim.split(res.stdout, "\0", { plain = true, trimempty = true })) do
        local file = vim.fs.joinpath(search_root, rel_path)
        -- the index still lists solutions deleted since the last commit
        local _, stat = nio.uv.fs_stat(file)
        if stat then
          found[#found + 1] = file
        end
      end
      return found
    end

    local function find_solutions(search_root)
      local candidates = find_git_solutions(search_root)
      if not candidates or #candidates == 0 then
        -- not a git repository, or its solutions are all ignored: search every directory
        candidates = vim.tbl_filter(function(file)
          return file:match("%.slnx?$") ~= nil
        end, lib.files.find(search_root))
      end
      return vim.tbl_filter(function(file)
        return not ignore_function(vim.fs.dirname(file))
      end, candidates)
    end

    if first_solution then
      solutions = find_solutions(first_solution)
      logger.info(string.format("neotest-vstest: scanning %s for solution file...", first_solution))
      logger.info(solutions)
    elseif config.broad_recursive_discovery then
      solutions = find_solutions(path)
      logger.info(string.format("neotest-vstest: scanning %s for solution file...", path))
      logger.info(solutions)
    end

    solution = config.solution_selector and config.solution_selector(solutions) or nil

    if not solution and vim.g.roslyn_nvim_selected_solution then
      solution = vim.g.roslyn_nvim_selected_solution
      logger.info(string.format("neotest-vstest: using solution from roslyn.nvim %s", solution))
    end

    if solution or #solutions > 0 then
      local solution_future = nio.control.future()

      if solution then
        solution_future.set(solution)
      else
        if #solutions == 1 then
          solution = solutions[1]
          solution_future.set(solution)
        else
          vim.ui.select(solutions, {
            prompt = "Multiple solutions exists. Select a solution file: ",
            format_item = function(item)
              return vim.fs.basename(item)
            end,
          }, function(selected)
            nio.run(function()
              if selected then
                solution = selected
                solution_dir = vim.fs.dirname(selected)
              end
              logger.info(string.format("neotest-vstest: selected solution file %s", selected))
              solution_future.set(solution)
            end)
          end)
        end
      end

      if solution_future.wait() and solution then
        dotnet_utils.build_path(solution)
        local solution_info = dotnet_utils.get_solution_info(solution)
        solution = string.gsub(solution, "/", lib.files.sep)
        solution_dir = string.gsub(vim.fs.dirname(solution), "/", lib.files.sep)
        logger.info(string.format("neotest-vstest: found solution dir %s", solution_dir))

        local background_discovery_semaphore = require("nio").control.semaphore(
          math.max(1, math.floor(vim.uv.available_parallelism() / 2))
        )

        -- neotest checks files one at a time, so without this each project's test host
        -- only starts once the previous project has finished discovering
        local client_discovery = require("neotest-vstest.client")
        local projects = solution_info and solution_info.projects or {}
        local solution_file = solution
        for _, project in ipairs(projects) do
          nio.run(function()
            -- each client is a test host process, so only a few are started at a time
            background_discovery_semaphore.with(function()
              local client = client_discovery.get_client_for_project(project, solution_file)
              if client then
                client:discover_tests()
              end
            end)
          end, function(success, err)
            if not success then
              logger.warn(
                "neotest-vstest: background discovery failed for "
                  .. project.proj_file
                  .. ": "
                  .. tostring(err)
              )
            end
          end)
        end
        return solution_dir
      end
    end

    logger.info(string.format("neotest-vstest: no solution file found in %s", path))
    return lib.files.match_root_pattern(".git")(path) or path
  end

  function DotnetNeotestAdapter.root(path)
    local root
    root_semaphore.with(function()
      root = find_root(path)
    end)
    -- discovery ends on libuv callbacks; adapters checked after this one need the main loop
    require("nio").scheduler()
    return root
  end

  function DotnetNeotestAdapter.is_test_file(file_path)
    local logger = require("neotest.logging")
    local client_discovery = require("neotest-vstest.client")

    logger.trace("neotest-vstest: checking if file is test file: " .. file_path)

    local isDotnetFile = (vim.endswith(file_path, ".csproj") or vim.endswith(file_path, ".fsproj"))
      or (vim.endswith(file_path, ".cs") or vim.endswith(file_path, ".fs"))

    if not isDotnetFile then
      return false
    end

    local project = dotnet_utils.get_proj_info(file_path)
    local client = client_discovery.get_client_for_project(project, solution)

    if not client then
      logger.debug(
        "neotest-vstest: marking file as non-test file since no client was found: " .. file_path
      )
      return false
    end

    local tests_in_file = client:discover_tests_for_path(file_path)

    if not tests_in_file or next(tests_in_file) == nil then
      logger.debug(
        string.format(
          "neotest-vstest: marking file as non-test file since no tests was found in file %s",
          file_path
        )
      )
      return false
    end

    return true
  end

  function DotnetNeotestAdapter.filter_dir(name, rel_path, root)
    local logger = require("neotest.logging")
    logger.trace("neotest-vstest: filtering dir", name, rel_path, root)

    if name == "bin" or name == "obj" then
      return false
    end

    -- Filter out directories that are not part of the solution (if there is a solution)
    local fullpath = vim.fs.joinpath(root, rel_path)
    if solution_dir then
      local solution_info = dotnet_utils.get_solution_info(solution)

      local is_project_reachable = vim
        .iter(solution_info and solution_info.projects or {})
        :map(function(proj)
          return vim.fs.dirname(proj.proj_file)
        end)
        :any(function(project_dir)
          -- path should be a subdir of a solution project
          -- or the solution project should be a subdir of the path
          return vim.fs.relpath(project_dir, fullpath) ~= nil
            or vim.fs.relpath(fullpath, project_dir) ~= nil
        end)
      if not is_project_reachable then
        logger.debug(
          string.format(
            "neotest-vstest: file '%s' is not a part of the solution '%s'",
            rel_path,
            solution_info.solution_file
          )
        )
      end
      return is_project_reachable
    else
      if config.discovery_directory_filter then
        return config.discovery_directory_filter(fullpath)
      else
        return true
      end
    end
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
    local lib = require("neotest.lib")

    ---@type neotest.Position
    local parent = table.remove(positions, 1)
    if not parent then
      return nil
    end
    parent.id = parent.type == "file" and parent.path or opts.position_id(parent, namespaces)
    local current_level = { parent }
    local child_namespaces = vim.list_extend({}, namespaces)
    if parent.type == "namespace" or (opts.nested_tests and parent.type == "test") then
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

      if parent.is_parameterized then
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

  ---@class neotest-vstest.Definition a test or namespace definition found in the source
  ---@field type "test"|"namespace"
  ---@field name string
  ---@field range integer[]
  ---@field test_ids string[] tests assigned to a test definition

  ---@param source string
  ---@param captured_nodes any
  ---@return neotest-vstest.Definition?
  local function get_definition(source, captured_nodes)
    local match_type = get_match_type(captured_nodes)
    if not match_type then
      return nil
    end
    local name = vim.treesitter.get_node_text(captured_nodes[match_type .. ".name"], source)
    return {
      type = match_type,
      -- f# names may be quoted in double backticks and c# names may be prefixed by @
      name = (name:gsub("``", ""):gsub("^@", "")),
      range = { captured_nodes[match_type .. ".definition"]:range() },
      test_ids = {},
    }
  end

  ---@param definition neotest-vstest.Definition
  ---@param row integer 0-based
  local function contains_row(definition, row)
    return definition.range[1] <= row and row <= definition.range[3]
  end

  --- Assigns each test to the definition of its method.
  --- The line numbers come from the last successful build, so they are wrong as soon as lines are
  --- added or removed until the next build succeeds. Tests are therefore matched by name, and the
  --- line only chooses between methods with the same name, or places tests whose name is not found.
  ---@param definitions neotest-vstest.Definition[] in document order
  ---@param tests_in_file table<string, neotest-vstest.TestCase> assigned tests are removed
  local function assign_tests(definitions, tests_in_file)
    -- a method is indexed by its name qualified with at least the class or namespace around it,
    -- so it is not mistaken for a method with the same name in another class
    local by_name = {}
    local function index(name, definition)
      by_name[name] = by_name[name] or {}
      table.insert(by_name[name], definition)
    end
    for _, definition in ipairs(definitions) do
      if definition.type == "test" then
        local enclosing = {}
        for _, other in ipairs(definitions) do
          if
            other.type == "namespace"
            and other.range[1] <= definition.range[1]
            and definition.range[3] <= other.range[3]
          then
            enclosing[#enclosing + 1] = other.name
          end
        end
        if #enclosing == 0 then
          index(definition.name, definition)
        end
        local name = definition.name
        for i = #enclosing, 1, -1 do
          name = enclosing[i] .. "." .. name
          index(name, definition)
        end
      end
    end

    ---@param qualified_name string? e.g. Namespace.Class+NestedClass.Method<T>(args)
    local function candidates(qualified_name)
      if not qualified_name then
        return nil
      end
      -- drop the arguments and type arguments of parameterized tests
      local name = qualified_name:gsub("%b()$", ""):gsub("%b<>$", ""):gsub("%+", ".")
      -- method names can contain dots in f#, so every suffix after a dot is tried, longest first
      local start = 1
      while true do
        local found = by_name[name:sub(start)]
        if found then
          return found
        end
        local dot = name:find(".", start, true)
        if not dot then
          return nil
        end
        start = dot + 1
      end
    end

    local ids = vim.tbl_keys(tests_in_file)
    table.sort(ids)
    for _, id in ipairs(ids) do
      local test = tests_in_file[id]
      local row = (test.LineNumber or 0) - 1
      local chosen
      local same_name = candidates(test.FullyQualifiedName)
      if same_name then
        local best_distance
        for _, definition in ipairs(same_name) do
          local distance = contains_row(definition, row) and 0
            or math.abs(definition.range[1] - row)
          if not best_distance or distance < best_distance then
            chosen, best_distance = definition, distance
          end
        end
      else
        -- a test belongs to the first definition that contains it
        for _, definition in ipairs(definitions) do
          if definition.type == "test" and contains_row(definition, row) then
            chosen = definition
            break
          end
        end
      end
      if chosen then
        table.insert(chosen.test_ids, id)
        tests_in_file[id] = nil
      end
    end
  end

  ---@param definition neotest-vstest.Definition
  ---@param tests table<string, neotest-vstest.TestCase>
  ---@param path string
  ---@return neotest.Position[]
  local function definition_positions(definition, tests, path)
    ---@type neotest.Position[]
    local positions = {}

    if definition.type == "test" then
      table.sort(definition.test_ids, function(a, b)
        return tests[a].DisplayName < tests[b].DisplayName
      end)
      for _, id in ipairs(definition.test_ids) do
        table.insert(positions, {
          id = id,
          type = "test",
          path = path,
          name = tests[id].DisplayName,
          range = definition.range,
        })
      end
    else
      table.insert(positions, {
        type = definition.type,
        path = path,
        name = definition.name,
        range = definition.range,
      })
    end

    if #positions > 1 then
      local pos = positions[1]
      table.insert(positions, 1, {
        type = "namespace",
        -- Keep this distinction for build_structure without exposing an
        -- unsupported position type to Neotest.
        is_parameterized = true,
        path = pos.path,
        -- remove parameterized part of test name
        name = pos.name:gsub("<.*>", ""):gsub("%(.*%)", ""),
        range = pos.range,
      })
    end

    return positions
  end

  --- Some adapters do not provide the file which the test is defined in.
  --- In those cases we nest the test cases under the solution file.
  ---@param project DotnetProjectInfo
  local function get_top_level_tests(project)
    local types = require("neotest.types")
    local logger = require("neotest.logging")
    local client_discovery = require("neotest-vstest.client")

    if not project then
      return {}
    end

    local client = client_discovery.get_client_for_project(project, solution)

    if not client then
      logger.debug(
        "neotest-vstest: not discovering top-level tests due to no client for project: "
          .. vim.inspect(project)
      )
    end

    local tests_in_file = (client and client:discover_tests()) or {}
    local tests_in_project = tests_in_file[project.proj_file]
    logger.debug(string.format("neotest-vstest: top-level tests in file: %s", project.proj_file))

    if not tests_in_project or next(tests_in_project) == nil then
      return
    end

    local n = vim.tbl_count(tests_in_project)

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
    for id, test in pairs(tests_in_project) do
      nodes[#nodes + 1] = {
        id = id,
        type = "test",
        path = test.CodeFilePath,
        name = test.DisplayName,
        range = { i, 0, i + 1, -1 },
      }
      i = i + 1
    end

    if #nodes <= 1 then
      return {}
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
    local nio = require("nio")
    local lib = require("neotest.lib")
    local types = require("neotest.types")
    local logger = require("neotest.logging")
    local client_discovery = require("neotest-vstest.client")

    logger.info(string.format("neotest-vstest: scanning %s for tests...", path))

    local project = dotnet_utils.get_proj_info(path)
    local client = client_discovery.get_client_for_project(project, solution)

    if not client then
      logger.debug(
        "neotest-vstest: not discovering tests due to no client for file: " .. vim.inspect(path)
      )
      return
    end

    if project and (vim.endswith(path, ".csproj") or vim.endswith(path, ".fsproj")) then
      return get_top_level_tests(project)
    end

    local filetype = (vim.endswith(path, ".fs") and "fsharp") or "c_sharp"

    local tests_in_file = client:discover_tests_for_path(path)

    if not tests_in_file or next(tests_in_file) == nil then
      logger.debug(string.format("neotest-vstest: no tests found for file %s", path))
      return
    end

    local tree

    if tests_in_file then
      local content = lib.files.read(path)
      tests_in_file = nio.fn.deepcopy(tests_in_file)
      local lang_tree =
        vim.treesitter.get_string_parser(content, filetype, { injections = { [filetype] = "" } })

      -- parse in time-sliced steps so large test files don't freeze neovim,
      -- falling back to a blocking parse if it takes longer than 'redrawtime'
      local parsed = nio.control.future()
      lang_tree:parse(false, function(err, trees)
        parsed.set(not err and trees or nil)
      end)
      local trees = parsed.wait() or lang_tree:parse(false)
      local root = trees[1]:root()

      ---@type vim.treesitter.Query
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
      ---@type neotest-vstest.Definition[]
      local definitions = {}
      for _, match in query:iter_matches(root, content, nil, nil) do
        local captured_nodes = {}
        for i, capture in ipairs(query.captures) do
          local nodes = match[i]
          captured_nodes[capture] = type(nodes) == "table" and nodes[#nodes] or nodes
        end
        definitions[#definitions + 1] = get_definition(content, captured_nodes)
      end

      local all_tests = vim.tbl_extend("error", {}, tests_in_file)
      assign_tests(definitions, tests_in_file)
      for _, definition in ipairs(definitions) do
        vim.list_extend(nodes, definition_positions(definition, all_tests, path))
      end

      -- add tests which does not have a matching tree-sitter node.
      for id, test in pairs(tests_in_file) do
        local line = test.LineNumber or 0
        nodes[#nodes + 1] = {
          id = id,
          type = "test",
          path = path,
          name = test.DisplayName,
          range = { line - 1, 0, line - 1, -1 },
        }
      end

      for _, node in ipairs(nodes) do
        node.project = project
      end

      if #nodes <= 1 then
        return {}
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
    local nio = require("nio")
    local lib = require("neotest.lib")
    local logger = require("neotest.logging")
    local utilities = require("neotest-vstest.utilities")
    local client_discovery = require("neotest-vstest.client")

    local projects = {}

    local tree = args.tree
    if not tree then
      return
    end

    for _, position in tree:iter() do
      if position.type == "test" then
        logger.debug(position)
        local client = client_discovery.get_client_for_project(position.project, solution)
        if client then
          local tests = projects[client] or {}
          projects[client] = vim.list_extend(tests, { position.id })
        else
          vim.notify_once(
            string.format(
              "neotest-vstest: could not find adapter client for test '%s' in project '%s'",
              position.name,
              vim.inspect(position.project)
            ),
            vim.log.levels.ERROR
          )
        end
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

          logger.info("neotest-vstest: received streamed test results in adapter spec")
          logger.debug(new_results)

          return { [new_results.id] = new_results.result }
        end
      end,
      strategy = (args.strategy == "dap" and require("neotest-vstest.strategies.vstest_debugger")(
        dap_settings
      )) or require("neotest-vstest.strategies.vstest"),
    }
  end

  function DotnetNeotestAdapter.results(spec, result)
    local types = require("neotest.types")
    local logger = require("neotest.logging")

    logger.info("neotest-vstest: waiting for test results")
    logger.debug(spec)
    logger.debug(result)
    ---@type table<string, neotest.Result>
    local results = spec.context.results or {}

    if not results then
      for _, id in ipairs(vim.tbl_values(spec.context.projects_id_map)) do
        results[id] = {
          status = types.ResultStatus.skipped,
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

  return DotnetNeotestAdapter
end

local DotnetNeotestAdapter = create_adapter()

---@param opts neotest-vstest.Config
local function apply_user_settings(_, opts)
  vim.g.neotest_vstest = vim.tbl_deep_extend("force", vim.g.neotest_vstest or {}, opts or {})
  return create_adapter()
end

setmetatable(DotnetNeotestAdapter, {
  __call = apply_user_settings,
})

return DotnetNeotestAdapter
