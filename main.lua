VERSION = "0.1.0"

local micro = import("micro")
local config = import("micro/config")
local shell = import("micro/shell")
local buffer = import("micro/buffer")
local util = import("micro/util")
local go_os = import("os")

-- not sure if this is the best way to import code from plugin directory...
config.AddRuntimeFile("mlsp", config.RTPlugin, "json.lua")
local json = loadstring(config.ReadRuntimeFile(config.RTPlugin, "json"))()

config.AddRuntimeFile("mlsp", config.RTPlugin, "settings.lua")
local settings = loadstring(config.ReadRuntimeFile(config.RTPlugin, "settings"))()

local activeConnections = {}
local docBuffers = {}

function init()
    config.MakeCommand("lsp", startServer, config.NoComplete)
    config.MakeCommand("lsp-stop", stopServers, config.NoComplete)
    config.MakeCommand("hover", hoverAction, config.NoComplete)
    config.MakeCommand("format", formatAction, config.NoComplete)
end

function startServer(bufpane, args)
    local success, lspServerCommand = pcall(function() return args[1] end)
    if not success then
        local ftype = bufpane.Buf:FileType()
        lspServerCommand = settings.languageServers[ftype]
        if lspServerCommand == nil then
            infobar(string.format("ERROR: no language server set up for file type '%s'", ftype))
            return
        end
    end

    for _, client in pairs(activeConnections) do
        if client.command == lspServerCommand then
            infobar(string.format("'%s' is already running", lspServerCommand))
            return
        end
    end

    LSPClient:initialize(lspServerCommand)
end

function stopServers(bufpane, args)
    local success, lspServerCommand = pcall(function() return args[1] end)
    local stopAll = not success

    local stoppedClients = {}
    for clientId, client in pairs(activeConnections) do
        if stopAll or client.command == lspServerCommand then
            client:stop()
            table.insert(stoppedClients, clientId)
        end
    end
    for idx, clientId in pairs(stoppedClients) do
        activeConnections[clientId] = nil
    end
end

LSPClient = {}
LSPClient.__index = LSPClient

function LSPClient:initialize(lspServerCommand)
    local args = lspServerCommand:split()
    runCommand = table.remove(args, 1)

    local client = {}
    setmetatable(client, LSPClient)

    local clientId = string.format("%s-%04x", runCommand, math.random(65536))
    activeConnections[clientId] = client

    client.clientId = clientId
    client.command = lspServerCommand
    client.requestId = 0
    client.buffer = ""
    client.expectedLength = nil
    client.serverCapabilities = {}
    client.serverName = nil
    client.serverVersion = nil
    client.sentRequests = {}
    client.openFiles = {}
    -- the last parameter(s) to JobSpawn are userargs which get passed down to
    -- the callback functions (onStdout, onStderr, onExit)
    client.job = shell.JobSpawn(runCommand, args, onStdout, onStderr, onExit, clientId)

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
                hover = { contentFormat = {"plaintext", "markdown"} },
                formatting = { dynamicRegistration = false }
            }
        }
    })
    return client
end

function LSPClient:stop()
    for docUri, _file in pairs(self.openFiles) do
        for _idx, docBuf in pairs(docBuffers[docUri]) do
            docBuf:ClearMessages(self.clientId)
        end
    end
    shell.JobStop(self.job)
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
            infobar(string.format("Initialized %s version %s", self.serverName, self.serverVersion))
        else
            infobar(string.format("Initialized '%s' (no version information)", self.command))
        end
        self:notification("initialized")
        -- FIXME: iterate over *all* currently open buffers
        onBufferOpen(micro.CurPane().Buf)
    elseif method == "textDocument/hover" then
        -- response.result.contents being a string or array is deprecated but as of 2023
        -- * pylsp still responds with {"contents": ""} for no results
        -- * lua-lsp still responds with {"contents": []} for no results
        if (
            response.result == nil or
            response.result.contents == "" or
            table.empty(response.result.contents)
        ) then
            infobar("no hover results")
        elseif type(response.result.contents) == "string" then
            infobar(response.result.contents)
        elseif type(response.result.contents.value) == "string" then
            infobar(response.result.contents.value)
        end
    elseif method == "textDocument/formatting" then
        if response.error then
            infobar(json.encode(response.error))
        elseif response.result == nil or next(response.result) == nil then
            infobar("formatted file (no changes)")
        else
            local textedits = response.result
            editBuf(micro.CurPane().Buf, textedits)
            infobar("formatted file")
        end
    else
        log("WARNING: dunno what to do with response to", method)
    end
