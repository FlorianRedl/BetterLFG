-- BetterLFG: a fourth side tab on the Group Finder that lists all open groups,
-- with a filter window next to it.
--
-- Design notes (learned from reading the client's Group Finder and the LFGForever addon):
--  * The window is LFGParentFrame, from the LoadOnDemand Blizzard_GroupFinder_VanillaStyle
--    (a Secure addon). It has no chrome; each tab panel brings its own portrait frame.
--  * So our "tab" is a panel with the same chrome (PortraitFrameTemplateNoCloseButton)
--    that fills LFGParentFrame and sits on top. We never Show/Hide Blizzard's panels
--    (that would run their code inside our call stack and risk taint).
--  * Search results can be secret values; every read goes through Readable().

local ADDON, NS = ...   -- NS: shared with Players.lua

-- Version comes from the .toc (## Version), so there is only one place to bump it.
local GetMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
local VERSION = (GetMeta and GetMeta(ADDON, "Version")) or "?"
-- The packager replaces @project-version@ with the git tag; unpackaged it stays a placeholder.
if VERSION:find("^@") then VERSION = "dev" end

local TAB_NAME = "BetterLFGTab"
local ICON = "Interface\\AddOns\\" .. ADDON .. "\\Media\\TabGruppe"
local TITLE = "Find Groups"
local ROW_HEIGHT = 40
local SEARCH_TIMEOUT = 15
local MAX_MEMBERS_SCANNED = 40

local parent, tab, panel, status, countText, soloText, soloClassText, scroll, content, filterWin
local soloClassCounts = {}
-- Forward declarations (defined further down).
local Render, WhisperLeader, ShowRowMenu, BuildSettings, OpenSettings
local rows = {}
local results = {}
local search = { queue = {}, running = false, token = 0 }

-- Filter state
-- Each range: on = checkbox, min/max = nil when the box is empty.
local RANGE_KEYS = { "members", "tank", "healer", "damage" }
-- `pending` is what the filter window shows; `filters` is what the list uses.
-- The Search button copies pending -> filters.
local function ResetRanges(state)
    for _, k in ipairs(RANGE_KEYS) do state[k] = { on = false, min = nil, max = nil } end
end
-- hiddenPlaystyles: set of playstyle keys the player unticked (empty = show all).
local pending = { levelOnly = true, names = {}, hiddenPlaystyles = {} }   -- names: selected dungeon names
local filters = { levelOnly = true, ids = nil, hiddenPlaystyles = {} }    -- ids: selected activity IDs, nil = all
ResetRanges(pending)
ResetRanges(filters)

-- Playstyles a listing can have (Enum.LFGEntryGeneralPlaystyle; None = 0 is not offered).
-- `key` is what gets saved, so it does not depend on the client language.
local PSE = Enum and Enum.LFGEntryGeneralPlaystyle or {}
local PLAYSTYLES = {
    { key = "Learning",   value = PSE.Learning or 1,   label = "Learning" },
    { key = "FunRelaxed", value = PSE.FunRelaxed or 2, label = "Relaxed" },
    { key = "FunSerious", value = PSE.FunSerious or 3, label = "Competitive" },
    { key = "Expert",     value = PSE.Expert or 4,     label = "Carry Offered" },
}
local PLAYSTYLE_KEY = {}
for _, p in ipairs(PLAYSTYLES) do PLAYSTYLE_KEY[p.value] = p.key end

local function CopySet(set)
    local copy = {}
    for k, v in pairs(set) do copy[k] = v end
    return copy
end

-- Saved between sessions (SavedVariables: BetterLFGDB): the "Find groups by role" ranges
-- and the unticked playstyles.
local function SaveRoles()
    BetterLFGDB = BetterLFGDB or {}
    local saved = {}
    for _, k in ipairs(RANGE_KEYS) do
        local f = filters[k]
        saved[k] = { on = f.on, min = f.min, max = f.max }
    end
    BetterLFGDB.roles = saved
    BetterLFGDB.hiddenPlaystyles = CopySet(filters.hiddenPlaystyles)
end

local function LoadRoles()
    local hidden = BetterLFGDB and BetterLFGDB.hiddenPlaystyles
    if type(hidden) == "table" then
        for _, p in ipairs(PLAYSTYLES) do
            if hidden[p.key] == true then
                pending.hiddenPlaystyles[p.key] = true
                filters.hiddenPlaystyles[p.key] = true
            end
        end
    end
    local saved = BetterLFGDB and BetterLFGDB.roles
    if type(saved) ~= "table" then return end
    for _, k in ipairs(RANGE_KEYS) do
        local s = saved[k]
        if type(s) == "table" then
            local r = {
                on = s.on == true,
                min = type(s.min) == "number" and s.min or nil,
                max = type(s.max) == "number" and s.max or nil,
            }
            pending[k] = { on = r.on, min = r.min, max = r.max }
            filters[k] = r
        end
    end
end

-- Blizzard's Group Finder hides every activity whose suggested level range does not
-- contain the player's level; "Only dungeons for my level" reproduces that rule.
-- Dungeons only (no quests/zones/battlegrounds/custom): the Dungeons category.
local DUNGEON_CATEGORY = _G.GROUP_FINDER_CATEGORY_ID_DUNGEONS or 2
local activityCategory
local function CategoryOf(id, info)
    if info and info.categoryID then return info.categoryID end
    if not activityCategory then
        activityCategory = {}
        for _, cat in ipairs(C_LFGList.GetAvailableCategories() or {}) do
            for _, aid in ipairs(C_LFGList.GetAvailableActivities(cat) or {}) do
                activityCategory[aid] = cat
            end
        end
    end
    return activityCategory[id]
end

local function IsDungeon(activityID, info)
    return CategoryOf(activityID, info) == DUNGEON_CATEGORY
end

-- A dungeon whose suggested level range contains the player's level.
local function IsInMyLevelRange(activityID)
    local a = C_LFGList.GetActivityInfoTable(activityID)
    if not a then return false end
    if not IsDungeon(activityID, a) then return false end
    local lvl = UnitLevel("player")
    -- Strict: the level must lie inside the suggested range (too low AND too high are out).
    -- Falls back to the hard min/max level when no suggestion is given.
    local lo = a.minLevelSuggestion or 0
    local hi = a.maxLevelSuggestion or 0
    if lo == 0 and hi == 0 then
        lo, hi = a.minLevel or 0, a.maxLevel or 0
    end
    if lo > 0 and lvl < lo then return false end
    if hi > 0 and lvl > hi then return false end
    return true
end

local function LevelText(a)
    local lo, hi = a.minLevelSuggestion or 0, a.maxLevelSuggestion or 0
    if lo == hi or hi == 0 then
        return lo ~= 0 and string.format("(%d)", lo) or ""
    end
    return string.format("(%d - %d)", lo, hi)
end

local ROLE_ICONS = "Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES"
local ROLE_COORDS = {
    TANK    = { 0, 19 / 64, 22 / 64, 41 / 64 },
    HEALER  = { 20 / 64, 39 / 64, 1 / 64, 20 / 64 },
    DAMAGER = { 20 / 64, 39 / 64, 22 / 64, 41 / 64 },
}
local MAX_ROLE_ICONS = 5

-- Class icons as inline text markup (Blizzard's class icon sheet + CLASS_ICON_TCOORDS).
local CLASS_ORDER = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local function ClassMarkup(cls)
    local c = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[cls]
    if not c then return nil end
    return string.format("|TInterface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES:16:16:0:0:256:256:%d:%d:%d:%d|t",
        c[1] * 256, c[2] * 256, c[3] * 256, c[4] * 256)
end
-- The classic nine, plus any other class that actually shows up.
local function ClassOrder(counts)
    local order, seen = {}, {}
    for _, cls in ipairs(CLASS_ORDER) do table.insert(order, cls); seen[cls] = true end
    for cls in pairs(counts) do
        if not seen[cls] then table.insert(order, cls) end
    end
    return order
end
local function ClassName(cls)
    return cls:sub(1, 1) .. cls:sub(2):lower()
end
-- Same role icons as inline text markup (pixel coords of the 64x64 texture).
local ROLE_MARKUP = {
    TANK    = "|T" .. ROLE_ICONS .. ":16:16:0:0:64:64:0:19:22:41|t",
    HEALER  = "|T" .. ROLE_ICONS .. ":16:16:0:0:64:64:20:39:1:20|t",
    DAMAGER = "|T" .. ROLE_ICONS .. ":16:16:0:0:64:64:20:39:22:41|t",
}

local function Readable(value, fallback)
    if value == nil then return fallback end
    if canaccessvalue and not canaccessvalue(value) then return fallback end
    return value
end

---------------------------------------------------------------------------
-- Filtering
---------------------------------------------------------------------------
-- A checked range applies to how many of that role are in the group
-- (empty "from"/"to" = no bound on that side). Unreadable counts never hide a group.
local ROLE_RULES = {
    { field = "tank",   key = "TANK" },
    { field = "healer", key = "HEALER" },
    { field = "damage", key = "DAMAGER" },
}

local function InRange(f, value)
    if value == nil then return true end
    if f.min and value < f.min then return false end
    if f.max and value > f.max then return false end
    return true
end

-- Dungeon selection / "only my level" (used for groups AND for the solo-player summary).
local function MatchesActivity(e)
    if filters.ids or filters.levelOnly then
        local ok = false
        for _, id in ipairs(e.activityIDs) do
            if filters.ids then
                if filters.ids[id] then ok = true break end
            elseif IsInMyLevelRange(id) then
                ok = true break
            end
        end
        -- Listings whose activity cannot be read are kept.
        if not ok and #e.activityIDs > 0 then return false end
    end
    return true
end

local function Matches(e)
    if filters.members.on and not InRange(filters.members, e.numMembers) then return false end
    -- Listings without a (readable) playstyle are always kept.
    local psKey = e.playstyleValue and PLAYSTYLE_KEY[e.playstyleValue]
    if psKey and filters.hiddenPlaystyles[psKey] then return false end
    if not MatchesActivity(e) then return false end
    for _, rule in ipairs(ROLE_RULES) do
        local f = filters[rule.field]
        if f.on and e.counts then
            local have = Readable(e.counts[rule.key], nil) or 0
            if not InRange(f, have) then return false end
        end
    end
    return true
end

---------------------------------------------------------------------------
-- Row tooltip
---------------------------------------------------------------------------
-- Blizzard's own group tooltip (leader crown, every member with class colour, level and
-- role icon, "Members (T/H/D)", voice chat, dungeons) is reused instead of rebuilt.
-- Their builder assumes the listing still exists and that its data is not secret, so
-- both are checked first (same guards LFGForever uses).
---------------------------------------------------------------------------
-- Item level via addon messages
---------------------------------------------------------------------------
-- The group search has no item level. Players who also run BetterLFG answer a whisper
-- addon message with their equipped average item level:
--   viewer -> member: "REQ"      member -> viewer: "ILVL:<number>"
local PREFIX = "BetterLFG"
local ILVL_TTL = 300          -- seconds an answer stays valid
local REQUEST_COOLDOWN = 30   -- seconds before the same player is asked again
local PENDING_TIME = 5        -- seconds we show "..." while waiting for an answer
local ilvlCache, ilvlRequested = {}, {}
local hoveredRow

if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
end

local function ShortName(name)
    name = name:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    return Ambiguate and Ambiguate(name, "short") or (name:match("^[^-]+") or name)
end

-- Equipment slots that count toward the item level (no shirt, no tabard), in display order.
local GEAR_SLOTS = {
    { 1, "Head" }, { 2, "Neck" }, { 3, "Shoulder" }, { 15, "Back" }, { 5, "Chest" },
    { 9, "Wrist" }, { 10, "Hands" }, { 6, "Waist" }, { 7, "Legs" }, { 8, "Feet" },
    { 11, "Ring" }, { 12, "Ring" }, { 13, "Trinket" }, { 14, "Trinket" },
    { 16, "Main Hand" }, { 17, "Off Hand" }, { 18, "Ranged" },
}

local function SlotItemLevel(slot)
    local link = GetInventoryItemLink("player", slot)
    if not link then return nil end
    local il = (C_Item and C_Item.GetDetailedItemLevelInfo and C_Item.GetDetailedItemLevelInfo(link))
        or (GetDetailedItemLevelInfo and GetDetailedItemLevelInfo(link))
        or select(4, GetItemInfo(link))
    return il, link
end

local function MyItemLevel()
    if GetAverageItemLevel then
        local _, equipped = GetAverageItemLevel()
        if equipped and equipped > 0 then return math.floor(equipped + 0.5) end
    end
    local sum, n = 0, 0
    for _, s in ipairs(GEAR_SLOTS) do
        local il = SlotItemLevel(s[1])
        if il then sum = sum + il; n = n + 1 end
    end
    return n > 0 and math.floor(sum / n + 0.5) or nil
end

-- Tooltip for the "Your item level" display: every slot with its item and item level.
-- Items clearly below the average get a light red background and a red number.
local lowMarks, lowMarksHooked = {}, false
local function ClearLowMarks()
    for _, t in ipairs(lowMarks) do t:Hide() end
end

local function IsClearlyLow(il, avg)
    return il and avg and (avg - il) >= math.max(5, avg * 0.2)
end

local function ShowMyGearTooltip(owner)
    if not lowMarksHooked then
        GameTooltip:HookScript("OnHide", ClearLowMarks)
        lowMarksHooked = true
    end
    ClearLowMarks()
    local avg = MyItemLevel()
    GameTooltip:SetOwner(owner, "ANCHOR_BOTTOMRIGHT")
    GameTooltip:AddDoubleLine("Your item level", tostring(avg or "?"), 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddLine(" ")
    local flagged = {}
    for _, s in ipairs(GEAR_SLOTS) do
        local il, link = SlotItemLevel(s[1])
        if link then
            if IsClearlyLow(il, avg) then
                GameTooltip:AddDoubleLine(s[2] .. ":  " .. link, tostring(il), 0.8, 0.8, 0.8, 1, 0.35, 0.35)
                table.insert(flagged, GameTooltip:NumLines())
            else
                GameTooltip:AddDoubleLine(s[2] .. ":  " .. link, il and tostring(il) or "?",
                    0.8, 0.8, 0.8, 1, 1, 1)
            end
        else
            GameTooltip:AddDoubleLine(s[2] .. ":  -", "", 0.5, 0.5, 0.5)
        end
    end
    GameTooltip:Show()

    -- Red bar behind each flagged line (placed after Show, when the lines are laid out).
    for i, lineIndex in ipairs(flagged) do
        local left = _G["GameTooltipTextLeft" .. lineIndex]
        if left then
            local t = lowMarks[i]
            if not t then
                t = GameTooltip:CreateTexture(nil, "ARTWORK", nil, -8)
                lowMarks[i] = t
            end
            t:SetColorTexture(1, 0.1, 0.1, 0.25)
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", left, "TOPLEFT", -4, 2)
            t:SetPoint("BOTTOMLEFT", left, "BOTTOMLEFT", -4, -2)
            t:SetPoint("RIGHT", GameTooltip, "RIGHT", -6, 0)
            t:Show()
        end
    end
end

-- Returns the item level (number), or nil plus "pending"/"unknown"; asks the player if needed.
local function ItemLevelFor(name)
    if name == UnitName("player") then return MyItemLevel() end
    local now = GetTime()
    local c = ilvlCache[name]
    if c and now - c.t < ILVL_TTL then return c.ilvl end
    local asked = ilvlRequested[name]
    if not asked or now - asked > REQUEST_COOLDOWN then
        ilvlRequested[name] = now
        asked = now
        pcall(C_ChatInfo.SendAddonMessage, PREFIX, "REQ", "WHISPER", name)
    end
    return nil, (now - asked < PENDING_TIME) and "pending" or "unknown"
end

-- Blizzard sizes the tooltip before we lengthen the level texts; widen it if a row overflows.
local function WidenTooltip(tt)
    local limit = tt:GetRight()
    if not limit or not canaccessvalue(limit) then return end
    limit = limit - 11
    local overflow = 0
    local function Consider(region)
        if not region or not region:IsShown() then return end
        local right = region:GetRight()
        if right and canaccessvalue(right) and right - limit > overflow then overflow = right - limit end
    end
    local function ConsiderRow(row)
        if not row or not row:IsShown() then return end
        Consider(row.Name); Consider(row.Level)
        for _, icon in ipairs(row.Roles or {}) do Consider(icon) end
    end
    ConsiderRow(tt.Leader)
    if tt.memberPool then for row in tt.memberPool:EnumerateActive() do ConsiderRow(row) end end
    if overflow > 0 then tt:SetWidth(tt:GetWidth() + overflow) end
end

-- Appends "iLvl 123" (or "..." while waiting, "?" without the addon) to each member's level.
local function AnnotateItemLevels(tt)
    local function Annotate(row)
        if not row or not row:IsShown() or not row.Name or not row.Level then return end
        local name = row.Name:GetText()
        if not name or not canaccessvalue(name) or name == "" then return end
        local levelText = row.Level:GetText() or ""
        if not canaccessvalue(levelText) then return end
        local il, state = ItemLevelFor(ShortName(name))
        local suffix
        if il then
            suffix = "  |cff9d9dffiLvl " .. il .. "|r"
        elseif state == "pending" then
            suffix = "  |cff808080iLvl ...|r"
        else
            suffix = "  |cff808080iLvl ?|r"
        end
        row.Level:SetText(levelText .. suffix)
    end
    Annotate(tt.Leader)
    if tt.memberPool then for row in tt.memberPool:EnumerateActive() do Annotate(row) end end
    WidenTooltip(tt)
end

local function HideRowTooltip()
    hoveredRow = nil
    if LFGBrowseSearchEntryTooltip then LFGBrowseSearchEntryTooltip:Hide() end
    GameTooltip:Hide()
end

-- Removes the "Voice chat" line from Blizzard's tooltip: hides every element whose key
-- mentions "voice", re-anchors whatever hung below it, and shortens the tooltip.
local debugTooltip = false
local function StripVoiceChat(tt)
    if debugTooltip then
        for key, obj in pairs(tt) do
            if type(key) == "string" then
                print("tooltip key:", key, type(obj), type(obj) == "table" and obj.IsShown and tostring(obj:IsShown()) or "")
            end
        end
    end
    local voice, removed = {}, 0
    for key, obj in pairs(tt) do
        if type(key) == "string" and key:lower():find("voice") and type(obj) == "table" and obj.Hide then
            voice[obj] = true
        end
    end
    if not next(voice) then return end

    -- Re-anchor the siblings that were attached to a voice element.
    for key, obj in pairs(tt) do
        if type(key) == "string" and type(obj) == "table" and not voice[obj]
            and obj.GetNumPoints and obj.GetPoint then
            local points, changed = {}, false
            for i = 1, obj:GetNumPoints() do
                local point, rel, relPoint, x, y = obj:GetPoint(i)
                if voice[rel] then
                    local _, vrel, vrelPoint, vx, vy = rel:GetPoint(1)
                    if vrel then
                        rel, relPoint, x, y = vrel, vrelPoint, (x or 0) + (vx or 0), (y or 0) + (vy or 0)
                        changed = true
                    end
                end
                points[i] = { point, rel, relPoint, x, y }
            end
            if changed then
                obj:ClearAllPoints()
                for _, p in ipairs(points) do obj:SetPoint(p[1], p[2], p[3], p[4], p[5]) end
            end
        end
    end

    for obj in pairs(voice) do
        if obj:IsShown() then
            local h = (obj.GetStringHeight and obj:GetStringHeight()) or obj:GetHeight() or 0
            if h > removed then removed = h end
            obj:Hide()
        end
    end
    if removed > 0 then tt:SetHeight(tt:GetHeight() - removed) end
end

local function ShowRowTooltip(row)
    local id = row.e and row.e.id
    if not id then return end
    local info = C_LFGList.GetSearchResultInfo(id)
    if not info then return end

    if LFGBrowseSearchEntryTooltip and LFGBrowseSearchEntryTooltip_UpdateAndShow
        and canaccessvalue(info.comment) then
        local tt = LFGBrowseSearchEntryTooltip
        LFGBrowseSearchEntryTooltip_UpdateAndShow(tt, id)
        tt:ClearAllPoints()
        tt:SetPoint("TOPLEFT", row, "TOPRIGHT", 8, 38)
        pcall(StripVoiceChat, tt)
        hoveredRow = row
        local ok, err = pcall(AnnotateItemLevels, tt)
        if not ok and debugTooltip then print("Better LFG iLvl error:", err) end
        return
    end

    -- Fallback when the data cannot be read: just the row's own (already guarded) text.
    local e = row.e
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(e.title, 1, 1, 1)
    if e.activity ~= "" then GameTooltip:AddLine(e.activity, 1, 0.82, 0) end
    GameTooltip:AddLine("Leader: " .. e.leader, 0.7, 0.7, 0.7)
    GameTooltip:Show()
end

---------------------------------------------------------------------------
-- Whisper actions and settings
---------------------------------------------------------------------------
local DEFAULT_WHISPER = "Hi! I'd like to join your group."
local WHISPER_COOLDOWN = 3
local lastWhisperAt = 0

local function GetWhisperText()
    local t = BetterLFGDB and BetterLFGDB.whisperText
    if type(t) ~= "string" then return DEFAULT_WHISPER end
    return t
end

-- The leader's name, read live from the listing; nil when it is gone or not readable
-- (in chat lockdown the client refuses whispers to a secret name anyway).
local function LeaderName(e)
    local info = e and C_LFGList.GetSearchResultInfo(e.id)
    local name = info and info.leaderName
    if not name or not canaccessvalue(name) then return nil end
    return name
end

-- Right click -> "Send message": opens the chat box with /w <leader>.
local function OpenWhisper(e)
    local name = LeaderName(e)
    if not name then
        print("|cffffd100Better LFG|r: the leader's name is not available right now.")
        return
    end
    if ChatFrameUtil and ChatFrameUtil.SendTell then
        ChatFrameUtil.SendTell(name)
    elseif ChatFrame_SendTell then
        ChatFrame_SendTell(name)
    end
end

-- Whisper button: sends the configured text to the leader.
function WhisperLeader(e)
    local name = LeaderName(e)
    if not name then
        print("|cffffd100Better LFG|r: the leader's name is not available right now.")
        return
    end
    local text = GetWhisperText()
    if text == "" then
        print("|cffffd100Better LFG|r: no whisper text set (gear button in the filter window).")
        return
    end
    if GetTime() - lastWhisperAt < WHISPER_COOLDOWN then return end
    lastWhisperAt = GetTime()
    if C_ChatInfo and C_ChatInfo.SendChatMessage then
        C_ChatInfo.SendChatMessage(text, "WHISPER", nil, name)
    else
        SendChatMessage(text, "WHISPER", nil, name)
    end
end

function ShowRowMenu(row)
    local e = row.e
    if not e or not MenuUtil then return end
    MenuUtil.CreateContextMenu(row, function(_, root)
        root:CreateTitle(e.leader or "")
        root:CreateButton("Send message", function() OpenWhisper(e) end)
    end)
end

-- Options -> AddOns -> BetterLFG (also opened by the gear in the filter window).
local settingsCategory
function BuildSettings()
    if settingsCategory or not Settings or not Settings.RegisterCanvasLayoutCategory then return end
    local f = CreateFrame("Frame")
    f.name = "Better LFG"

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Better LFG")

    local version = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    version:SetPoint("LEFT", title, "RIGHT", 8, -1)
    version:SetText("Version " .. VERSION)

    local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -24)
    label:SetText("Whisper message")

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -4)
    hint:SetText("Sent to the group leader when you click the speech bubble in the group list.")

    local edit = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    edit:SetSize(460, 22)
    edit:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 6, -8)
    edit:SetAutoFocus(false)
    edit:SetMaxLetters(255)
    edit:SetScript("OnTextChanged", function(self, userInput)
        if userInput then
            BetterLFGDB = BetterLFGDB or {}
            BetterLFGDB.whisperText = self:GetText()
        end
    end)
    edit:SetScript("OnEnterPressed", edit.ClearFocus)
    edit:SetScript("OnEscapePressed", edit.ClearFocus)

    local reset = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    reset:SetSize(120, 22)
    reset:SetPoint("LEFT", edit, "RIGHT", 10, 0)
    reset:SetText("Default text")
    reset:SetScript("OnClick", function()
        BetterLFGDB = BetterLFGDB or {}
        BetterLFGDB.whisperText = DEFAULT_WHISPER
        edit:SetText(DEFAULT_WHISPER)
    end)

    f:SetScript("OnShow", function() edit:SetText(GetWhisperText()) end)

    settingsCategory = Settings.RegisterCanvasLayoutCategory(f, "Better LFG")
    Settings.RegisterAddOnCategory(settingsCategory)
