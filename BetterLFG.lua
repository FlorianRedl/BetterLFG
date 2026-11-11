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
local spinner
local soloClassCounts = {}
-- Forward declarations (defined further down).
local Render, WhisperLeader, ShowRowMenu, BuildSettings, OpenSettings
local rows = {}
local results = {}
local search = { queue = {}, running = false, token = 0 }

-- Filter state
-- "Find groups by role": five checkboxes (all off = no constraint), ANDed together.
--   tankAvailable / healerAvailable / damageAvailable: the group is SHORT of that role
--   hasTank / hasHealer:                                the group already has it
-- `enough` is a full dungeon party: 1 tank, 1 healer, 3 damage dealers.
local ROLE_CRITERIA = {
    { field = "tankAvailable",   counts = "TANK",    enough = 1, covered = false },
    { field = "healerAvailable", counts = "HEALER",  enough = 1, covered = false },
    { field = "damageAvailable", counts = "DAMAGER", enough = 3, covered = false },
    { field = "hasTank",         counts = "TANK",    enough = 1, covered = true },
    { field = "hasHealer",       counts = "HEALER",  enough = 1, covered = true },
}
-- `pending` is what the filter window shows; `filters` is what the list uses.
-- The Search button copies pending -> filters.
-- hiddenGroupClasses: "No groups with..." - hide groups that contain one of these classes.
local function ResetRanges(state)
    state.roles = {}
    for _, c in ipairs(ROLE_CRITERIA) do state.roles[c.field] = false end
    state.hiddenGroupClasses = {}
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
    BetterLFGDB.groupRoles = CopySet(filters.roles)
    BetterLFGDB.hiddenGroupClasses = CopySet(filters.hiddenGroupClasses)
    BetterLFGDB.roles = nil   -- the old from/to ranges of version 1.x
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
    local roles = BetterLFGDB and BetterLFGDB.groupRoles
    if type(roles) == "table" then
        for _, c in ipairs(ROLE_CRITERIA) do
            pending.roles[c.field] = roles[c.field] == true
            filters.roles[c.field] = roles[c.field] == true
        end
    end
    local classes = BetterLFGDB and BetterLFGDB.hiddenGroupClasses
    if type(classes) == "table" then
        for k, v in pairs(classes) do
            if type(k) == "string" and v == true then
                pending.hiddenGroupClasses[k] = true
                filters.hiddenGroupClasses[k] = true
            end
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
    -- Listings without a (readable) playstyle are always kept.
    local psKey = e.playstyleValue and PLAYSTYLE_KEY[e.playstyleValue]
    if psKey and filters.hiddenPlaystyles[psKey] then return false end
    if not MatchesActivity(e) then return false end
    -- Role checkboxes; a count that cannot be read never hides a group.
    if e.counts then
        for _, c in ipairs(ROLE_CRITERIA) do
            if filters.roles[c.field] then
                local have = Readable(e.counts[c.counts], nil)
                if have ~= nil and (have >= c.enough) ~= c.covered then return false end
            end
        end
    end
    -- "No groups with...": any member of a hidden class hides the group.
    if e.classes and next(filters.hiddenGroupClasses) then
        for cls in pairs(e.classes) do
            if filters.hiddenGroupClasses[cls] then return false end
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
local unitTooltipName   -- player whose world tooltip is showing (to refresh it on an answer)

if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
end

local function ShortName(name)
    name = name:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    return Ambiguate and Ambiguate(name, "short") or (name:match("^[^-]+") or name)
end

-- Players known to use Better LFG: anyone who sent us one of our addon messages.
-- Saved with the time they were last seen, kept for 14 days.
local KNOWN_USER_DAYS = 14
local function KnownUsers()
    BetterLFGDB = BetterLFGDB or {}
    if type(BetterLFGDB.knownUsers) ~= "table" then BetterLFGDB.knownUsers = {} end
    return BetterLFGDB.knownUsers
end

-- Returns true when the player was not known before.
local function MarkUser(name)
    if not name or name == "" then return false end
    local users = KnownUsers()
    local isNew = users[name] == nil
    users[name] = time()
    return isNew
end

function NS.IsBLFGUser(name)
    if not name or name == "" or name == "(hidden)" then return false end
    name = ShortName(name)
    if name == UnitName("player") then return true end
    return KnownUsers()[name] ~= nil
end

local function PruneKnownUsers()
    local users, limit = KnownUsers(), time() - KNOWN_USER_DAYS * 86400
    for name, seen in pairs(users) do
        if type(seen) ~= "number" or seen < limit then users[name] = nil end
    end
end

-- Small dark-blue "B-LFG" tag right after a name text (hidden when not a known user).
function NS.CreateUserIcon(row, nameText)
    local tag = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tag:SetText("B-LFG")
    tag:SetTextColor(0.25, 0.45, 0.85)
    tag:Hide()
    tag.nameText = nameText
    return tag
end

function NS.UpdateUserIcon(icon, name)
    if NS.IsBLFGUser(name) then
        local w = math.min(icon.nameText:GetStringWidth(), icon.nameText:GetWidth())
        icon:ClearAllPoints()
        icon:SetPoint("LEFT", icon.nameText, "LEFT", w + 3, 0)
        icon:Show()
    else
        icon:Hide()
    end
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
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Players who also use Better LFG see your item level in their group tooltip - and you see theirs.",
        0.4, 0.8, 1, true)
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

    -- Footer note on Blizzard's tooltip, only while WE show it (hidden with the tooltip,
    -- so Blizzard's own Browse tab never shows a stale note).
    if not tt.BetterLFGNote then
        tt.BetterLFGNote = tt:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        tt.BetterLFGNote:SetJustifyH("LEFT")
        tt.BetterLFGNote:SetTextColor(0.4, 0.8, 1)
        tt:HookScript("OnHide", function(self) self.BetterLFGNote:Hide() end)
    end
    local note = tt.BetterLFGNote
    note:ClearAllPoints()
    note:SetPoint("BOTTOMLEFT", tt, "BOTTOMLEFT", 11, 10)
    note:SetWidth(tt:GetWidth() - 22)
    note:SetText("iLvl is only shown for players who also use Better LFG.")
    note:Show()
    tt:SetHeight(tt:GetHeight() + note:GetStringHeight() + 6)
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
local DEFAULT_WHISPER = "Hi! I'm a level %level% %race% %class%. Can I join your group for %dungeon%?"

