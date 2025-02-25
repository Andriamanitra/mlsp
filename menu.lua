local micro = import("micro")
local buffer = import("micro/buffer")

function _preInsertNewline(bp)
    local callback = bp.Buf.Settings["onEnter"]
    if callback ~= nil then
        local line = bp.Buf:Line(bp.Buf:GetActiveCursor().Y)
        callback(bp, line)
    end
end

function _preInsertTab(bp)
    local callback = bp.Buf.Settings["onTab"]
    if callback ~= nil then
        local line = bp.Buf:Line(bp.Buf:GetActiveCursor().Y)
        callback(bp, line)
    end
end

function Menu(args)
    local labels = args.labels
    if labels == nil then
        labels = {}
        for label, _ in pairs(args.onEnter or {}) do
            table.insert(labels, label)
        end
    end
    local menu = {}
    menu.name = args.name or "[µlsp] Menu"
    menu.header = args.header or ""
    menu.onEnter = args.onEnter or {}
    menu.onTab = args.onTab or {}
    menu.labels = labels
    menu.defaultAction = args.defaultAction
    menu.open = openMenu
    return menu
end

function openMenu(m)
    local content = m.header .. "\n" .. table.concat(m.labels, "\n")
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