end

function OpenSettings()
    if InCombatLockdown() then
        print("|cffffd100Better LFG|r: settings cannot be opened in combat.")
        return
    end
    if settingsCategory then Settings.OpenToCategory(settingsCategory:GetID()) end
end

-- Answer requests, store answers, and redraw the hovered tooltip when an answer arrives.
local comm = CreateFrame("Frame")
comm:RegisterEvent("CHAT_MSG_ADDON")
comm:SetScript("OnEvent", function(_, _, prefix, message, channel, sender)
    if prefix ~= PREFIX or not sender then return end
    if not canaccessvalue(sender) or not canaccessvalue(message) then return end
    local who = ShortName(sender)
    if message == "REQ" then
        local il = MyItemLevel()
        if il then pcall(C_ChatInfo.SendAddonMessage, PREFIX, "ILVL:" .. il, "WHISPER", sender) end
        return
    end
    local il = tonumber(message:match("^ILVL:(%d+)$") or "")
    if il then
        ilvlCache[who] = { ilvl = il, t = GetTime() }
        if hoveredRow and hoveredRow:IsMouseOver() then ShowRowTooltip(hoveredRow) end
    end
end)

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------
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
        r.stripe = r:CreateTexture(nil, "BACKGROUND")
        r.stripe:SetAllPoints()
        r.stripe:SetColorTexture(1, 1, 1, 0.03)
    end

    -- Line 1: leader | average level | playstyle
    r.leader = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    r.leader:SetPoint("TOPLEFT", 8, -6)
    r.leader:SetWidth(150)
    r.leader:SetJustifyH("LEFT")
    r.leader:SetWordWrap(false)

    r.level = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.level:SetPoint("LEFT", r.leader, "RIGHT", 4, 0)
    r.level:SetWidth(46)
    r.level:SetJustifyH("LEFT")

    r.playstyle = r:CreateFontString(nil, "OVERLAY", "GameFontGreenSmall")
    r.playstyle:SetPoint("LEFT", r.level, "RIGHT", 4, 0)
    r.playstyle:SetPoint("RIGHT", r, "RIGHT", -(MAX_ROLE_ICONS * 20 + 38), 0)
    r.playstyle:SetJustifyH("LEFT")
    r.playstyle:SetWordWrap(false)

    -- Role icons, right to left: one per tank, healer and damage dealer.
    r.icons = {}
    for n = 1, MAX_ROLE_ICONS do
        local t = r:CreateTexture(nil, "ARTWORK")
        t:SetSize(18, 18)
        t:SetTexture(ROLE_ICONS)
        t:SetPoint("TOPRIGHT", r, "TOPRIGHT", -34 - (MAX_ROLE_ICONS - n) * 20, -5)
        r.icons[n] = t
    end


    -- Line 2: dungeon | group title
    r.activity = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    r.activity:SetPoint("BOTTOMLEFT", 8, 6)
    r.activity:SetWidth(170)
    r.activity:SetJustifyH("LEFT")
    r.activity:SetWordWrap(false)

    r.title = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    r.title:SetPoint("LEFT", r.activity, "RIGHT", 4, 0)
    r.title:SetPoint("RIGHT", r, "RIGHT", -8, 0)
    r.title:SetJustifyH("LEFT")
    r.title:SetWordWrap(false)

    -- Whisper button: sends the message from the settings to the group leader.
    r.whisper = CreateFrame("Button", nil, r)
    r.whisper:SetSize(18, 18)
    r.whisper:SetPoint("TOPRIGHT", r, "TOPRIGHT", -8, -5)
    r.whisper:SetNormalAtlas("transmog-icon-chat")
    r.whisper:SetHighlightAtlas("transmog-icon-chat", "ADD")
    r.whisper:SetScript("OnClick", function(self) WhisperLeader(self:GetParent().e) end)
    r.whisper:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Whisper the leader", 1, 1, 1)
        GameTooltip:AddLine(GetWhisperText(), 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("Change the text in the settings (gear in the filter window).", 0.5, 0.5, 0.5, true)
        GameTooltip:Show()
    end)
    r.whisper:SetScript("OnLeave", GameTooltip_Hide)

    -- Right click: context menu.
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r:SetScript("OnClick", function(self, button)
        if button == "RightButton" then ShowRowMenu(self) end
    end)

    r:SetScript("OnEnter", function(self) ShowRowTooltip(self) end)
    r:SetScript("OnLeave", HideRowTooltip)
    rows[i] = r
    return r
