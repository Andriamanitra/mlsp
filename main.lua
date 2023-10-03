VERSION = "0.1.0"

local micro = import("micro")
local config = import("micro/config")
local shell = import("micro/shell")
local buffer = import("micro/buffer")
local util = import("micro/util")
local go_os = import("os")
local go_strings = import("strings")

-- not sure if this is the best way to import code from plugin directory...
config.AddRuntimeFile("mlsp", config.RTPlugin, "json.lua")
local json = loadstring(config.ReadRuntimeFile(config.RTPlugin, "json"))()

config.AddRuntimeFile("mlsp", config.RTPlugin, "settings.lua")
local settings = loadstring(config.ReadRuntimeFile(config.RTPlugin, "settings"))()

local activeConnections = {}
local docBuffers = {}
local lastAutocompletion = -1

function init()
    micro.SetStatusInfoFn("mlsp.status")
    config.MakeCommand("lsp", startServer, config.NoComplete)
    config.MakeCommand("lsp-stop", stopServers, config.NoComplete)
    config.MakeCommand("lsp-showlog", showLog, config.NoComplete)
    config.MakeCommand("hover", hoverAction, config.NoComplete)
    config.MakeCommand("format", formatAction, config.NoComplete)
    config.MakeCommand("autocomplete", completionAction, config.NoComplete)
end

function status(buf)
    local servers = {}
    for clientId, client in pairs(activeConnections) do
        local name = client.name or client.command:match("%S+")
        table.insert(servers, name)
    end
    if #servers == 0 then
        return "off"
    elseif #servers == 1 then
        return servers[1]
    else
        return string.format("[%s]", table.concat(servers, ","))
    end
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

function showLog(bufpane, args)
    local hasArgs, lspServerCommand = pcall(function() return args[1] end)

    local foundClient
    for clientId, client in pairs(activeConnections) do
        if not hasArgs or client.command:startsWith(lspServerCommand) then
            foundClient = client
            break
        end
    end

    if foundClient == nil then
        infobar("no LSP client found")
        return
    end


    if foundClient.stderr == "" then
        infobar(foundClient.clientId .. " has not written anything to stderr")
        return
    end

    local title = string.format("Log for '%s' (%s)", foundClient.command, foundClient.clientId)
    local newBuffer = buffer.NewBuffer(foundClient.stderr, title)

    newBuffer:SetOption("filetype", "text")
    newBuffer.Type.scratch = true
    newBuffer.Type.Readonly = true

    micro.CurPane():HSplitBuf(newBuffer)
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
    client.stderr = ""
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
    local rootUri = string.format("file://%s", wd:uriEncode())

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
    for filePath, _file in pairs(self.openFiles) do
        for _idx, docBuf in pairs(docBuffers[filePath]) do
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

function LSPClient:handleResponseError(method, error)
    infobar(string.format("%s (Error %d, %s)", error.message, error.code, method))

    if method == "textDocument/completion" then
        setCompletions({})
    end
end