-- Default texts per language (Settings -> "Restore default text").
local DEFAULT_WHISPERS = {
    { code = "en", label = "English", text = DEFAULT_WHISPER },
    { code = "de", label = "Deutsch",
      text = "Hi! Ich bin %class% (%race%, Stufe %level%). Kann ich für %dungeon% in eure Gruppe?" },
    { code = "es", label = "Español",
      text = "¡Hola! Soy %class% (%race%, nivel %level%). ¿Puedo unirme a vuestro grupo para %dungeon%?" },
    { code = "fr", label = "Français",
      text = "Salut ! Je suis %class% (%race%, niveau %level%). Je peux rejoindre votre groupe pour %dungeon% ?" },
}
local WHISPER_COOLDOWN = 3
local lastWhisperAt = 0

-- The text the player saved (with placeholders), or the default.
-- Earlier default texts: a player who never changed them gets the current default.
local OLD_DEFAULTS = {
    ["Hi! I'd like to join your group."] = true,
    ["Hi! I'm a level %level% %race% %class%. Can I join your group?"] = true,
}
local function GetWhisperText()
    local t = BetterLFGDB and BetterLFGDB.whisperText
    if type(t) ~= "string" or OLD_DEFAULTS[t] then return DEFAULT_WHISPER end
    return t
end

-- The dungeon(s) of the group being whispered. A group can be listed for several
-- dungeons: those that match the player's dungeon filter are named; without a match
-- (or without a filter) all of the group's dungeons, joined with " / ".
local function DungeonText(e)
    if not e then return nil end
    local names, seen = {}, {}
    local function Add(id)
        local a = C_LFGList.GetActivityInfoTable(id)
        local n = a and (a.fullName or a.shortName)
        if n and not seen[n] then
            seen[n] = true
            table.insert(names, n)
        end
    end
    if filters.ids then
        for _, id in ipairs(e.activityIDs or {}) do
            if filters.ids[id] then Add(id) end
        end
    end
    if #names == 0 then
        for _, id in ipairs(e.activityIDs or {}) do Add(id) end
    end
    if #names == 0 and e.activity and e.activity ~= "" then names[1] = e.activity end
    if #names == 0 then return nil end
    return table.concat(names, " / ")
end

-- Placeholders, filled in from the player's character when the message is sent.
-- Race and class are English, so an English text reads right on any client - unless a
-- default text in the client's own language was chosen (e.g. German text on a German
-- client), then the client's own (localized) names are used. Other languages' names
-- are not available from the client, so they fall back to English.
local function UseClientNames()
    local lang = BetterLFGDB and BetterLFGDB.whisperLang
    return lang and lang ~= "en" and (GetLocale() or ""):sub(1, 2) == lang
end

local function EnglishClass()
    local localized, classFile = UnitClass("player")
    if UseClientNames() and localized then return localized end
    if not classFile then return "" end
    if classFile == "DEATHKNIGHT" then return "Death Knight" end
    if classFile == "DEMONHUNTER" then return "Demon Hunter" end
    return classFile:sub(1, 1) .. classFile:sub(2):lower()
end

local function EnglishRace()
    local localized, raceFile = UnitRace("player")
    if UseClientNames() and localized then return localized end
    if not raceFile then return "" end
    if raceFile == "Scourge" then return "Undead" end
    return (raceFile:gsub("(%l)(%u)", "%1 %2"))   -- "NightElf" -> "Night Elf"
end

local PLACEHOLDERS = {
    { "%level%", function() return tostring(UnitLevel("player")) end, "your level" },
    { "%race%",  EnglishRace,  "your race" },
    { "%class%", EnglishClass, "your class" },
    { "%name%",  function() return UnitName("player") or "" end, "your name" },
    { "%ilvl%",  function() return tostring(MyItemLevel() or "?") end, "your item level" },
    -- Without a group (settings preview) a sample name is shown.
    { "%dungeon%", function(e)
        if not e then return "[dungeon]" end
        return DungeonText(e) or "your dungeon"
    end, "the group's dungeon(s)" },
}

