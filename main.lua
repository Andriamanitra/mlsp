VERSION = "0.2.0"

local micro = import("micro")
local config = import("micro/config")
local shell = import("micro/shell")
local buffer = import("micro/buffer")
local util = import("micro/util")
local go_os = import("os")
local go_strings = import("strings")
local go_time = import("time")
local filepath = import("path/filepath")

local settings = settings
local json = json

function init()
    -- ordering of the table affects the autocomplete suggestion order
    local subcommands = {
        ["start"]               = startServer,
        ["stop"]                = stopServers,
        ["diagnostic-info"]     = openDiagnosticBufferAction,
        ["document-symbols"]    = documentSymbolsAction,
        ["find-references"]     = findReferencesAction,
        ["format"]              = formatAction,
        ["goto-definition"]     = gotoAction("definition"),
        ["goto-declaration"]    = gotoAction("declaration"),
        ["goto-implementation"] = gotoAction("implementation"),
        ["goto-typedefinition"] = gotoAction("typeDefinition"),
        ["goto-current-func"]   = gotoCurrentFunction,
        ["hover"]               = hoverAction,
        ["sync-document"]       = function (bp) syncFullDocument(bp.Buf) end,
        ["autocomplete"]        = completionAction,
        ["showlog"]             = showLog,
    }

    local lspCompleter = function (buf)
        -- Do NOT autocomplete after first argument
        -- TODO: autocomplete "lsp start " and "lsp stop "
        local args = go_strings.Split(buf:Line(0), " ")
        if #args > 2 then return nil, nil end

        local suggestions = {}
        local completions = {}
        local lastArg = args[#args]

        for subcommand, _ in pairs(subcommands) do
            local startIdx, endIdx = string.find(subcommand, lastArg, 1, true)
            if startIdx == 1 then
                local completion = string.sub(subcommand, endIdx + 1, #subcommand)
                table.insert(completions, completion)
                table.insert(suggestions, subcommand)
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

local activeConnections = {}
local allConnections = {}
setmetatable(allConnections, { __index = function (_, k) return activeConnections[k] end })
local docBuffers = {}
local undoStackLengthBefore = 0
local gotoCurrentFunc = false -- gotoCurrentFunction() vs. documentSymbolsAction()

-- https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#messageType
local MessageType = {
    Error   = 1,
    Warning = 2,
    Info    = 3,
    Log     = 4,
    Debug   = 5,
}

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

function status(buf)
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

function stopServers(bufpane, args)
    local name = args[1]
    if not name then -- stop all
        for clientId, client in pairs(activeConnections) do
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

function showLog(bufpane, args)
    local hasArgs, name = pcall(function() return args[1] end)

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

    client:request("initialize", params)
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

function LSPClient:handleResponseResult(method, result)
    if method == "initialize" then
        self.serverCapabilities = result.capabilities
        if result.serverInfo then
            self.serverName = result.serverInfo.name
            self.serverVersion = result.serverInfo.version
            display_info(string.format("Initialized %s version %s", self.serverName, self.serverVersion))
        else
            display_info(string.format("Initialized '%s' (no version information)", self.clientId))
        end
        self:notification("initialized")
        activeConnections[self.clientId] = self
        allConnections[self.clientId] = nil
        if type(self.onInitialized) == "function" then
            self:onInitialized()
        end
        -- FIXME: iterate over *all* currently open buffers
        onBufferOpen(micro.CurPane().Buf)
    elseif method == "textDocument/hover" then
        local showHoverInfo = function (results)
            local bf = buffer.NewBuffer(results, "[µlsp] hover")
            bf.Type.Scratch = true
            bf.Type.Readonly = true
            micro.CurPane():HSplitIndex(bf, true)
        end

        -- result.contents being a string or array is deprecated but as of 2023
        -- * pylsp still responds with {"contents": ""} for no results
        -- * lua-lsp still responds with {"contents": []} for no results
        if result == nil or result.contents == "" or table.empty(result.contents) then
            display_info("No hover results")
        elseif type(result.contents) == "string" then
            showHoverInfo(result.contents)
        elseif type(result.contents.value) == "string" then
            showHoverInfo(result.contents.value)
        else
            display_info("WARNING: Ignored textDocument/hover result due to unrecognized format")
        end
    elseif method == "textDocument/formatting" then
        if result == nil or next(result) == nil then
            display_info("Formatted file (no changes)")
        else
            local textedits = result
            editBuf(micro.CurPane().Buf, textedits)
            display_info("Formatted file")
        end
    elseif method == "textDocument/rangeFormatting" then
        if result == nil or next(result) == nil then
            display_info("Formatted selection (no changes)")
        else
            local textedits = result
            editBuf(micro.CurPane().Buf, textedits)
            display_info("Formatted selection")
        end
    elseif method == "textDocument/completion" then
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

        local buf = micro.CurPane().Buf
        local wordbytes, _ = buf:GetWord()
        local stem = util.String(wordbytes)

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
                    local insertText, _ = insertText:gsub("^" .. stem, "")
                    table.insert(completions, insertText)
                end
            end
        end

        if #completions == 0 then
            -- fall back to micro's built-in completer
            micro.CurPane():Autocomplete()
        else
            -- turn completions into Completer function for micro
            -- https://pkg.go.dev/github.com/zyedidia/micro/v2/internal/buffer#Completer
            local completer = function (buf) return completions, labels end
            buf:Autocomplete(completer)
        end

    elseif method == "textDocument/references" then
        if result == nil or table.empty(result) then
            display_info("No references found")
            return
        end
        showReferenceLocations("[µlsp] references", result)
    elseif
        method == "textDocument/declaration" or
        method == "textDocument/definition" or
        method == "textDocument/typeDefinition" or
        method == "textDocument/implementation"
    then
        -- result: Location | Location[] | LocationLink[] | null
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
            local filepath = absPathFromFileUri(result.uri)
            local startLoc, _ = LSPRange.toLocs(result.range)

            openFileAtLoc(filepath, startLoc)
        end
    elseif method == "textDocument/documentSymbol" and gotoCurrentFunc then
        gotoCurrentFunc = false
        if result == nil or table.empty(result) then
            display_info("No symbols found in current document to navigate")
            return
        end

        local bp = micro.CurPane()
        local cursor = bp.Buf:GetActiveCursor()
        for _, sym in ipairs(result) do
            -- 12: function AND is DocumentSymbol[]. In SymbolInformation[]
            -- there is no range that can "be used to re-construct a hierarchy
            -- of the symbols."
            if sym.kind == 12 and sym.range then
                local startLoc, endLoc = LSPRange.toLocs(sym.range)
                if cursor:GreaterEqual(startLoc) and cursor:LessEqual(endLoc) then
                    display_info("You are in '", sym.name, "', going to the top!")
                    local newCursorLoc, _ = LSPRange.toLocs(sym.selectionRange)
                    cursor:GotoLoc(newCursorLoc)
                    bp:Center()
                    return
                end
            end
        end
        display_error("You are not inside a function")

    elseif method == "textDocument/documentSymbol" then
        if result == nil or table.empty(result) then
            display_info("No symbols found in current document")
            return
        end
        local symbolLocations = {}
        local symbolLabels = {}
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
                    uri = micro.CurPane().Buf.AbsPath,
                    range = sym.range
                })
            else
                table.insert(symbolLocations, sym.location)
            end
            table.insert(symbolLabels, string.format("%-15s %s", "["..SYMBOLKINDS[sym.kind].."]", sym.name))
        end
        showSymbolLocations("[µlsp] document symbols", symbolLocations, symbolLabels)
    else
        log("WARNING: dunno what to do with response to", method)
    end
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
        elseif notification.params.type == MessageType.Warning then
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
        elseif request.params.type == MessageType.Warning then
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

    if decodedMsg.result then
        local request = self.sentRequests[decodedMsg.id]
        self.sentRequests[decodedMsg.id] = nil
        self:handleResponseResult(request, decodedMsg.result)
    elseif decodedMsg.error then
        local request = self.sentRequests[decodedMsg.id]
        self.sentRequests[decodedMsg.id] = nil
        self:handleResponseError(request, decodedMsg.error)
    elseif decodedMsg.id and decodedMsg.method then
        self:handleRequest(decodedMsg)
    elseif decodedMsg.method then
        self:handleNotification(decodedMsg)
    else
        log("WARNING: unrecognized message type")
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

    local filetype = buf:FileType()
    -- NOTE: if we cancel didOpen then the rest of did*() are "cancelled"
    -- by self.openFiles[filePath].
    -- NOTE: we let pass files with 'unknown' filetype to support niche cases.
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
    local textDocument = self:textDocumentIdentifier(buf)
    local filePath = buf.AbsPath

    if self.openFiles[filePath] ~= nil then
        self.openFiles[filePath] = nil

        self:notification("textDocument/didClose", {
            textDocument = textDocument
        })
    end
