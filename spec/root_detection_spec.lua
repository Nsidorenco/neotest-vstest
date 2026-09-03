describe("Test root detection", function()
  -- increase nio.test timeout
  vim.env.PLENARY_TEST_TIMEOUT = 80000
  -- add test_discovery script and treesitter parsers installed with luarocks
  vim.opt.runtimepath:append(vim.fn.getcwd())
  vim.opt.runtimepath:append(vim.fn.expand("~/.luarocks/lib/lua/5.1/"))

  local nio = require("nio")
  nio.tests.it("Detect .sln file as root", function()
    local plugin = require("neotest-vstest")
    local dir = vim.fn.getcwd() .. "/spec/samples/test_solution"
    local root = plugin.root(dir)
    assert.are_equal(dir, root)
  end)
  nio.tests.it("Detect .sln file as root from project dir", function()
    local plugin = require("neotest-vstest")
    local dir = vim.fn.getcwd() .. "/spec/samples/test_solution"
    local root = plugin.root(dir .. "/src/FsharpTest")
    assert.are_equal(dir, root)
  end)
  nio.tests.it("Detect roots concurrently", function()
    local plugin = require("neotest-vstest")({
      solution_selector = function(solutions)
        return solutions[1]
      end,
    })
    local lib = require("neotest.lib")
    local dotnet_utils = require("neotest-vstest.dotnet_utils")
    local solution_dir = vim.fn.getcwd() .. "/spec/samples/test_solution"
    local solution_path = solution_dir .. "/src/FsharpTest"
    local solution_file = solution_dir .. "/fsharp-test.sln"
    local no_solution_dir = "/mock/no-solution"
    local original_match_root_pattern = lib.files.match_root_pattern
    local original_find = vim.fs.find
    local original_build_path = dotnet_utils.build_path
    local original_get_solution_info = dotnet_utils.get_solution_info
    local build_started = nio.control.event()
    local release_build = nio.control.event()
    local found_path
    local built_path
    local info_path

    lib.files.match_root_pattern = function(pattern)
      if pattern == "*.sln" then
        return function(path)
          if path == solution_path then
            return solution_dir
          end
        end
      end
      if pattern == ".git" then
        return function()
          return "/mock/repository"
        end
      end
      return original_match_root_pattern(pattern)
    end
    vim.fs.find = function(_, opts)
      found_path = opts.path
      return opts.path == solution_dir and { solution_file } or {}
    end
    dotnet_utils.build_path = function(path)
      built_path = path
      build_started.set()
      release_build.wait()
    end
    dotnet_utils.get_solution_info = function(path)
      info_path = path
      return {}
    end

    local ok, roots = pcall(nio.gather, {
      function()
        return plugin.root(solution_path)
      end,
      function()
        build_started.wait()

        local no_solution_root
        local no_solution_done = nio.control.event()
        nio.run(function()
          local success
          success, no_solution_root = pcall(plugin.root, no_solution_dir)
          no_solution_done.set()
          if not success then
            error(no_solution_root)
          end
        end)
        release_build.set()
        no_solution_done.wait()
        return no_solution_root
      end,
    })
    lib.files.match_root_pattern = original_match_root_pattern
    vim.fs.find = original_find
    dotnet_utils.build_path = original_build_path
    dotnet_utils.get_solution_info = original_get_solution_info

    assert.is_true(ok, roots)
    assert.are_equal(solution_dir, found_path)
    assert.are_equal(solution_file, built_path)
    assert.are_equal(solution_file, info_path)
    assert.are_equal(solution_dir, roots[1])
    assert.are_equal(solution_dir, roots[2])
  end)
end)