function LSPClient:handleResponseResult(method, result)
    if method == "initialize" then
        self.capabilities = result.capabilities
        if result.serverInfo then
            self.serverName = result.serverInfo.name
            self.serverVersion = result.serverInfo.version
            infobar(string.format("Initialized %s version %s", self.serverName, self.serverVersion))
        else
            infobar(string.format("Initialized '%s' (no version information)", self.command))
        end
        self:notification("initialized")
        -- FIXME: iterate over *all* currently open buffers
        onBufferOpen(micro.CurPane().Buf)
    elseif method == "textDocument/hover" then
        -- result.contents being a string or array is deprecated but as of 2023
        -- * pylsp still responds with {"contents": ""} for no results
        -- * lua-lsp still responds with {"contents": []} for no results
        if result == nil or result.contents == "" or table.empty(result.contents) then
            infobar("no hover results")
        elseif type(result.contents) == "string" then
            infobar(result.contents)
        elseif type(result.contents.value) == "string" then
            infobar(result.contents.value)
        end
    elseif method == "textDocument/formatting" then
        if result == nil or next(result) == nil then
            infobar("formatted file (no changes)")
        else
            local textedits = result
            editBuf(micro.CurPane().Buf, textedits)
            infobar("formatted file")
        end
    elseif method == "textDocument/rangeFormatting" then
        if result == nil or next(result) == nil then
            infobar("formatted selection (no changes)")
        else
            local textedits = result
            editBuf(micro.CurPane().Buf, textedits)
            infobar("formatted selection")
        end
    elseif method == "textDocument/completion" then
        -- TODO: handle result.isIncomplete = true somehow
        local completions = {}

        if result ~= nil then
            -- result can be either CompletionItem[] or an object
            -- { isIncomplete: bool, items: CompletionItem[] }
            completions = result.items or result
        end

        if #completions == 0 then
            infobar("no completions")
            setCompletions({})
            return
        end

        local rawcompletions = {}
        for k, v in pairs(completions) do
            table.insert(rawcompletions, v.insertText or v.label)
        end

        local cursor = micro.CurPane().Buf:GetActiveCursor()

        local backward = cursor.X
        while backward > 0 and util.IsWordChar(util.RuneStr(cursor:RuneUnder(backward-1))) do
            backward = backward - 1
        end

        cursor:SetSelectionStart(buffer.Loc(backward, cursor.Y))
        cursor:SetSelectionEnd(buffer.Loc(cursor.X, cursor.Y))
        cursor:DeleteSelection()

        setCompletions(rawcompletions)
    else
        log("WARNING: dunno what to do with response to", method)
    end
end

function LSPClient:handleNotification(notification)
    if notification.method == "textDocument/publishDiagnostics" then
        local filePath = notification.params.uri:match("file://(.*)$"):uriDecode()

        if self.openFiles[filePath] == nil then
            log("DEBUG: received diagnostics for document that is not open:", filePath)
            return
        end

        local docVersion = notification.params.version
        if docVersion ~= nil and docVersion ~= self.openFiles[filePath].version then
            log("WARNING: received diagnostics for outdated version of document")
            return
        end

        -- in the usual case there is only one buffer with the same document so a loop
        -- would not be necessary, but there may sometimes be multiple buffers with the
        -- same exact document open!
        for filePath, buf in pairs(docBuffers[filePath]) do
            showDiagnostics(buf, self.clientId, notification.params.diagnostics)
        end
    elseif notification.method == "window/showMessage" then
        -- notification.params.type can be 1 = error, 2 = warning, 3 = info, 4 = log, 5 = debug
        if notification.params.type < 3 then
            infobar(notification.params.message)
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
        if decodedMsg.error then
            self:handleResponseError(request, decodedMsg.error)
        else
            self:handleResponseResult(request, decodedMsg.result)
        end
    else
        self:handleNotification(decodedMsg)
    end
end

function LSPClient:textDocumentIdentifier(buf)
    return { uri = string.format("file://%s", buf.AbsPath:uriEncode()) }
end

function LSPClient:didOpen(buf)
    local textDocument = self:textDocumentIdentifier(buf)
    local filePath = buf.AbsPath

    -- if file is already open, do nothing
    if self.openFiles[filePath] ~= nil then
        return
    end

    local bufText = util.String(buf:Bytes())
    self.openFiles[filePath] = {version = 1}
    textDocument.languageId = buf:FileType()
    textDocument.version = 1
    textDocument.text = bufText

    self:notification("textDocument/didOpen", {
        textDocument = textDocument
    })
end

function LSPClient:didClose(buf)
    local textDocument = self:textDocumentIdentifier(buf)
    local filePath = buf.AbsPath

    if self.openFiles[filePath] ~= nil then
        self.openFiles[filePath] = nil

        self:notification("textDocument/didClose", {
            textDocument = textDocument
        })
    end
end