-- `e` is the group being whispered (nil for the settings preview).
local function FormatWhisper(text, e)
    for _, p in ipairs(PLACEHOLDERS) do
        local pattern = p[1]:gsub("%%", "%%%%")              -- "%level%" as a literal pattern
        local value = p[2](e):gsub("%%", "%%%%")             -- keep any "%" in the value literal
        text = text:gsub(pattern, value)
    end
    return text
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
    local text = FormatWhisper(GetWhisperText(), e)
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

    -- Larger, multi-line text box (wraps; Enter just leaves the box, a whisper is one line).
    local box = CreateFrame("Frame", nil, f, "BackdropTemplate")
    box:SetSize(600, 64)
    box:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -8)
    box:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    box:SetBackdropColor(0, 0, 0, 0.6)
    box:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)

    local edit = CreateFrame("EditBox", nil, box)
    edit:SetMultiLine(true)
    edit:SetFontObject(ChatFontNormal)
    edit:SetPoint("TOPLEFT", 8, -7)
    edit:SetPoint("BOTTOMRIGHT", -8, 7)
    edit:SetWidth(584)
    edit:SetAutoFocus(false)
    edit:SetMaxLetters(255)
    edit:SetScript("OnEnterPressed", edit.ClearFocus)
    edit:SetScript("OnEscapePressed", edit.ClearFocus)
    box:EnableMouse(true)
    box:SetScript("OnMouseDown", function() edit:SetFocus() end)

    -- Placeholder list and a live preview of what will actually be sent.
    local parts = {}
    for _, p in ipairs(PLACEHOLDERS) do
        table.insert(parts, "|cffffd100" .. p[1] .. "|r " .. p[3])
    end
    local help = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    help:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, -44)   -- below the "Restore default text" dropdown
    help:SetWidth(600)
    help:SetJustifyH("LEFT")
    help:SetText("Placeholders:  " .. table.concat(parts, ",   "))

    local preview = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    preview:SetPoint("TOPLEFT", help, "BOTTOMLEFT", 0, -10)
    preview:SetWidth(600)
    preview:SetJustifyH("LEFT")
    local function UpdatePreview()
        preview:SetText("Preview:  |cffffffff" .. FormatWhisper(edit:GetText()) .. "|r")
    end

    edit:SetScript("OnTextChanged", function(self, userInput)
        if userInput then
            BetterLFGDB = BetterLFGDB or {}
            -- A whisper is a single line: line breaks become spaces.
            BetterLFGDB.whisperText = (self:GetText():gsub("[\r\n]+", " "))
        end
        UpdatePreview()
    end)

    -- "Restore default text" in one of several languages.
    local restore = CreateFrame("DropdownButton", nil, f, "WowStyle1DropdownTemplate")
    restore:SetWidth(190)
    restore:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, -8)
    restore:SetDefaultText("Restore default text")
    restore:SetupMenu(function(_, root)
        for _, d in ipairs(DEFAULT_WHISPERS) do
            root:CreateButton(d.label, function()
                BetterLFGDB = BetterLFGDB or {}
                BetterLFGDB.whisperText = d.text
                BetterLFGDB.whisperLang = d.code
                edit:SetText(d.text)
            end)
        end
    end)

    -- Item level in the normal player tooltip (off by default).
    local unitCheck = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    unitCheck:SetPoint("TOPLEFT", preview, "BOTTOMLEFT", -4, -24)
    unitCheck.Text:SetText("Show item level in player tooltips (hovering a character in the world)")
    unitCheck:SetScript("OnClick", function(self)
        BetterLFGDB = BetterLFGDB or {}
        BetterLFGDB.unitTooltipIlvl = self:GetChecked() and true or false
    end)
    local unitHint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    unitHint:SetPoint("TOPLEFT", unitCheck, "BOTTOMLEFT", 30, -2)
    unitHint:SetWidth(560)
    unitHint:SetJustifyH("LEFT")
    unitHint:SetText("Players near you are inspected directly (works for everyone). Further away, only players of your faction who also use Better LFG.")

    -- Green flash on rows that changed live (on by default).
    local flashCheck = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    flashCheck:SetPoint("TOPLEFT", unitHint, "BOTTOMLEFT", -30, -16)
    flashCheck.Text:SetText("Highlight live updates")
    flashCheck:SetScript("OnClick", function(self)
        BetterLFGDB = BetterLFGDB or {}
        BetterLFGDB.flashUpdates = self:GetChecked() and true or false
    end)
    local flashHint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    flashHint:SetPoint("TOPLEFT", flashCheck, "BOTTOMLEFT", 30, -2)
    flashHint:SetWidth(560)
    flashHint:SetJustifyH("LEFT")
    flashHint:SetText("A row flashes green for a moment when its group or player changes - e.g. someone joined, a role was filled, or it was delisted.")

    -- Open our tab when the Group Finder opens (on by default).
    local openCheck = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    openCheck:SetPoint("TOPLEFT", flashHint, "BOTTOMLEFT", -30, -16)
    openCheck.Text:SetText("Open Find Groups by default")
    openCheck:SetScript("OnClick", function(self)
        BetterLFGDB = BetterLFGDB or {}
        BetterLFGDB.openByDefault = self:GetChecked() and true or false
    end)
    local openHint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    openHint:SetPoint("TOPLEFT", openCheck, "BOTTOMLEFT", 30, -2)
    openHint:SetWidth(560)
    openHint:SetJustifyH("LEFT")
    openHint:SetText("Opening the Group Finder (key I or the micro menu) shows the Find Groups tab instead of Blizzard's tab.")

    -- "Fewest armor competition" (off by default).
    local armorCheck = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    armorCheck:SetPoint("TOPLEFT", openHint, "BOTTOMLEFT", -30, -16)
    armorCheck.Text:SetText("Fewest armor competition")
    armorCheck:SetScript("OnClick", function(self)
        BetterLFGDB = BetterLFGDB or {}
        BetterLFGDB.armorFeature = self:GetChecked() and true or false
        if NS.UpdateArmorVisibility then NS.UpdateArmorVisibility() end
        if Render then pcall(Render) end
    end)
    local armorHint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    armorHint:SetPoint("TOPLEFT", armorCheck, "BOTTOMLEFT", 30, -2)
    armorHint:SetWidth(560)
    armorHint:SetJustifyH("LEFT")
    armorHint:SetText("Adds a selection to the Group Filters that puts groups with the fewest members wearing your (or a chosen) armor type first - less competition for loot.")

    f:SetScript("OnShow", function()
        edit:SetText(GetWhisperText())
        unitCheck:SetChecked(BetterLFGDB and BetterLFGDB.unitTooltipIlvl == true)
        flashCheck:SetChecked(not (BetterLFGDB and BetterLFGDB.flashUpdates == false))
        openCheck:SetChecked(not (BetterLFGDB and BetterLFGDB.openByDefault == false))
        armorCheck:SetChecked(BetterLFGDB and BetterLFGDB.armorFeature == true)
    end)

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
    -- Whoever sends us one of our messages uses Better LFG: mark them (and redraw the
    -- lists once, so the icon appears next to their name).
    if MarkUser(who) and Render and ((panel and panel:IsShown()) or (NS.playersPanel and NS.playersPanel:IsShown())) then
        Render()
    end
    if message == "REQ" then
        local il = MyItemLevel()
        if il then pcall(C_ChatInfo.SendAddonMessage, PREFIX, "ILVL:" .. il, "WHISPER", sender) end
        return
    end
    local il = tonumber(message:match("^ILVL:(%d+)$") or "")
    if il then
        ilvlCache[who] = { ilvl = il, t = GetTime() }
        if hoveredRow and hoveredRow:IsMouseOver() then ShowRowTooltip(hoveredRow) end
        -- The world tooltip of that player is open: redraw it with the answer.
        if unitTooltipName == who and GameTooltip:IsShown() and GameTooltip.RefreshData then
            pcall(GameTooltip.RefreshData, GameTooltip)
        end
    end
end)

---------------------------------------------------------------------------
-- Item level in the normal player tooltip (option, off by default)
---------------------------------------------------------------------------
-- Two ways to get another player's item level:
--  1. INSPECT (players in inspect range, ~28 yards): NotifyInspect -> INSPECT_READY ->
--     read their equipped items. Works for everyone, no addon needed on their side.
--  2. The addon message (see above), for players further away who use Better LFG.
local INSPECT_GAP = 1.5          -- seconds between inspects (the server throttles them)
local INSPECT_TIMEOUT = 3
local lastInspectAt = 0
local inspecting                 -- { guid, name, t } of the inspect in flight

local function InspectedItemLevel(unit)
    if C_PaperDollInfo and C_PaperDollInfo.GetInspectItemLevel then
        local il = C_PaperDollInfo.GetInspectItemLevel(unit)
        if il and canaccessvalue(il) and il > 0 then return math.floor(il + 0.5) end
    end
    local sum, n = 0, 0
    for _, s in ipairs(GEAR_SLOTS) do
        local link = GetInventoryItemLink(unit, s[1])
        if link and canaccessvalue(link) then
            local il = (C_Item and C_Item.GetDetailedItemLevelInfo and C_Item.GetDetailedItemLevelInfo(link))
                or (GetDetailedItemLevelInfo and GetDetailedItemLevelInfo(link))
                or select(4, GetItemInfo(link))
            if il then sum = sum + il; n = n + 1 end
        end
    end
    return n > 0 and math.floor(sum / n + 0.5) or nil
end

