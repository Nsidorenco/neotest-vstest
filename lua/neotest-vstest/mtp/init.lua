local logger = require("neotest.logging")
local mtp_client = require("neotest-vstest.mtp.client")

--- @class neotest-vstest.mtp-client: neotest-vstest.Client
--- @field private last_discovered integer
local Client = {}
Client.__index = Client

---@param project DotnetProjectInfo
function Client:new(project)
  logger.info("neotest-vstest: Creating new (MTP) client for: " .. vim.inspect(project))
  local client = {
    project = project,
    test_cases = {},
    last_discovered = 0,
  }
  setmetatable(client, self)

  return client
end

local function map_test_cases(project, test_nodes)
  local test_cases = {}
  for _, node in ipairs(test_nodes) do
    local location = node["location.file"] or project.proj_file
    local line_number = node["location.line-start"] or node["location.line-end"] or 0
    local fully_qualified_name = node["location.type"]
      or node["location.method"]
      or node["display-name"]
    local file = location and vim.fs.normalize(location)
    local existing = test_cases[file] or {}
    if node.uid then
      test_cases[file] = vim.tbl_extend("force", existing, {
        [node.uid] = {
          CodeFilePath = location,
          DisplayName = string.gsub(node["display-name"], "[^(]+%.", "", 1),
          LineNumber = line_number,
          FullyQualifiedName = fully_qualified_name,
        },
      })
    else
      logger.warn("neotest-vstest: failed to map test case: " .. vim.inspect(node))
    end
  end

  return test_cases
end

function Client:discover_tests()
  self.test_nodes = mtp_client.discovery_tests(self.project.dll_file)
  self.test_cases = map_test_cases(self.project, self.test_nodes)

  return self.test_cases
end

--- Decode the first UTF-8 codepoint in `s` starting at byte `i`.
--- Returns the codepoint and the number of bytes consumed.
local function utf8_codepoint(s, i)
  local b1 = s:byte(i)
  if b1 < 0xC0 then
    return b1, 1
  elseif b1 < 0xE0 then
    return (b1 % 0x20) * 0x40 + (s:byte(i + 1) % 0x40), 2
  elseif b1 < 0xF0 then
    return (b1 % 0x10) * 0x1000 + (s:byte(i + 1) % 0x40) * 0x40 + (s:byte(i + 2) % 0x40), 3
  else
    return (b1 % 0x08) * 0x40000
      + (s:byte(i + 1) % 0x40) * 0x1000
      + (s:byte(i + 2) % 0x40) * 0x40
      + (s:byte(i + 3) % 0x40),
      4
  end
end

--- Escape all non-ASCII characters so the JSON-RPC payload is pure ASCII.
---
--- The MTP server (Microsoft.Testing.Platform v1, bundled in e.g. xunit.v3) reads the
--- request body with a StreamReader: Content-Length is declared in UTF-8 *bytes* but the
--- reader consumes *chars*. Any multi-byte character in the payload (e.g. "·" or "∞" in
--- theory display names) makes chars < bytes, so the server over-reads into the next
--- frame's headers, desynchronizes the stream, and crashes with a JsonReaderException.
--- Keeping the payload ASCII-only guarantees bytes == chars.
--- See https://github.com/Nsidorenco/neotest-vstest/issues/85
local function escape_non_ascii(str)
  if not str:find("[\128-\255]") then
    return str
  end
  local out = {}
  local i = 1
  local n = #str
  while i <= n do
    local b = str:byte(i)
    if b < 0x80 then
      out[#out + 1] = str:sub(i, i)
      i = i + 1
    else
      local cp, len = utf8_codepoint(str, i)
      out[#out + 1] = string.format("\\u{%04X}", cp)
      i = i + len
    end
  end
  return table.concat(out)
end

local function sanitize_node(node)
  local sanitized = {}
  for key, value in pairs(node) do
    if type(value) == "string" then
      sanitized[key] = escape_non_ascii(value)
    else
      sanitized[key] = value
    end
  end
  return sanitized
end

---@async
---@param ids string[] list of test ids to run
---@return neotest-vstest.Client.RunResult
function Client:run_tests(ids)
  local nodes = {}
  for _, node in ipairs(self.test_nodes) do
    if vim.tbl_contains(ids, node.uid) then
      nodes[#nodes + 1] = sanitize_node(node)
    end
  end
  local client = mtp_client.run_tests(self.project.dll_file, nodes)
  client.start_client()
  return client
end

---@async
---@param ids string[] list of test ids to run
---@return neotest-vstest.Client.RunResult
function Client:debug_tests(ids)
  local nodes = {}
  for _, node in ipairs(self.test_nodes) do
    if vim.tbl_contains(ids, node.uid) then
      nodes[#nodes + 1] = sanitize_node(node)
    end
  end
  return mtp_client.debug_tests(self.project.dll_file, nodes)
end

return Client
