local nio = require("nio")
local logger = require("neotest.logging")
local types = require("neotest.types")

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
        logger.info("neotest-vstest: MTP process stdout: " .. data)
      end
      if err then
        logger.warn("neotest-vstest: MTP process stdout: " .. data)
      end
    end,
  })

  logger.debug("neotest-vstest: MTP process started with PID: " .. process.pid)
  logger.debug(process.cmd)

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

---@async
---@param dll_path string path to test project dll file
function M.create_client(dll_path)
  local server = start_server(dll_path)
  local client = vim.lsp.client.create({
    name = "neotest-mtp",
    cmd = vim.lsp.rpc.connect(server:getsockname().ip, server:getsockname().port),
    root_dir = vim.fs.dirname(dll_path),
    on_exit = function()
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

  return client
end

---@async
---@param dll_path string path to test project dll file
function M.discovery_tests(dll_path)
  local client = M.create_client(dll_path)

  local tests = {}
  local discovery_semaphore = nio.control.semaphore(1)

  nio.scheduler()

  client.handlers["testing/testUpdates/tests"] = function(err, result, ctx)
    nio.run(function()
      discovery_semaphore.with(function()
        for _, test in ipairs(result.changes) do
          logger.debug("neotest-vstest: Discovered test: " .. test.node.uid)
          tests[#tests + 1] = test.node
        end
      end)
    end)
  end

  client:initialize()
  local run_id = uuid()
  local future_result = nio.control.future()
  client:request("testing/discoverTests", {
    runId = run_id,
  }, function(err, _)
    nio.run(function()
      if err then
        future_result.set_error(err)
      else
        discovery_semaphore.with(function()
          future_result.set(tests)
        end)
      end
    end)
  end)

  local result = future_result.wait()

  logger.debug("neotest-vstest: Discovered test results: " .. vim.inspect(result))

  client:stop(true)

  return result
end

---@async
---@param dll_path string path to test project dll file
---@param nodes any[] list of test nodes to run
---@return neotest-vstest.Client.RunResult
function M.run_tests(dll_path, nodes)
  local client = M.create_client(dll_path)

  local run_results = {}
  local result_stream = nio.control.queue()
  local output_stream = nio.control.queue()
  local discovery_semaphore = nio.control.semaphore(1)

  nio.scheduler()

  client.handlers["testing/testUpdates/tests"] = function(err, result, ctx)
    nio.run(function()
      discovery_semaphore.with(function()
        for _, test in ipairs(result.changes) do
          logger.debug("neotest-vstest: got test result for: " .. test.node.uid)
          logger.debug(test)
          local status_map = {
            ["passed"] = types.ResultStatus.passed,
            ["skipped"] = types.ResultStatus.skipped,
            ["failed"] = types.ResultStatus.failed,
            ["timed-out"] = types.ResultStatus.failed,
            ["error"] = types.ResultStatus.failed,
          }

          local errors = {}
          if test.node["error.message"] then
            errors[#errors + 1] = { message = test.node["error.message"] }
          end
          if test.node["error.stacktrace"] then
            errors[#errors + 1] = { message = test.node["error.stacktrace"] }
          end

          local test_result = {
            status = status_map[test.node["execution-state"]],
            short = test.node["standardOutput"]
              or test.node["error.message"]
              or test.node["execution-state"],
            errors = errors,
          }
          run_results[test.node.uid] = test_result
          result_stream.put({ id = test.node.uid, result = test_result })
        end
      end)
    end)
  end

  client.handlers["client/log"] = function(err, result, ctx)
    nio.run(function()
      output_stream.put_nowait(result.message)
    end)
  end

  client:initialize()
  local run_id = uuid()
  local future_result = nio.control.future()
  client:request("testing/runTests", {
    runId = run_id,
    testCases = nodes,
  }, function(err, _)
    nio.run(function()
      if err then
        future_result.set_error(err)
      else
        discovery_semaphore.with(function()
          future_result.set(run_results)
        end)
      end
    end)
  end)

  local result = future_result.wait()

  logger.debug("neotest-vstest: Discovered test results: " .. vim.inspect(result))

  return {
    output_stream = output_stream.get,
    result_stream = result_stream.get,
    result_future = future_result,
    stop = function()
      client:stop(true)
    end,
  }
end

return M