-- Starts an inspect if the unit is in range; true when one was started (or is running).
local function TryInspect(unit, name)
    if inspecting and inspecting.name == name and GetTime() - inspecting.t < INSPECT_TIMEOUT then
        return true
    end
    if InCombatLockdown() then return false end
    if InspectFrame and InspectFrame:IsShown() then return false end   -- don't disturb a manual inspect
    if not CanInspect or not CanInspect(unit) then return false end
    local ok, inRange = pcall(CheckInteractDistance, unit, 1)          -- 1 = inspect distance
    if not ok or not inRange then return false end
    if GetTime() - lastInspectAt < INSPECT_GAP then return false end
    local guid = UnitGUID(unit)
    if not guid or not canaccessvalue(guid) then return false end
    lastInspectAt = GetTime()
    inspecting = { guid = guid, name = name, t = GetTime() }
    if not pcall(NotifyInspect, unit) then
        inspecting = nil
        return false
    end
    return true
end

local inspectFrame = CreateFrame("Frame")
inspectFrame:RegisterEvent("INSPECT_READY")
inspectFrame:SetScript("OnEvent", function(_, _, guid)
    if not inspecting or guid ~= inspecting.guid then return end
    local name = inspecting.name
    inspecting = nil
    -- Find a unit token that still points at that player.
    local unit = UnitTokenFromGUID and UnitTokenFromGUID(guid)
    if not unit then
        for _, u in ipairs({ "mouseover", "target", "focus" }) do
            if UnitGUID(u) == guid then unit = u break end
        end
    end
    local il = unit and InspectedItemLevel(unit)
    if not (InspectFrame and InspectFrame:IsShown()) and ClearInspectPlayer then ClearInspectPlayer() end
    if il then
        ilvlCache[name] = { ilvl = il, t = GetTime() }
        if unitTooltipName == name and GameTooltip:IsShown() and GameTooltip.RefreshData then
            pcall(GameTooltip.RefreshData, GameTooltip)
        end
    end
end)

local function AddUnitItemLevel(tooltip)
    if not (BetterLFGDB and BetterLFGDB.unitTooltipIlvl) then return end
    if tooltip ~= GameTooltip or not tooltip.GetUnit then return end
    local _, unit = tooltip:GetUnit()
    if not unit or not canaccessvalue(unit) then return end
    local isPlayer = UnitIsPlayer(unit)
    if not canaccessvalue(isPlayer) or not isPlayer then return end

    local il, state
    if UnitIsUnit(unit, "player") then
        il = MyItemLevel()
    else
        local name = GetUnitName(unit, true)
        if not name or not canaccessvalue(name) then return end
        name = ShortName(name)
        unitTooltipName = name
        local c = ilvlCache[name]
        if c and GetTime() - c.t < ILVL_TTL then
            il = c.ilvl
        elseif TryInspect(unit, name) then
            state = "pending"
        else
            -- Out of inspect range: ask via addon message (own faction only,
            -- addon whispers don't reach the other faction).
            local theirs, mine = UnitFactionGroup(unit), UnitFactionGroup("player")
            if canaccessvalue(theirs) and theirs == mine then
                il, state = ItemLevelFor(name)
            else
                state = "range"
            end
        end
    end

    if il then
        tooltip:AddLine("Item Level: |cffffffff" .. il .. "|r", 0.4, 0.8, 1)
    elseif state == "pending" then
        tooltip:AddLine("Item Level: |cff808080...|r", 0.4, 0.8, 1)
    elseif state == "range" then
        tooltip:AddLine("Item Level: |cff808080? (too far away)|r", 0.4, 0.8, 1)
    else
        tooltip:AddLine("Item Level: |cff808080? (too far away, no Better LFG)|r", 0.4, 0.8, 1)
    end
    tooltip:Show()
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip)
        pcall(AddUnitItemLevel, tooltip)
    end)
elseif GameTooltip:HasScript("OnTooltipSetUnit") then
    GameTooltip:HookScript("OnTooltipSetUnit", function(tooltip) pcall(AddUnitItemLevel, tooltip) end)
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------
-- Loading spinner in the middle of a list while a search runs: Blizzard's own
-- LoadingSpinnerTemplate (the one its Browse tab uses; it animates by itself while
-- shown), with a small "Searching..." label below. Falls back to the label alone.
function NS.CreateSpinner(inset)
    local holder = CreateFrame("Frame", nil, inset)
    holder:SetSize(60, 60)
    holder:SetPoint("CENTER", inset, "CENTER", 0, 10)
    holder:SetFrameLevel(inset:GetFrameLevel() + 10)
    local ok, spinner = pcall(CreateFrame, "Frame", nil, holder, "LoadingSpinnerTemplate")
    if ok and spinner then
        spinner:SetPoint("CENTER")
    end
    local label = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOP", holder, "BOTTOM", 0, -2)
    label:SetText("Searching...")
    holder:Hide()
    return holder
end

-- A short green flash over a row (used when a listing was updated live).
function NS.FlashRow(row)
    -- Option "Highlight live updates" (on by default).
    if BetterLFGDB and BetterLFGDB.flashUpdates == false then return end
    if not row.flashAnim then
        local t = row:CreateTexture(nil, "BACKGROUND", nil, 2)
        t:SetAllPoints()
        t:SetColorTexture(0.3, 0.9, 0.4, 1)
        t:SetAlpha(0)
        local ag = t:CreateAnimationGroup()
        local fadeIn = ag:CreateAnimation("Alpha")
        fadeIn:SetFromAlpha(0)
        fadeIn:SetToAlpha(0.15)
        fadeIn:SetDuration(0.15)
        fadeIn:SetOrder(1)
        local fadeOut = ag:CreateAnimation("Alpha")
        fadeOut:SetFromAlpha(0.15)
        fadeOut:SetToAlpha(0)
        fadeOut:SetDuration(0.9)
        fadeOut:SetOrder(2)
        ag:SetScript("OnFinished", function() t:SetAlpha(0) end)
        row.flashAnim = ag
    end
    row.flashAnim:Stop()
    row.flashAnim:Play()
end

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
    r.leader:SetWidth(118)   -- room for the "B-LFG" tag after the name
    r.leader:SetJustifyH("LEFT")
    r.leader:SetWordWrap(false)
    r.blfg = NS.CreateUserIcon(r, r.leader)

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
        GameTooltip:AddLine(FormatWhisper(GetWhisperText(), self:GetParent().e), 0.8, 0.8, 0.8, true)
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

---------------------------------------------------------------------------
-- Armor types ("Fewest armor competition")
---------------------------------------------------------------------------
-- Classic rules: Hunters and Shamans wear leather until 40, then mail;
-- Warriors and Paladins wear mail until 40, then plate.
local ARMOR_LEVEL = 40
local function ArmorType(classFile, level)
    if classFile == "MAGE" or classFile == "PRIEST" or classFile == "WARLOCK" then return "CLOTH" end
    if classFile == "ROGUE" or classFile == "DRUID" or classFile == "MONK" or classFile == "DEMONHUNTER" then
        return "LEATHER"
    end
    local high = type(level) == "number" and level >= ARMOR_LEVEL
    if classFile == "HUNTER" or classFile == "SHAMAN" or classFile == "EVOKER" then
        return high and "MAIL" or "LEATHER"
    end
    if classFile == "WARRIOR" or classFile == "PALADIN" or classFile == "DEATHKNIGHT" then
        return high and "PLATE" or "MAIL"
    end
    return nil
