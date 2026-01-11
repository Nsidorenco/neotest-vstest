local nio = require("nio")
local FanoutAccum = require("neotest.types.fanout_accum")
local logger = require("neotest.logging")

local M = {}

---@class neotest-vstest.stream_queue
---@field get async fun(): any
---@field write fun(data: any)

---@return neotest-vstest.stream_queue
function M.stream_queue()
  local queue = nio.control.queue()

  local write = function(data)
    queue.put_nowait(data)
  end

  return {
    get = queue.get,
    write = write,
  }
end

---@class neotest-vstest.ResultAccumulator
---@field output_accum neotest.FanoutAccum
---@field output_finish_future nio.control.Future
---@field output_path string
---@field private test_run_result_functions function[]
---@field private stop_stream_functions function[]
---@field private stop_streams fun(): nil
---@field private await_results fun(): nio.control.Future
---@field private output_stream async fun(): async fun(): string Async iterator of process output
M.ResultAccumulator = {}
M.ResultAccumulator.__index = M.ResultAccumulator

function M.ResultAccumulator:new()
  local output_finish_future = nio.control.future()

  local output_accum = FanoutAccum(function(prev, new)
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

  ---@type function[]
  local test_run_result_functions = {}
  ---@type function[]
  local stop_stream_functions = {}

  local result_future = nio.control.future()

  local await_results = function()
    nio.run(function()
      if #test_run_result_functions > 0 then
        local results = nio.gather(test_run_result_functions)
        result_future.set(results)
      end
      output_finish_future.set()
    end)
  end

  local client = {
    output_accum = output_accum,
    output_finish_future = output_finish_future,
    output_path = output_path,
    test_run_result_functions = test_run_result_functions,
    stop_stream_functions = stop_stream_functions,
    stop_streams = function()
      for _, stop_stream in ipairs(stop_stream_functions) do
        stop_stream()
      end
    end,
    await_results = function()
      await_results()
      return result_future
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
        while queue.size ~= 0 or not output_finish_future.is_set do
          return queue.get()
        end
      end
    end,
  }

  setmetatable(client, self)

  return client
end

---@async
---@param run_result neotest-vstest.Client.RunResult
function M.ResultAccumulator:add_run_result(run_result, write_stream)
  nio.run(function()
    while not self.output_finish_future.is_set() do
      local data = run_result.output_stream()
      for _, line in ipairs(data) do
        self.output_accum:push(line .. "\n")
      end
    end
  end)

  nio.run(function()
    while not self.output_finish_future.is_set() do
      local result = nio.first({ run_result.result_stream, self.output_finish_future.wait })
      logger.debug("neotest-vstest: got test stream result: ")
      logger.debug(result)
      if result then
        write_stream(result)
      end
    end
  end)

  table.insert(self.test_run_result_functions, run_result.result_future.wait)
  table.insert(self.stop_stream_functions, run_result.stop)
end

---@param set_result function(any): nil
---@return neotest.Process
function M.ResultAccumulator:build_neotest_result_table(set_result)
  local result_future = self.await_results()

  return {
    is_complete = function()
      return self.output_finish_future.is_set()
    end,
    output = function()
      return self.output_path
    end,
    stop = self.stop_streams,
    output_stream = self.output_stream,
    attach = function() end,
    result = function()
      self.output_finish_future.wait()
      self.stop_streams()
      local results = result_future.wait()

      logger.debug("neotest-vstest: got parsed results:")
      logger.debug(results)

      for _, result in ipairs(results) do
        set_result(result)
      end

      return 0
    end,
  }
end

return M
