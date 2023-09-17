VERSION = "0.1.0"

local micro = import("micro")
local config = import("micro/config")
local shell = import("micro/shell")
local buffer = import("micro/buffer")
local util = import("micro/util")
local go_os = import("os")

-- currently the json.lua file needs to be placed either in
-- current working directory or /usr/local/share/lua/5.1/json.lua
-- FIXME: figure out how to do relative import instead
local json = require "json"

local lspServers = {
  go         = "gopls",
  haskell    = "haskell-language-server-wrapper",
  javascript = "deno lsp",
  python     = "pylsp",
  rust       = "rust-analyzer",
  zig        = "zls",
}

local activeConnections = {}
local bufferStates = {}

function init()
    config.MakeCommand("lsp", startServer, config.NoComplete)
    config.MakeCommand("hover", hoverAction, config.NoComplete)
end

function startServer(bufpane, args)
    local success, lspServerCommand = pcall(function() return args[1] end)
    if not success then
        lspServerCommand = lspServers[bufpane.Buf:FileType()]
    end
    LSPClient:initialize(lspServerCommand)
end

LSPClient = {}
LSPClient.__index = LSPClient

function LSPClient:initialize(lspServerCommand)
    local args = lspServerCommand:split()
    lspServerCommand = table.remove(args, 1)

    local client = {}
    setmetatable(client, LSPClient)

    local clientId = string.format("%s-%04x", lspServerCommand, math.random(65536))
    activeConnections[clientId] = client

    client.clientId = clientId
    client.requestId = 0
    client.buffer = ""
    client.expectedLength = nil
    client.serverCapabilities = {}
    client.serverName = nil
    client.serverVersion = nil
    client.sentRequests = {}
    client.openFileVersions = {}
    -- the last parameter(s) to JobSpawn are userargs which get passed down to
    -- the callback functions (onStdout, onStderr, onExit)
    client.job = shell.JobSpawn(lspServerCommand, args, onStdout, onStderr, onExit, clientId)

    if client.job.Err ~= nil then
        infobar(string.format("Error: %s", client.job.Err:Error()))
    end

    local wd, _ = go_os.Getwd()
    local rootUri = string.format("file://%s", wd)

    client:request("initialize", {
        processId = go_os.Getpid(),
        rootUri = rootUri,
        workspaceFolders = { { name = "root", uri = rootUri } },
        capabilities = {
            textDocument = { 
                hover = { contentFormat = {"plaintext", "markdown"} }
            }
        }
    })
    return client
end