end

-- Sorting: nil = server order, "level" = average level, "members" = number of members.
local sortKey, sortDesc = "members", true   -- default: most members first
local headers = {}

local function SortValue(e)
    if sortKey == "level" then return e.avgLevel or 0 end
    return e.numMembers or 0
end

local function UpdateHeaders()
    for key, h in pairs(headers) do
        if key == sortKey then
            if sortDesc then
                h.arrow:SetTexCoord(0, 0.5625, 0, 1)
            else
                h.arrow:SetTexCoord(0, 0.5625, 1, 0)
            end
            h.arrow:Show()
        else
            h.arrow:Hide()
        end
    end
end

function Render()
    for _, r in ipairs(rows) do r:Hide() end
    local list = {}
    -- Solo listings (players looking for a group) are not listed; they are summed up by role.
    local solo = { players = 0, TANK = 0, HEALER = 0, DAMAGER = 0, classes = {} }
    for i, e in ipairs(results) do
        if e.isSolo then
            local live = C_LFGList.GetSearchResultInfo(e.id)
            local delisted = (not live) or Readable(live.isDelisted, false) == true
            if not delisted and MatchesActivity(e) then
                solo.players = solo.players + 1
                if e.soloClass then
                    solo.classes[e.soloClass] = (solo.classes[e.soloClass] or 0) + 1
                end
                local roles = e.soloRoles
                if roles then
                    if Readable(roles.tank, false) == true then solo.TANK = solo.TANK + 1 end
                    if Readable(roles.healer, false) == true then solo.HEALER = solo.HEALER + 1 end
                    if Readable(roles.dps, false) == true then solo.DAMAGER = solo.DAMAGER + 1 end
                end
            end
        elseif Matches(e) then
            e.order = i
            table.insert(list, e)
        end
    end
    if sortKey then
        table.sort(list, function(a, b)
            local va, vb = SortValue(a), SortValue(b)
            if va ~= vb then
                if sortDesc then return va > vb end
                return va < vb
            end
            return a.order < b.order
        end)
    end
    UpdateHeaders()
    local shown = 0
    for _, e in ipairs(list) do
        do
            shown = shown + 1
            local r = GetRow(shown)
            r.e = e
            r.leader:SetText(e.leader)
            if e.color then
                r.leader:SetTextColor(e.color.r, e.color.g, e.color.b)
            else
                r.leader:SetTextColor(1, 0.82, 0)
            end
            r.level:SetText(e.avgLevel and ("Ø " .. e.avgLevel) or "")
            r.playstyle:SetText(e.playstyle)
            -- Delisted since the search: keep the row, but faded and marked.
            local live = C_LFGList.GetSearchResultInfo(e.id)
            local delisted = (not live) or Readable(live.isDelisted, false) == true
            r:SetAlpha(delisted and 0.4 or 1)
            r.whisper:SetEnabled(not delisted)
            r.whisper:GetNormalTexture():SetDesaturated(delisted)
            if delisted then r.playstyle:SetText("|cffcc6666Delisted|r") end
            local n = 0
            for _, key in ipairs({ "TANK", "HEALER", "DAMAGER" }) do
                local have = e.counts and Readable(e.counts[key], nil) or 0
                for _ = 1, have do
                    if n < MAX_ROLE_ICONS then
                        n = n + 1
                        r.icons[n]:SetTexCoord(unpack(ROLE_COORDS[key]))
                        r.icons[n]:SetDesaturated(delisted)
                        r.icons[n]:Show()
                    end
                end
            end
            for k = n + 1, MAX_ROLE_ICONS do r.icons[k]:Hide() end
            r.activity:SetText(e.activity)
            r.title:SetText(e.title)
            r:Show()
        end
    end
    content:SetHeight(math.max(1, shown * ROW_HEIGHT))
    if countText then
        countText:SetText(search.running and "" or (shown == 1 and "1 group" or (shown .. " groups")))
    end
    if soloClassText then
        soloClassCounts = solo.classes
        if search.running then
            soloClassText:SetText("")
        else
            local parts = {}
            for _, cls in ipairs(ClassOrder(solo.classes)) do
                local icon = ClassMarkup(cls)
                if icon then
                    local n = solo.classes[cls] or 0
                    table.insert(parts, icon .. (n > 0 and (" |cffffffff" .. n .. "|r") or " |cff6060600|r"))
                end
            end
            soloClassText:SetText(table.concat(parts, "   "))
        end
    end
    if soloText then
        if search.running then
            soloText:SetText("")
        else
            soloText:SetFormattedText("Solo players: |cffffffff%d|r     %s |cffffffff%d|r    %s |cffffffff%d|r    %s |cffffffff%d|r",
                solo.players, ROLE_MARKUP.TANK, solo.TANK, ROLE_MARKUP.HEALER, solo.HEALER,
                ROLE_MARKUP.DAMAGER, solo.DAMAGER)
        end
    end
    -- Empty-state message in the middle of the list.
    if shown > 0 then
        status:SetText("")
    elseif search.running then
        status:SetText("Searching...")
    elseif #results == 0 then
        status:SetText("No open groups found.")
    else
        status:SetText("No groups match your filters.")
    end
    -- The players tab shows the same search results.
    if NS.RenderPlayers then NS.RenderPlayers() end
