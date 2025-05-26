local nio = require("nio")
local logger = require("neotest.logging")
local FanoutAccum = require("neotest.types.fanout_accum")
local dotnet_utils = require("neotest-vstest.dotnet_utils")
local discovery = require("neotest-vstest.vstest.discovery")

---@async
---@param spec neotest.RunSpec
---@return neotest.Process
return function(spec)
  if spec.context.solution then
    dotnet_utils.build_path(spec.context.solution)
  else
    for client, _ in pairs(spec.context.client_id_map) do
      dotnet_utils.build_project(client.project)
    end
  end

  local output_finish_future = nio.control.future()

  local output_accum = FanoutAccum(function(prev, new)
    if not prev then
      return new
    end
    return prev .. new
  end, nil)

  local result_accum = FanoutAccum(function(prev, new)
    if not prev then
      return new
    end
    return prev .. new
  end, nil)

  local output_path = nio.fn.tempname()
  local output_open_err, output_fd = nio.uv.fs_open(output_path, "w", 438)
  assert(not output_open_err, output_open_err)

  output_accum:subscribe(function(data)
    local write_err = nio.uv.fs_write(output_fd, data, nil)
    assert(not write_err, write_err)
  end)

  result_accum:subscribe(function(data)
    spec.context.write_stream(data)
  end)

  ---@type function[]
  local test_run_result_functions = {}
  local stop_stream_functions = {}

  for client, ids in pairs(spec.context.client_id_map) do
    local run_result = client:run_tests(ids)

    nio.run(function()
      while not output_finish_future.is_set() do
        local data = run_result.output_stream()
        for _, line in ipairs(data) do
          result_accum:push(line .. "\n")
        end
      end
    end)

    nio.run(function()
      while not output_finish_future.is_set() do
        local data = run_result.result_stream()
        for _, line in ipairs(data) do
          logger.debug("neotest-vstest: writing result: ")
          logger.debug(line)
          output_accum:push(line)
        end
      end
    end)

    table.insert(test_run_result_functions, run_result.result_future.wait)
    table.insert(stop_stream_functions, run_result.stop)
  end

  local results = {}
  local stop_streams

  nio.run(function()
    results = nio.gather(test_run_result_functions)

    stop_streams = function()
      for _, stop_stream in ipairs(stop_stream_functions) do
        stop_stream()
      end
    end

    output_finish_future.set()
  end)

  return {
    is_complete = function()
      return output_finish_future.is_set()
    end,
    output = function()
      return output_path
    end,
    stop = function()
      if stop_streams then
        stop_streams()
      end
    end,
    output_stream = function()
      local queue = nio.control.queue()
      output_accum:subscribe(function(data)
        queue.put_nowait(data)
      end)
      return function()
        local data = nio.first({ queue.get, output_finish_future.wait })
        if data then
          return data
        end
        while queue.size ~= 0 do
          return queue.get()
        end
      end
    end,
    attach = function() end,
    result = function()
      output_finish_future.wait()
      stop_streams()

      logger.debug("neotest-vstest: got parsed results:")
      logger.debug(results)

      for _, result in ipairs(results) do
        logger.debug("neotest-vstest: extending result with: " .. vim.inspect(result))
        spec.context.results = vim.tbl_extend("force", spec.context.results, result)
      end

      return 0
    end,
  }
end
