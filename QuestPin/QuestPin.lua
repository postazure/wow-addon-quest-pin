-- Quest Pin: tracks the quests for the zone you're in, and keeps pinned quests tracked everywhere.
--
-- How it works
--   * The watch list (Blizzard's "tracked" quests) is kept equal to: quests in your zone + pinned quests.
--   * Blizzard's "Quests" tracker section is swapped for two sections built from Blizzard's own quest
--     module: "<zone name>" (quests in your zone, pinned or not) and "Pinned" (pinned quests elsewhere).
--   * Pinned quests get a pushpin after their title, in the tracker and on the quest log's track box.
--   * In the quest log, ticking a quest's track box pins it; unticking unpins it (or hides a zone
--     quest until you leave the zone). Right-click a quest in the log or tracker for Pin / Unpin.

local ADDON = ...

local PIN_TEX = "Interface\\AddOns\\QuestPin\\Media\\pin"
local PIN_ICON = "|T" .. PIN_TEX .. ":0:0:0:0|t"
local PINNED_HEADER = "Pinned"

local DEFAULTS = {
    autoZone = true,        -- track quests in your zone automatically
    matchObjectives = true, -- a quest is "in the zone" if the map sends you there
    matchLogZone = true,    -- ... or if the quest log files it under this zone
    showLocation = true,    -- "Go to X (from Y)" line on pinned quests
}

local db                -- QuestPinDB: { pinned = {[questID]=true}, giver = {[questID]=zoneName}, options... }
local inZone = {}       -- questID -> true, for quests in the current zone (rebuilt by Reconcile)
local logZone = {}      -- questID -> quest log header (normally the zone the quest belongs to)
local destCache = {}    -- questID -> zone info table or false (rebuilt by Reconcile)
local dismissed = {}    -- questID -> true: zone quests you untracked; cleared when you change zone
local zoneID, zoneName  -- the zone you're in
local busy = false      -- true while we change the watch list ourselves
local menuQuestID       -- quest whose tracker menu is being built

local function Print(msg)
    print("|cffffd200Quest Pin:|r " .. msg)
end

-- ---------------------------------------------------------------------------
-- Maps

local zoneCache = {}

-- Walks a map up to its zone (caves, city districts and other micro maps belong to a zone).
local function ToZone(mapID)
    if not mapID or mapID == 0 then return nil end
    local cached = zoneCache[mapID]
    if cached ~= nil then return cached or nil end

    local info = C_Map.GetMapInfo(mapID)
    while info and (info.mapType == Enum.UIMapType.Micro or info.mapType == Enum.UIMapType.Orphan)
        and info.parentMapID and info.parentMapID ~= 0 do
        local parent = C_Map.GetMapInfo(info.parentMapID)
        if not parent then break end
        info = parent
    end
    zoneCache[mapID] = info or false
    return info
end

-- Where the quest wants you to go next: the map its objectives (or turn-in) are on.
local function Destination(questID)
    local dest = destCache[questID]
    if dest == nil then
        local mapID = GetQuestUiMapID and GetQuestUiMapID(questID)
        if not mapID or mapID == 0 then
            mapID = C_QuestLog.GetNextWaypoint(questID)
        end
        dest = ToZone(mapID) or false
        destCache[questID] = dest
    end
    return dest or nil
end

-- The zone you were in when you took the quest; for older quests, the quest log's zone header.
local function GiverZone(questID)
    local giver = db and db.giver[questID]
    if giver and giver ~= "" then return giver end
    local header = logZone[questID]
    if header and header ~= "" then return header end
end

-- ---------------------------------------------------------------------------
-- Watch list

local function MaxWatches()
    return Constants and Constants.QuestWatchConsts and Constants.QuestWatchConsts.MAX_QUEST_WATCHES or 25
end

local function UpdateTrackerSections()
    if not QuestPinZoneTracker then return end
    QuestPinZoneTracker:SetHeader(zoneName or TRACKER_HEADER_QUESTS)
    QuestPinZoneTracker:MarkDirty()
    QuestPinPinnedTracker:MarkDirty()