function LSPClient:didChange(buf)
    local textDocument = self:textDocumentIdentifier(buf)
    local filePath = buf.AbsPath

    if self.openFiles[filePath] == nil then
        log("ERROR: tried to emit didChange event for document that was not open")
        return
    end

    local bufText = util.String(buf:Bytes())
    local newVersion = self.openFiles[filePath].version + 1

    self.openFiles[filePath].version = newVersion
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

    -- TODO: figure out if this is a performance bottleneck when receiving long
    -- messages (tens of thousands of bytes) – I suspect Go's buffers would be
    -- much faster than Lua string concatenation
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
    local cursor = buf:GetActiveCursor()

    for clientId, client in pairs(activeConnections) do
        client:request("textDocument/hover", {
            textDocument = client:textDocumentIdentifier(buf),
            position = { line = cursor.Y, character = cursor.X }
        })
    end
end

function formatAction(bufpane)
    local buf = bufpane.Buf
    local selectedRanges = {}

    for i = 1, #buf:GetCursors() do
        local cursor = buf:GetCursor(i - 1)
        if cursor:HasSelection() then
            table.insert(selectedRanges, LspRange.fromSelection(cursor.CurSelection))
        end
    end

    if #selectedRanges > 1 then
        infobar("formatting multiple selections is not supported yet")
        return
    end

    local formatOptions = {
        -- most servers completely ignore these values but tabSize and
        -- insertSpaces are required according to the specification
        -- https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#formattingOptions
        tabSize = buf.Settings["tabsize"],
        insertSpaces = buf.Settings["tabstospaces"],
        trimTrailingWhitespace = true,
        insertFinalNewline = true,
        trimFinalNewlines = true
    }

    if #selectedRanges == 0 then
        local client = findClientWithCapability("documentFormattingProvider", "formatting")
        if client ~= nil then
            client:request("textDocument/formatting", {
                textDocument = client:textDocumentIdentifier(buf),
                options = formatOptions
            })
        end
    else
        local client = findClientWithCapability("documentRangeFormattingProvider", "formatting selections")
        if client ~= nil then
            client:request("textDocument/rangeFormatting", {
                textDocument = client:textDocumentIdentifier(buf),
                range = selectedRanges[1],
                options = formatOptions
            })
        end
    end
end

