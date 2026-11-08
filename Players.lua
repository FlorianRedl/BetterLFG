-- Better LFG: "Find Players" tab.
--
-- Lists the players who listed themselves alone (solo listings) so a group builder can
-- find the missing roles. It reuses the groups tab's search (same results table, same
-- one-search-per-click rule) and only filters and draws the solo listings differently.

local ADDON, NS = ...

local ICON = "Interface\\AddOns\\" .. ADDON .. "\\Media\\TabSpieler"
local TITLE = "Find Players"
local ROW_HEIGHT = 40
local INVITE_ATLAS = "common-button-list-plus"
local MAX_LEVEL_DIGITS = 2

local parent, tab, panel, status, countText, scroll, content, filterWin
local rows = {}
local sortDesc = true   -- sorted by level, highest first

-- `pending` = what the filter window shows; `filters` = what the list uses (Search copies).
local function NewState()
    return {
        names = {}, ids = nil, levelOnly = true,
        roles = { tank = false, healer = false, dps = false },
        minLevel = nil, maxLevel = nil,
        minMyLevel = false,   -- "Min my level": minimum = the searching player's own level
        hiddenClasses = {},
    }
end
local pending, filters = NewState(), NewState()

local function CopySet(set)
    local c = {}
    for k, v in pairs(set) do c[k] = v end
    return c
end

---------------------------------------------------------------------------
-- Saving (roles, level range, hidden classes)
---------------------------------------------------------------------------
local function SaveFilters()
    BetterLFGDB = BetterLFGDB or {}
    BetterLFGDB.players = {
        roles = CopySet(filters.roles),
        minLevel = filters.minLevel,
        maxLevel = filters.maxLevel,
        minMyLevel = filters.minMyLevel,
        hiddenClasses = CopySet(filters.hiddenClasses),
    }
end

function NS.LoadPlayerFilters()
    local s = BetterLFGDB and BetterLFGDB.players
    if type(s) ~= "table" then return end
    for _, state in ipairs({ pending, filters }) do
        if type(s.roles) == "table" then
            for _, k in ipairs({ "tank", "healer", "dps" }) do state.roles[k] = s.roles[k] == true end
        end
        state.minLevel = type(s.minLevel) == "number" and s.minLevel or nil
        state.maxLevel = type(s.maxLevel) == "number" and s.maxLevel or nil
        state.minMyLevel = s.minMyLevel == true
        state.hiddenClasses = {}
        if type(s.hiddenClasses) == "table" then
            for k, v in pairs(s.hiddenClasses) do
                if type(k) == "string" and v == true then state.hiddenClasses[k] = true end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Filtering
---------------------------------------------------------------------------
local function IsDelisted(e)
    local live = C_LFGList.GetSearchResultInfo(e.id)
    return (not live) or NS.Readable(live.isDelisted, false) == true
end

local function MatchesActivity(e)
    if filters.ids or filters.levelOnly then
        local ok = false
        for _, id in ipairs(e.activityIDs) do
            if filters.ids then
                if filters.ids[id] then ok = true break end
            elseif NS.IsInMyLevelRange(id) then
                ok = true break
            end
        end
        if not ok and #e.activityIDs > 0 then return false end
    end
    return true
end

-- Unreadable data never hides a player.
local function Matches(e)
    if not MatchesActivity(e) then return false end
    local r = filters.roles
    if (r.tank or r.healer or r.dps) and e.soloRoles then
        local R = NS.Readable
        local offers = (r.tank and R(e.soloRoles.tank, false) == true)
            or (r.healer and R(e.soloRoles.healer, false) == true)
            or (r.dps and R(e.soloRoles.dps, false) == true)
        if not offers then return false end
    end
    if e.soloLevel then
        -- "Min my level" replaces the typed minimum with the own (current) level.
        local minLevel = filters.minMyLevel and UnitLevel("player") or filters.minLevel
        if minLevel and e.soloLevel < minLevel then return false end
        if filters.maxLevel and e.soloLevel > filters.maxLevel then return false end
    end
    if e.soloClass and filters.hiddenClasses[e.soloClass] then return false end
    return true
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------
local function Invite(e)
    local name = NS.LeaderName(e)
    if not name then
        print("|cffffd100Better LFG|r: the player's name is not available right now.")
        return
    end
    if C_PartyInfo and C_PartyInfo.InviteUnit then
        C_PartyInfo.InviteUnit(name)
    elseif InviteUnit then
        InviteUnit(name)
    end