end

function LSPClient:didChange(buf, changes)
    local textDocument = self:textDocumentIdentifier(buf)
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
    local textDocument = self:textDocumentIdentifier(buf)
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
    if client ~= nil then
        local buf = bufpane.Buf
        local cursor = buf:GetActiveCursor()
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
            table.insert(selectedRanges, LSPRange.fromSelection(cursor.CurSelection))
        end
    end

    if #selectedRanges > 1 then
        display_error("Formatting multiple selections is not supported yet")
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

    local filetype = bufpane.Buf:FileType()
    if #selectedRanges == 0 then
        local client = findClient(filetype, "documentFormattingProvider", "formatting")
        if client ~= nil then
            client:request("textDocument/formatting", {
                textDocument = client:textDocumentIdentifier(buf),
                options = formatOptions
            })
        end
    else
        local client = findClient(filetype, "documentRangeFormattingProvider", "formatting selections")
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
    local client = findClient(bufpane.Buf:FileType(), "completionProvider", "completion")
    if client ~= nil then
        local buf = bufpane.Buf
        local cursor = buf:GetActiveCursor()
        client:request("textDocument/completion", {
            textDocument = client:textDocumentIdentifier(buf),
            position = { line = cursor.Y, character = cursor.X },
            context = {
                -- 1 = Invoked, 2 = TriggerCharacter, 3 = TriggerForIncompleteCompletions
                triggerKind = 1,
            }
        })
    end