function LSPClient:send(msg)
    msg = json.encode(msg)
    local msgWithHeaders = string.format("Content-Length: %d\r\n\r\n%s", #msg, msg)
    shell.JobSend(self.job, msgWithHeaders)
    log("(", self.clientId, ")->", msgWithHeaders, "\n\n")
end

function LSPClient:notification(method, params)
    local msg = {
        jsonrpc = "2.0",
        method = method
    }
    if params ~= nil then
        msg.params = params
    else
        -- the spec allows params to be omitted but language server implementations
        -- are buggy so we can put an empty object there for now
        -- https://github.com/golang/go/issues/57459
        msg.params = json.object
    end
    self:send(msg)
end

function LSPClient:request(method, params)
    local msg = {
        jsonrpc = "2.0",
        id = self.requestId,
        method = method
    }
    if params ~= nil then
        msg.params = params
    else
        -- the spec allows params to be omitted but language server implementations
        -- are buggy so we can put an empty object there for now
        -- https://github.com/golang/go/issues/57459
        msg.params = json.object
    end
    self.sentRequests[self.requestId] = method
    self.requestId = self.requestId + 1
    self:send(msg)
end

function LSPClient:handleResponse(method, response)
    if method == "initialize" then
        self.capabilities = response.result.capabilities
        if response.result.serverInfo then
            self.serverName = response.result.serverInfo.name
            self.serverVersion = response.result.serverInfo.version
        end
        self:notification("initialized")
        infobar(string.format("Initialized %s version %s", self.serverName, self.serverVersion))
        -- FIXME: iterate over *all* currently open buffers
        onBufferOpen(micro.CurPane().Buf)
    elseif method == "textDocument/hover" then
        -- response.result.contents being a string is deprecated but as of 2023
        -- pylsp still responds with {"contents": ""} for no results
        if response.result == nil or response.result.contents == "" then
            return infobar("no hover results")
        elseif type(response.result.contents) == "string" then
            infobar(response.result.contents)
        elseif type(response.result.contents.value) == "string" then
            infobar(response.result.contents.value)
        end
    else
        log("WARNING: dunno what to do with response to", method)
    end
end

function LSPClient:receiveMessage(text)
    local decodedMsg = json.decode(text)
    local request = self.sentRequests[decodedMsg.id]
    if request then
        self.sentRequests[decodedMsg.id] = nil
        self:handleResponse(request, decodedMsg)
    else
        log("WARNING: don't know what to do with that message")
    end
end

function LSPClient:didOpen(buf)
    local ftype = buf:FileType()
    local bufText = util.String(buf:Bytes())
    local bufUri = string.format("file://%s", buf.AbsPath)
    self.openFileVersions[bufUri] = 1
    self:notification("textDocument/didOpen", {
        textDocument = {
            uri = bufUri,
            languageId = ftype,
            version = 1,
            text = bufText
        }
    })
end

function LSPClient:didChange(buf)
    local ftype = buf:FileType()
    local bufText = util.String(buf:Bytes())
    local bufUri = string.format("file://%s", buf.AbsPath)
    local newVersion = (self.openFileVersions[bufUri] or 1) + 1
    self.openFileVersions[bufUri] = newVersion
    self:notification("textDocument/didChange", {
        textDocument = {
            uri = bufUri,
            version = newVersion
        },
        contentChanges = {
            { text = bufText }
        }
    })
end

function LSPClient:onStdout(text)

    self.buffer = self.buffer .. text

    while true do
        if self.expectedLength == nil then
            -- receive headers
            -- TODO: figure out if it's necessary to handle the Content-Type header
            local a, b = self.buffer:find("\r\n\r\n")
            if a == nil then return end
            local headers = self.buffer:sub(0, a)
            local _, _, m = headers:find("Content%-Length: (%d+)")
            self.expectedLength = tonumber(m)
            self.buffer = self.buffer:sub(b+1)

        elseif self.buffer:len() < self.expectedLength then
            return

        else
            -- receive content
            self:receiveMessage(self.buffer:sub(0, self.expectedLength))
            self.buffer = self.buffer:sub(self.expectedLength + 1)
            self.expectedLength = nil
        end
    end
end

function log(...)
    micro.Log("[µlsp]", unpack(arg))
end

function infobar(text)
    micro.InfoBar():Message("[µlsp] " .. text:gsub("%s+", " "))
end



-- USER TRIGGERED ACTIONS
function hoverAction(bufpane)
    local buf = bufpane.Buf
    local bufUri = string.format("file://%s", buf.AbsPath)
    local cursor = buf:GetActiveCursor()

    for clientId, client in pairs(activeConnections) do
        client:request("textDocument/hover", {
            textDocument = { uri = bufUri },
            position = { line = cursor.Y, character = cursor.X }
        })
    end
end




-- EVENTS (LUA CALLBACKS)
-- https://github.com/zyedidia/micro/blob/master/runtime/help/plugins.md#lua-callbacks
-- FIXME: split bufpanes?

function onStdout(text, userargs)
    local clientId = userargs[1]
    log("<-(", clientId, "[stdout] )", text, "\n\n")
    local client = activeConnections[clientId]
    client:onStdout(text)
end

function onStderr(text, userargs)
    local clientId = userargs[1]
    log("<-(", clientId, "[stderr] )", text, "\n\n")
end

function onExit(text, userargs)
    local clientId = userargs[1]
    log(clientId, "exited")
    -- infobar(clientId .. " exited")
end

function onBufferOpen(buf)
    for clientId, client in pairs(activeConnections) do
        client:didOpen(buf)
    end
end

-- FIXME: figure out how to disable all this garbage when there are no active connections
function onRune(bufpane, rune)
    local buf = bufpane.Buf
    -- filetype is "unknown" for the command prompt
    if buf:FileType() == "unknown" then
        return
    end

    for clientId, client in pairs(activeConnections) do
        client:didChange(buf)
    end
end

function onMoveLinesUp(bp) onRune(bp) end
function onMoveLinesDown(bp) onRune(bp) end
function onDeleteWordRight(bp) onRune(bp) end
function onDeleteWordLeft(bp) onRune(bp) end
function onInsertNewline(bp) onRune(bp) end
function onInsertSpace(bp) onRune(bp) end
function onBackspace(bp) onRune(bp) end
function onDelete(bp) onRune(bp) end
function onInsertTab(bp) onRune(bp) end
function onUndo(bp) onRune(bp) end
function onRedo(bp) onRune(bp) end
function onCut(bp) onRune(bp) end
function onCutLine(bp) onRune(bp) end
function onDuplicateLine(bp) onRune(bp) end
function onDeleteLine(bp) onRune(bp) end
function onIndentSelection(bp) onRune(bp) end
function onOutdentSelection(bp) onRune(bp) end
function onOutdentLine(bp) onRune(bp) end
function onIndentLine(bp) onRune(bp) end
function onPaste(bp) onRune(bp) end
function onPlayMacro(bp) onRune(bp) end
function onAutocomplete(bp) onRune(bp) end



-- HELPER FUNCTIONS

function string.split(s)
    local result = {}
    for x in string.gmatch(s, "[^%s]+") do
        table.insert(result, x)
    end
    return result
end