end

---------------------------------------------------------------------------
-- Search (all categories, one after the other)
---------------------------------------------------------------------------
local function FinishSearch()
    search.running = false
    search.token = search.token + 1
    Render()
end

local function AverageLevel(id, numMembers, leaderInfo)
    local sum, n = 0, 0
    for i = 1, math.min(numMembers or 0, MAX_MEMBERS_SCANNED) do
        local m = C_LFGList.GetSearchResultPlayerInfo(id, i)
        local lvl = m and Readable(m.level, nil)
        if type(lvl) == "number" then sum = sum + lvl; n = n + 1 end
    end
    if n > 0 then return math.floor(sum / n + 0.5) end
    local lead = leaderInfo and Readable(leaderInfo.level, nil)
    if type(lead) == "number" then return lead end
    return nil
end

local function Collect()
    local ids = C_LFGList.GetSearchResults()
    -- Some builds return (count, ids), others just ids.
    if type(ids) ~= "table" then
        local _, second = C_LFGList.GetSearchResults()
        ids = second
    end
    for _, id in ipairs(ids or {}) do
        local info = C_LFGList.GetSearchResultInfo(id)
        if info and Readable(info.isDelisted, false) ~= true and not (search.seen and search.seen[id]) then
            if search.seen then search.seen[id] = true end
            local actIDs = Readable(info.activityIDs, nil) or {}
            local activity = ""
            if actIDs[1] and C_LFGList.GetActivityInfoTable then
                local a = C_LFGList.GetActivityInfoTable(actIDs[1])
                if a then activity = a.fullName or a.shortName or "" end
            end
            local numMembers = Readable(info.numMembers, nil)
            -- A solo listing: read the roles the player signed up for (bools, see LFGForever).
            local isSolo = numMembers == 1
            local soloRoles, soloClass, soloLevel, soloArea
            if isSolo then
                local m = C_LFGList.GetSearchResultPlayerInfo(id, 1)
                soloRoles = m and Readable(m.lfgRoles, nil)
                soloClass = m and Readable(m.classFilename, nil)
                soloLevel = m and Readable(m.level, nil)
                soloArea = m and Readable(m.areaName, nil)
            end
            local leaderInfo = C_LFGList.GetSearchResultLeaderInfo and C_LFGList.GetSearchResultLeaderInfo(id)
            local classFile = leaderInfo and Readable(leaderInfo.classFilename, nil)
            local color = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] or nil
            local ps = Readable(info.generalPlaystyle, nil)
            local playstyle = ""
            if ps ~= nil and GetGeneralPlaystyleString then
                playstyle = GetGeneralPlaystyleString(ps) or ""
            end
            table.insert(results, {
                id = id,
                title = Readable(info.name, "(hidden)"),
                activity = activity,
                activityIDs = actIDs,
                leader = Readable(info.leaderName, "(hidden)"),                color = color,
                avgLevel = AverageLevel(id, numMembers, leaderInfo),
                playstyle = playstyle,
                playstyleValue = type(ps) == "number" and ps or nil,
                isSolo = isSolo,
                soloRoles = soloRoles,
                soloClass = soloClass,
                soloLevel = type(soloLevel) == "number" and soloLevel or nil,
                soloArea = soloArea,
                comment = Readable(info.comment, nil),
                numMembers = type(numMembers) == "number" and numMembers or nil,
                members = numMembers and tostring(numMembers) or "",
                counts = Readable(C_LFGList.GetSearchResultMemberCounts(id), nil),
            })
        end
    end
