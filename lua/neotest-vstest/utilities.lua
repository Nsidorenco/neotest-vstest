local nio = require("nio")

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

return M