end

local ARMOR_LABELS = { CLOTH = "Cloth", LEATHER = "Leather", MAIL = "Mail", PLATE = "Plate" }

-- The armor type the list is sorted by (fewest wearers first), or nil when off.
-- Saved setting: nil/"OFF", "MINE" (own class and level), or one of the types.
local function MyArmorType()
    local _, classFile = UnitClass("player")
    return ArmorType(classFile, UnitLevel("player"))
end

-- Option "Fewest armor competition" (off by default): only then is the selection shown
-- in Group Filters and the sort applied.
local function ArmorFeatureOn()
    return BetterLFGDB and BetterLFGDB.armorFeature == true
end

local function ActiveArmorSort()
    if not ArmorFeatureOn() then return nil end
    local s = BetterLFGDB and BetterLFGDB.armorSort
    if s == "MINE" then return MyArmorType() end
    if ARMOR_LABELS[s] then return s end
    return nil
end

-- The classes in a group, as a set ({ MAGE = true, ... }), for "No groups with...".
local function MemberClasses(id, numMembers)
    local classes = {}
    for i = 1, math.min(numMembers or 0, MAX_MEMBERS_SCANNED) do
        local m = C_LFGList.GetSearchResultPlayerInfo(id, i)
        local classFile = m and Readable(m.classFilename, nil)
        if classFile then classes[classFile] = true end
    end
    return classes
end

-- Members of each armor type in a group ({ CLOTH = 1, LEATHER = 2, ... }).
local function CountArmor(id, numMembers)
    local counts = { CLOTH = 0, LEATHER = 0, MAIL = 0, PLATE = 0 }
    for i = 1, math.min(numMembers or 0, MAX_MEMBERS_SCANNED) do
        local m = C_LFGList.GetSearchResultPlayerInfo(id, i)
        local classFile = m and Readable(m.classFilename, nil)
        local level = m and Readable(m.level, nil)
        local armor = classFile and ArmorType(classFile, level)
        if armor then counts[armor] = counts[armor] + 1 end
    end
    return counts