end

local function Reconcile()
    if not db then return end

    -- Scan the quest log.
    wipe(logZone)
    wipe(destCache)
    local numEntries = C_QuestLog.GetNumQuestLogEntries()
    local header
    for i = 1, numEntries do
        local info = C_QuestLog.GetInfo(i)
        if info then
            if info.isHeader then
                header = info.title
            elseif not info.isHidden and not info.isTask and not info.isBounty then
                logZone[info.questID] = header or ""
            end
        end
    end

    -- Forget pins for quests that left the log (only once the log has loaded).
    if numEntries > 0 then
        for questID in pairs(db.pinned) do
            if not logZone[questID] then db.pinned[questID] = nil end
        end
        for questID in pairs(db.giver) do
            if not C_QuestLog.GetLogIndexForQuestID(questID) then db.giver[questID] = nil end
        end
    end

    -- Which zone are we in?
    local zone = ToZone(C_Map.GetBestMapForUnit("player"))
    local newZoneID = zone and zone.mapID
    if newZoneID ~= zoneID then
        zoneID = newZoneID
        zoneName = zone and zone.name
        wipe(dismissed)
    end

    -- Which quests are in it?
    wipe(inZone)
    if zone then
        if db.matchObjectives then
            for _, poi in ipairs(C_QuestLog.GetQuestsOnMap(zone.mapID) or {}) do
                if logZone[poi.questID] then inZone[poi.questID] = true end
            end
        end
        for questID, logHeader in pairs(logZone) do
            if not inZone[questID] then
                if db.matchLogZone and logHeader == zone.name then
                    inZone[questID] = true
                elseif db.matchObjectives then
                    local dest = Destination(questID)
                    if dest and dest.mapID == zone.mapID then inZone[questID] = true end
                end
            end
        end
    end

    -- Wanted: pinned quests first (so they win if we hit the watch cap), then zone quests.
    local want, order = {}, {}
    for questID in pairs(db.pinned) do
        if logZone[questID] then want[questID] = true; order[#order + 1] = questID end
    end
    if db.autoZone then
        for questID in pairs(inZone) do
            if not want[questID] and not dismissed[questID] then
                want[questID] = true; order[#order + 1] = questID
            end
        end
    end

    busy = true
    for i = C_QuestLog.GetNumQuestWatches(), 1, -1 do
        local questID = C_QuestLog.GetQuestIDForQuestWatchIndex(i)
        -- Only manage normal log quests; leave anything else alone.
        if questID and logZone[questID] and not want[questID] then
            C_QuestLog.RemoveQuestWatch(questID)
        end
    end
    local max = MaxWatches()
    for _, questID in ipairs(order) do
        if C_QuestLog.GetQuestWatchType(questID) == nil then
            if C_QuestLog.GetNumQuestWatches() >= max then break end
            C_QuestLog.AddQuestWatch(questID)
        end
    end
    busy = false

    UpdateTrackerSections()
end

local pending = false
local function Refresh(delay)
    if pending then return end
    pending = true
    C_Timer.After(delay or 0.1, function()
        pending = false
        Reconcile()
    end)
end

-- ---------------------------------------------------------------------------
-- Pins

local function UpdateLogRows() end -- defined below

local function SetPinned(questID, pinned)
    if not db or not questID then return end
    if pinned then
        db.pinned[questID] = true
        dismissed[questID] = nil
    else
        db.pinned[questID] = nil
    end
    Reconcile()
    UpdateLogRows()
end

local function TogglePin(questID)
    SetPinned(questID, not (db and db.pinned[questID]))
end

-- ---------------------------------------------------------------------------
-- Tracker sections (Blizzard's quest module, filtered)

local Shared = {}

-- Blizzard appends this after the quest title, so the pushpin goes there.
function Shared:GetQuestTagText(questID)
    local tag = QuestObjectiveTrackerMixin.GetQuestTagText(self, questID)
    if db and db.pinned[questID] then
        return tag and (tag .. " " .. PIN_ICON) or PIN_ICON
    end
    return tag
end

local function LocationText(questID, isZoneSection)
    local from = GiverZone(questID)
    if isZoneSection then
        -- Everything here is in this zone already; only say where it came from if that's elsewhere.
        if from and from ~= zoneName then return "From " .. from end
        return nil
    end
    local dest = Destination(questID)
    local destName = dest and dest.name
    if destName and from and destName ~= from then
        return ("Go to |cffffffff%s|r  |cff999999(from %s)|r"):format(destName, from)
    elseif destName then
        return ("Go to |cffffffff%s|r"):format(destName)
    elseif from then
        return ("|cff999999From %s|r"):format(from)
    end
end

-- Called by Blizzard's UpdateSingle before the objectives; the location line goes first.
function Shared:DoQuestObjectives(block, ...)
    if db and db.showLocation then
        local text = LocationText(block.id, self.isZoneSection)
        if text then
            block:AddObjective("QuestPinLocation", text, nil, true, OBJECTIVE_DASH_STYLE_HIDE,
                OBJECTIVE_TRACKER_COLOR["Normal"])
        end
    end
    return QuestObjectiveTrackerMixin.DoQuestObjectives(self, block, ...)
end

function Shared:OnBlockHeaderClick(block, mouseButton)
    menuQuestID = block.id
    return QuestObjectiveTrackerMixin.OnBlockHeaderClick(self, block, mouseButton)
end

QuestPinZoneTrackerMixin = CreateFromMixins(QuestObjectiveTrackerMixin, Shared, {
    headerText = TRACKER_HEADER_QUESTS,
    isZoneSection = true,
})

function QuestPinZoneTrackerMixin:ShouldDisplayQuest(quest)
    return inZone[quest:GetID()] and QuestObjectiveTrackerMixin.ShouldDisplayQuest(self, quest)
end

QuestPinPinnedTrackerMixin = CreateFromMixins(QuestObjectiveTrackerMixin, Shared, {
    headerText = PINNED_HEADER,
})

-- Everything tracked outside the zone. Normally that's only pinned quests.
function QuestPinPinnedTrackerMixin:ShouldDisplayQuest(quest)
    return not inZone[quest:GetID()] and QuestObjectiveTrackerMixin.ShouldDisplayQuest(self, quest)
end

-- Auto-quest popups ("click to complete") show once, in the zone section.
function QuestPinPinnedTrackerMixin:AddAutoQuestObjectives()
end

-- Swap Blizzard's "Quests" section for ours, in the same spot.
local installed = false
local function Install(tries)
    if installed then return end
    local manager, blizzard = ObjectiveTrackerManager, QuestObjectiveTracker
    local container = manager and blizzard and manager:GetContainerForModule(blizzard)
    if not container then
        -- The tracker sets itself up after PLAYER_ENTERING_WORLD; try again shortly.
        tries = (tries or 0) + 1
        if tries <= 20 then C_Timer.After(0.5, function() Install(tries) end) end
        return
    end
    installed = true

    local order = blizzard.uiOrder or 4
    QuestPinZoneTracker.uiOrder = order
    QuestPinPinnedTracker.uiOrder = order + 0.5

    container:RemoveModule(blizzard)
    manager.moduleToContainerMap[blizzard] = nil
    blizzard:Hide()

    manager:SetModuleContainer(QuestPinZoneTracker, container)
    manager:SetModuleContainer(QuestPinPinnedTracker, container)
    Reconcile()
end

-- ---------------------------------------------------------------------------
-- Quest log

local rowIcons = setmetatable({}, { __mode = "k" })

-- Pinned quests show a pushpin in place of the track box's tick.
UpdateLogRows = function()
    if not db or not QuestScrollFrame or not QuestScrollFrame.titleFramePool then return end
    for button in QuestScrollFrame.titleFramePool:EnumerateActive() do
        local box = button.Checkbox
        if box then
            local pinned = button.questID and db.pinned[button.questID] or false
            local icon = rowIcons[button]
            if pinned and not icon then
                icon = box:CreateTexture(nil, "OVERLAY")
                icon:SetTexture(PIN_TEX)
                icon:SetSize(18, 18)
                icon:SetPoint("CENTER", box, "CENTER", 2, 2)
                rowIcons[button] = icon
            end
            if icon then icon:SetShown(pinned) end
            if pinned and box.CheckMark then box.CheckMark:Hide() end
        end
    end
end

local function AddTooltipLines(button)
    local questID = button and button.questID
    if not db or not questID or GameTooltip:GetOwner() ~= button then return end
    local dest, from = Destination(questID), GiverZone(questID)
    GameTooltip:AddLine(" ")
    if dest and dest.name then GameTooltip:AddDoubleLine("Goes to", dest.name, 1, 0.82, 0, 1, 1, 1) end
    if from then GameTooltip:AddDoubleLine("From", from, 1, 0.82, 0, 1, 1, 1) end
    if db.pinned[questID] then
        GameTooltip:AddLine(PIN_ICON .. " Pinned: tracked in every zone", 0.6, 0.8, 1)
    else
        GameTooltip:AddLine("Right-click > Pin quest to track it everywhere", 0.6, 0.6, 0.6)
    end
    GameTooltip:Show()
end

-- ---------------------------------------------------------------------------
-- Menus

local function AddPinButton(rootDescription, questID)
    if not questID or not logZone[questID] then return end
    rootDescription:CreateDivider()
    if db.pinned[questID] then
        rootDescription:CreateButton("Unpin quest", function() SetPinned(questID, false) end)
    else
        rootDescription:CreateButton("Pin quest", function() SetPinned(questID, true) end)
    end
end

-- For tracker sections that aren't ours (campaign quests), find the block under the mouse.
local function QuestIDUnderMouse()
    local foci = GetMouseFoci and GetMouseFoci()
    local frame = foci and foci[1]
    while frame do
        if frame.parentModule and type(frame.id) == "number" then return frame.id end
        frame = frame:GetParent()
    end
end

local function SetUpMenus()
    if not (Menu and Menu.ModifyMenu) then return end
    Menu.ModifyMenu("MENU_QUEST_MAP_LOG_TITLE", function(owner, rootDescription)
        AddPinButton(rootDescription, owner and owner.questID)
    end)
    Menu.ModifyMenu("MENU_QUEST_OBJECTIVE_TRACKER", function(owner, rootDescription)
        local questID = QuestIDUnderMouse() or menuQuestID
        menuQuestID = nil
        AddPinButton(rootDescription, questID)
    end)
end

-- ---------------------------------------------------------------------------
-- Hooks on Blizzard's own tracking actions

local function SetUpHooks()
    -- Untracking a quest (tracker "Stop tracking", shift-click, quest log box) unpins it, and hides a
    -- zone quest until you leave the zone.
    hooksecurefunc(C_QuestLog, "RemoveQuestWatch", function(questID)
        if busy or not questID or not db then return end
        db.pinned[questID] = nil
        if inZone[questID] then dismissed[questID] = true end
        Refresh()
    end)

    -- Tracking a quest from the quest log pins it (or brings back a hidden zone quest).
    if QuestMapQuestOptions_TrackQuest then
        hooksecurefunc("QuestMapQuestOptions_TrackQuest", function(questID)
            if busy or not questID or not db then return end
            if C_QuestLog.GetQuestWatchType(questID) ~= nil then
                if dismissed[questID] then
                    dismissed[questID] = nil
                else
                    db.pinned[questID] = true
                end
                Refresh()
            end
        end)
    end

    if QuestLogQuests_Update then hooksecurefunc("QuestLogQuests_Update", UpdateLogRows) end
    if QuestMapLogTitleButton_OnEnter then hooksecurefunc("QuestMapLogTitleButton_OnEnter", AddTooltipLines) end
end

-- ---------------------------------------------------------------------------
-- Slash commands

local function OnOff(v) return v and "|cff00ff00on|r" or "|cffff4040off|r" end

local function QuestIDFromInput(input)
    return tonumber(input:match("|Hquest:(%d+)") or input:match("^(%d+)$"))
end

local TOGGLES = {
    auto = { key = "autoZone", label = "Auto-track quests in your zone" },
    objectives = { key = "matchObjectives", label = "Zone quests: the map sends you here" },
    logzone = { key = "matchLogZone", label = "Zone quests: the quest log files it under this zone" },
    location = { key = "showLocation", label = "Show where pinned quests go and where they came from" },
}

SLASH_QUESTPIN1 = "/questpin"
SLASH_QUESTPIN2 = "/qpin"
SlashCmdList.QUESTPIN = function(msg)
    msg = strtrim(msg or "")
    local cmd = msg:lower():match("^(%S+)") or ""
    local toggle = TOGGLES[cmd]
    if toggle then
        db[toggle.key] = not db[toggle.key]
        Print(toggle.label .. ": " .. OnOff(db[toggle.key]))
        Reconcile()
    elseif cmd == "list" then
        local any = false
        for questID in pairs(db.pinned) do
            any = true
            local dest = Destination(questID)
            Print(PIN_ICON .. " " .. (C_QuestLog.GetTitleForQuestID(questID) or questID)
                .. (dest and dest.name and (" - " .. dest.name) or ""))
        end
        if not any then Print("No pinned quests.") end
    elseif cmd == "clear" then
        wipe(db.pinned)
        Reconcile()
        UpdateLogRows()
        Print("Unpinned every quest.")
    elseif QuestIDFromInput(msg) then
        local questID = QuestIDFromInput(msg)
        if not C_QuestLog.GetLogIndexForQuestID(questID) then
            Print("That quest isn't in your quest log.")
        else
            TogglePin(questID)
            Print((db.pinned[questID] and "Pinned " or "Unpinned ") .. (C_QuestLog.GetTitleForQuestID(questID) or questID))
        end
    else
        Print("You are in " .. (zoneName or "?") .. ". Commands:")
        Print("/qpin <quest link or ID> - pin or unpin a quest")
        Print("/qpin list - list pinned quests")
        Print("/qpin clear - unpin everything")
        for _, name in ipairs({ "auto", "objectives", "logzone", "location" }) do
            Print(("/qpin %s - %s (%s)"):format(name, TOGGLES[name].label, OnOff(db[TOGGLES[name].key])))
        end
        Print("In the quest log, tick a quest's track box (or right-click > Pin quest) to pin it.")
    end
end

-- ---------------------------------------------------------------------------
-- Events

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        QuestPinDB = QuestPinDB or {}
        db = QuestPinDB
        db.pinned = db.pinned or {}
        db.giver = db.giver or {}
        for k, v in pairs(DEFAULTS) do
            if db[k] == nil then db[k] = v end
        end
        SetUpHooks()
        SetUpMenus()
        self:RegisterEvent("PLAYER_ENTERING_WORLD")
        self:RegisterEvent("ZONE_CHANGED_NEW_AREA")
        self:RegisterEvent("ZONE_CHANGED")
        self:RegisterEvent("ZONE_CHANGED_INDOORS")
        self:RegisterEvent("QUEST_LOG_UPDATE")
        self:RegisterEvent("QUEST_POI_UPDATE")
        self:RegisterEvent("QUEST_ACCEPTED")
        self:RegisterEvent("QUEST_REMOVED")
    elseif event == "PLAYER_ENTERING_WORLD" then
        Install()
        Refresh(0.5)
    elseif event == "QUEST_ACCEPTED" then
        -- Some clients send (questLogIndex, questID), others just (questID).
        local a, b = ...
        local questID = b or a
        local zone = ToZone(C_Map.GetBestMapForUnit("player"))
        if questID and zone and zone.name then db.giver[questID] = zone.name end
        Refresh()
    elseif event == "QUEST_REMOVED" then
        local questID = ...
        if questID then
            db.pinned[questID] = nil
            db.giver[questID] = nil
            dismissed[questID] = nil
        end
        Refresh()
    else
        Refresh(event == "QUEST_LOG_UPDATE" and 0.25 or 0.1)
    end
end)