end

local function ShowMenu(row)
    local e = row.e
    if not e or not MenuUtil then return end
    MenuUtil.CreateContextMenu(row, function(_, root)
        root:CreateTitle(e.leader or "")
        root:CreateButton("Send message", function() NS.OpenWhisper(e) end)
        root:CreateButton("Invite to group", function() Invite(e) end)
    end)
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------
local ROLE_KEYS = { { "tank", "TANK" }, { "healer", "HEALER" }, { "dps", "DAMAGER" } }

local function GetRow(i)
    local r = rows[i]
    if r then return r end
    r = CreateFrame("Button", nil, content)
    r:SetHeight(ROW_HEIGHT)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
    r:SetPoint("RIGHT", content, "RIGHT", 0, 0)
    r.hl = r:CreateTexture(nil, "HIGHLIGHT")
    r.hl:SetAllPoints()
    r.hl:SetColorTexture(1, 1, 1, 0.08)
    if i % 2 == 0 then
        local stripe = r:CreateTexture(nil, "BACKGROUND")
        stripe:SetAllPoints()
        stripe:SetColorTexture(1, 1, 1, 0.03)
    end

    -- Line 1: [class icon] name | level | roles ........ [invite]
    r.class = r:CreateTexture(nil, "ARTWORK")
    r.class:SetSize(16, 16)
    r.class:SetPoint("TOPLEFT", 8, -5)
    r.class:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES")

    r.name = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    r.name:SetPoint("LEFT", r.class, "RIGHT", 4, 0)
    r.name:SetWidth(150)
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)

    r.level = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.level:SetPoint("LEFT", r.name, "RIGHT", 4, 0)
    r.level:SetWidth(50)
    r.level:SetJustifyH("LEFT")

    r.playstyle = r:CreateFontString(nil, "OVERLAY", "GameFontGreenSmall")
    r.playstyle:SetPoint("LEFT", r.level, "RIGHT", 4, 0)
    r.playstyle:SetPoint("RIGHT", r, "RIGHT", -100, 0)
    r.playstyle:SetJustifyH("LEFT")
    r.playstyle:SetWordWrap(false)

    r.invite = CreateFrame("Button", nil, r)
    r.invite:SetSize(18, 18)
    r.invite:SetPoint("TOPRIGHT", r, "TOPRIGHT", -8, -5)
    r.invite:SetNormalAtlas(INVITE_ATLAS)
    r.invite:SetHighlightAtlas(INVITE_ATLAS, "ADD")
    r.invite:SetScript("OnClick", function(self) Invite(self:GetParent().e) end)
    r.invite:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Invite to group", 1, 1, 1)
        GameTooltip:Show()
    end)
    r.invite:SetScript("OnLeave", GameTooltip_Hide)

    -- Roles the player signed up for, right to left before the invite button.
    r.roles = {}
    for n = 1, 3 do
        local t = r:CreateTexture(nil, "ARTWORK")
        t:SetSize(18, 18)
        t:SetTexture(NS.ROLE_ICONS)
        t:SetPoint("TOPRIGHT", r, "TOPRIGHT", -34 - (3 - n) * 20, -5)
        r.roles[n] = t
    end

    -- Line 2: dungeon | zone
    r.info = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    r.info:SetPoint("BOTTOMLEFT", 8, 6)
    r.info:SetPoint("RIGHT", r, "RIGHT", -8, 0)
    r.info:SetJustifyH("LEFT")
    r.info:SetWordWrap(false)

    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r:SetScript("OnClick", function(self, button)
        if button == "RightButton" then ShowMenu(self) end
    end)
    r:SetScript("OnEnter", function(self) NS.ShowRowTooltip(self) end)
    r:SetScript("OnLeave", function() NS.HideRowTooltip() end)
    rows[i] = r
    return r
