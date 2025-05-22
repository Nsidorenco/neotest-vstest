local nio = require("nio")

local M = {}

---@class neotest-vstest.stream_queue
---@field get async fun(): any
---@field write fun(data: any)

---@return neotest-vstest.stream_queue
function M.stream_queue()
  local queue = nio.control.queue()
  local write_semaphore = nio.control.semaphore(1)

  local write = function(data)
    write_semaphore.with(function()
      queue.put_nowait(data)
    end)
  end

  return {
    get = queue.get,
    write = write,
  }
end

return M