function completionAction(bufpane)
    local buf = bufpane.Buf
    local cursor = buf:GetActiveCursor()

    for clientId, client in pairs(activeConnections) do
        client:request("textDocument/completion", {
            textDocument = client:textDocumentIdentifier(buf),
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
    -- log("<-(", clientId, "[stderr] )", text, "\n\n")
    local client = activeConnections[clientId]
    client.stderr = client.stderr .. text
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

    local filePath = buf.AbsPath

    if docBuffers[filePath] == nil then
        docBuffers[filePath] = {}
    end
    table.insert(docBuffers[filePath], buf)

    for clientId, client in pairs(activeConnections) do
        client:didOpen(buf)
    end
end

function onQuit(bufpane)
    local closedBuf = bufpane.Buf
    if closedBuf.Type.Kind ~= buffer.BTDefault then return end

    local filePath = closedBuf.AbsPath
    if docBuffers[filePath] == nil then
        return
    elseif #docBuffers[filePath] > 1 then
        -- there are still other buffers with the same file open
        local remainingBuffers = {}
        for _, buf in pairs(docBuffers[filePath]) do
            if buf ~= closedBuf then
                table.insert(remainingBuffers, buf)
            end
        end
        docBuffers[filePath] = remainingBuffers
    else
        -- this was the last buffer in which this particular file was open
        docBuffers[filePath] = nil

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

function preAutocomplete(bufpane)
    if not settings.tabAutocomplete then return end

    -- "[µlsp] no autocompletions" message can be confusing if it does
    -- not get cleared before falling back to micro's own completion
    bufpane:ClearInfo()

    local cursor = bufpane.Buf:GetActiveCursor()

    -- use micro's own autocompleter if there is no LSP connection
    if next(activeConnections) == nil then return end

    -- don't autocomplete at the beginning of the line because you
    -- often want tab to mean indentation there!
    if cursor.X == 0 then return end

    -- if last auto completion happened on the same line then don't
    -- do completionAction again (because updating the completions
    -- would mess up tabbing through the suggestions)
    -- FIXME: invent a better heuristic than line number for this
    if lastAutocompletion == cursor.Y then return end

    local charBeforeCursor = util.RuneStr(cursor:RuneUnder(cursor.X-1))

    if util.IsWordChar(charBeforeCursor) then
        -- make sure there are at least two empty suggestions to capture
        -- the autocompletion event – otherwise micro inserts '\t' before
        -- the language server has a chance to reply with suggestions
        setCompletions({"", ""})
        completionAction(bufpane)
        lastAutocompletion = cursor.Y
    end
end

-- FIXME: figure out how to disable all this garbage when there are no active connections
function onDocumentEdit(bufpane)
    local buf = bufpane.Buf
    -- filetype is "unknown" for the command prompt
    if buf:FileType() == "unknown" then
        return
    end

    for clientId, client in pairs(activeConnections) do
        client:didChange(buf)
    end
end

function CursorUp(bufpane)       clearAutocomplete() end
function CursorDown(bufpane)     clearAutocomplete() end
function CursorPageUp(bufpane)   clearAutocomplete() end
function CursorPageDown(bufpane) clearAutocomplete() end
function CursorLeft(bufpane)     clearAutocomplete() end
function CursorRight(bufpane)    clearAutocomplete() end
function CursorStart(bufpane)    clearAutocomplete() end
function CursorEnd(bufpane)      clearAutocomplete() end

function onRune(bp, rune)        onDocumentEdit(bp); clearAutocomplete() end
function onMoveLinesUp(bp)       onDocumentEdit(bp); clearAutocomplete() end
function onMoveLinesDown(bp)     onDocumentEdit(bp); clearAutocomplete() end
function onDeleteWordRight(bp)   onDocumentEdit(bp); clearAutocomplete() end
function onDeleteWordLeft(bp)    onDocumentEdit(bp); clearAutocomplete() end
function onInsertNewline(bp)     onDocumentEdit(bp); clearAutocomplete() end
function onInsertSpace(bp)       onDocumentEdit(bp); clearAutocomplete() end
function onBackspace(bp)         onDocumentEdit(bp); clearAutocomplete() end
function onDelete(bp)            onDocumentEdit(bp); clearAutocomplete() end
function onInsertTab(bp)         onDocumentEdit(bp); clearAutocomplete() end
function onUndo(bp)              onDocumentEdit(bp); clearAutocomplete() end
function onRedo(bp)              onDocumentEdit(bp); clearAutocomplete() end
function onCut(bp)               onDocumentEdit(bp); clearAutocomplete() end
function onCutLine(bp)           onDocumentEdit(bp); clearAutocomplete() end
function onDuplicateLine(bp)     onDocumentEdit(bp); clearAutocomplete() end
function onDeleteLine(bp)        onDocumentEdit(bp); clearAutocomplete() end
function onIndentSelection(bp)   onDocumentEdit(bp); clearAutocomplete() end
function onOutdentSelection(bp)  onDocumentEdit(bp); clearAutocomplete() end
function onOutdentLine(bp)       onDocumentEdit(bp); clearAutocomplete() end
function onIndentLine(bp)        onDocumentEdit(bp); clearAutocomplete() end
function onPaste(bp)             onDocumentEdit(bp); clearAutocomplete() end
function onPlayMacro(bp)         onDocumentEdit(bp); clearAutocomplete() end

function onAutocomplete(bp)      onDocumentEdit(bp) end



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

function string.uriEncode(str)
    local function charToHex(c)
        return string.format("%%%02X", string.byte(c))
    end
    str = str:gsub("([^%w/ _%-.~])", charToHex)
    str = str:gsub(" ", "+")
    return str
end


function table.empty(x)
    return type(x) == "table" and next(x) == nil
end


function editBuf(buf, textedits)
    -- sort edits by start position (earliest first)
    function sortByRangeStart(texteditA, texteditB)
        local a = texteditA.range.start
        local b = texteditB.range.start
        return a.line < b.line or (a.line == b.line and a.character < b.character)
    end
    -- FIXME: table.sort is not guaranteed to be stable, and the LSP specification
    -- says that if two edits share the same start position the order in the array
    -- should dictate the order, so this is probably bugged in rare edge cases...
    table.sort(textedits, sortByRangeStart)

    local cursor = buf:GetActiveCursor()

    -- maybe there is a nice way to keep multicursors and selections? for now let's
    -- just get rid of them before editing the buffer to avoid weird behavior
    buf:ClearCursors()
    cursor:Deselect(true)

    -- using byte offset seems to be the easiest & most reliable way to keep cursor
    -- position even when lines get added/removed
    local cursorLoc = buffer.Loc(cursor.Loc.X, cursor.Loc.Y)
    local cursorByteOffset = buffer.ByteOffset(cursorLoc, buf)

    local editedBufParts = {}

    local prevEnd = buf:Start()

    for _, textedit in pairs(textedits) do
        local startLoc = buffer.Loc(textedit.range["start"].character, textedit.range["start"].line)
        local endLoc = buffer.Loc(textedit.range["end"].character, textedit.range["end"].line)
        table.insert(editedBufParts, util.String(buf:Substr(prevEnd, startLoc)))
        table.insert(editedBufParts, textedit.newText)
        prevEnd = endLoc

        -- if the cursor is in the middle of a textedit this can move it a bit but it's fiiiine
        -- (I don't think there's a clean way to figure out the right place for it)
        if startLoc:LessThan(cursorLoc) then
            local oldTextLength = buffer.ByteOffset(endLoc, buf) - buffer.ByteOffset(startLoc, buf)
            cursorByteOffset = cursorByteOffset - oldTextLength + textedit.newText:len()
        end
    end

    table.insert(editedBufParts, util.String(buf:Substr(prevEnd, buf:End())))

    buf:Remove(buf:Start(), buf:End())
    buf:Insert(buf:End(), go_strings.Join(editedBufParts, ""))

    local newCursorLoc = buffer.Loc(0, 0):Move(cursorByteOffset, buf)
    buf:GetActiveCursor():GotoLoc(newCursorLoc)

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

            local startLoc = buffer.Loc(diagnostic.range.start.character, diagnostic.range.start.line)
            local endLoc = buffer.Loc(diagnostic.range["end"].character, diagnostic.range["end"].line)
            local msg = string.format("[µlsp] %s%s", extraInfo or "", diagnostic.message)
            buf:AddMessage(buffer.NewMessage(owner, msg, startLoc, endLoc, msgType))
        end
    end
end

LspRange = {
    fromSelection = function(selection)
        -- create Range https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#range
        -- from [2]Loc https://pkg.go.dev/github.com/zyedidia/micro/v2@v2.0.12/internal/buffer#Cursor
        return {
            ["start"] = {
                line = selection[1].Y,
                character = selection[1].X
            },
            ["end"] = {
                line = selection[2].Y,
                character = selection[2].X
            }
        }    
    end
}

function clearAutocomplete()
    lastAutocompletion = -1
end

function setCompletions(completions)
    local buf = micro.CurPane().Buf

    buf.Suggestions = completions
    buf.Completions = completions
    buf.CurSuggestion = -1

    if next(completions) == nil then
        buf.HasSuggestions = false
    else
        buf:CycleAutocomplete(true)
    end
end

function findClientWithCapability(capabilityName, featureDescription)
    for clientId, client in pairs(activeConnections) do
        -- some language servers (gopls) don't say their capabilities so
        -- client.capabilities[cap] can be nil even when a feature is supported,
        -- but if it's false then the feature is definitely not supported
        if client.capabilities[cap] ~= false then
            return client
        end
    end
    infobar(string.format("None of the active language server(s) support %s", featureDescription))
    return nil
end
