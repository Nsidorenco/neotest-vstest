local nio = require("nio")
local logger = require("neotest.logging")

local M = {}

---Start a TCP server acting as a proxy between the neovim lsp and the mtp server.
---@async
---@param dll_path string path to test project dll file
---@return uv.uv_tcp_t server
local function start_server(dll_path)
  local server, server_err = vim.uv.new_tcp()
  assert(server, server_err)

  local mtp_client
  local lsp_client

  local connected = nio.control.event()

  server:bind("127.0.0.1", 0)
  server:listen(128, function(listen_err)
    if mtp_client and lsp_client then
      return
    end

    assert(not listen_err, listen_err)
    local client, client_err = vim.uv.new_tcp()
    assert(client, client_err)
    server:accept(client)

    if not mtp_client then
      logger.debug("neotest-vstest: Accepted connection from mtp")
      mtp_client = client
      client:read_start(function(err, data)
        assert(not err, err)
        if data then
          logger.trace("neotest-vstest: Received data from mtp: " .. data)
          lsp_client:write(data)
        else
          client:shutdown()
          client:close()
          if lsp_client then
            lsp_client:close()
            lsp_client:shutdown()
          end
          server:close()
          server:shutdown()
        end
      end)
      connected.set()
    else
      lsp_client = client
      logger.debug("neotest-vstest: Accepted connection from lsp")
      client:read_start(function(err, data)
        assert(not err, err)
        if data then
          logger.trace("neotest-vstest: Received data from lsp: " .. data)
          mtp_client:write(data)
        else
          client:shutdown()
          client:close()
          if mtp_client then
            mtp_client:close()
            mtp_client:shutdown()
          end
          server:close()
          server:shutdown()
        end
      end)
    end
  end)

  logger.debug("neotest-vstest: proxy server started on port: " .. server:getsockname().port)

  local process = vim.system({
    "dotnet",
    dll_path,
    "--server",
    "--client-port",
    server:getsockname().port,
  }, {
    stdout = function(err, data)
      if data then
        vim.print(data)
      end
      if err then
        vim.print(err)
      end
    end,
  })

  logger.debug("neotest-vstest: MTP process started with PID: " .. process.pid)

  logger.debug("neotest-vstest: Waiting for client to connect...")
  connected.wait()
  logger.debug("neotest-vstest: Client connected")

  return server
end

local random = math.random
local function uuid()
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return string.gsub(template, "[xy]", function(c)
    local v = (c == "x") and random(0, 0xf) or random(8, 0xb)
    return string.format("%x", v)
  end)
end

---@class MTPClient
---@field discover_tests fun(): any[]

---@async
---@param dll_path string path to test project dll file
---@return MTPClient
function M.start_client(dll_path)
  local server = start_server(dll_path)
  local client = vim.lsp.client.create({
    name = "neotest-mtp",
    cmd = vim.lsp.rpc.connect(server:getsockname().ip, server:getsockname().port),
    root_dir = vim.fs.dirname(dll_path),
    on_exit = function()
      server:close()
      server:shutdown()
    end,
    before_init = function(params)
      params.processId = vim.fn.getpid()
      params.clientInfo = {
        name = "neotest-mtp",
        version = "1.0",
      }
    end,
    capabilities = {
      testing = {
        debuggerProvider = true,
        attachmentSupport = true,
      },
    },
  })
  assert(client, "Failed to create LSP client")

  local discovery_dict = {}
  local discovery_semaphore = nio.control.semaphore(1)

  client.handlers["testing/testUpdates/tests"] = function(err, result, ctx)
    nio.run(function()
      discovery_semaphore.with(function()
        local previous = discovery_dict[result.runId] or {}
        local nodes = {}
        for _, test in ipairs(result.changes) do
          nodes[test.node.uid] = {
            display_name = test.node["display-name"],
            execution_state = test.node["execution-state"],
            location = {
              file = test.node["location.file"],
              line_start = test.node["location.line-start"],
              line_end = test.node["location.line-end"],
              method = test.node["location.method"],
              namespace = test.node["location.namespace"],
              type = test.node["location.type"],
            },
            node_type = test.node["node-type"],
          }
        end
        discovery_dict[result.runId] = vim.tbl_extend("force", previous, nodes)
      end)
    end)
  end

  client:initialize()

  return {
    discover_tests = function()
      local run_id = uuid()
      discovery_dict[run_id] = {}
      client:request_sync("testing/discoverTests", {
        runId = run_id,
      })
      local tests
      discovery_semaphore.with(function()
        tests = discovery_dict[run_id]
      end)

      vim.print(tests)
    end,
  }
end

return M