end

function gotoAction(kind)
    local cap = string.format("%sProvider", kind)
    local requestMethod = string.format("textDocument/%s", kind)

    return function(bufpane)
        local client = findClient(bufpane.Buf:FileType(), cap, requestMethod)
        if client ~= nil then
            local buf = bufpane.Buf
            local cursor = buf:GetActiveCursor()
            client:request(requestMethod, {
                textDocument = client:textDocumentIdentifier(buf),
                position = { line = cursor.Y, character = cursor.X }
            })
        end
    end
end

function gotoCurrentFunction(bp)
    gotoCurrentFunc = true
    documentSymbolsAction(bp)
end

function findReferencesAction(bufpane)
    local client = findClient(bufpane.Buf:FileType(), "referencesProvider", "finding references")
    if client ~= nil then
        local buf = bufpane.Buf
        local cursor = buf:GetActiveCursor()
        client:request("textDocument/references", {
            textDocument = client:textDocumentIdentifier(buf),
            position = { line = cursor.Y, character = cursor.X },
            context = { includeDeclaration = true }
        })
    end
end

function documentSymbolsAction(bufpane)
    local client = findClient(bufpane.Buf:FileType(), "documentSymbolProvider", "document symbols")
    if client ~= nil then
        local buf = bufpane.Buf
        client:request("textDocument/documentSymbol", {
            textDocument = client:textDocumentIdentifier(buf)
        })
    end
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
                local startLoc, endLoc = LSPRange.toLocs(diagnostic.range)
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
                    local newpane = micro.CurPane():HSplitBuf(newBuffer)
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

function onExit(text, userargs)
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
    if findClient(bufpane.Buf:FileType(), "completionProvider") == nil then return end

    local word, wordStartX = bufpane.Buf:GetWord()
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

    local word, wordStartX = bufpane.Buf:GetWord()
    if wordStartX >= 0 then
        return false -- returning false prevents tab from being inserted
    end
end

-- FIXME: figure out how to disable all this garbage when there are no active connections

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

    for _, client in pairs(activeConnections) do
    	client:didChange(buf, changes)
    end
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

    local TEXT_EVENT = {INSERT = 1, REMOVE = -1, REPLACE = 0}
    local tevents = {}
    for i = 1, numChanges do
        table.insert(tevents, elem.Value)
        elem = elem.Next
    end

    local changes = {}
    for i = 1, #tevents do
        local tev = tevents[#tevents + 1 - i]
        for _, delta in userdataIterator(tev.Deltas) do
            local text = ""
            local range = LSPRange.fromDelta(delta)

            if tev.EventType == TEXT_EVENT.INSERT then
                range["end"] = range["start"]
                text = util.String(delta.Text)
            end

            table.insert(changes, { range = range, text = text })
        end
    end

    for _, client in pairs(activeConnections) do
    	client:didChange(buf, changes)
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


function editBuf(buf, textedits)
    -- sort edits by start position (earliest first)
    local function sortByRangeStart(texteditA, texteditB)
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
        local startLoc, endLoc = LSPRange.toLocs(textedit.range)
        if endLoc:GreaterThan(buf:End()) then
            endLoc = buf:End()
        end

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

    syncFullDocument(buf)
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

            local lineNumber = diagnostic.range.start.line + 1

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
            msg = msg:gsub("(%a)\n(%a)", "%1 / %2"):gsub("%s+", " ")
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
    relPath, err = filepath.Rel(cwd, absPath)
    if err then return absPath end
    return relPath
end

function openFileAtLoc(filepath, loc)
    local bp = micro.CurPane()

    -- don't open a new tab if file is already open
    local alreadyOpenPane, tabIdx, paneIdx = findBufPaneByPath(filepath)

    if alreadyOpenPane then
        micro.Tabs():SetActive(tabIdx)
        alreadyOpenPane:tab():SetActive(paneIdx)
        bp = alreadyOpenPane
    else
        local newBuf, err = buffer.NewBufferFromFile(filepath)
        if err ~= nil then
            display_error(err)
            return
        end
        bp:AddTab()
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
    for tabIdx, tab in userdataIterator(micro.Tabs().List) do
        for paneIdx, pane in userdataIterator(tab.Panes) do
            -- pane.Buf is nil for panes that are not BufPanes (terminals etc)
            if pane.Buf ~= nil and fpath == pane.Buf.AbsPath then
                -- lua indexing starts from 1 but go is stupid and starts from 0 :/
                return pane, tabIdx - 1, paneIdx - 1
            end
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