end

-- C_LFGList.Search only works when called directly from a click (hardware event); a call
-- from a timer is silently dropped. So every search is ONE synchronous call inside the
-- click handler (tab, Refresh, Search), for the Dungeons category, narrowed server-side
-- to the dungeons the applied filters allow.
local debugSearch = false
local function dprint(...)
    if debugSearch then print("|cff88ccffOG|r", ...) end
end

-- `f` is a filter table with .ids / .levelOnly (the groups tab's or the players tab's).
local function SearchActivities(f)
    local list = {}
    if f.ids then
        for id in pairs(f.ids) do table.insert(list, id) end
    else
        for _, id in ipairs(C_LFGList.GetAvailableActivities(DUNGEON_CATEGORY) or {}) do
            if not f.levelOnly or IsInMyLevelRange(id) then table.insert(list, id) end
        end
    end
    return list
end

local function Refresh(f)
    -- One search at a time; a search that has hung for a long time may be restarted.
    if search.running and GetTime() - (search.startedAt or 0) < SEARCH_TIMEOUT then return end
    wipe(results)
    search.seen = {}
    local activities = SearchActivities(type(f) == "table" and f or filters)
    if #activities == 0 then
        dprint("No dungeons to search for")
        search.running = false
        Render()
        return
    end
    search.running = true
    search.startedAt = GetTime()
    search.awaiting = true
    local token = search.token + 1
    search.token = token
    Render()

    local ok, err = pcall(C_LFGList.Search, DUNGEON_CATEGORY, 0, 0, nil, false, nil, activities)
    if not ok then
        dprint("Search error:", err)
        search.awaiting = nil
        return FinishSearch()
    end
    dprint("Search started:", #activities, "dungeons")
    if search.token ~= token then return end   -- answer already arrived during the call

    C_Timer.After(SEARCH_TIMEOUT, function()
        if search.running and search.token == token then
            dprint("Timeout, no answer from the server")
            search.awaiting = nil
            FinishSearch()
        end
    end)
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("LFG_LIST_SEARCH_RESULTS_RECEIVED")
ev:RegisterEvent("LFG_LIST_SEARCH_FAILED")
ev:RegisterEvent("LFG_LIST_SEARCH_RESULT_UPDATED")
local renderQueued = false
ev:SetScript("OnEvent", function(_, event)
    -- A listing changed (e.g. was delisted): redraw once, coalescing bursts of updates.
    if event == "LFG_LIST_SEARCH_RESULT_UPDATED" then
        local function AnyShown()
            return (panel and panel:IsShown()) or (NS.playersPanel and NS.playersPanel:IsShown())
        end
        if not renderQueued and AnyShown() and not search.running then
            renderQueued = true
            C_Timer.After(0.2, function()
                renderQueued = false
                if AnyShown() then Render() end   -- Render also redraws the players tab
            end)
        end
        return
    end
    dprint("Event", event, "awaiting:", tostring(search.awaiting))
    if not search.running or not search.awaiting then return end
    search.awaiting = nil
    if event == "LFG_LIST_SEARCH_RESULTS_RECEIVED" then Collect() end
    FinishSearch()
end)

---------------------------------------------------------------------------
-- Filter window (to the right of the main window)
---------------------------------------------------------------------------
-- Dungeons for the dropdown, one entry per name (several activity IDs can share a name).
local function ActivityChoices(levelOnly)
    local list, byName = {}, {}
    for _, cat in ipairs(C_LFGList.GetAvailableCategories() or {}) do
        for _, id in ipairs(C_LFGList.GetAvailableActivities(cat) or {}) do
            local a = C_LFGList.GetActivityInfoTable(id)
            local name = a and (a.fullName or a.shortName)
            -- The dropdown is for dungeons only; the checkbox narrows it to my level.
            if name and IsDungeon(id, a) and (not levelOnly or IsInMyLevelRange(id)) then
                local c = byName[name]
                if not c then
                    c = { name = name, text = name, ids = {}, minLevel = a.minLevelSuggestion or 0 }
                    local lv = LevelText(a)
                    if lv ~= "" then c.text = name .. " " .. lv end
                    byName[name] = c
                    table.insert(list, c)
                end
                table.insert(c.ids, id)
            end
        end
    end
    table.sort(list, function(a, b)
        if a.minLevel ~= b.minLevel then return a.minLevel < b.minLevel end
        return a.name < b.name
    end)
    return list
end

local function SelectedCount()
    local n = 0
    for _ in pairs(pending.names) do n = n + 1 end
    return n
end

local function BuildFilterWindow()
    local psDropdown, UpdatePlaystyleText
    -- Same bronze frame chrome as the Group Finder window (Blizzard's own templates).
    local ok = pcall(function()
        filterWin = CreateFrame("Frame", "BetterLFGFilterFrame", panel, "ButtonFrameTemplate")
    end)
    if ok and filterWin then
        if ButtonFrameTemplate_HidePortrait then ButtonFrameTemplate_HidePortrait(filterWin) end
        if filterWin.CloseButton then filterWin.CloseButton:Hide() end
        if filterWin.Inset then filterWin.Inset:Hide() end
    else
        filterWin = CreateFrame("Frame", "BetterLFGFilterFrame", panel, "PortraitFrameTemplateNoCloseButton")
    end
    filterWin:SetWidth(330)
    filterWin:SetPoint("TOPLEFT", parent, "TOPRIGHT", 48, 0)
    filterWin:SetPoint("BOTTOMLEFT", parent, "BOTTOMRIGHT", 48, 0)
    filterWin:EnableMouse(true)
    pcall(filterWin.SetTitle, filterWin, "Filters")
    -- Same dark inset as the main window's list area (created first so it sits behind the controls).
    local fInset = CreateFrame("Frame", nil, filterWin, "InsetFrameTemplate")
    fInset:SetPoint("TOPLEFT", filterWin, "TOPLEFT", 8, -28)
    fInset:SetPoint("BOTTOMRIGHT", filterWin, "BOTTOMRIGHT", -6, 8)

    -- Dungeon dropdown (multi-select)
    local dungeonLabel = filterWin:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dungeonLabel:SetPoint("TOPLEFT", filterWin, "TOPLEFT", 22, -44)
    dungeonLabel:SetText("Dungeon")

    local dropdown = CreateFrame("DropdownButton", nil, filterWin, "WowStyle1DropdownTemplate")
    dropdown:SetWidth(270)
    dropdown:SetPoint("TOPLEFT", dungeonLabel, "BOTTOMLEFT", 0, -6)

    local function UpdateDropdownText()
        local n = SelectedCount()
        if n == 0 then
            dropdown:SetDefaultText("All dungeons")
        elseif n == 1 then
            dropdown:SetDefaultText(next(pending.names))
        else
            dropdown:SetDefaultText(n .. " dungeons selected")
        end
    end
    UpdateDropdownText()

    dropdown:SetupMenu(function(_, root)
        pcall(root.SetScrollMode, root, 320)
        root:CreateButton("Clear selection", function()
            wipe(pending.names)
            UpdateDropdownText()
            dropdown:GenerateMenu()
        end)
        for _, c in ipairs(ActivityChoices(pending.levelOnly)) do
            root:CreateCheckbox(c.text,
                function() return pending.names[c.name] == true end,
                function()
                    pending.names[c.name] = (not pending.names[c.name]) or nil
                    UpdateDropdownText()
                end)
        end
    end)

    local levelCheck = CreateFrame("CheckButton", nil, filterWin, "UICheckButtonTemplate")
    levelCheck:SetPoint("TOPLEFT", dropdown, "BOTTOMLEFT", -4, -2)
    levelCheck.Text:SetText("Only dungeons for my level")
    levelCheck:SetChecked(pending.levelOnly)
    levelCheck:SetScript("OnClick", function(self)
        pending.levelOnly = self:GetChecked() and true or false
    end)

    -- Playstyle dropdown (multi-select; all ticked = no filter, untick to hide a playstyle)
    local psLabel = filterWin:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    psLabel:SetPoint("TOPLEFT", levelCheck, "BOTTOMLEFT", 4, -14)
    psLabel:SetText("Playstyle")

    psDropdown = CreateFrame("DropdownButton", nil, filterWin, "WowStyle1DropdownTemplate")
    psDropdown:SetWidth(270)
    psDropdown:SetPoint("TOPLEFT", psLabel, "BOTTOMLEFT", 0, -6)

    UpdatePlaystyleText = function()
        local shown, names = 0, {}
        for _, p in ipairs(PLAYSTYLES) do
            if not pending.hiddenPlaystyles[p.key] then
                shown = shown + 1
                table.insert(names, p.label)
            end
        end
        if shown == #PLAYSTYLES then
            psDropdown:SetDefaultText("All playstyles")
        elseif shown == 0 then
            psDropdown:SetDefaultText("No playstyle")
        else
            psDropdown:SetDefaultText(table.concat(names, ", "))
        end
    end
    UpdatePlaystyleText()

    psDropdown:SetupMenu(function(_, root)
        for _, p in ipairs(PLAYSTYLES) do
            root:CreateCheckbox(p.label,
                function() return not pending.hiddenPlaystyles[p.key] end,
                function()
                    pending.hiddenPlaystyles[p.key] = (not pending.hiddenPlaystyles[p.key]) or nil
                    UpdatePlaystyleText()
                end)
        end
    end)

    -- Role / member ranges
    local roleHeader = filterWin:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    roleHeader:SetPoint("TOPLEFT", psDropdown, "BOTTOMLEFT", 0, -22)
    roleHeader:SetText("Find groups by role")

    -- One row per range: [x] [icon] Label ....... [from] to [to]
    local rowsUI = {}
    local defs = {
        { field = "members", label = "Members .........." },
        { field = "tank",    label = "Tanks ............", role = "TANK" },
        { field = "healer",  label = "Heals ............", role = "HEALER" },
        { field = "damage",  label = "DPS ..............", role = "DAMAGER" },
    }

    local function MakeBox(parentFrame, field, bound)
        local box = CreateFrame("EditBox", nil, parentFrame, "InputBoxTemplate")
        box:SetSize(38, 20)
        box:SetAutoFocus(false)
        box:SetNumeric(true)
        box:SetMaxLetters(2)
        box:SetJustifyH("CENTER")
        box:SetScript("OnTextChanged", function(self)
            local text = self:GetText()
            pending[field][bound] = text ~= "" and tonumber(text) or nil
        end)
        box:SetScript("OnEnterPressed", box.ClearFocus)
        box:SetScript("OnEscapePressed", box.ClearFocus)
        return box
    end

    local anchor, offsetY = roleHeader, -8
    for _, d in ipairs(defs) do
        local row = CreateFrame("Frame", nil, filterWin)
        row:SetSize(280, 26)
        row:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", anchor == roleHeader and -2 or 0, offsetY)

        local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        cb:SetSize(26, 26)
        cb:SetPoint("LEFT", 0, 0)
        cb:SetScript("OnClick", function(self)
            pending[d.field].on = self:GetChecked() and true or false
        end)

        local labelAnchor = cb
        if d.role then
            local icon = row:CreateTexture(nil, "ARTWORK")
            icon:SetSize(18, 18)
            icon:SetTexture(ROLE_ICONS)
            icon:SetTexCoord(unpack(ROLE_COORDS[d.role]))
            icon:SetPoint("LEFT", cb, "RIGHT", 2, 0)
            labelAnchor = icon
        end
        local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("LEFT", labelAnchor, "RIGHT", 4, 0)
        text:SetWidth(d.role and 84 or 102)
        text:SetJustifyH("LEFT")
        text:SetText(d.label)

        local from = MakeBox(row, d.field, "min")
        from:SetPoint("LEFT", text, "RIGHT", 8, 0)
        local to = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        to:SetPoint("LEFT", from, "RIGHT", 6, 0)
        to:SetText("to")
        local upper = MakeBox(row, d.field, "max")
        upper:SetPoint("LEFT", to, "RIGHT", 8, 0)

        rowsUI[d.field] = { cb = cb, from = from, to = upper }
        anchor, offsetY = row, -2
    end

    -- Show the restored values (LoadRoles ran before this window was built).
    for field, ui in pairs(rowsUI) do
        local p = pending[field]
        ui.cb:SetChecked(p.on)
        ui.from:SetText(p.min and tostring(p.min) or "")
        ui.to:SetText(p.max and tostring(p.max) or "")
    end

    -- Bottom bar: [Reset] [gear] ................ [Search]
    local function ApplyFilters()
        for _, k in ipairs(RANGE_KEYS) do
            local p = pending[k]
            filters[k] = { on = p.on, min = p.min, max = p.max }
        end
        filters.levelOnly = pending.levelOnly
        filters.hiddenPlaystyles = CopySet(pending.hiddenPlaystyles)
        filters.ids = nil
        if next(pending.names) then
            filters.ids = {}
            for _, c in ipairs(ActivityChoices(false)) do
                if pending.names[c.name] then
                    for _, id in ipairs(c.ids) do filters.ids[id] = true end
                end
            end
        end
    end

    local searchBtn = CreateFrame("Button", nil, filterWin, "UIPanelButtonTemplate")
    searchBtn:SetSize(100, 24)
    searchBtn:SetPoint("BOTTOMRIGHT", -16, 14)
    searchBtn:SetText("Search")
    searchBtn:SetScript("OnClick", function()
        for _, ui in pairs(rowsUI) do
            ui.from:ClearFocus()
            ui.to:ClearFocus()
        end
        ApplyFilters()
        SaveRoles()
        Render()
        Refresh()
    end)

    -- Resets every filter except the dungeon selection.
    local resetBtn = CreateFrame("Button", nil, filterWin, "UIPanelButtonTemplate")
    resetBtn:SetSize(100, 24)
    resetBtn:SetPoint("BOTTOMLEFT", 16, 14)
    resetBtn:SetText("Reset filters")
    resetBtn:SetScript("OnClick", function()
        ResetRanges(pending)
        ResetRanges(filters)
        wipe(pending.hiddenPlaystyles)
        wipe(filters.hiddenPlaystyles)
        UpdatePlaystyleText()
        for _, ui in pairs(rowsUI) do
            ui.cb:SetChecked(false)
            ui.from:SetText("")
            ui.to:SetText("")
        end
        SaveRoles()
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
    gear:SetScript("OnClick", function()
        OpenSettings()
    end)
end

---------------------------------------------------------------------------
-- Main panel and tab
---------------------------------------------------------------------------
local function ClosePanel()
    if panel then panel:Hide() end
end

local function BuildPanel()
    panel = CreateFrame("Frame", "BetterLFGPanel", parent, "PortraitFrameTemplateNoCloseButton")
    panel:SetAllPoints(parent)
    -- High enough to cover everything of the other tabs (e.g. the Who List search box).
    panel:SetFrameLevel(parent:GetFrameLevel() + 500)
    panel:EnableMouse(true)
    panel:Hide()

    if panel.SetTitle then panel:SetTitle(TITLE) end
    if panel.PortraitContainer and panel.PortraitContainer.portrait then
        panel.PortraitContainer.portrait:SetTexture(ICON)
    elseif panel.SetPortraitToAsset then
        panel:SetPortraitToAsset(ICON)
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

    -- Column headers, aligned with the row columns. "Ø Level" and "Members" sort on click
    -- (first click: highest first, second click: lowest first).
    local function MakeHeader(text, key, tooltip, x, alignRight)
        local h = CreateFrame("Button", nil, inset)
        h:SetHeight(18)
        h.text = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h.text:SetText(text)
        h:SetWidth(h.text:GetStringWidth() + 14)
        h.arrow = h:CreateTexture(nil, "OVERLAY")
        h.arrow:SetSize(9, 8)
        h.arrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
        h.arrow:Hide()
        if alignRight then
            h:SetPoint("TOPRIGHT", inset, "TOPRIGHT", x, -6)
            h.text:SetPoint("RIGHT", 0, 0)
            h.arrow:SetPoint("RIGHT", h.text, "LEFT", -3, 0)
        else
            h:SetPoint("TOPLEFT", inset, "TOPLEFT", x, -6)
            h.text:SetPoint("LEFT", 0, 0)
            h.arrow:SetPoint("LEFT", h.text, "RIGHT", 3, 0)
        end
        if key then
            h:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2", "ADD")
            h:GetHighlightTexture():SetAlpha(0.3)
            h:SetScript("OnClick", function()
                if sortKey == key then
                    sortDesc = not sortDesc
                else
                    sortKey, sortDesc = key, true
                end
                Render()
            end)
            headers[key] = h
        end
        if tooltip then
            h:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetText(tooltip, 1, 1, 1, 1, true)
                GameTooltip:Show()
            end)
            h:SetScript("OnLeave", GameTooltip_Hide)
        end
        return h
    end
    MakeHeader("Leader", nil, nil, 14)
    MakeHeader("Ø Level", "level", "Average level of all group members.\nClick to sort.", 168)
    MakeHeader("Playstyle", nil, nil, 218)
    MakeHeader("Members", "members", "Members by role.\nClick to sort by number of members.", -60, true)

    local divider = inset:CreateTexture(nil, "ARTWORK")
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", inset, "TOPLEFT", 8, -26)
    divider:SetPoint("TOPRIGHT", inset, "TOPRIGHT", -8, -26)
    divider:SetColorTexture(1, 0.82, 0, 0.25)

    -- Own item level, top left next to the portrait; hover for the per-slot list.
    local myIlvl = CreateFrame("Button", nil, panel)
    myIlvl:SetSize(160, 20)
    myIlvl:SetPoint("BOTTOMLEFT", inset, "TOPLEFT", 54, 4)
    myIlvl.text = myIlvl:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    myIlvl.text:SetPoint("LEFT", 0, 0)
    local function UpdateMyIlvl()
        local il = MyItemLevel()
        myIlvl.text:SetText("Your iLvl: |cffffffff" .. (il and tostring(il) or "?") .. "|r")
        myIlvl:SetWidth(myIlvl.text:GetStringWidth() + 4)
    end
    myIlvl:SetScript("OnEnter", function(self) ShowMyGearTooltip(self) end)
    myIlvl:SetScript("OnLeave", GameTooltip_Hide)
    myIlvl:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    myIlvl:SetScript("OnEvent", UpdateMyIlvl)
    myIlvl:SetScript("OnShow", UpdateMyIlvl)
    UpdateMyIlvl()

    -- Display only (searching happens via the filter window's Search button).
    countText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    countText:SetPoint("BOTTOMRIGHT", inset, "TOPRIGHT", -6, 6)

    scroll = CreateFrame("ScrollFrame", "BetterLFGScroll", inset, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 6, -28)
    scroll:SetPoint("BOTTOMRIGHT", -26, 56)

    -- Summary bar: solo players looking for a group, by the roles they signed up for.
    local soloBar = CreateFrame("Frame", nil, inset)
    soloBar:SetPoint("BOTTOMLEFT", inset, "BOTTOMLEFT", 6, 4)
    soloBar:SetPoint("BOTTOMRIGHT", inset, "BOTTOMRIGHT", -6, 4)
    soloBar:SetHeight(48)
    local soloLine = soloBar:CreateTexture(nil, "ARTWORK")
    soloLine:SetHeight(1)
    soloLine:SetPoint("TOPLEFT", 2, 0)
    soloLine:SetPoint("TOPRIGHT", -2, 0)
    soloLine:SetColorTexture(1, 0.82, 0, 0.25)
    soloText = soloBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    soloText:SetPoint("TOPLEFT", 8, -7)
    -- Second row: solo players per class.
    soloClassText = soloBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    soloClassText:SetPoint("TOPLEFT", soloText, "BOTTOMLEFT", 0, -6)
    soloBar:EnableMouse(true)
    soloBar:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Solo players", 1, 1, 1)
        GameTooltip:AddLine("Players listed on their own to be invited, for the dungeons in your filter.", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("A player who signed up for several roles counts once for each role.", 0.8, 0.8, 0.8, true)
        local any = false
        for _, cls in ipairs(ClassOrder(soloClassCounts)) do
            local n = soloClassCounts[cls]
            if n and n > 0 then
                if not any then GameTooltip:AddLine(" "); any = true end
                local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[cls]
                GameTooltip:AddDoubleLine((ClassMarkup(cls) or "") .. " " .. ClassName(cls), tostring(n),
                    color and color.r or 1, color and color.g or 1, color and color.b or 1, 1, 1, 1)
            end
        end
        GameTooltip:Show()
    end)
    soloBar:SetScript("OnLeave", GameTooltip_Hide)
    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(10, 1)
    scroll:SetScrollChild(content)
    scroll:SetScript("OnSizeChanged", function(_, w) content:SetWidth(w) end)

    BuildFilterWindow()

    -- Other tabs' widgets (e.g. the Who List search box) can sit in a higher strata than
    -- their window; frame level only matters within one strata. So take the highest
    -- strata found among the window's visible frames and use it, with a very high level.
    panel:SetScript("OnShow", function()
        -- Only one of our tabs at a time.
        if NS.playersPanel then NS.playersPanel:Hide() end
        NS.RaiseAbove(panel)
        tab:SetChecked(true)
        Refresh()
    end)
    panel:SetScript("OnHide", function() tab:SetChecked(false) end)
    parent:HookScript("OnHide", ClosePanel)
end

-- Other tabs' widgets (e.g. the Who List search box) can sit in a higher strata than
-- their window; frame level only matters within one strata. So take the highest strata
-- found among the window's visible frames and use it, with a very high level.
local STRATA = { "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG", "FULLSCREEN", "FULLSCREEN_DIALOG", "TOOLTIP" }
local STRATA_RANK = {}
for i, name in ipairs(STRATA) do STRATA_RANK[name] = i end
function NS.RaiseAbove(frame)
    local function Highest(f, depth, best)
        for _, child in ipairs({ f:GetChildren() }) do
            if child ~= frame and child ~= tab and child ~= NS.playersTab and child:IsShown() then
                local r = STRATA_RANK[child:GetFrameStrata()] or 1
                if r > best then best = r end
                if depth > 0 then best = Highest(child, depth - 1, best) end
            end
        end
        return best
    end
    local best = Highest(parent, 4, STRATA_RANK[parent:GetFrameStrata()] or 1)
    -- Never into TOOLTIP, so tooltips and menus stay on top of us.
    best = math.min(best, STRATA_RANK.FULLSCREEN_DIALOG)
    frame:SetFrameStrata(STRATA[best])
    frame:SetFrameLevel(parent:GetFrameLevel() + 500)
end

local function BuildTab()
    tab = CreateFrame("Frame", TAB_NAME, parent, "LargeSideTabButtonTemplate")
    tab.Icon:SetTexture(ICON)
    tab.Icon:SetSize(30, 30)
    tab:SetFillToInterior(true)
    -- Below Blizzard's last side tab - or below another addon's tab that took that spot
    -- (LFGForever anchors its tab exactly there). Re-checked whenever the window opens,
    -- because that addon may build its tab after us.
    local function AnchorTab()
        local above = _G.LFGForeverBlizzardTab or parent.WhoListingTab
        tab:ClearAllPoints()
        if above then
            tab:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -2)
        else
            tab:SetPoint("TOPLEFT", parent, "TOPRIGHT", 0, -330)
        end
    end
    AnchorTab()
    parent:HookScript("OnShow", AnchorTab)
    tab:SetChecked(false)
    tab.tooltipText = TITLE
    tab:SetCustomOnMouseUpHandler(function(_, button, upInside)
        if button == "LeftButton" and upInside then
            if panel:IsShown() then panel:Hide() else panel:Show() end
        end
    end)
end

-- Clicking one of Blizzard's own side tabs must bring their panel back.
local function HookBlizzardTabs()
    for _, child in ipairs({ parent:GetChildren() }) do
        if child ~= tab and child.Icon and child.SetCustomOnMouseUpHandler then
            child:HookScript("OnMouseUp", function() ClosePanel() end)
        end
    end
end

-- Shared with Players.lua (the "Find Players" tab).
NS.Readable = Readable
NS.results = results
NS.search = search
NS.Refresh = Refresh
NS.ShowRowTooltip = ShowRowTooltip
NS.HideRowTooltip = HideRowTooltip
NS.OpenWhisper = OpenWhisper
NS.LeaderName = LeaderName
NS.OpenSettings = function() OpenSettings() end
NS.ActivityChoices = ActivityChoices
NS.IsInMyLevelRange = IsInMyLevelRange
NS.ROLE_ICONS = ROLE_ICONS
NS.ROLE_COORDS = ROLE_COORDS
NS.ClassMarkup = ClassMarkup
NS.ClassOrder = ClassOrder
NS.ClassName = ClassName

-- Wait for our own saved variables first, then for the Group Finder.
EventUtil.ContinueOnAddOnLoaded(ADDON, function()
    BetterLFGDB = BetterLFGDB or {}
    LoadRoles()
    BuildSettings()
    if NS.LoadPlayerFilters then NS.LoadPlayerFilters() end
    EventUtil.ContinueOnAddOnLoaded("Blizzard_GroupFinder_VanillaStyle", function()
        parent = _G.LFGParentFrame
        if not parent or tab then return end
        BuildTab()
        BuildPanel()
        HookBlizzardTabs()
        NS.parent, NS.groupsPanel, NS.groupsTab = parent, panel, tab
        if NS.BuildPlayers then NS.BuildPlayers() end
    end)
end)

-- Debug: /blfg levels  -> prints the level data of every activity (to check the level filter).
SLASH_BETTERLFG1 = "/blfg"
SlashCmdList.BETTERLFG = function(msg)
    if msg == "search" then
        debugSearch = not debugSearch
        print("Better LFG search debug:", debugSearch and "on (click Refresh)" or "off")
        return
    end
    if msg == "tooltip" then
        debugTooltip = not debugTooltip
        print("Better LFG tooltip debug:", debugTooltip and "on (hover a row)" or "off")
        return
    end
    if msg == "focus" then
        -- Hover a widget, then run this: prints the frame under the mouse and its parents.
        local f = GetMouseFoci and GetMouseFoci()[1] or GetMouseFocus()
        for _ = 1, 8 do
            if not f then break end
            print(f:GetName() or "<anonymous>", f:GetObjectType(), f:GetFrameStrata(), f:GetFrameLevel())
            f = f:GetParent()
        end
        return
    end
    if msg ~= "levels" then
        print("|cffffd100Better LFG|r " .. VERSION .. ": /blfg levels | /blfg focus | /blfg search | /blfg tooltip")
        return
    end
    print("Player level:", UnitLevel("player"))
    for _, cat in ipairs(C_LFGList.GetAvailableCategories() or {}) do
        for _, id in ipairs(C_LFGList.GetAvailableActivities(cat) or {}) do
            local a = C_LFGList.GetActivityInfoTable(id)
            if a then
                print(string.format("[cat %s] %s | sugg %s-%s | hard %s-%s | inRange=%s", tostring(cat), a.fullName or "?",
                    tostring(a.minLevelSuggestion), tostring(a.maxLevelSuggestion),
                    tostring(a.minLevel), tostring(a.maxLevel), tostring(IsInMyLevelRange(id))))
            end
        end
    end
end