end

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
    -- "Fewest armor competition" comes first, the column sort breaks ties.
    local armor = ActiveArmorSort()
    if sortKey or armor then
        table.sort(list, function(a, b)
            if armor then
                local ca = a.armor and a.armor[armor] or 0
                local cb = b.armor and b.armor[armor] or 0
                if ca ~= cb then return ca < cb end
            end
            if sortKey then
                local va, vb = SortValue(a), SortValue(b)
                if va ~= vb then
                    if sortDesc then return va > vb end
                    return va < vb
                end
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
            -- Updated live since the last draw: flash once (only while the tab is visible).
            if e.flashAt and not e.flashedGroups and panel:IsShown() and GetTime() - e.flashAt < 2 then
                e.flashedGroups = true
                NS.FlashRow(r)
            end
            r.leader:SetText(e.leader)
            if e.color then
                r.leader:SetTextColor(e.color.r, e.color.g, e.color.b)
            else
                r.leader:SetTextColor(1, 0.82, 0)
            end
            NS.UpdateUserIcon(r.blfg, e.leader)
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
    -- Spinner while searching, else an empty-state message in the middle of the list.
    if spinner then spinner:SetShown(search.running and shown == 0) end
    if shown > 0 or search.running then
        status:SetText("")
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

-- Everything the lists show about one search result, read fresh from the client.
local function BuildEntry(id, info)
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
            return {
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
                armor = (not isSolo) and CountArmor(id, numMembers) or nil,
                classes = (not isSolo) and MemberClasses(id, numMembers) or nil,
            }
end

local resultIndex = {}   -- result id -> position in `results`

local function Collect()
    local ids = C_LFGList.GetSearchResults()
    -- Some builds return (count, ids), others just ids.
    if type(ids) ~= "table" then
        local _, second = C_LFGList.GetSearchResults()
        ids = second
    end
    wipe(resultIndex)
    for _, id in ipairs(ids or {}) do
        local info = C_LFGList.GetSearchResultInfo(id)
        if info and Readable(info.isDelisted, false) ~= true and not (search.seen and search.seen[id]) then
            if search.seen then search.seen[id] = true end
            table.insert(results, BuildEntry(id, info))
            resultIndex[id] = #results
        end
    end
end

-- A listing changed after the search (members joined/left, roles, delisted ...):
-- re-read it in place and mark it, so its row flashes green once.
local function UpdateEntry(id)
    local i = resultIndex[id]
    if not i or not results[i] or results[i].id ~= id then return false end
    local info = C_LFGList.GetSearchResultInfo(id)
    if not info then return false end
    local fresh = BuildEntry(id, info)
    fresh.flashAt = GetTime()
    results[i] = fresh
    return true
end

-- C_LFGList.Search only works when called directly from a click (hardware event); a call
-- from a timer is silently dropped. So every search is ONE synchronous call inside the
-- click handler (tab, Refresh, Search), for the Dungeons category, narrowed server-side
-- to the dungeons the applied filters allow.
local debugSearch = false
local function dprint(...)
    if debugSearch then print("|cff88ccffOG|r", ...) end
end

---------------------------------------------------------------------------
-- Languages (server-side search filter, shared by both tabs)
---------------------------------------------------------------------------
-- Results carry no language, so this goes into C_LFGList.Search. Without it the
-- server only returns listings in the client's own language (tested by LFGForever),
-- which is why players with different client languages see different groups.
-- The game's own language is always included ("locked"). Saved as the set of
-- unticked languages, so by default every offered language is searched.
local LANGUAGE_NAMES = {
    enUS = "English", enGB = "English", deDE = "German", frFR = "French",
    esES = "Spanish", esMX = "Spanish (Latin America)", ptBR = "Portuguese",
    itIT = "Italian", ruRU = "Russian", koKR = "Korean",
    zhCN = "Chinese (Simplified)", zhTW = "Chinese (Traditional)",
}

local function OfferedLanguages()
    local offered, seen = {}, {}
    local answer = C_LFGList.GetAvailableLanguageSearchFilter and C_LFGList.GetAvailableLanguageSearchFilter()
    if type(answer) ~= "table" then return offered end
    for _, code in ipairs(answer) do
        if type(code) == "string" and not seen[code] then
            seen[code] = true
            table.insert(offered, code)
        end
    end
    return offered
end

local function LockedLanguages()
    local locked = {}
    local defaults = C_LFGList.GetDefaultLanguageSearchFilter and C_LFGList.GetDefaultLanguageSearchFilter()
    if type(defaults) == "table" then
        for code, on in pairs(defaults) do
            if on then locked[code] = true end
        end
    end
    return locked
end

local function HiddenLanguages()
    BetterLFGDB = BetterLFGDB or {}
    if type(BetterLFGDB.hiddenLanguages) ~= "table" then BetterLFGDB.hiddenLanguages = {} end
    return BetterLFGDB.hiddenLanguages
end

-- The table C_LFGList.Search expects ({ deDE = true, enUS = true, ... }), or nil.
local function LanguageSearchFilter()
    local hidden, locked = HiddenLanguages(), LockedLanguages()
    local filter, any = {}, false
    for _, code in ipairs(OfferedLanguages()) do
        if locked[code] or not hidden[code] then
            filter[code] = true
            any = true
        end
    end
    return any and filter or nil
end

-- Blizzard's dropdown shows the ticked entries as its text ("Learning, Relaxed, ...").
-- This replaces that with our own summary ("All playstyles", "2 of 4 languages", ...).
function NS.UseSummaryText(dd, compute)
    if dd.SetSelectionText then
        dd:SetSelectionText(function() return compute() end)
    end
end

-- Rebuilds a dropdown so its text matches the current state (after a reset).
function NS.RefreshDropdown(dd)
    if dd and dd.GenerateMenu then pcall(dd.GenerateMenu, dd) end
end

-- Back to the default: every offered language ticked.
function NS.ResetLanguages()
    wipe(HiddenLanguages())
end

-- A "Languages" label + multi-select dropdown below `anchor`; returns the dropdown.
-- Takes effect with the next search.
function NS.CreateLanguageDropdown(parentFrame, anchor, xOffset)
    local label = parentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", xOffset or 0, -14)
    label:SetText("Languages")

    local dd = CreateFrame("DropdownButton", nil, parentFrame, "WowStyle1DropdownTemplate")
    dd:SetWidth(270)
    dd:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -6)

    local function UpdateText()
        local offered, hidden, locked = OfferedLanguages(), HiddenLanguages(), LockedLanguages()
        local shown = 0
        for _, code in ipairs(offered) do
            if locked[code] or not hidden[code] then shown = shown + 1 end
        end
        local text = (#offered == 0 or shown == #offered) and "All languages"
            or (shown .. " of " .. #offered .. " languages")
        dd:SetDefaultText(text)
        return text
    end
    UpdateText()
    NS.UseSummaryText(dd, UpdateText)
    dd.Refresh = function()
        UpdateText()
        NS.RefreshDropdown(dd)
    end
    -- Shared with the other tab: catch up with changes made there.
    dd:HookScript("OnShow", function() dd.Refresh() end)

    dd:SetupMenu(function(_, root)
        local hidden, locked = HiddenLanguages(), LockedLanguages()
        for _, code in ipairs(OfferedLanguages()) do
            local name = LANGUAGE_NAMES[code] or code
            if locked[code] then
                local cb = root:CreateCheckbox(name .. " (your game language)", function() return true end, function() end)
                if cb.SetEnabled then cb:SetEnabled(false) end
            else
                root:CreateCheckbox(name,
                    function() return not hidden[code] end,
                    function()
                        hidden[code] = (not hidden[code]) or nil
                        UpdateText()
                    end)
            end
        end
    end)
    return dd
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

    local ok, err = pcall(C_LFGList.Search, DUNGEON_CATEGORY, 0, 0, LanguageSearchFilter(), false, nil, activities)
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
ev:SetScript("OnEvent", function(_, event, resultID)
    -- A listing changed: re-read it, then redraw once (bursts of updates are coalesced).
    if event == "LFG_LIST_SEARCH_RESULT_UPDATED" then
        if search.running then return end
        if type(resultID) == "number" then UpdateEntry(resultID) end
        local function AnyShown()
            return (panel and panel:IsShown()) or (NS.playersPanel and NS.playersPanel:IsShown())
        end
        if not renderQueued and AnyShown() then
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
    pcall(filterWin.SetTitle, filterWin, "Group Filters")
    -- Same dark inset as the main window's list area (created first so it sits behind the controls).
    local fInset = CreateFrame("Frame", nil, filterWin, "InsetFrameTemplate")
    fInset:SetPoint("TOPLEFT", filterWin, "TOPLEFT", 8, -28)
    fInset:SetPoint("BOTTOMRIGHT", filterWin, "BOTTOMRIGHT", -6, 8)
    filterWin.fInset = fInset

    -- Dungeon dropdown (multi-select)
    local dungeonLabel = filterWin:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dungeonLabel:SetPoint("TOPLEFT", filterWin, "TOPLEFT", 22, -44)
    dungeonLabel:SetText("Dungeon")

    local dropdown = CreateFrame("DropdownButton", nil, filterWin, "WowStyle1DropdownTemplate")
    dropdown:SetWidth(270)
    dropdown:SetPoint("TOPLEFT", dungeonLabel, "BOTTOMLEFT", 0, -6)

    local function UpdateDropdownText()
        local n = SelectedCount()
        local text = (n == 0 and "All dungeons") or (n == 1 and next(pending.names)) or (n .. " dungeons selected")
        dropdown:SetDefaultText(text)
        return text
    end
    UpdateDropdownText()
    NS.UseSummaryText(dropdown, UpdateDropdownText)

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
        local text = (shown == #PLAYSTYLES and "All playstyles") or (shown == 0 and "No playstyle")
            or table.concat(names, ", ")
        psDropdown:SetDefaultText(text)
        return text
    end
    UpdatePlaystyleText()
    NS.UseSummaryText(psDropdown, UpdatePlaystyleText)

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
    local langDropdown = NS.CreateLanguageDropdown(filterWin, psDropdown)

    -- "Fewest armor competition": sorts groups by how few members wear an armor type.
    -- Applies immediately (it is a sort, not a filter) and is saved.
    local armorLabel = filterWin:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    armorLabel:SetPoint("TOPLEFT", langDropdown, "BOTTOMLEFT", 0, -14)
    armorLabel:SetText("Sort by fewest armor competition")

    local armorDropdown = CreateFrame("DropdownButton", nil, filterWin, "WowStyle1DropdownTemplate")
    armorDropdown:SetWidth(270)
    armorDropdown:SetPoint("TOPLEFT", armorLabel, "BOTTOMLEFT", 0, -6)
    -- Entries: Off, Cloth, Leather, Mail, Plate - the player's own type is marked
    -- "(my armor type)". An old saved "MINE" counts as the own type.
    local function ArmorLabel(key)
        local label = ARMOR_LABELS[key]
        if key == MyArmorType() then label = label .. " (my armor type)" end
        return label
    end
    local function SelectedArmor()
        local s = BetterLFGDB and BetterLFGDB.armorSort
        if s == "MINE" then return MyArmorType() end
        return ARMOR_LABELS[s] and s or nil
    end
    local function ArmorText()
        local key = SelectedArmor()
        return key and ArmorLabel(key) or "Off"
    end
    armorDropdown:SetDefaultText(ArmorText())
    NS.UseSummaryText(armorDropdown, ArmorText)
    local function SetArmorSort(value)
        BetterLFGDB = BetterLFGDB or {}
        BetterLFGDB.armorSort = value
        armorDropdown:SetDefaultText(ArmorText())
        Render()
    end
    armorDropdown:SetupMenu(function(_, root)
        root:CreateRadio("Off", function() return SelectedArmor() == nil end, function() SetArmorSort("OFF") end)
        for _, key in ipairs({ "CLOTH", "LEATHER", "MAIL", "PLATE" }) do
            root:CreateRadio(ArmorLabel(key), function() return SelectedArmor() == key end,
                function() SetArmorSort(key) end)
        end
    end)
    armorDropdown:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Sort by fewest armor competition", 1, 1, 1)
        GameTooltip:AddLine("This only sorts the list - no group is hidden.", 0.4, 0.8, 1, true)
        GameTooltip:AddLine("Groups with the fewest members wearing this armor type come first - less competition for loot.", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("Hunters and Shamans count as leather below level 40, Warriors and Paladins as mail.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    armorDropdown:HookScript("OnLeave", GameTooltip_Hide)

    -- Shown only while the option is on; the role section moves up when it is hidden.
    local function UpdateArmorVisibility()
        local on = ArmorFeatureOn()
        armorLabel:SetShown(on)
        armorDropdown:SetShown(on)
        roleHeader:ClearAllPoints()
        roleHeader:SetPoint("TOPLEFT", on and armorDropdown or langDropdown, "BOTTOMLEFT", 0, -22)
    end
    UpdateArmorVisibility()
    NS.UpdateArmorVisibility = UpdateArmorVisibility
    roleHeader:SetText("Find groups by role")

    -- Two columns of checkboxes:   [x] Tank available     [x] Has tank
    --                              [x] Healer available   [x] Has healer
    --                              [x] DPS available
    local roleChecks = {}
    local ROLE_UI = {
        { field = "tankAvailable",   role = "TANK",    label = "Tank available",   col = 0, row = 0,
          tip = "Groups that still need a tank." },
        { field = "hasTank",         role = "TANK",    label = "Has tank",         col = 1, row = 0,
          tip = "Groups that already have a tank." },
        { field = "healerAvailable", role = "HEALER",  label = "Healer available", col = 0, row = 1,
          tip = "Groups that still need a healer." },
        { field = "hasHealer",       role = "HEALER",  label = "Has healer",       col = 1, row = 1,
          tip = "Groups that already have a healer." },
        { field = "damageAvailable", role = "DAMAGER", label = "DPS available",    col = 0, row = 2,
          tip = "Groups that still have room for a damage dealer (fewer than 3)." },
    }
    local COL_WIDTH, ROW_STEP = 150, 26
    for _, d in ipairs(ROLE_UI) do
        local cb = CreateFrame("CheckButton", nil, filterWin, "UICheckButtonTemplate")
        cb:SetSize(26, 26)
        cb:SetPoint("TOPLEFT", roleHeader, "BOTTOMLEFT", -2 + d.col * COL_WIDTH, -6 - d.row * ROW_STEP)
        local icon = filterWin:CreateTexture(nil, "ARTWORK")
        icon:SetSize(16, 16)
        icon:SetTexture(ROLE_ICONS)
        icon:SetTexCoord(unpack(ROLE_COORDS[d.role]))
        icon:SetPoint("LEFT", cb, "RIGHT", 1, 0)
        local text = filterWin:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("LEFT", icon, "RIGHT", 4, 0)
        text:SetText(d.label)
        cb:SetChecked(pending.roles[d.field])
        cb:SetScript("OnClick", function(self)
            pending.roles[d.field] = self:GetChecked() and true or false
        end)
        cb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(d.label, 1, 1, 1)
            GameTooltip:AddLine(d.tip, 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", GameTooltip_Hide)
        roleChecks[d.field] = cb
    end

    -- "No groups with...": hide groups that contain one of the ticked classes.
    local classDropdown = CreateFrame("DropdownButton", nil, filterWin, "WowStyle1DropdownTemplate")
    classDropdown:SetWidth(270)
    classDropdown:SetPoint("TOPLEFT", roleHeader, "BOTTOMLEFT", 0, -12 - 3 * ROW_STEP)
    local function ClassText()
        local names = {}
        for _, cls in ipairs(ClassOrder({})) do
            if pending.hiddenGroupClasses[cls] then table.insert(names, ClassName(cls)) end
        end
        local text = (#names == 0 and "No groups with...") or ("No groups with: " .. table.concat(names, ", "))
        classDropdown:SetDefaultText(text)
        return text
    end
    ClassText()
    NS.UseSummaryText(classDropdown, ClassText)
    classDropdown:SetupMenu(function(_, root)
        for _, cls in ipairs(ClassOrder({})) do
            root:CreateCheckbox((ClassMarkup(cls) or "") .. " " .. ClassName(cls),
                function() return pending.hiddenGroupClasses[cls] == true end,
                function()
                    pending.hiddenGroupClasses[cls] = (not pending.hiddenGroupClasses[cls]) or nil
                    ClassText()
                end)
        end
    end)

    -- Bottom bar: [Reset] [gear] ................ [Search]
    local function ApplyFilters()
        filters.roles = CopySet(pending.roles)
        filters.hiddenGroupClasses = CopySet(pending.hiddenGroupClasses)
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
        ApplyFilters()
        SaveRoles()
        Render()
        Refresh()
    end)

    -- Resets every filter to its default, including dungeons and languages.
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
        -- Dungeons: all, only for my level (the default).
        wipe(pending.names)
        filters.ids = nil
        pending.levelOnly, filters.levelOnly = true, true
        levelCheck:SetChecked(true)
        UpdateDropdownText()
        NS.RefreshDropdown(dropdown)
        NS.RefreshDropdown(psDropdown)
        -- Armor sort: off.
        BetterLFGDB = BetterLFGDB or {}
        BetterLFGDB.armorSort = "OFF"
        armorDropdown:SetDefaultText("Off")
        NS.RefreshDropdown(armorDropdown)
        -- Languages: all (shared with the players tab).
        NS.ResetLanguages()
        langDropdown.Refresh()
        for _, cb in pairs(roleChecks) do cb:SetChecked(false) end
        ClassText()
        NS.RefreshDropdown(classDropdown)
        SaveRoles()
        Render()
    end)

    -- The shared filters may have been changed in Find Players: show their current state.
    filterWin.SyncShared = function()
        UpdateArmorVisibility()
        UpdateDropdownText()
        NS.RefreshDropdown(dropdown)
        levelCheck:SetChecked(pending.levelOnly)
        UpdatePlaystyleText()
        NS.RefreshDropdown(psDropdown)
        langDropdown.Refresh()
    end

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
    panel.closeBtn = close
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
    spinner = NS.CreateSpinner(inset)

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
        NS.FixFilterBorder(filterWin)
        NS.FixCloseButton(panel)
        NS.SuppressBlizzardTabs()
        if filterWin.SyncShared then filterWin.SyncShared() end
        tab:SetChecked(true)
        Refresh()
    end)
    panel:SetScript("OnHide", function()
        tab:SetChecked(false)
        NS.RestoreBlizzardTabs()
    end)
    parent:HookScript("OnHide", ClosePanel)
end

-- Other tabs' widgets (e.g. the Who List search box) can sit in a higher strata than
-- their window; frame level only matters within one strata. So take the highest strata
-- found among the window's visible frames and use it, with a very high level.
local STRATA = { "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG", "FULLSCREEN", "FULLSCREEN_DIALOG", "TOOLTIP" }
local STRATA_RANK = {}
for i, name in ipairs(STRATA) do STRATA_RANK[name] = i end
-- The filter window's border (NineSlice) must stay above its dark inset, otherwise the
-- inset covers the inner half of the border and it looks thin. Re-applied on every
-- show, because raising the panel shifts the children's frame levels.
function NS.FixFilterBorder(win)
    if win and win.NineSlice and win.fInset then
        win.NineSlice:SetFrameLevel(win.fInset:GetFrameLevel() + 1)
    end
end

-- Our panels' close button: same size and spot as the Group Finder's own close button
-- (which our panel covers), and above the panel's border so the border can't hide it.
function NS.FixCloseButton(p)
    local c = p and p.closeBtn
    if not c then return end
    -- Blizzard's default close-button spot for its portrait frames
    -- (UIPanelCloseButtonDefaultAnchors): top right corner, x = 1, y = 0, 24x24.
    c:ClearAllPoints()
    c:SetPoint("TOPRIGHT", p, "TOPRIGHT", 1, 0)
    c:SetSize(24, 24)
    c:SetFrameStrata(p:GetFrameStrata())
    -- Above every other layer of the window (border, portrait, title bar have their own,
    -- partly fixed, frame levels in Blizzard's template) - otherwise the X is there and
    -- clickable, but drawn underneath and invisible.
    local top = p:GetFrameLevel()
    for _, child in ipairs({ p:GetChildren() }) do
        if child ~= c and child:GetFrameLevel() > top then top = child:GetFrameLevel() end
    end
    c:SetFrameLevel(top + 5)
    c:Show()
end

-- Blizzard's own side tab stays "selected" while one of our panels covers its panel.
-- Purely visual fix: while ours is open, their selected tab is shown unselected, and
-- the previous state comes back when ours closes. Their selectedTab field and panels
-- are never touched.
local suppressedTabs = {}
local function IsOurTab(t)
    return t == tab or t == NS.playersTab or t == _G.LFGForeverBlizzardTab
end

-- Blizzard's side tabs are frames, not check buttons: there is no GetChecked, the
-- selection is their SelectedTexture being shown (which SetChecked toggles).
local function IsTabSelected(t)
    if t.GetChecked then return t:GetChecked() end
    if t.SelectedTexture then return t.SelectedTexture:IsShown() end
    return false
end

function NS.SuppressBlizzardTabs()
    for _, child in ipairs({ parent:GetChildren() }) do
        if not IsOurTab(child) and child.Icon and child.SetChecked and IsTabSelected(child) then
            child:SetChecked(false)
            suppressedTabs[child] = true
        end
    end
end

-- Called when one of our panels closes. Not while the other one of ours is open.
function NS.RestoreBlizzardTabs()
    if (NS.groupsPanel and NS.groupsPanel:IsShown()) or (NS.playersPanel and NS.playersPanel:IsShown()) then
        return
    end
    for t in pairs(suppressedTabs) do t:SetChecked(true) end
    wipe(suppressedTabs)
end

-- A Blizzard tab was clicked: their code has already set the right tab as selected,
-- so forget the old state instead of restoring it, then close our panels.
function NS.OnBlizzardTabClick()
    wipe(suppressedTabs)
    if NS.groupsPanel then NS.groupsPanel:Hide() end
    if NS.playersPanel then NS.playersPanel:Hide() end
end

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
            child:HookScript("OnMouseUp", function() NS.OnBlizzardTabClick() end)
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
NS.PLAYSTYLES = PLAYSTYLES
NS.PLAYSTYLE_KEY = PLAYSTYLE_KEY
-- Dungeons, "only my level" and playstyles are shared with Find Players: it reads and
-- writes these same tables (never replace the tables themselves, only their fields).
NS.groupPending = pending
NS.groupFilters = filters
NS.SaveGroupFilters = SaveRoles

-- Wait for our own saved variables first, then for the Group Finder.
EventUtil.ContinueOnAddOnLoaded(ADDON, function()
    BetterLFGDB = BetterLFGDB or {}
    LoadRoles()
    PruneKnownUsers()
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
        -- Workaround for a Blizzard quirk: on the first open per session the panel manager
        -- places the Group Finder next to the Character window before that window has its
        -- final width (stats pane), so the two overlap. Re-run Blizzard's own positioning
        -- one frame later, and whenever the Character window changes width. Out of combat
        -- only (the panel manager is protected in combat).
        local function Reposition()
            if InCombatLockdown() or not UpdateUIPanelPositions then return end
            if parent:IsShown() and CharacterFrame and CharacterFrame:IsShown() then
                pcall(UpdateUIPanelPositions, CharacterFrame)
            end
        end
        if CharacterFrame then
            CharacterFrame:HookScript("OnShow", function() C_Timer.After(0, Reposition) end)
            CharacterFrame:HookScript("OnSizeChanged", function() C_Timer.After(0, Reposition) end)
        end

        -- Option "Open Find Groups by default" (on): opening the Group Finder (key I,
        -- micro menu) shows our tab. This runs inside that key press / click, so the
        -- search the panel starts is allowed.
        parent:HookScript("OnShow", function()
            if BetterLFGDB and BetterLFGDB.openByDefault == false then return end
            if not panel:IsShown() then panel:Show() end
            -- Blizzard selects its tab only after this hook, so un-highlight it once
            -- more on the next frame.
            C_Timer.After(0, function()
                if panel:IsShown() then NS.SuppressBlizzardTabs() end
            end)
        end)
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