end

function LSPClient:handleNotification(notification)
    if notification.method == "textDocument/publishDiagnostics" then
        local docUri = notification.params.uri:uriDecode()

        if self.openFiles[docUri] == nil then
            log("DEBUG: received diagnostics for document that is not open:", docUri)
            return
        end

        local docVersion = notification.params.version
        if docVersion ~= nil and docVersion ~= self.openFiles[docUri].version then
            log("WARNING: received diagnostics for outdated version of document")
            return
        end

        -- in the usual case there is only one buffer with the same document so a loop
        -- would not be necessary, but there may sometimes be multiple buffers with the
        -- same exact document open!
        for docUri, buf in pairs(docBuffers[docUri]) do
            showDiagnostics(buf, self.clientId, notification.params.diagnostics)
        end
    else
        log("WARNING: don't know what to do with that message")
    end
end

function LSPClient:receiveMessage(text)
    local decodedMsg = json.decode(text)
    local request = self.sentRequests[decodedMsg.id]
    if request then
        self.sentRequests[decodedMsg.id] = nil
        self:handleResponse(request, decodedMsg)
    else
        self:handleNotification(decodedMsg)
    end
end

function LSPClient:textDocumentIdentifier(buf)
    return { uri = string.format("file://%s", buf.AbsPath) }
end

function LSPClient:didOpen(buf)
    local textDocument = self:textDocumentIdentifier(buf)

    -- if file is already open, do nothing
    if self.openFiles[textDocument.uri] ~= nil then
        return
    end

    local bufText = util.String(buf:Bytes())
    self.openFiles[textDocument.uri] = {version = 1}
    textDocument.languageId = buf:FileType()
    textDocument.version = 1
    textDocument.text = bufText

    self:notification("textDocument/didOpen", {
        textDocument = textDocument
    })
end

function LSPClient:didClose(buf)
    local textDocument = self:textDocumentIdentifier(buf)

    if self.openFiles[textDocument.uri] ~= nil then
        self.openFiles[textDocument.uri] = nil

        self:notification("textDocument/didClose", {
            textDocument = textDocument
        })
    end
end

function LSPClient:didChange(buf)
    local textDocument = self:textDocumentIdentifier(buf)

    if self.openFiles[textDocument.uri] == nil then
        log("ERROR: tried to emit didChange event for document that was not open")
        return
    end

    local bufText = util.String(buf:Bytes())
    local newVersion = self.openFiles[textDocument.uri].version + 1

    self.openFiles[textDocument.uri].version = newVersion
    textDocument.version = newVersion

    self:notification("textDocument/didChange", {
        textDocument = textDocument,
        contentChanges = {
            { text = bufText }
        }
    })
end

