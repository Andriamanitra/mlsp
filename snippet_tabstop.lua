--[[

MIT License

Copyright (c) 2025 usfbih8u

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

]]

-- NOTE: this module does NOT fully implement the snippet syntax specification.
-- Full information can be found here:
-- https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#snippet_syntax

---@class SnippetTabstopper
---@field _regex string Regex to perform the tab stop search
---@field bufpane BufPane? The bufpane where the snippet is (used to check if we are in the correct pane)
---@field startLoc Loc? Location where the snippet starts
---@field endLoc Loc? Location where the snippet ends
local SnippetTabstopper = {
    _regex = "\\$\\{(?:[^{}]+|\\{[^{}]*\\})*\\}|\\$\\d+"
}
SnippetTabstopper.__index = SnippetTabstopper

---Resets the SnippetTabstopper to its original values.
---@param self SnippetTabstopper
local function TabstopperReset(self)
    self.bufpane = nil
    self.startLoc = nil
    self.endLoc = nil
    self.first_done = false
end

---Searches for the next tab stop.
---NOTE: The search is not performed by tab stop index, but by regex match order.
---@param self SnippetTabstopper
---@param searchDown boolean Indicates whether the search should proceed backwards.
---@return Loc[]? -- match found
local function SearchNextTabstop(self, searchDown)
    local buf = self.bufpane.Buf
    local cursor = self.bufpane.Cursor

    if self.first_done == false then --First time? If there is a tab stop, go to startLoc.
        local _, found, err = buf:FindNext(
            self._regex, self.startLoc, self.endLoc, self.startLoc, searchDown, true -- use regex
        )
        assert(err == nil, "regex SHOULD BE valid")
        if not found then return nil end
        -- NOTE: If `searchDown` is false, the last tab stop will be selected.
        -- The first tab stop backward from `startLoc` is the last one.
        cursor:GotoLoc(self.startLoc)
    end
    self.first_done = true

    local fromLoc
    if cursor:HasSelection() then
        if searchDown then
            --Skip '$' to search for nested placeholders
            cursor:Deselect(true) --cursor in startLoc
            cursor:Right()
        else
            --skip closing '}'
            cursor:Deselect(false) --cursor in endLoc
        end
    end
    fromLoc = -cursor.Loc

    local match, found, err = buf:FindNext(
        self._regex, self.startLoc, self.endLoc, fromLoc, searchDown, true -- use regex
    )
    assert(err == nil, "regex SHOULD BE valid")
    if not found then return nil end

    return match
end

---Selects a tab stop.
---@param self SnippetTabstopper
---@param tabstop Loc[] The tabstop location.
local function SelectTabstop(self, tabstop)
    self.bufpane.Cursor:GotoLoc(tabstop[1])
    self.bufpane.Cursor:SetSelectionStart(tabstop[1])
    self.bufpane.Cursor:SetSelectionEnd(tabstop[2])
end

----------------------------------------------------------------
-- Public API
----------------------------------------------------------------

---Initializes a SnippetTabstopper.
---@param bufpane BufPane The BufPane where the snippet resides.
---@param startLoc Loc The location where the snippet starts.
---@param endLoc Loc The location where the snippet ends.
---@return SnippetTabstopper -- Instance of SnippetTabstopper
function SnippetTabstopper.new(bufpane, startLoc, endLoc)
    assert(bufpane); assert(startLoc); assert(endLoc)
    local self = setmetatable({}, SnippetTabstopper)

    self.bufpane = bufpane
    self.startLoc = startLoc
    self.endLoc = endLoc
    self.first_done = false

    return self
end

---Checks if `bufpane` is the BufPane of the snippet and ensures that
---SnippetTabstopper is initialized.
---@param bufpane BufPane Current Bufpane
function SnippetTabstopper:isBufPane(bufpane)
    return self.bufpane and self.bufpane == bufpane
end

---Goes to the next tabstop.
---@param bufpane BufPane Current BufPane
---@param searchDown boolean Indicates whether the search should go up or down
---@return boolean True if the action was performed; otherwise, false.
function SnippetTabstopper:nextTabstop(bufpane, searchDown)
    if not self:isBufPane(bufpane) then
        return false -- Don't reset while in a different buffer
    end

    local loc = -bufpane.Cursor.Loc
    if loc:LessThan(self.startLoc) or loc:GreaterThan(self.endLoc) then
        TabstopperReset(self)
        return false
    end

    local tabstop = SearchNextTabstop(self, searchDown or false)
    if not tabstop then
        TabstopperReset(self)
        return false
    end

    SelectTabstop(self, tabstop)
    return true
end

return SnippetTabstopper
