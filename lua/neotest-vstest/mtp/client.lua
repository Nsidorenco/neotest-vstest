local nio = require("nio")
local logger = require("neotest.logging")
local types = require("neotest.types")

local M = {}

---Start a TCP server acting as a proxy between the neovim lsp and the mtp server.
---@async
---@param dll_path string path to test project dll file
---@param mtp_env? table<string, string> environment variables for the mtp server
---@return nio.control.Future<uv.uv_tcp_t> server_future, vim.SystemObj mtp_process
local function start_server(dll_path, mtp_env)
  local server, server_err = vim.uv.new_tcp()
  assert(server, server_err)

  local mtp_client
  local lsp_client

  local server_future = nio.control.future()

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
        if err then
          logger.warn("neotest-vstest: " .. err)
        end
        if data then
          logger.trace("neotest-vstest: Received data from mtp with pid: " .. data)
          lsp_client:write(data)
        end
      end)
      server_future.set(server)
      logger.debug("neotest-vstest: Client connected")
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
    env = mtp_env or {},
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

  return server_future, process
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
---@param on_update function (err: lsp.ResponseError, result: any, ctx: lsp.HandlerContext)
---@param on_log function (err: lsp.ResponseError, result: any, ctx: lsp.HandlerContext)
---@param mtp_env? table<string, string> environment variables for the mtp server
---@return nio.control.Future<vim.lsp.Client> client_future, integer mtp_process_pid
function M.create_client(dll_path, on_update, on_log, mtp_env)
  local server_future, mtp_process = start_server(dll_path, mtp_env)

  nio.scheduler()
  local cleanup_autocmd_id = vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("neotest_vstest_mtp_shutdown", { clear = false }),
    desc = "Shutdown dotnet MTP client process on Neovim exit",
    callback = function()
      mtp_process:kill(vim.uv.constants.SIGKILL)
    end,
  })

  local client_future = nio.control.future()

  nio.run(function()
    local server = server_future.wait()
    local client = vim.lsp.client.create({
      name = "neotest-mtp",
      cmd = vim.lsp.rpc.connect(server:getsockname().ip, server:getsockname().port),
      root_dir = vim.fs.dirname(dll_path),
      on_exit = function()
        logger.debug(
          "neotest-vstest: MTP process shutdown triggered from client with PID: " .. mtp_process.pid
        )
        server:shutdown()
        mtp_process:kill(vim.uv.constants.SIGKILL)
        vim.api.nvim_del_autocmd(cleanup_autocmd_id)
      end,
      before_init = function(params)
        params.processId = vim.fn.getpid()
        params.clientInfo = {
          name = "neotest-mtp",
          version = "1.8",
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

    client.handlers["testing/testUpdates/tests"] = function(err, result, ctx)
      on_update(err, result, ctx)
    end

    client.handlers["client/log"] = function(err, result, ctx)
      on_log(err, result, ctx)
    end

    client_future.set(client)
  end)

  return client_future, mtp_process.pid
end

---@async
---@param dll_path string path to test project dll file
function M.discovery_tests(dll_path)
  local tests = {}

  local on_update = function(err, result, ctx)
    if result.changes and result.changes ~= vim.NIL then
      for _, test in ipairs(result.changes) do
        tests[#tests + 1] = test.node
      end
    end
  end

  local client_future = M.create_client(dll_path, on_update, function() end)

  --@type vim.lsp.Client
  local client = client_future.wait()

  nio.scheduler()

  client:initialize()
  local run_id = uuid()
  client:request_sync("testing/discoverTests", {
    runId = run_id,
  }, 30000)

  logger.debug("neotest-vstest: Discovered test results: " .. vim.inspect(tests))

  client:stop(true)

  return tests
end

local status_map = {
  ["passed"] = types.ResultStatus.passed,
  ["skipped"] = types.ResultStatus.skipped,
  ["failed"] = types.ResultStatus.failed,
  ["timed-out"] = types.ResultStatus.skipped,
  ["error"] = types.ResultStatus.failed,
}

local function parseTestResult(test)
  logger.debug("neotest-vstest: got test result for: " .. test.node.uid)
  logger.debug(test)

  local errors = {}
  if test.node["error.message"] then
    errors[#errors + 1] = { message = test.node["error.message"] }
  end
  if test.node["error.stacktrace"] then
    errors[#errors + 1] = { message = test.node["error.stacktrace"] }
  end

  local outcome = test.node["execution-state"] and status_map[test.node["execution-state"]]

  if not outcome then
    return nil
  end

  local default_short_message = (test.node["display-name"] or "") .. outcome

  return {
    status = outcome,
    short = test.node["standardOutput"]
      or test.node["error.message"]
      or test.node["execution-state"]
      or default_short_message,
    errors = errors,
  }
end

---@async
---@param dll_path string path to test project dll file
---@param nodes any[] list of test nodes to run
---@return neotest-vstest.Client.RunResult
function M.run_tests(dll_path, nodes)
  local run_results = {}
  local result_stream = nio.control.queue()
  local output_stream = nio.control.queue()

  local on_update = function(_, result)
    if result.changes and result.changes ~= vim.NIL then
      nio.run(function()
        for _, test in ipairs(result.changes) do
          local test_result = run_results[test.node.uid]
          if test_result then
            logger.debug("neotest-vstest: preparing to update test result for: " .. test.node.uid)
            result_stream.put_nowait({ id = test.node.uid, result = test_result })
            logger.debug("neotest-vstest: Updated test result for: " .. test.node.uid)
          end
        end
      end)

      for _, test in ipairs(result.changes) do
        local test_result = parseTestResult(test)
        if test_result then
          run_results[test.node.uid] = test_result
        end
      end
    end
  end

  local on_log = function(_, result)
    nio.run(function()
      output_stream.put_nowait({ result.message })
    end)
  end

  ---@type vim.lsp.Client
  local client = M.create_client(dll_path, on_update, on_log).wait()

  nio.scheduler()

  client:initialize()
  local run_id = uuid()
  local future_result = nio.control.future()
  local done_event = nio.control.event()

  logger.debug("neotest-vstest: running tests for: " .. vim.inspect(nodes))

  client:request("testing/runTests", {
    runId = run_id,
    tests = nodes,
  }, function(err, _)
    nio.run(function()
      if err then
        future_result.set_error(err)
      else
        done_event.wait()
        future_result.set(run_results)
      end
    end)
  end)

  nio.run(function()
    while result_stream.size() > 0 and output_stream.size() > 0 and not future_result.is_set() do
      nio.sleep(100)
    end
    done_event.set()
  end)

  return {
    result_future = future_result,
    result_stream = result_stream.get,
    output_stream = output_stream.get,
    stop = function()
      client:stop(true)
    end,
  }
end

function M.debug_tests(dll_path, nodes)
  local mtp_env = {
    ["TESTINGPLATFORM_WAIT_ATTACH_DEBUGGER"] = "1",
  }

  local run_results = {}
  local result_stream = nio.control.queue()
  local output_stream = nio.control.queue()
  local future_result = nio.control.future()
  local done_event = nio.control.event()

  local on_update = function(_, result)
    if result.changes and result.changes ~= vim.NIL then
      for _, test in ipairs(result.changes) do
        local test_result = parseTestResult(test)
        if test_result then
          run_results[test.node.uid] = test_result
        end
      end
    end
  end

  local on_log = function(_, result, _)
    nio.run(function()
      output_stream.put_nowait({ result.message })
    end)
  end

  local client_future, mtp_process_pid = M.create_client(dll_path, on_update, on_log, mtp_env)

  nio.run(function()
    while result_stream.size() > 0 and output_stream.size() > 0 and not future_result.is_set() do
      nio.sleep(100)
    end
    done_event.set()
  end)

  return {
    pid = mtp_process_pid,
    on_attach = function()
      local client = client_future.wait()

      nio.scheduler()

      client:initialize()
      local run_id = uuid()
      client:request("testing/runTests", {
        runId = run_id,
        tests = nodes,
      }, function(err, _)
        nio.run(function()
          if err then
            future_result.set_error(err)
          else
            done_event.wait()
            future_result.set(run_results)
          end
        end)
      end)
    end,
    output_stream = output_stream.get,
    result_stream = result_stream.get,
    result_future = future_result,
    stop = function()
      client_future.wait():stop(true)
    end,
  }
end

return M
