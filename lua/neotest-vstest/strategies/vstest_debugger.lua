local nio = require("nio")
local FanoutAccum = require("neotest.types").FanoutAccum
local logger = require("neotest.logging")
local dotnet_utils = require("neotest-vstest.dotnet_utils")
local discovery = require("neotest-vstest.vstest.discovery")

---@param dap_config table
---@return fun(spec: neotest.RunSpec): neotest.Process
return function(dap_config)
  return function(spec)
    local dap = require("dap")

    local handler_id = "neotest_" .. nio.fn.localtime()
    local data_accum = FanoutAccum(function(prev, new)
      if not prev then
        return new
      end
      return prev .. new
    end, nil)

    assert(
      vim.tbl_count(spec.context.client_id_map) <= 1,
      "neotest-vstest: cannot debug tests across multiple projects at once"
    )

    local client = vim.tbl_keys(spec.context.client_id_map)[1]
    local ids = spec.context.projects_id_map[client]

    if spec.context.solution then
      dotnet_utils.build_path(spec.context.solution)
    else
      dotnet_utils.build_project(client.project)
    end

    local output_path = nio.fn.tempname()
    local open_err, output_fd = nio.uv.fs_open(output_path, "w", 438)
    assert(not open_err, open_err)

    data_accum:subscribe(function(data)
      local write_err, _ = nio.uv.fs_write(output_fd, data)
      assert(not write_err, write_err)
    end)

    local result_accum = FanoutAccum(function(prev, new)
      if not prev then
        return new
      end
      return prev .. new
    end, nil)

    result_accum:subscribe(function(data)
      spec.context.write_stream(data)
    end)

    local finish_future = nio.control.future()
    local result_code

    local client = discovery.get_client_for_project(project)
    assert(client, "failed to get client for project")

    local run_result = client:debug_tests(ids)

    nio.run(function()
      while not finish_future.is_set() do
        local data = run_result.output_stream()
        for _, line in ipairs(data) do
          result_accum:push(line .. "\n")
        end
      end
    end)

    nio.run(function()
      while not finish_future.is_set() do
        local data = run_result.result_stream()
        for _, line in ipairs(data) do
          logger.debug("neotest-vstest: writing result: ")
          logger.debug(line)
          data_accum:push(line)
        end
      end
    end)

    nio.scheduler()
    dap.run(
      vim.tbl_extend(
        "keep",
        { env = spec.env, cwd = spec.cwd },
        dap_config,
        { processId = vim.trim(run_result.pid), cwd = project.proj_dir }
      ),
      {
        before = function(config)
          dap.listeners.after.configurationDone["neotest-vstest"] = function()
            nio.run(run_result.on_attach)
          end

          dap.listeners.after.event_output[handler_id] = function(_, body)
            if vim.tbl_contains({ "stdout", "stderr" }, body.category) then
              nio.run(function()
                data_accum:push(body.output)
              end)
            end
          end
          dap.listeners.after.event_exited[handler_id] = function(_, info)
            result_code = info.exitCode
            pcall(finish_future.set)
          end

          return config
        end,
        after = function()
          local received_exit = result_code ~= nil
          if not received_exit then
            result_code = 0
            pcall(finish_future.set)
          end
          dap.listeners.after.event_output[handler_id] = nil
          dap.listeners.after.event_exited[handler_id] = nil
        end,
      }
    )
    return {
      is_complete = function()
        return result_code ~= nil
      end,
      output_stream = function()
        local queue = nio.control.queue()
        data_accum:subscribe(queue.put)
        return function()
          return nio.first({ finish_future.wait, queue.get })
        end
      end,
      output = function()
        return output_path
      end,
      attach = function()
        dap.repl.open()
      end,
      stop = function()
        dap.terminate()
        run_result.stop()
      end,
      result = function()
        local result = run_result.result_future.wait()
        run_result.stop()

        logger.debug("neotest-vstest: got parsed results:")
        logger.debug(result)

        logger.debug("neotest-vstest: extending result with: " .. vim.inspect(result))
        spec.context.results = vim.tbl_extend("force", spec.context.results, result)

        return result_code
      end,
    }
  end
end
