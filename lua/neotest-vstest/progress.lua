local M = {}

local active = false
local opts_sticky = { title = "neotest-vstest", id = "neotest-vstest-progress", timeout = false }
local opts_dismiss = { title = "neotest-vstest", id = "neotest-vstest-progress" }

---@param msg string
---@param level integer
---@param opts table
local function notify(msg, level, opts)
  vim.schedule(function()
    vim.notify(msg, level, opts)
  end)
end

---@param msg string
function M.begin(msg)
  if not active then
    active = true
    notify(msg, vim.log.levels.INFO, opts_sticky)
  end
end

---@param msg string
function M.update(msg)
  if active then
    notify(msg, vim.log.levels.INFO, opts_sticky)
  end
end

function M.finish()
  if active then
    active = false
    notify("✓ Test discovery complete", vim.log.levels.INFO, opts_dismiss)
  end
end

return M
