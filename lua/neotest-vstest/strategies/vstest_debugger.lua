local nio = require("nio")
local logger = require("neotest.logging")
local dotnet_utils = require("neotest-vstest.dotnet_utils")

---@param dap_config table
---@return fun(spec: neotest.RunSpec): neotest.Process
return function(dap_config)
  return function(spec)
    local resultAccumulator = require("neotest-vstest.utilities").ResultAccumulator:new()
    local dap = require("dap")

    local handler_id = "neotest_" .. nio.fn.localtime()

    assert(
      vim.tbl_count(spec.context.client_id_map) <= 1,
      "neotest-vstest: cannot debug tests across multiple projects at once"
    )

    ---@type neotest-vstest.Client
    local client = vim.tbl_keys(spec.context.client_id_map)[1]
    local ids = spec.context.client_id_map[client]

    if client then
      if spec.context.solution then
        dotnet_utils.build_path(spec.context.solution)
      else
        dotnet_utils.build_project(client.project)
      end
    end

    local run_result = client:debug_tests(ids)
    resultAccumulator:add_run_result(run_result, spec.context.write_stream)

    logger.debug("neotest-vstest: starting debug session: " .. vim.inspect(run_result))

    dap_config = vim.tbl_extend(
      "keep",
      { env = spec.env, cwd = spec.cwd },
      dap_config,
      { processId = run_result.pid, cwd = client.project.proj_dir }
    )
    --
    logger.debug("neotest-vstest: dap config: " .. vim.inspect(dap_config))

    local dap_opts = {
      before = function(config)
        dap.listeners.after.configurationDone["neotest-vstest"] = function()
          nio.run(run_result.on_attach)
        end

        -- dap.listeners.after.event_output[handler_id] = function(_, body)
        --   if vim.tbl_contains({ "stdout", "stderr" }, body.category) then
        --     nio.run(function()
        --       data_accum:push(body.output)
        --     end)
        --   end
        -- end
        -- dap.listeners.after.event_exited[handler_id] = function(_, info)
        --   result_code = info.exitCode
        --   pcall(finish_future.set)
        -- end

        return config
      end,
      after = function()
        -- local received_exit = result_code ~= nil
        -- if not received_exit then
        --   result_code = 0
        --   pcall(finish_future.set)
        -- end
        dap.listeners.after.event_output[handler_id] = nil
        dap.listeners.after.event_exited[handler_id] = nil
      end,
    }

    logger.debug(
      "neotest-vstest: starting dap session. Config: "
        .. vim.inspect(dap_config)
        .. ", opts: "
        .. vim.inspect(dap_opts)
    )

    nio.scheduler()
    dap.run(dap_config, dap_opts)

    logger.debug("neotest-vstest: returning debug result")

    local set_result = function(result)
      spec.context.results = vim.tbl_extend("force", spec.context.results, result)
    end

    return resultAccumulator:build_neotest_result_table(set_result)
  end
end
