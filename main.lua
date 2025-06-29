VERSION = "0.2.0"

local micro = import("micro")
local config = import("micro/config")
local shell = import("micro/shell")
local buffer = import("micro/buffer")
local util = import("micro/util")
local go_os = import("os")
local go_strings = import("strings")
local go_filepath = import("path/filepath")

local settings = settings
local json = json

local activeConnections = {}
local allConnections = {}
setmetatable(allConnections, { __index = function (_, k) return activeConnections[k] end })
local docBuffers = {}
local undoStackLengthBefore = 0

-- https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#messageType
---@enum MessageType
local MessageType = {
    Error   = 1,
    Warning = 2,
    Info    = 3,
    Log     = 4,
    Debug   = 5,
}

-- https://github.com/zyedidia/micro/blob/bf255b6c353f6a8abf7b5520b5620c52b2f5f2fb/internal/buffer/eventhandler.go#L18-L23
---@enum TextEventType
local TextEventType = {
    INSERT = 1,
    REMOVE = -1,
    REPLACE = 0
}

function init()
    -- ordering of the table affects the autocomplete suggestion order
    local subcommands = {
        ["start"]               = startServer,
        ["stop"]                = stopServers,
        ["diagnostic-info"]     = openDiagnosticBufferAction,
        ["document-symbols"]    = documentSymbolsAction,
        ["find-references"]     = findReferencesAction,
        ["format"]              = formatAction,
        ["rename"]              = renameAction,
        ["goto-definition"]     = gotoAction("definition"),
        ["goto-declaration"]    = gotoAction("declaration"),
        ["goto-implementation"] = gotoAction("implementation"),
        ["goto-typedefinition"] = gotoAction("typeDefinition"),
        ["hover"]               = hoverAction,
        ["sync-document"]       = function (bp) syncFullDocument(bp.Buf) end,
        ["autocomplete"]        = completionAction,
        ["showlog"]             = showLog,
    }

    local lspCompleter = function (buf)
        local args = {}
        local splits = go_strings.Split(buf:Line(0):gsub("%s+", " "), " ")
        for i = 1, #splits do table.insert(args, splits[i]) end

        local iterator = keyIterator(subcommands)
        if #args == 3 then
            if args[2] == "start" then
                iterator = keyIterator(languageServer)
            elseif args[2] == "stop" then
                iterator = keyIterator(activeConnections)
            else return nil, nil end
        elseif #args > 2 then
            return nil, nil
        end

        local suggestions = {}
        local completions = {}
        local lastArg = args[#args]

        for _, suggestion in iterator do
            local startIdx, endIdx = string.find(suggestion, lastArg, 1, true)
            if startIdx == 1 then
                local completion = string.sub(suggestion, endIdx + 1, #suggestion)
                table.insert(completions, completion)
                table.insert(suggestions, suggestion)
            end
        end

        return completions, suggestions
    end

    local lspCommand = function(bp, argsUserdata)
        local args = {}
        for _, a in userdataIterator(argsUserdata) do table.insert(args, a) end

        if #args == 0 then
            startServer(bp, {})
            return
        end

        local subcommand = table.remove(args, 1)
        local func = subcommands[subcommand]
        if func then
            func(bp, args)
        else
            display_error(string.format("Unknown subcommand '%s'", subcommand))
        end
    end

    micro.SetStatusInfoFn("mlsp.status")
    config.MakeCommand("lsp", lspCommand, lspCompleter)
end

local LSPClient = {}
LSPClient.__index = LSPClient

local LSPRange = {
    fromSelection = function(selection)
        -- create Range https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#range
        -- from [2]Loc https://pkg.go.dev/github.com/zyedidia/micro/v2@v2.0.12/internal/buffer#Cursor
        return {
            ["start"] = { line = selection[1].Y, character = selection[1].X },
            ["end"]   = { line = selection[2].Y, character = selection[2].X }
        }
    end,
    fromDelta = function(delta)
        local deltaEnd = delta.End
        -- for some reason delta.End is often 0,0 when inserting characters
        if deltaEnd.Y == 0 and deltaEnd.X == 0 then
            deltaEnd = delta.Start
        end

        return {
            ["start"] = { line = delta.Start.Y, character = delta.Start.X },
            ["end"]   = { line = deltaEnd.Y, character = deltaEnd.X }
        }
    end,
    toLocs = function(range)
        local a, b = range["start"], range["end"]
        return buffer.Loc(a.character, a.line), buffer.Loc(b.character, b.line)
    end
}

function status(_buf)
    local servers = {}
    for _, client in pairs(activeConnections) do
        table.insert(servers, client.clientId)
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
    local server
    if next(args) ~= nil then
        local cmd = table.remove(args, 1)
        -- prefer languageServer with given name from config.lua if no args given
        if next(args) == nil and languageServer[cmd] ~= nil then
            server = languageServer[cmd]
        else
            server = languageServer[cmd] or { cmd = cmd, args = args }
        end
    else
        local ftype = bufpane.Buf:FileType()
        server = settings.defaultLanguageServer[ftype]
        if server == nil then
            display_error(string.format("No language server set up for file type '%s'", ftype))
            return
        end
    end

    LSPClient:initialize(server)
end

function stopServers(_, args)
    if not next(activeConnections) then
        display_info("There is no active language server")
        return
    end

    local name = args[1]
    if not name then -- stop all
        for _, client in pairs(activeConnections) do
            client:stop()
        end
        activeConnections = {}
    elseif activeConnections[name] then
        activeConnections[name]:stop()
        activeConnections[name] = nil
    else
        display_error(string.format("No active language server with name '%s'", name))
    end
end

function showLog(_, args)
    local hasArgs, name = pcall(function() return args[1] end)

    local foundClient = nil
    for _, client in pairs(activeConnections) do
        if not hasArgs or client.name == name then
            foundClient = client
            break
        end
    end

    if foundClient == nil then
        display_info("No LSP client found")
        return
    end

    if foundClient.stderr == "" then
        display_info(foundClient.clientId, " has not written anything to stderr")
        return
    end

    local title = string.format("[µlsp] Log for '%s' (%s)", foundClient.name, foundClient.clientId)
    local newBuffer = buffer.NewBuffer(foundClient.stderr, title)

    newBuffer:SetOption("filetype", "text")
    newBuffer.Type.scratch = true
    newBuffer.Type.Readonly = true

    micro.CurPane():HSplitBuf(newBuffer)
end

function LSPClient:initialize(server)
    local clientId = server.shortName or server.cmd

    if allConnections[clientId] ~= nil then
        display_info(clientId, " is already running")
        return
    end

    local client = {}
    setmetatable(client, LSPClient)

    allConnections[clientId] = client

    client.clientId = clientId
    client.requestId = 0
    client.stderr = ""
    client.buffer = ""
    client.expectedLength = nil
    client.serverCapabilities = {}
    client.serverName = nil
    client.serverVersion = nil
    client.sentRequests = {}
    client.openFiles = {}
    client.onInitialized = server.onInitialized
    client.filetypes = server.filetypes
    client.dirtyBufs = {}

    -- the last parameter(s) to JobSpawn are userargs which get passed down to
    -- the callback functions (onStdout, onStderr, onExit)
    client.job = shell.JobSpawn(server.cmd, server.args, onStdout, onStderr, onExit, clientId)
    if client.job.Err ~= nil then
        return
    end
    log(string.format("Started '%s' with args", server.cmd), server.args)

    local wd, _ = go_os.Getwd()
    local rootUri = string.format("file://%s", wd:uriEncode())

    local params = {
        processId = go_os.Getpid(),
        rootUri = rootUri,
        workspaceFolders = { { name = "root", uri = rootUri } },
        capabilities = {
            textDocument = {
                synchronization = { didSave = true, willSave = false },
                hover = { contentFormat = {"plaintext"} },
                completion = {
                    completionItem = {
                        snippetSupport = false,
                        documentationFormat = {},
                    },
                    contextSupport = true
                }
            }
        }
    }
    if server.initializationOptions ~= nil then
        params.initializationOptions = server.initializationOptions
    end

    client:request(Request("initialize", params), {
        method = "initialize",
        onResult = function(result)
            client.serverCapabilities = result.capabilities
            if result.serverInfo then
                client.serverName = result.serverInfo.name
                client.serverVersion = result.serverInfo.version
                display_info(("Initialized %s version %s"):format(client.serverName, client.serverVersion))
            else
                display_info(("Initialized '%s' (no version information)"):format(client.clientId))
            end
            client:notification("initialized")
            activeConnections[client.clientId] = client
            allConnections[client.clientId] = nil
            if type(client.onInitialized) == "function" then
                client:onInitialized()
            end
            for _, _, bp in bufpaneIterator() do
                onBufferOpen(bp.Buf)
            end
        end
    })

    return client
end

function LSPClient:stop()
    for filePath, _ in pairs(self.openFiles) do
        for _, docBuf in ipairs(docBuffers[filePath]) do
            docBuf:ClearMessages(self.clientId)
        end
    end
    log("stopped", self.clientId)
    display_info(self.clientId, " stopped")
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

function defaultOnErrorHandler(method, error)
    display_error(("%s (Error %d, %s)"):format(error.message, error.code, method))
end

---@alias jsonObject {}

---@class LSPRequest
---@field id number
---@field jsonrpc string
---@field method string
---@field params table|jsonObject

---@param method string
---@param params? table
function Request(method, params)
    return {
        method = method,
        -- the spec allows params to be omitted but language server implementations
        -- are buggy so we can put an empty object there for now
        -- https://github.com/golang/go/issues/57459
        params = params or json.object
    }
end

---@param method string
---@param bp BufPane
---@param arguments userdata|any?
---@return LSPRequest?
function DefaultRequest(method, bp, arguments)
    -- most servers completely ignore these values but tabSize and
    -- insertSpaces are required according to the specification
    -- https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#formattingOptions
    local formatOptions = {
        tabSize = bp.Buf.Settings["tabsize"],
        insertSpaces = bp.Buf.Settings["tabstospaces"],
        trimTrailingWhitespace = true,
        insertFinalNewline = true,
        trimFinalNewlines = true
    }

    local defaultRequests = {
        -- NOTE: ["initialize"] = function (_, _) error("Leave it where it is") end,

        ["textDocument/hover"] = function(bufpane, _)
            local buf = bufpane.Buf
            local cursor = buf:GetActiveCursor()
            return Request("textDocument/hover", {
                textDocument = textDocumentIdentifier(buf),
                position = { line = cursor.Y, character = cursor.X }
            })
        end,

        ["textDocument/formatting"] = function(bufpane, _)
            local buf = bufpane.Buf
            return Request("textDocument/formatting", {
                textDocument = textDocumentIdentifier(buf),
                options = formatOptions
            })
        end,

        ["textDocument/rangeFormatting"] = function(bufpane, ranges)
            local buf = bufpane.Buf
            return Request("textDocument/rangeFormatting", {
                textDocument = textDocumentIdentifier(buf),
                range = ranges[1],
                options = formatOptions
            })
        end,

        ["textDocument/completion"] = function(bufpane, _)
            local buf = bufpane.Buf
            local cursor = buf:GetActiveCursor()
            return Request("textDocument/completion", {
                textDocument = textDocumentIdentifier(buf),
                position = { line = cursor.Y, character = cursor.X },
                context = {
                    -- 1 = Invoked, 2 = TriggerCharacter, 3 = TriggerForIncompleteCompletions
                    triggerKind = 1,
                }
            })
        end,

        --NOTE: Avoids to copy paste the body to the others gotoAction
        ["textDocument/definition"] = function(bufpane, args)
            local method_ = args or "textDocument/definition"
            local buf = bufpane.Buf
            local cursor = buf:GetActiveCursor()
            return Request(method_, {
                textDocument = textDocumentIdentifier(buf),
                position = { line = cursor.Y, character = cursor.X }
            })
        end,

        ["textDocument/declaration"] = function(bufpane, _)
            return DefaultRequest("textDocument/definition", bufpane, "textDocument/declaration")
        end,

        ["textDocument/implementation"] = function(bufpane, _)
            return DefaultRequest("textDocument/definition", bufpane, "textDocument/implementation")
        end,

        ["textDocument/typeDefinition"] = function(bufpane, _)
            return DefaultRequest("textDocument/definition", bufpane, "textDocument/typeDefinition")
        end,

        ["textDocument/references"] = function(bufpane, _)
            local buf = bufpane.Buf
            local cursor = buf:GetActiveCursor()
            return Request("textDocument/references", {
                textDocument = textDocumentIdentifier(buf),
                position = { line = cursor.Y, character = cursor.X },
                context = { includeDeclaration = true }
            })
        end,

        ["textDocument/documentSymbol"] = function(bufpane, _)
            return Request("textDocument/documentSymbol",{
                textDocument = textDocumentIdentifier(bufpane.Buf)
            })
        end,

        ["textDocument/rename"] = function(bufpane, newName)
            assert(newName)
            local buf = bufpane.Buf
            local cursor = buf:GetActiveCursor()
            return Request("textDocument/rename", {
                textDocument = textDocumentIdentifier(buf),
                position = { line = cursor.Y, character = cursor.X },
                newName = newName,
            })
        end
    }

    return defaultRequests[method](bp or micro.CurPane(), arguments)
end

---@class LSPMsgHandler
---@field method string Method that is handled
---@field onResult function Callback to handle results on the LSP Server response
---@field onError function Callback to handle errors on the LSP Server response

---@param request LSPRequest
---@param handler? LSPMsgHandler
function LSPClient:request(request, handler)
    assert(request, "MUST not be nil")
    request.jsonrpc = "2.0"
    request.id = self.requestId

    -- fill any non set handler with the default one
    handler = handler or {
        onResult = defaultOnResultHandlers[request.method],
        onError = defaultOnErrorHandler,
        method = request.method
    }
    handler.onResult = handler.onResult or defaultOnResultHandlers[request.method]
    handler.onError  = handler.onError  or defaultOnErrorHandler
    handler.method   = handler.method   or request.method
    assert(type(handler.onResult) == "function", "'handler.onResult' MUST be a function")

    self.sentRequests[self.requestId] = handler
    self.requestId = self.requestId + 1
    self:send(request)
end

function LSPClient:responseResult(id, result)
    local msg = {
        jsonrpc = "2.0",
        id = id,
        result = result,
    }
    self:send(msg)
end

function LSPClient:responseError(id, err)
    local msg = {
        jsonrpc = "2.0",
        id = id,
        error = err,
    }
    self:send(msg)
end

function LSPClient:supportsFiletype(filetype)
    if self.filetypes == nil then return true end

    for _, ftSupported in ipairs(self.filetypes) do
        if ftSupported == filetype then
            return true
        end
    end
    return false
end

function LSPClient:hasCapability(capability)
    return self.serverCapabilities[capability] ~= nil
end

function LSPClient:handleResponseError(method, error)
    display_error(string.format("%s (Error %d, %s)", error.message, error.code, method))
end

function LSPClient:handleNotification(notification)
    if notification.method == "textDocument/publishDiagnostics" then
        local filePath = absPathFromFileUri(notification.params.uri)

        if self.openFiles[filePath] == nil then
            log("DEBUG: received diagnostics for document that is not open:", filePath)
            return
        end

        local docVersion = notification.params.version
        if docVersion ~= nil and docVersion ~= self.openFiles[filePath].version then
            log("WARNING: received diagnostics for outdated version of document")
            return
        end

        self.openFiles[filePath].diagnostics = notification.params.diagnostics

        -- in the usual case there is only one buffer with the same document so a loop
        -- would not be necessary, but there may sometimes be multiple buffers with the
        -- same exact document open!
        for _, buf in ipairs(docBuffers[filePath]) do
            showDiagnostics(buf, self.clientId, notification.params.diagnostics)
        end
    elseif notification.method == "window/showMessage" then
        if notification.params.type == MessageType.Error then
            display_error(notification.params.message)
        elseif notification.params.type == MessageType.Warning
        or notification.params.type == MessageType.Info then
            display_info(notification.params.message)
        end
    elseif notification.method == "window/logMessage" then
        -- TODO: somehow include these messages in `lsp showlog`
    else
        log("WARNING: don't know what to do with that notification")
    end
end

function LSPClient:handleRequest(request)
    if request.method == "window/showMessageRequest" then
        if request.params.type == MessageType.Error then
            display_error(request.params.message)
        elseif request.params.type == MessageType.Warning
        or request.params.type == MessageType.Info then
            display_info(request.params.message)
        end
        -- TODO: make it possible to respond with one of request.params.actions
        self:responseResult(request.id, json.null)
    else
        log("WARNING: don't know what to do with that request")
    end
end

function LSPClient:receiveMessage(text)
    local decodedMsg = json.decode(text)

    ---@type LSPMsgHandler
    local handler
    if decodedMsg.id and (decodedMsg.result ~= nil or decodedMsg.error) then
        handler = self.sentRequests[decodedMsg.id]
        self.sentRequests[decodedMsg.id] = nil
        assert(type(handler) == "table", "handler must be always a table")
        assert(type(handler.onResult) == "function", "handler.onResult must be always a function")
        assert(type(handler.onError) == "function", "handler.onError must be always a function")
        assert(type(handler.method) == "string", "handler.method must be always a string")
    end

    if decodedMsg.result ~= nil then
        assert(handler, "MUST NOT BE NIL HERE")
        handler.onResult(decodedMsg.result)
    elseif decodedMsg.error then
        assert(handler, "MUST NOT BE NIL HERE")
        handler.onError(handler.method, decodedMsg.error)
    elseif decodedMsg.id and decodedMsg.method then
        self:handleRequest(decodedMsg)
    elseif decodedMsg.method then
        self:handleNotification(decodedMsg)
    elseif self.sentRequests[decodedMsg.id] ~= nil then
        handler = self.sentRequests[decodedMsg.id]
        self.sentRequests[decodedMsg.id] = nil
        display_info(("No result for %s"):format(handler.method))
    else
        log("WARNING: unrecognized message type")
    end
end

function LSPClient:didOpen(buf)
    local textDocument = textDocumentIdentifier(buf)
    local filePath = buf.AbsPath

    -- if file is already open, do nothing
    if self.openFiles[filePath] ~= nil then
        return
    end

    -- NOTE: if we cancel `didOpen()` then the rest of `did*()` are "cancelled"
    -- by self.openFiles[filePath] being `nil`.

    local filetype = buf:FileType()
    if filetype ~= "unknown" and not self:supportsFiletype(filetype) then
        log(string.format("'%s' doesn't support '%s' filetype. 'didOpen' cancelled for '%s'",
                          self.clientId, filetype, buf:GetName()))
        return
    end

    local bufText = util.String(buf:Bytes())
    self.openFiles[filePath] = {
        version = 1,
        diagnostics = {}
    }
    textDocument.languageId = filetype
    textDocument.version = 1
    textDocument.text = bufText

    self:notification("textDocument/didOpen", {
        textDocument = textDocument
    })
end

function LSPClient:didClose(buf)
    local textDocument = textDocumentIdentifier(buf)
    local filePath = buf.AbsPath

    if self.openFiles[filePath] ~= nil then
        self.openFiles[filePath] = nil

        self:notification("textDocument/didClose", {
            textDocument = textDocument
        })
    end
end

function LSPClient:didChange(buf, changes)
    local textDocument = textDocumentIdentifier(buf)
    local filePath = buf.AbsPath

    if self.openFiles[filePath] == nil then return end

    local newVersion = self.openFiles[filePath].version + 1

    self.openFiles[filePath].version = newVersion
    textDocument.version = newVersion

    self:notification("textDocument/didChange", {
        textDocument = textDocument,
        contentChanges = changes
    })
end

function LSPClient:didSave(buf)
    local textDocument = textDocumentIdentifier(buf)
    if self.openFiles[buf.AbsPath] == nil then return end
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

function display_error(...)
    micro.InfoBar():Error("[µlsp] ", unpack(arg))
end

function display_info(...)
    micro.InfoBar():Message("[µlsp] ", unpack(arg))
end


-- USER TRIGGERED ACTIONS
function hoverAction(bufpane)
    local client = findClient(bufpane.Buf:FileType(), "hoverProvider", "hover information")
    if not client then return end

    local method_str = "textDocument/hover"
    client:request(DefaultRequest(method_str, bufpane), {
        method = method_str,
        ---@param result? Hover
        onResult = function(result)
            local showHoverInfo = function(data)
                local bf = buffer.NewBuffer(data, "[µlsp] hover")
                bf.Type.Scratch = true
                bf.Type.Readonly = true
                bufpane:HSplitIndex(bf, true)
            end

            -- result.contents being a string or array is deprecated but as of 2023
            -- * pylsp still responds with {"contents": ""} for no results
            -- * lua-lsp still responds with {"contents": []} for no results
            if result == nil or result.contents == "" or table.empty(result.contents) then
                display_info("No hover results")
            elseif type(result.contents) == "string" then --MarkedString
                showHoverInfo(result.contents)
            elseif type(result.contents.value) == "string" then --MarkedContent
                showHoverInfo(result.contents.value)
            else
                display_info("WARNING: Ignored textDocument/hover result due to unrecognized format")
            end
        end,

        onError = defaultOnErrorHandler
    })
end

function formatAction(bufpane)
    local selectedRanges = {}
    local buf = bufpane.Buf
    for i = 1, #buf:GetCursors() do
        local cursor = buf:GetCursor(i - 1)
        if cursor:HasSelection() then
            table.insert(selectedRanges, LSPRange.fromSelection(cursor.CurSelection))
        end
    end

    if #selectedRanges > 1 then
        display_error("Formatting multiple selections is not supported yet")
        return
    end
    buf:DeselectCursors() -- do not preserve the selections

    local filetype = bufpane.Buf:FileType()
    local client, req, onResult
    if #selectedRanges == 0 then
        client = findClient(filetype, "documentFormattingProvider", "formatting")
        req = DefaultRequest("textDocument/formatting", bufpane)
        ---@param result? TextEdit[]
        onResult = function(result)
            if result == nil or next(result) == nil then
                display_info("Formatted file (no changes)")
            else
                local textedits = result
                applyTextEdits(bufpane.Buf, textedits)
                display_info("Formatted file")
            end
        end

    else
        client = findClient(filetype, "documentRangeFormattingProvider", "formatting selections")
        req = DefaultRequest("textDocument/rangeFormatting", bufpane, selectedRanges)
        ---@param result? TextEdit[]
        onResult = function(result)
            if result == nil or next(result) == nil then
                display_info("Formatted selection (no changes)")
            else
                local textedits = result
                applyTextEdits(bufpane.Buf, textedits)
                display_info("Formatted selection")
            end
        end
    end

    if client ~= nil then
        client:request(req, {
            method = req.method,
            onResult = onResult,
            onError = defaultOnErrorHandler
        })
    end
end

function renameAction(bufpane, args)
    local buf = bufpane.Buf
    if #buf:GetCursors() > 1 then
        display_error("'rename' is not available for multiple cursors")
        return
    end

    local client = findClient(bufpane.Buf:FileType(), "renameProvider", "rename")
    if not client then return end

    local cursor = buf:GetActiveCursor()
    cursor:Deselect(true) -- selection isn't preserved; place the cursor at the start

    local method_str = "textDocument/rename"
    ---@param result? WorkspaceEdit
    local handler = {
        method = method_str,
        onResult = function(result)
            if result == nil or table.empty(result) then
                display_info("Renamed symbol (no changes required)")
                return
            end

            if applyWorkspaceEdit(result) then
                display_info("Renamed symbol")
            else
                display_error("Renaming symbol may not have worked properly")
            end
        end,
        onError = defaultOnErrorHandler
    }

    if #args > 0 then -- `lsp rename newName`
        client:request(DefaultRequest(method_str, bufpane, args[1]), handler)
    else -- `lsp rename`
        micro.InfoBar():Prompt(
            string.format("[µlsp] rename symbol at line %d column %d to: ", cursor.Y + 1, cursor.X + 1),
            "", -- placeholder
            "µlsp-rename-symbol", -- prompt type (prompts with same type share history)
            nil, -- event callback
            function(newName, canceled) -- done callback
                if not canceled then
                    client:request(DefaultRequest(method_str, bufpane, newName), handler)
                end
            end
        )
    end
end

function completionAction(bufpane)
    local client = findClient(bufpane.Buf:FileType(), "completionProvider", "completion")
    if not client then return end

    local method_str = "textDocument/completion"
    client:request(DefaultRequest(method_str, bufpane), {
        method = method_str,
        ---@param result? CompletionItem[] | CompletionList If a CompletionItem[] is provided it is interpreted to be complete. So it is the same as { isIncomplete: false, items }
        onResult = function(result)
            -- TODO: handle result.isIncomplete = true somehow
            local completionitems = {}
            if result ~= nil then
                -- result can be either CompletionItem[] or an object
                -- { isIncomplete: bool, items: CompletionItem[] }
                completionitems = result.items or result
            end

            local function bySortText(itemA, itemB)
                local a = itemA.sortText or itemA.label
                local b = itemB.sortText or itemB.label
                return string.lower(a) < string.lower(b)
            end

            table.sort(completionitems, bySortText)

            local buf = bufpane.Buf
            local wordbytes, _ = buf:GetWord()
            local stem = util.String(wordbytes)

            ---@enum InsertTextFormat
            local InsertTextFormat = {
                PlainText = 1,
                Snippet = 2,
            }

            local completions = {}
            local labels = {}
            for i, item in ipairs(completionitems) do
                -- discard completions that don't start with the stem under cursor
                if string.startsWith(item.filterText or item.label, stem) then
                    if i > 1 and completionitems[i-1].label == item.label then
                        -- skip duplicate
                    elseif item.insertTextFormat == InsertTextFormat.Snippet then
                        -- TODO: support snippets
                    elseif item.additionalTextEdits then
                        -- TODO: support additionalTextEdits (eg. adding an import on autocomplete)
                    else
                        -- TODO: support item.textEdit
                        -- TODO: item.labelDetails.detail should be shown in faint color after the label

                        table.insert(labels, item.label)

                        local insertText = item.insertText or item.label
                        insertText = insertText:gsub("^" .. stem, "")
                        table.insert(completions, insertText)
                    end
                end
            end

            if #completions == 0 then
                -- fall back to micro's built-in completer
                bufpane:Autocomplete()
            else
                -- turn completions into Completer function for micro
                -- https://pkg.go.dev/github.com/zyedidia/micro/v2/internal/buffer#Completer
                local completer = function() return completions, labels end
                buf:Autocomplete(completer)
            end
        end,
        onError = defaultOnErrorHandler
    })
end

function gotoAction(kind)
    local cap = string.format("%sProvider", kind)
    local requestMethod = string.format("textDocument/%s", kind)

    return function(bufpane)
        local client = findClient(bufpane.Buf:FileType(), cap, requestMethod)
        if not client then return end
        client:request(DefaultRequest(requestMethod, bufpane), {
            method = requestMethod,
            ---@param result? Location | Location[] | LocationLink[]
            onResult = function(result)
                gotoLSPLocation(requestMethod, result)
            end,
            onError = defaultOnErrorHandler
        })
    end
end

function findReferencesAction(bufpane)
    local client = findClient(bufpane.Buf:FileType(), "referencesProvider", "finding references")
    if not client then return end

    local method_str = "textDocument/references"
    client:request(DefaultRequest(method_str, bufpane), {
        method = method_str,
        ---@param result? Location[]
        onResult = function(result)
            if result == nil or table.empty(result) then
                display_info("No references found")
                return
            end
            showReferenceLocations("[µlsp] references", result)
        end,
        onError = defaultOnErrorHandler
    })
end

function documentSymbolsAction(bufpane)
    local client = findClient(bufpane.Buf:FileType(), "documentSymbolProvider", "document symbols")
    if not client then return end

    local method_str = "textDocument/documentSymbol"
    client:request(DefaultRequest(method_str, bufpane), {
        method = method_str,
        ---@param result? DocumentSymbol[]
        onResult = function(result)
            if result == nil or table.empty(result) then
                display_info("No symbols found in current document")
                return
            end

            local symbolLocations = {}
            local symbolLabels = {}
            ---@enum SymbolKindString
            local SYMBOLKINDS = {
                [1] = "File",
                [2] = "Module",
                [3] = "Namespace",
                [4] = "Package",
                [5] = "Class",
                [6] = "Method",
                [7] = "Property",
                [8] = "Field",
                [9] = "Constructor",
                [10] = "Enum",
                [11] = "Interface",
                [12] = "Function",
                [13] = "Variable",
                [14] = "Constant",
                [15] = "String",
                [16] = "Number",
                [17] = "Boolean",
                [18] = "Array",
                [19] = "Object",
                [20] = "Key",
                [21] = "Null",
                [22] = "EnumMember",
                [23] = "Struct",
                [24] = "Event",
                [25] = "Operator",
                [26] = "TypeParameter",
            }

            for _, sym in ipairs(result) do
                -- if sym.location is missing we are dealing with DocumentSymbol[]
                -- instead of SymbolInformation[]
                if sym.location == nil then
                    table.insert(symbolLocations, {
                        uri = bufpane.Buf.AbsPath,
                        range = sym.range
                    })
                else
                    table.insert(symbolLocations, sym.location)
                end
                table.insert(symbolLabels, string.format("%-15s %s", "["..SYMBOLKINDS[sym.kind].."]", sym.name))
            end

            showSymbolLocations("[µlsp] document symbols", symbolLocations, symbolLabels)
        end,
        onError = defaultOnErrorHandler
    })
end

function openDiagnosticBufferAction(bufpane)
    local buf = bufpane.Buf
    local cursor = buf:GetActiveCursor()
    local filePath = buf.AbsPath
    local found = false

    for _, client in pairs(activeConnections) do
        local file = client.openFiles[filePath]
        if file then
            local diagnostics = file.diagnostics
            for idx, diagnostic in pairs(diagnostics) do
                local startLoc, _ = LSPRange.toLocs(diagnostic.range)
                if cursor.Loc.Y == startLoc.Y then
                    found = true
                    local bufContents = string.format(
                        "%s %s\nhref: %s\nseverity: %s\n\n%s",
                        diagnostic.source or client.serverName or client.clientId,
                        diagnostic.code or "(no error code)",
                        diagnostic.codeDescription and diagnostic.codeDescription.href or "-",
                        diagnostic.severity and severityToString(diagnostic.severity) or "-",
                        diagnostic.message
                    )
                    local bufTitle = string.format("[µlsp] %s diagnostics #%d", client.clientId, idx)
                    local newBuffer = buffer.NewBuffer(bufContents, bufTitle)
                    newBuffer.Type.Readonly = true
                    local height = bufpane:GetView().Height
                    micro.CurPane():HSplitBuf(newBuffer)
                    if height > 16 then
                        bufpane:ResizePane(height - 8)
                    end
                end
            end
        end
    end

    if not found then
        display_info("Found no diagnostics on current line")
    end
end


-- EVENTS (LUA CALLBACKS)
-- https://github.com/zyedidia/micro/blob/master/runtime/help/plugins.md#lua-callbacks

function onStdout(text, userargs)
    local clientId = userargs[1]
    log("<-(", clientId, "[stdout] )", text, "\n\n")
    local client = allConnections[clientId]
    client:onStdout(text)
end

function onStderr(text, userargs)
    local clientId = userargs[1]
    -- log("<-(", clientId, "[stderr] )", text, "\n\n")
    local client = allConnections[clientId]
    client.stderr = client.stderr .. text
end

function onExit(_text, userargs)
    local clientId = userargs[1]
    local client = allConnections[clientId]
    if client then
        local reasonMsg
        if client.job.Err ~= nil then -- LookPath error
            reasonMsg = string.format("%s exited (%s)", clientId, client.job.Err:Error())
        elseif client.job.ProcessState ~= nil then
            reasonMsg = string.format("%s exited (%s)", clientId, client.job.ProcessState:String())
        else
            reasonMsg = string.format("%s exited", clientId)
        end
        display_error(reasonMsg)
        log(reasonMsg)
    end
    activeConnections[clientId] = nil
    allConnections[clientId] = nil
end

function onBufferOpen(buf)
    if buf.Type.Kind ~= buffer.BTDefault then return end
    -- Ignore buffers created by clients
    if string.startsWith(buf:GetName(), "[µlsp]") then return end

    if settings.ignoreBuffersWithUnknownFiletype and buf:FileType() == "unknown" then
        log(string.format("Ignoring buffer '%s' with unknown filetype", buf:GetName()))
        return
    end

    local filePath = buf.AbsPath

    if docBuffers[filePath] == nil then
        docBuffers[filePath] = { buf }
    else
        table.insert(docBuffers[filePath], buf)
    end

    for _, client in pairs(activeConnections) do
        client:didOpen(buf)
    end

    local autostarts = settings.autostart[buf:FileType()]
    if autostarts ~= nil then
        for _, server in ipairs(autostarts) do
            local clientId = server.shortName or server.cmd
            if allConnections[clientId] == nil then
                LSPClient:initialize(server)
            end
        end
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
        for _, buf in ipairs(docBuffers[filePath]) do
            if buf ~= closedBuf then
                table.insert(remainingBuffers, buf)
            end
        end
        docBuffers[filePath] = remainingBuffers
    else
        -- this was the last buffer in which this particular file was open
        docBuffers[filePath] = nil

        for _, client in pairs(activeConnections) do
            client:didClose(closedBuf)
        end
    end

end

function onSave(bufpane)
    for _, client in pairs(activeConnections) do
        client:didSave(bufpane.Buf)
    end
end

function preAutocomplete(bufpane)
    if not settings.tabAutocomplete then return end
    -- use micro's own autocompleter if there is no LSP connection
    if next(activeConnections) == nil then return end

    local filetype = bufpane.Buf:FileType()
    local client = findClient(filetype, "completionProvider")
    if client == nil or not client:supportsFiletype(filetype) then
        return true -- continue with autocomplete event
    end

    local _, wordStartX = bufpane.Buf:GetWord()
    if wordStartX < 0 then
        return false -- cancel the autocomplete event if there is no word before cursor
    end

    if not bufpane.Buf.HasSuggestions then
        completionAction(bufpane)
        return false -- cancel the event (a new one is triggered once the server responds)
    end
end

function preInsertTab(bufpane)
    if next(activeConnections) == nil then return end
    if not settings.tabAutocomplete then return end
    if findClient(bufpane.Buf:FileType(), "completionProvider") == nil then return end

    local _, wordStartX = bufpane.Buf:GetWord()
    if wordStartX >= 0 then
        return false -- returning false prevents tab from being inserted
    end
end

-- FIXME: figure out how to disable all this garbage when there are no active connections

function onAnyEvent()
    -- apply full document changes for clients that only support that
    for _, client in pairs(activeConnections) do
        for buf, _ in pairs(client.dirtyBufs) do
            local changes = {
                { text = util.String(buf:Bytes()) }
            }
            client:didChange(buf, changes)
        end
        client.dirtyBufs = {}
    end
end

function onBeforeTextEvent(buf, tevent)
    if next(activeConnections) == nil then return end
    if buf.Type.Kind ~= buffer.BTDefault then return end

    local changes = {}
    for _, delta in userdataIterator(tevent.Deltas) do
        table.insert(
            changes,
            {
                range = LSPRange.fromDelta(delta),
                text = util.String(delta.Text)
            }
        )
    end

    bufferChanged(buf, changes)
end

function syncFullDocument(buf)
    if next(activeConnections) == nil then return end

    -- filetype is "unknown" for the command prompt
    if buf:FileType() == "unknown" then
        return
    end

    local changes = {
        { text = util.String(buf:Bytes()) }
    }
    for _, client in pairs(activeConnections) do
        client:didChange(buf, changes)
    end
end

function preUndo(bp)
    undoStackLengthBefore = bp.Buf.UndoStack:Len()
end
function onUndo(bp)
    local numUndos = undoStackLengthBefore - bp.Buf.UndoStack:Len()
    return handleUndosRedos(bp.Buf, bp.Buf.RedoStack.Top, numUndos)
end

function preRedo(bp)
    undoStackLengthBefore = bp.Buf.UndoStack:Len()
end
function onRedo(bp)
    local numRedos = bp.Buf.UndoStack:Len() - undoStackLengthBefore
    return handleUndosRedos(bp.Buf, bp.Buf.UndoStack.Top, numRedos)
end

function handleUndosRedos(buf, elem, numChanges)
    if next(activeConnections) == nil then return end

    local tevents = {}
    for _ = 1, numChanges do
        table.insert(tevents, elem.Value)
        elem = elem.Next
    end

    local changes = {}
    for i = 1, #tevents do
        local tev = tevents[#tevents + 1 - i]
        for _, delta in userdataIterator(tev.Deltas) do
            local text = ""
            local range = LSPRange.fromDelta(delta)

            if tev.EventType == TextEventType.INSERT then
                range["end"] = range["start"]
                text = util.String(delta.Text)
            elseif tev.EventType == TextEventType.REPLACE then
                -- mimics `ExecuteTextEvent()`: https://github.com/zyedidia/micro/blob/f49487dc3adf82ec5e63bf1b6c0ffaed268aa747/internal/buffer/eventhandler.go#L116
                text = util.String(buf:Substr(-delta.Start, -delta.End))
                range["end"] = {
                    line = delta.Start.Y,
                    character = delta.Start.X + util.CharacterCountInString(delta.Text)
                }
            end

            table.insert(changes, { range = range, text = text })
        end
    end

    bufferChanged(buf, changes)
end

function bufferChanged(buf, changes)
    for _, client in pairs(activeConnections) do
        local syncKind = client.serverCapabilities.textDocumentSync.change
        if syncKind == 1 then -- only full document changes are supported
            client.dirtyBufs[buf] = true
        elseif syncKind == 2 then -- incremental changes are supported
            client:didChange(buf, changes)
        end
    end
end

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

function severityToString(severity)
    local severityTable = {
        [1] = "error",
        [2] = "warning",
        [3] = "information",
        [4] = "hint"
    }
    return severityTable[severity] or "information"
end

function showDiagnostics(buf, owner, diagnostics)

    buf:ClearMessages(owner)

    for _, diagnostic in pairs(diagnostics) do
        local severity = severityToString(diagnostic.severity)

        if settings.showDiagnostics[severity] then
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

            local msgType = buffer.MTInfo
            if severity == "warning" then
                msgType = buffer.MTWarning
            elseif severity == "error" then
                msgType = buffer.MTError
            end

            local startLoc, endLoc = LSPRange.toLocs(diagnostic.range)

            -- prevent underlining empty space at the ends of lines
            -- (fix pylsp being off-by-one with endLoc.X)
            local endLineLength = #buf:Line(endLoc.Y)
            if endLoc.X > endLineLength then
                endLoc = buffer.Loc(endLineLength, endLoc.Y)
            end

            local msg = diagnostic.message
            -- make the msg look better on one line if there's newlines or extra whitespace
            msg = msg:gsub("^%s+", ""):gsub("%s+$", ""):gsub("\n", " / "):gsub("%s+", " ")
            msg = string.format("[µlsp] %s%s", extraInfo or "", msg)
            buf:AddMessage(buffer.NewMessage(owner, msg, startLoc, endLoc, msgType))
        end
    end
end

-- Finds the first active LSPClient that supports the given filetype and LSP capability.
function findClient(filetype, capability, capabilityDescription)
    if next(activeConnections) == nil then
        display_error("No language server is running! Try starting one with the `lsp` command.")
        return
    end

    for _, client in pairs(activeConnections) do
        if client.filetypes ~= nil
        and client:supportsFiletype(filetype)
        and client:hasCapability(capability) then
            return client
        end
    end

    -- If no client supports the file type, return the first one that has the capability.
    for _, client in pairs(activeConnections) do
        if client:hasCapability(capability) then return client end
    end

    if capabilityDescription then
        display_error("None of the active language server(s) support ", capabilityDescription)
    end
    return nil
end

function absPathFromFileUri(uri)
    local match = uri:match("file://(.*)$")
    if match then
        return match:uriDecode()
    else
        return uri
    end
end

function relPathFromAbsPath(absPath)
    local cwd, err = go_os.Getwd()
    if err then return absPath end
    local relPath
    relPath, err = go_filepath.Rel(cwd, absPath)
    if err then return absPath end
    return relPath
end

function openFileAtLoc(filePath, loc)
    -- don't open a new tab if file is already open
    local function openExistingBufPane(fpath)
        for tabIdx, paneIdx, bp in bufpaneIterator() do
            if fpath == bp.Buf.AbsPath then
                micro.Tabs():SetActive(tabIdx)
                bp:tab():SetActive(paneIdx)
                return bp
            end
        end
    end

    local bp = openExistingBufPane(filePath)
    if bp == nil then
        local newBuf, err = buffer.NewBufferFromFile(filePath)
        if err ~= nil then
            display_error(err)
            return
        end
        micro.CurPane():AddTab()
        bp = micro.CurPane()
        bp:OpenBuffer(newBuf)
    end

    bp.Buf:ClearCursors() -- remove multicursors
    local cursor = bp.Buf:GetActiveCursor()
    cursor:Deselect(false) -- clear selection
    cursor:GotoLoc(loc)
    bp.Buf:RelocateCursors() -- make sure cursor is inside the buffer
    bp:Center()
end

-- takes Location[] https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#location
-- and renders them to user
function showSymbolLocations(newBufferTitle, lspLocations, labels)
    local symbols = {}
    local maxLabelLen = 0
    for i, lspLoc in ipairs(lspLocations) do
        local fpath = absPathFromFileUri(lspLoc.uri)
        local lineNumber = lspLoc.range.start.line + 1
        local columnNumber = lspLoc.range.start.character + 1
        local labelLen = #labels[i]
        symbols[i] = {
            label = labels[i],
            location = string.format("%s:%d:%d\n", fpath, lineNumber, columnNumber)
        }
        if maxLabelLen < labelLen then maxLabelLen = labelLen end
    end

    local bufContents = ""
    local format = "%-" .. maxLabelLen .. "s # %s"
    for _, sym in ipairs(symbols) do
        bufContents = bufContents .. string.format(format, sym.label, sym.location)
    end

    local newBuffer = buffer.NewBuffer(bufContents, newBufferTitle)
    newBuffer.Type.Scratch = true
    newBuffer.Type.Readonly = true
    micro.CurPane():HSplitBuf(newBuffer)
end

-- takes Location[] https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#location
-- and renders them to user
function showReferenceLocations(newBufferTitle, lspLocations)
    local references = {}
    for i, lspLoc in ipairs(lspLocations) do
        local fpath = absPathFromFileUri(lspLoc.uri)
        local lineNumber = lspLoc.range.start.line + 1
        local columnNumber = lspLoc.range.start.character + 1
        references[i] = {
            path = fpath,
            line = lineNumber,
            column = columnNumber,
        }
    end

    table.sort(references, function(a, b)
        if a.path ~= b.path then return a.path < b.path end
        if a.line ~= b.line then return a.line < b.line end
        return a.column < b.column
    end)

    local bufLines = {}
    local curFilePath = ""
    local file = nil
    local lineCount = 0
    local lineContent = ""
    for _, ref in ipairs(references) do
        if curFilePath ~= ref.path then
            if file then file:close() end
            if #bufLines > 0 then table.insert(bufLines, "") end
            curFilePath = ref.path
            table.insert(bufLines, curFilePath)
            file = io.open(curFilePath, "rb")
            lineCount = 0
        end

        -- file can be nil if io.open failed
        if file ~= nil then
            while lineCount < ref.line do
                lineContent = file:read("*l")
                lineCount = lineCount + 1
            end
        end
        table.insert(bufLines, string.format("\t%d:%d:%s", ref.line, ref.column, lineContent or ""))
    end

    if file then file:close() end -- last iteration does not close last file
    table.insert(bufLines, "")

    local newBuffer = buffer.NewBuffer(table.concat(bufLines, "\n"), newBufferTitle)
    newBuffer.Type.Scratch = true
    newBuffer.Type.Readonly = true
    --We enforce tabs, dont annoy users
    newBuffer.Settings["hltaberrors"] = false
    micro.CurPane():HSplitBuf(newBuffer)
end

function findBufPaneByPath(fpath)
    if fpath == nil then return nil end
    for tabIdx, paneIdx, bp in bufpaneIterator() do
        if fpath == bp.Buf.AbsPath then
            return bp, tabIdx, paneIdx
        end
    end
end

function bufpaneIterator()
    local co = coroutine.create(function ()
        for tabIdx, tab in userdataIterator(micro.Tabs().List) do
            for paneIdx, pane in userdataIterator(tab.Panes) do
                -- pane.Buf is nil for panes that are not BufPanes (terminals etc)
                if pane.Buf ~= nil then
                    -- lua indexing starts from 1 but go is stupid and starts from 0 :/
                    coroutine.yield(tabIdx - 1, paneIdx - 1, pane)
                end
            end
        end
    end)
    return function()
        local _, tabIdx, paneIdx, bp = coroutine.resume(co)
        if bp then
            return tabIdx, paneIdx, bp
        end
    end
end

function userdataIterator(data)
    local idx = 0
    return function ()
        idx = idx + 1
        local success, item = pcall(function() return data[idx] end)
        if success then return idx, item end
    end
end

function keyIterator(dict)
    local idx = 0
    local key = nil
    return function()
        idx = idx + 1
        key = next(dict, key)
        if key then return idx, key end
    end
end

function textDocumentIdentifier(buf)
    return { uri = string.format("file://%s", buf.AbsPath:uriEncode()) }
end

---@param buf Buffer
---@param edits TextEdit[]
function applyTextEdits(buf, edits)
    -- From https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textEditArray
    -- "Text edits ranges must never overlap, that means no part of the original
    -- document must be manipulated by more than one edit. However, it is possible
    -- that multiple edits have the same start position: multiple inserts, or any
    -- number of inserts followed by a single remove or replace edit. If multiple
    -- inserts have the same position, the order in the array defines the order in
    -- which the inserted strings appear in the resulting text."

    ---To avoid invalidating locations we sort bottom to top and right to left
    ---@param A TextEdit
    ---@param B TextEdit
    ---@return boolean -- perform swap?
    local function sortEditsLastFirst(A, B)
        local as, bs = A.range.start, B.range.start
        return as.line > bs.line
           or (as.line == bs.line and as.character >= bs.character)
    end

    table.sort(edits, sortEditsLastFirst)

    for i, edit in ipairs(edits) do
        local startLoc, endLoc = LSPRange.toLocs(edit.range)

        if edit.newText == "" then
            buf:Remove(startLoc, endLoc)
        elseif startLoc.Y == endLoc.Y and startLoc.X == endLoc.X then
            buf:Insert(startLoc, edit.newText)
        else
            local cursorsToFix = {}
            for _, cursor in userdataIterator(buf:GetCursors()) do
                local curLoc = -cursor.Loc
                if startLoc:LessEqual(curLoc) and curLoc:LessEqual(endLoc) then
                    cursorsToFix[cursor] = startLoc:Move(startLoc:Diff(curLoc, buf), buf)
                end
            end

            buf:Replace(startLoc, endLoc, edit.newText)

            for cursor, newLoc in pairs(cursorsToFix) do
                cursor:GotoLoc(newLoc)
            end
        end
    end
end

function applyWorkspaceEdit(workspaceEdit)
    -- https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#workspaceEdit
    -- workspaceEdit contains either:
    -- * changes?: { [uri: DocumentUri]: TextEdit[]; };
    -- OR
    -- * documentChanges?: (TextDocumentEdit | CreateFile | RenameFile | DeleteFile)[]

    local failures = 0

    for documentUri, textedits in pairs(workspaceEdit.changes or {}) do
        local absPath = absPathFromFileUri(documentUri)
        local bufpane, _, _ = findBufPaneByPath(absPath)
        if bufpane ~= nil then
            applyTextEdits(bufpane.Buf, textedits)
        else
            failures = failures + 1
            log("ERROR: Unable to apply workspace edit for document with uri", documentUri)
        end
    end

    for _, textDocumentEdit in ipairs(workspaceEdit.documentChanges or {}) do
        if textDocumentEdit.kind ~= nil then
            -- FIXME: support CreateFile, RenameFile, DeleteFile
            log("WARNING: Skipping unsupported textDocumentEdit:", textDocumentEdit.kind)
            failures = failures + 1
        else
            local absPath = absPathFromFileUri(textDocumentEdit.textDocument.uri)
            local bufpane, _, _ = findBufPaneByPath(absPath)
            if bufpane ~= nil then
                applyTextEdits(bufpane.Buf, textDocumentEdit.edits)
            else
                failures = failures + 1
                log("ERROR: Unable to apply workspace edit for textdocument", textDocumentEdit.textDocument)
            end
        end
    end

    return failures == 0
end

---@param method string
---@param result Location | Location[] | LocationLink[] | null
function gotoLSPLocation(method, result)
    if result == nil or table.empty(result) then
        display_info(string.format("%s not found", method:match("textDocument/(.*)$")))
    else
        -- FIXME: handle list of results properly
        -- if result is a list just take the first one
        if result[1] then result = result[1] end

        -- FIXME: support LocationLink[]
        if result.targetRange ~= nil then
            display_info("LocationLinks are not supported yet")
            return
        end

        -- now result should be Location
        local filePath = absPathFromFileUri(result.uri)
        local startLoc, _ = LSPRange.toLocs(result.range)
        openFileAtLoc(filePath, startLoc)
    end
end