end

local function Render()
    if not panel then return end
    for _, r in ipairs(rows) do r:Hide() end

    local list = {}
    for i, e in ipairs(NS.results) do
        if e.isSolo and Matches(e) then
            e.porder = i
            table.insert(list, e)
        end
    end
    table.sort(list, function(a, b)
        local va, vb = a.soloLevel or 0, b.soloLevel or 0
        if va ~= vb then
            if sortDesc then return va > vb end
            return va < vb
        end
        return a.porder < b.porder
    end)

    for i, e in ipairs(list) do
        local r = GetRow(i)
        r.e = e
        -- Updated live since the last draw: flash once.
        if e.flashAt and not e.flashedPlayers and GetTime() - e.flashAt < 2 then
            e.flashedPlayers = true
            NS.FlashRow(r)
        end
        local delisted = IsDelisted(e)
        r:SetAlpha(delisted and 0.4 or 1)
        r.invite:SetEnabled(not delisted)
        r.invite:GetNormalTexture():SetDesaturated(delisted)

        local coords = e.soloClass and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[e.soloClass]
        if coords then
            r.class:SetTexCoord(unpack(coords))
            r.class:Show()
        else
            r.class:Hide()
        end
        r.name:SetText(e.leader)
        local color = e.soloClass and RAID_CLASS_COLORS and RAID_CLASS_COLORS[e.soloClass]
        if color then
            r.name:SetTextColor(color.r, color.g, color.b)
        else
            r.name:SetTextColor(1, 0.82, 0)
        end
        r.level:SetText(e.soloLevel and ("Lvl " .. e.soloLevel) or "")
        r.playstyle:SetText(delisted and "|cffcc6666Delisted|r" or (e.playstyle or ""))

        local n = 0
        for _, rk in ipairs(ROLE_KEYS) do
            if e.soloRoles and NS.Readable(e.soloRoles[rk[1]], false) == true then
                n = n + 1
                r.roles[n]:SetTexCoord(unpack(NS.ROLE_COORDS[rk[2]]))
                r.roles[n]:SetDesaturated(delisted)
                r.roles[n]:Show()
            end
        end
        -- Right-align the icons that are used.
        for k = 1, 3 do
            local t = r.roles[k]
            t:ClearAllPoints()
            t:SetPoint("TOPRIGHT", r, "TOPRIGHT", -34 - (n - k) * 20, -5)
            if k > n then t:Hide() end
        end

        local info = e.activity or ""
        if e.soloArea and e.soloArea ~= "" then
            info = (info ~= "" and (info .. "  |  ") or "") .. e.soloArea
        end
        r.info:SetText(info)
        r:Show()
    end
    content:SetHeight(math.max(1, #list * ROW_HEIGHT))

    local running = NS.search.running
    countText:SetText(running and "" or (#list == 1 and "1 player" or (#list .. " players")))
    if #list > 0 then
        status:SetText("")
    elseif running then
        status:SetText("Searching...")
    else
        status:SetText("No players match your filters.")
    end
end
NS.RenderPlayers = function()
    if panel and panel:IsShown() then Render() end
end

---------------------------------------------------------------------------
-- Filter window
---------------------------------------------------------------------------
local function ApplyFilters()
    filters.levelOnly = pending.levelOnly
    filters.roles = CopySet(pending.roles)
    filters.minLevel, filters.maxLevel = pending.minLevel, pending.maxLevel
    filters.minMyLevel = pending.minMyLevel
    filters.hiddenClasses = CopySet(pending.hiddenClasses)
    filters.ids = nil
    if next(pending.names) then
        filters.ids = {}
        for _, c in ipairs(NS.ActivityChoices(false)) do
            if pending.names[c.name] then
                for _, id in ipairs(c.ids) do filters.ids[id] = true end
            end
        end
    end
end

local function BuildFilterWindow()
    local ok = pcall(function()
        filterWin = CreateFrame("Frame", "BetterLFGPlayerFilterFrame", panel, "ButtonFrameTemplate")
    end)
    if ok and filterWin then
        if ButtonFrameTemplate_HidePortrait then ButtonFrameTemplate_HidePortrait(filterWin) end
        if filterWin.CloseButton then filterWin.CloseButton:Hide() end
        if filterWin.Inset then filterWin.Inset:Hide() end
    else
        filterWin = CreateFrame("Frame", "BetterLFGPlayerFilterFrame", panel, "PortraitFrameTemplateNoCloseButton")
    end
    filterWin:SetWidth(330)
    filterWin:SetPoint("TOPLEFT", parent, "TOPRIGHT", 48, 0)
    filterWin:SetPoint("BOTTOMLEFT", parent, "BOTTOMRIGHT", 48, 0)
    filterWin:EnableMouse(true)
    pcall(filterWin.SetTitle, filterWin, "Player Filters")
    local fInset = CreateFrame("Frame", nil, filterWin, "InsetFrameTemplate")
    fInset:SetPoint("TOPLEFT", filterWin, "TOPLEFT", 8, -28)
    fInset:SetPoint("BOTTOMRIGHT", filterWin, "BOTTOMRIGHT", -6, 8)
    filterWin.fInset = fInset

    -- Dungeon (multi-select) + level checkbox
    local dungeonLabel = filterWin:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dungeonLabel:SetPoint("TOPLEFT", filterWin, "TOPLEFT", 22, -44)
    dungeonLabel:SetText("Dungeon")

    local dropdown = CreateFrame("DropdownButton", nil, filterWin, "WowStyle1DropdownTemplate")
    dropdown:SetWidth(270)
    dropdown:SetPoint("TOPLEFT", dungeonLabel, "BOTTOMLEFT", 0, -6)
    local function UpdateDungeonText()
        local n, first = 0, nil
        for name in pairs(pending.names) do n = n + 1; first = first or name end
        local text = (n == 0 and "All dungeons") or (n == 1 and first) or (n .. " dungeons selected")
        dropdown:SetDefaultText(text)
        return text
    end
    UpdateDungeonText()
    NS.UseSummaryText(dropdown, UpdateDungeonText)
    dropdown:SetupMenu(function(_, root)
        pcall(root.SetScrollMode, root, 320)
        root:CreateButton("Clear selection", function()
            wipe(pending.names)
            UpdateDungeonText()
            dropdown:GenerateMenu()
        end)
        for _, c in ipairs(NS.ActivityChoices(pending.levelOnly)) do
            root:CreateCheckbox(c.text,
                function() return pending.names[c.name] == true end,
                function()
                    pending.names[c.name] = (not pending.names[c.name]) or nil
                    UpdateDungeonText()
                end)
        end
    end)

    local levelCheck = CreateFrame("CheckButton", nil, filterWin, "UICheckButtonTemplate")
    levelCheck:SetPoint("TOPLEFT", dropdown, "BOTTOMLEFT", -4, -2)
    levelCheck.Text:SetText("Only dungeons for my level")
    levelCheck:SetChecked(pending.levelOnly)
    levelCheck:SetScript("OnClick", function(self) pending.levelOnly = self:GetChecked() and true or false end)

    -- Languages (shared with the groups tab; applied on the next search)
    local langDropdown = NS.CreateLanguageDropdown(filterWin, levelCheck, 4)

    -- Roles: show players who can play any of the ticked roles
    local roleHeader = filterWin:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    roleHeader:SetPoint("TOPLEFT", langDropdown, "BOTTOMLEFT", 0, -14)
    roleHeader:SetText("Looking for")

    local roleChecks = {}
    local roleDefs = { { "tank", "TANK", "Tank" }, { "healer", "HEALER", "Healer" }, { "dps", "DAMAGER", "DPS" } }
    local anchor = roleHeader
    for i, d in ipairs(roleDefs) do
        local cb = CreateFrame("CheckButton", nil, filterWin, "UICheckButtonTemplate")
        cb:SetSize(26, 26)
        if i == 1 then
            cb:SetPoint("TOPLEFT", roleHeader, "BOTTOMLEFT", -2, -4)
        else
            cb:SetPoint("LEFT", anchor, "RIGHT", 64, 0)
        end
        local icon = filterWin:CreateTexture(nil, "ARTWORK")
        icon:SetSize(18, 18)
        icon:SetTexture(NS.ROLE_ICONS)
        icon:SetTexCoord(unpack(NS.ROLE_COORDS[d[2]]))
        icon:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        local text = filterWin:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("LEFT", icon, "RIGHT", 3, 0)
        text:SetText(d[3])
        cb:SetChecked(pending.roles[d[1]])
        cb:SetScript("OnClick", function(self) pending.roles[d[1]] = self:GetChecked() and true or false end)
        roleChecks[d[1]] = cb
        anchor = cb
    end

    -- Level range
    local levelHeader = filterWin:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    levelHeader:SetPoint("TOPLEFT", roleChecks.tank, "BOTTOMLEFT", 2, -14)
    levelHeader:SetText("Level")

    local function MakeBox(key)
        local box = CreateFrame("EditBox", nil, filterWin, "InputBoxTemplate")
        box:SetSize(38, 20)
        box:SetAutoFocus(false)
        box:SetNumeric(true)
        box:SetMaxLetters(MAX_LEVEL_DIGITS)
        box:SetJustifyH("CENTER")
        box:SetText(pending[key] and tostring(pending[key]) or "")
        box:SetScript("OnTextChanged", function(self)
            local t = self:GetText()
            pending[key] = t ~= "" and tonumber(t) or nil
        end)
        box:SetScript("OnEnterPressed", box.ClearFocus)
        box:SetScript("OnEscapePressed", box.ClearFocus)
        return box
    end
    local fromBox = MakeBox("minLevel")
    fromBox:SetPoint("TOPLEFT", levelHeader, "BOTTOMLEFT", 6, -6)
    local toText = filterWin:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    toText:SetPoint("LEFT", fromBox, "RIGHT", 6, 0)
    toText:SetText("to")
    local toBox = MakeBox("maxLevel")
    toBox:SetPoint("LEFT", toText, "RIGHT", 8, 0)

    -- "Min my level": the minimum becomes the searching player's own level.
    local myLevelCheck = CreateFrame("CheckButton", nil, filterWin, "UICheckButtonTemplate")
    myLevelCheck:SetSize(24, 24)
    myLevelCheck:SetPoint("LEFT", toBox, "RIGHT", 14, 0)
    myLevelCheck.Text:SetText("Min my level")
    myLevelCheck.Text:SetFontObject("GameFontNormalSmall")
    local function UpdateMinBox()
        -- The typed minimum does not apply while the box is ticked.
        fromBox:SetEnabled(not pending.minMyLevel)
        fromBox:SetAlpha(pending.minMyLevel and 0.4 or 1)
    end
    myLevelCheck:SetChecked(pending.minMyLevel)
    myLevelCheck:SetScript("OnClick", function(self)
        pending.minMyLevel = self:GetChecked() and true or false
        UpdateMinBox()
    end)
    myLevelCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Min my level", 1, 1, 1)
        GameTooltip:AddLine("Only players at least your own level (currently " .. UnitLevel("player") .. ").", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    myLevelCheck:SetScript("OnLeave", GameTooltip_Hide)
    UpdateMinBox()

    -- Classes: one checkbox each, 3 per row (all ticked = no filter).
    local classLabel = filterWin:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    classLabel:SetPoint("TOPLEFT", fromBox, "BOTTOMLEFT", -6, -16)
    classLabel:SetText("Class")

    local classChecks = {}
    local COLS, COL_WIDTH, ROW_HEIGHT_CB = 3, 96, 24
    for i, cls in ipairs(NS.ClassOrder({})) do
        local col, row = (i - 1) % COLS, math.floor((i - 1) / COLS)
        local cb = CreateFrame("CheckButton", nil, filterWin, "UICheckButtonTemplate")
        cb:SetSize(24, 24)
        cb:SetPoint("TOPLEFT", classLabel, "BOTTOMLEFT", -2 + col * COL_WIDTH, -4 - row * ROW_HEIGHT_CB)
        local icon = filterWin:CreateTexture(nil, "ARTWORK")
        icon:SetSize(16, 16)
        icon:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES")
        local coords = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[cls]
        if coords then icon:SetTexCoord(unpack(coords)) end
        icon:SetPoint("LEFT", cb, "RIGHT", 0, 0)
        local text = filterWin:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("LEFT", icon, "RIGHT", 3, 0)
        text:SetText(NS.ClassName(cls))
        local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[cls]
        if color then text:SetTextColor(color.r, color.g, color.b) end
        cb:SetChecked(not pending.hiddenClasses[cls])
        cb:SetScript("OnClick", function(self)
            pending.hiddenClasses[cls] = (not self:GetChecked()) or nil
        end)
        classChecks[cls] = cb
    end

    -- Bottom bar: [Reset filters] [gear] ........ [Search]
    local searchBtn = CreateFrame("Button", nil, filterWin, "UIPanelButtonTemplate")
    searchBtn:SetSize(100, 24)
    searchBtn:SetPoint("BOTTOMRIGHT", -16, 14)
    searchBtn:SetText("Search")
    searchBtn:SetScript("OnClick", function()
        fromBox:ClearFocus(); toBox:ClearFocus()
        ApplyFilters()
        SaveFilters()
        Render()
        NS.Refresh(filters)
    end)

    -- Resets every filter to its default, including dungeons and languages.
    local resetBtn = CreateFrame("Button", nil, filterWin, "UIPanelButtonTemplate")
    resetBtn:SetSize(100, 24)
    resetBtn:SetPoint("BOTTOMLEFT", 16, 14)
    resetBtn:SetText("Reset filters")
    resetBtn:SetScript("OnClick", function()
        for _, state in ipairs({ pending, filters }) do
            state.roles = { tank = false, healer = false, dps = false }
            state.minLevel, state.maxLevel = nil, nil
            state.minMyLevel = false
            state.hiddenClasses = {}
        end
        for _, cb in pairs(roleChecks) do cb:SetChecked(false) end
        fromBox:SetText(""); toBox:SetText("")
        myLevelCheck:SetChecked(false)
        UpdateMinBox()
        -- Dungeons: all, only for my level (the default).
        wipe(pending.names)
        filters.ids = nil
        pending.levelOnly, filters.levelOnly = true, true
        levelCheck:SetChecked(true)
        UpdateDungeonText()
        NS.RefreshDropdown(dropdown)
        -- Languages: all (shared with the groups tab).
        NS.ResetLanguages()
        langDropdown.Refresh()
        for _, cb in pairs(classChecks) do cb:SetChecked(true) end
        SaveFilters()
        Render()
    end)

    local gear = CreateFrame("Button", nil, filterWin)
    gear:SetSize(24, 24)
    gear:SetPoint("LEFT", resetBtn, "RIGHT", 6, 0)
    gear:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
    gear:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    gear:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Settings")
        GameTooltip:Show()
    end)
    gear:SetScript("OnLeave", GameTooltip_Hide)
    gear:SetScript("OnClick", function() NS.OpenSettings() end)
end

---------------------------------------------------------------------------
-- Panel and tab
---------------------------------------------------------------------------
local function BuildPanel()
    panel = CreateFrame("Frame", "BetterLFGPlayersPanel", parent, "PortraitFrameTemplateNoCloseButton")
    panel:SetAllPoints(parent)
    panel:EnableMouse(true)
    panel:Hide()
    NS.playersPanel = panel

    if panel.SetTitle then panel:SetTitle(TITLE) end
    if panel.PortraitContainer and panel.PortraitContainer.portrait then
        panel.PortraitContainer.portrait:SetTexture(ICON)
    end

    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButtonNoScripts")
    close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function()
        panel:Hide()
        if not InCombatLockdown() then HideUIPanel(parent) end
    end)

    local inset = CreateFrame("Frame", nil, panel, "InsetFrameTemplate")
    inset:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -64)
    inset:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -6, 8)

    status = inset:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    status:SetPoint("CENTER", inset, "CENTER", 0, 0)

    countText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    countText:SetPoint("BOTTOMRIGHT", inset, "TOPRIGHT", -6, 6)

    -- Column headers; "Level" sorts on click.
    local function Header(text, x, alignRight)
        local h = CreateFrame("Button", nil, inset)
        h:SetHeight(18)
        h.text = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h.text:SetText(text)
        h:SetWidth(h.text:GetStringWidth() + 14)
        if alignRight then
            h:SetPoint("TOPRIGHT", inset, "TOPRIGHT", x, -6)
            h.text:SetPoint("RIGHT", 0, 0)
        else
            h:SetPoint("TOPLEFT", inset, "TOPLEFT", x, -6)
            h.text:SetPoint("LEFT", 0, 0)
        end
        return h
    end
    Header("Player", 14)
    local levelHeader = Header("Level", 188)
    levelHeader.arrow = levelHeader:CreateTexture(nil, "OVERLAY")
    levelHeader.arrow:SetSize(9, 8)
    levelHeader.arrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
    levelHeader.arrow:SetPoint("LEFT", levelHeader.text, "RIGHT", 3, 0)
    local function UpdateArrow()
        if sortDesc then
            levelHeader.arrow:SetTexCoord(0, 0.5625, 0, 1)
        else
            levelHeader.arrow:SetTexCoord(0, 0.5625, 1, 0)
        end
    end
    UpdateArrow()
    levelHeader:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2", "ADD")
    levelHeader:GetHighlightTexture():SetAlpha(0.3)
    levelHeader:SetScript("OnClick", function()
        sortDesc = not sortDesc
        UpdateArrow()
        Render()
    end)
    Header("Playstyle", 242)
    Header("Roles", -60, true)

    local divider = inset:CreateTexture(nil, "ARTWORK")
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", inset, "TOPLEFT", 8, -26)
    divider:SetPoint("TOPRIGHT", inset, "TOPRIGHT", -8, -26)
    divider:SetColorTexture(1, 0.82, 0, 0.25)

    scroll = CreateFrame("ScrollFrame", "BetterLFGPlayersScroll", inset, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 6, -28)
    scroll:SetPoint("BOTTOMRIGHT", -26, 6)
    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(10, 1)
    scroll:SetScrollChild(content)
    scroll:SetScript("OnSizeChanged", function(_, w) content:SetWidth(w) end)

    BuildFilterWindow()

    panel:SetScript("OnShow", function()
        if NS.groupsPanel then NS.groupsPanel:Hide() end
        NS.RaiseAbove(panel)
        NS.FixFilterBorder(filterWin)
        tab:SetChecked(true)
        Render()
        NS.Refresh(filters)   -- runs inside the tab click, so the search is allowed
    end)
    panel:SetScript("OnHide", function() tab:SetChecked(false) end)
    parent:HookScript("OnHide", function() panel:Hide() end)
end

local function BuildTab()
    tab = CreateFrame("Frame", "BetterLFGPlayersTab", parent, "LargeSideTabButtonTemplate")
    tab.Icon:SetTexture(ICON)
    tab.Icon:SetSize(30, 30)
    tab:SetFillToInterior(true)
    tab:SetPoint("TOPLEFT", NS.groupsTab, "BOTTOMLEFT", 0, -2)
    tab:SetChecked(false)
    tab.tooltipText = TITLE
    tab:SetCustomOnMouseUpHandler(function(_, button, upInside)
        if button == "LeftButton" and upInside then
            if panel:IsShown() then panel:Hide() else panel:Show() end
        end
    end)
    NS.playersTab = tab
end

function NS.BuildPlayers()
    parent = NS.parent
    if not parent or tab then return end
    BuildTab()
    BuildPanel()
    -- Blizzard's own side tabs bring their panel back.
    for _, child in ipairs({ parent:GetChildren() }) do
        if child ~= tab and child ~= NS.groupsTab and child.Icon and child.SetCustomOnMouseUpHandler then
            child:HookScript("OnMouseUp", function() panel:Hide() end)
        end
    end
end