function LSPClient:didSave(buf)
    local textDocument = self:textDocumentIdentifier(buf)

    self:notification("textDocument/didSave", {
        textDocument = textDocument
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

function formatAction(bufpane)
    local buf = bufpane.Buf
    local bufUri = string.format("file://%s", buf.AbsPath)

    for clientId, client in pairs(activeConnections) do
        client:request("textDocument/formatting", {
            textDocument = { uri = bufUri },
            options = {
                -- most servers completely ignore these values but tabSize and
                -- insertSpaces are required according to the specification
                -- https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#formattingOptions
                tabSize = buf.Settings["tabsize"],
                insertSpaces = buf.Settings["tabstospaces"],
                trimTrailingWhitespace = true,
                insertFinalNewline = true,
                trimFinalNewlines = true
            }
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
    activeConnections[clientId] = nil
    log(clientId, "exited")
    infobar(clientId .. " exited")
end

function onBufferOpen(buf)
    if buf.Type.Kind ~= buffer.BTDefault then return end
    if buf:FileType() == "unknown" then return end

    local docUri = string.format("file://%s", buf.AbsPath)

    if docBuffers[docUri] == nil then
        docBuffers[docUri] = {}
    end
    table.insert(docBuffers[docUri], buf)

    for clientId, client in pairs(activeConnections) do
        client:didOpen(buf)
    end
end

function onQuit(bufpane)
    local closedBuf = bufpane.Buf
    if closedBuf.Type.Kind ~= buffer.BTDefault then return end

    local docUri = string.format("file://%s", closedBuf.AbsPath)
    if docBuffers[docUri] == nil then
        return
    elseif #docBuffers[docUri] > 1 then
        -- there are still other buffers with the same file open
        local remainingBuffers = {}
        for _, buf in pairs(docBuffers[docUri]) do
            if buf ~= closedBuf then
                table.insert(remainingBuffers, buf)
            end
        end
        docBuffers[docUri] = remainingBuffers
    else
        -- this was the last buffer in which this particular file was open
        docBuffers[docUri] = nil

        for clientId, client in pairs(activeConnections) do
            client:didClose(closedBuf)
        end
    end

end

function onSave(bufpane)
    for clientId, client in pairs(activeConnections) do
        client:didSave(bufpane.Buf)
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

function string.split(str)
    local result = {}
    for x in str:gmatch("[^%s]+") do
        table.insert(result, x)
    end
    return result
end

function string.startsWith(str, needle)
	return string.sub(str, 1, #needle) == needle
end

function string.uriDecode(str)
    local function hexToChar(x)
        return string.char(tonumber(x, 16))
    end
    return str:gsub("%%(%x%x)", hexToChar)
end


function table.empty(x)
    return type(x) == "table" and next(x) == nil
end

function editBuf(buf, textedits)
    -- sort edits so the last edit (from the end of the file) happens first
    -- in order to not mess up line numbers for other edits
    function sortByRangeStart(texteditA, texteditB)
        local a = texteditA.range.start
        local b = texteditB.range.start
        return b.line < a.line or (a.line == b.line and b.character < a.character)
    end
    table.sort(textedits, sortByRangeStart)

    for _, textedit in pairs(textedits) do
        local startPos = buffer.Loc(
            textedit.range["start"].character,
            textedit.range["start"].line
        )
        local endPos = buffer.Loc(
            textedit.range["end"].character,
            textedit.range["end"].line
        )

        buf:Remove(startPos, endPos)
        buf:Insert(startPos, textedit.newText)
    end

    for clientId, client in pairs(activeConnections) do
        client:didChange(buf)
    end
end

function showDiagnostics(buf, owner, diagnostics)
    local SEVERITY_ERROR = 1
    local SEVERITY_WARNING = 2
    local SEVERITY_INFORMATION = 3
    local SEVERITY_HINT = 4
    local severityTable = {
        [SEVERITY_ERROR] = "error",
        [SEVERITY_WARNING] = "warning",
        [SEVERITY_INFORMATION] = "information",
        [SEVERITY_HINT] = "hint"
    }

    buf:ClearMessages(owner)

    for _, diagnostic in pairs(diagnostics) do
        if diagnostic.severity == nil then
            diagnostic.severity = SEVERITY_INFORMATION
        end

        if settings.showDiagnostics[severityTable[diagnostic.severity]] then
            local extraInfo = nil
            if diagnostic.code ~= nil then
                diagnostic.code = tostring(diagnostic.code)
                if string.startsWith(diagnostic.message, diagnostic.code .. " ") then
                    diagnostic.message = diagnostic.message:sub(2 + #diagnostic.code)
                end
            end
            if diagnostic.source ~= nil and diagnostic.code ~= nil then
                extraInfo = string.format("(%s %s) ", diagnostic.source, diagnostic.code)
            elseif diagnostic.source ~= nil then
                extraInfo = string.format("(%s) ", diagnostic.source)
            elseif diagnostic.code ~= nil then
                extraInfo = string.format("(%s) ", diagnostic.code)
            end

            local lineNumber = diagnostic.range.start.line + 1

            local msgType = buffer.MTInfo
            if diagnostic.severity == SEVERITY_WARNING then
                msgType = buffer.MTWarning
            elseif diagnostic.severity == SEVERITY_ERROR then
                msgType = buffer.MTError
            end

            msg = string.format("[µlsp] %s%s", extraInfo or "", diagnostic.message)
            buf:AddMessage(buffer.NewMessageAtLine(owner, msg, lineNumber, msgType))
        end
    end
end
