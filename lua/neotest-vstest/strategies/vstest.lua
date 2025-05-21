local nio = require("nio")
local lib = require("neotest.lib")
local logger = require("neotest.logging")
local FanoutAccum = require("neotest.types.fanout_accum")
local vstest = require("neotest-vstest.vstest")
local dotnet_utils = require("neotest-vstest.dotnet_utils")
local cli_wrapper = require("neotest-vstest.vstest.cli_wrapper")

---@async
---@param spec neotest.RunSpec
---@return neotest.Process
return function(spec)
  if spec.context.solution then
    dotnet_utils.build_path(spec.context.solution)
  else
    for project, _ in pairs(spec.context.projects_id_map) do
      dotnet_utils.build_project(project)
    end
  end

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

  local result_stream_open_err, result_stream_fd =
    nio.uv.fs_open(spec.context.results_stream_path, "w", 438)
  assert(not result_stream_open_err, result_stream_open_err)

  output_accum:subscribe(function(data)
    local write_err = nio.uv.fs_write(output_fd, data, nil)
    assert(not write_err, write_err)
  end)

  result_accum:subscribe(function(data)
    local write_err = nio.uv.fs_write(result_stream_fd, data, nil)
    assert(not write_err, write_err)
  end)

  ---@type function[]
  local test_run_results = {}

  for project, ids in pairs(spec.context.projects_id_map) do
    local process_output_file, stream_file, result_file = vstest.run_tests(project, ids)

    local result_stream_data, result_stop_stream = lib.files.stream_lines(stream_file)
    local output_stream_data, output_stop_stream = lib.files.stream_lines(process_output_file)

    local stop_stream = function()
      output_stop_stream()
      result_stop_stream()
      local output_close_err = nio.uv.fs_close(output_fd)
      assert(not output_close_err, output_close_err)
      local result_close_error = nio.uv.fs_close(result_stream_fd)
      assert(not result_close_error, result_close_error)
    end

    nio.run(function()
      local stream = result_stream_data()
      for _, line in ipairs(stream) do
        result_accum:push(line .. "\n")
      end
    end)

    nio.run(function()
      local stream = output_stream_data()
      for _, line in ipairs(stream) do
        logger.debug("neotest-vstest: writing output: " .. line)
        output_accum:push(line .. "\n")
      end
    end)

    table.insert(test_run_results, function()
      cli_wrapper.spin_lock_wait_file(result_file, 5 * 30 * 1000)
      return { stop_stream = stop_stream, result_file = result_file }
    end)
  end

  local result_future = nio.control.future()
  local result_paths = {}
  local stop_streams

  nio.run(function()
    local stop_stream_functions = {}
    local result = nio.gather(test_run_results)
    for _, res in ipairs(result) do
      table.insert(stop_stream_functions, res.stop_stream)
      table.insert(result_paths, res.result_file)
    end

    stop_streams = function()
      for _, stop_stream in ipairs(stop_stream_functions) do
        stop_stream()
      end
    end

    result_future.set()
  end)

  return {
    is_complete = function()
      return result_future.is_set()
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
        local data = nio.first({ queue.get, result_future.wait })
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
      result_future.wait()
      stop_streams()

      local open_err, result_fd = nio.uv.fs_open(spec.context.results_path, "w", 438)
      assert(not open_err, open_err)

      for _, result_path in ipairs(result_paths) do
        for _, line in ipairs(lib.files.read_lines(result_path)) do
          local write_err = nio.uv.fs_write(result_fd, line .. "\n", nil)
          assert(not write_err, write_err)
        end
      end

      local close_err = nio.uv.fs_close(result_fd)
      assert(not close_err, close_err)

      return 0
    end,
  }
end
