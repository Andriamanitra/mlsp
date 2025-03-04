local micro = import("micro")
local buffer = import("micro/buffer")

local function _preInsertNewline(bp)
    local callback = bp.Buf.Settings["onEnter"]
    if callback ~= nil then
        local line = bp.Buf:Line(bp.Buf:GetActiveCursor().Y)
        callback(bp, line)
    end
end

local function _preInsertTab(bp)
    local callback = bp.Buf.Settings["onTab"]
    if callback ~= nil then
        local line = bp.Buf:Line(bp.Buf:GetActiveCursor().Y)
        callback(bp, line)
    end
end

local function openMenu(m)
    local content = m.header .. "\n" .. table.concat(m.labels, "\n") .. "\n"
    local newBuffer = buffer.NewBuffer(content, m.name)
    newBuffer.Type.Scratch = true
    newBuffer.Type.Readonly = true
    newBuffer.Settings["statusline"] = false
    newBuffer.Settings["hltaberrors"] = false
    newBuffer.Settings["onEnter"] = function(bp, selected)
        local action = m.onEnter[selected] or m.defaultAction
        if type(action) == "function" then
            action(bp)
        end
    end
    newBuffer.Settings["onTab"] = function(bp, selected)
        local action = m.onTab[selected]
        if type(action) == "function" then
            action(bp)
        end
    end
    local bp = micro.CurPane():HSplitBuf(newBuffer)
    local _, headerLineCount = string.gsub(m.header, "\n", "\n")
    bp:GotoLoc(buffer.Loc(0, headerLineCount + 1))
end

local function Menu(args)
    local labels = args.labels
    if labels == nil then
        labels = {}
        for label, _ in pairs(args.onEnter or {}) do
            table.insert(labels, label)
        end
    end

    return {
        name = args.name or "[µlsp] Menu",
        header = args.header or "",
        onEnter = args.onEnter or {},
        onTab = args.onTab or {},
        labels = labels,
        defaultAction = args.defaultAction,
        open = openMenu
    }
end

menu = {
    new = Menu,
    preInsertNewline = _preInsertNewline,
    preInsertTab = _preInsertTab
}
