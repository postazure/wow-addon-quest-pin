-- Quest Pin: tracks the quests for the zone you're in, and keeps pinned quests tracked everywhere.
--
-- How it works
--   * The watch list (Blizzard's "tracked" quests) is kept equal to: quests in your zone + pinned quests.
--   * Blizzard's "Quests" tracker section is swapped for sections built from Blizzard's own quest
--     module: "Pinned" (every pinned quest, wherever it is) and "<zone name>" (unpinned quests in
--     your zone), with finished quests from either moved to "Ready to turn in" below them.
--     Each quest shows in one section only.
--   * Pinned quests look like any other tracked quest; the Pinned section is what sets them apart.
--   * In the quest log, the track box shows and toggles the pin: ticked means pinned, for zone
--     quests too. Right-click a quest in the log or tracker for Pin / Unpin.

local ADDON = ...

local PIN_TEX = "Interface\\AddOns\\QuestPin\\Media\\pin"
local PIN_ICON = "|T" .. PIN_TEX .. ":0:0:0:0|t"
local PINNED_HEADER = "Pinned"
local READY_HEADER = "Ready to turn in"

local DEFAULTS = {
    autoZone = true,        -- track quests in your zone automatically
    matchObjectives = true, -- a quest is "in the zone" if the map sends you there
    matchLogZone = true,    -- ... or if the quest log files it under this zone
    showLocation = true,    -- "Go to X (from Y)" line on pinned quests
    holdInFlight = true,    -- keep the current zone's quests while flying; switch once you land
}

local db                -- QuestPinDB: { pinned = {[questID]=true}, giver = {[questID]=zoneName}, options... }
local inZone = {}       -- questID -> true, for quests in the current zone (rebuilt by Reconcile)
local logZone = {}      -- questID -> quest log header (normally the zone the quest belongs to)
local destCache = {}    -- questID -> zone info table or false (rebuilt by Reconcile)
local dismissed = {}    -- questID -> true: zone quests you untracked; cleared when you change zone
local zoneID, zoneName  -- the zone you're in
local curZone           -- its map info (kept while flying)
local busy = false      -- true while we change the watch list ourselves
local menuQuestID       -- quest whose tracker menu is being built

local function Print(msg)
    print("|cffffd200Quest Pin:|r " .. msg)
end

-- Runs our extras inside Blizzard's tracker and quest log updates. An error in them would stop
-- Blizzard's update half way (stale objectives), so catch it and print it once instead.
local reportedErrors = {}
local function Safe(f, ...)
    local ok, err = pcall(f, ...)
    if not ok then
        err = tostring(err)
        if not reportedErrors[err] then
            reportedErrors[err] = true
            Print("|cffff4040error|r (please report): " .. err)
        end
        return nil
    end
    return err
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

-- The place you're in, as { id, name, maps = {[mapID]=true}, names = {[name]=true} }.
-- In a dungeon or raid this is the whole instance: every floor's map, plus the instance's own name
-- (some instances have no map at all). Elsewhere it's the zone.
local function CurrentZone()
    local info = ToZone(C_Map.GetBestMapForUnit("player"))
    local instName, instanceID
    if IsInInstance() then
        local name, _, _, _, _, _, _, id = GetInstanceInfo()
        if name and name ~= "" then instName, instanceID = name, id end
    end
    if not info and not instName then return nil end

    local zone = { maps = {}, names = {} }
    if info then
        zone.id, zone.name = info.mapID, info.name
        zone.maps[info.mapID] = true
        if info.name then zone.names[info.name] = true end
        -- Multi-floor maps (dungeon levels) share a map group.
        local group = C_Map.GetMapGroupID and C_Map.GetMapGroupID(info.mapID)
        local floors = group and C_Map.GetMapGroupMembersInfo(group)
        for _, floor in ipairs(floors or {}) do
            zone.maps[floor.mapID] = true
            if floor.name then zone.names[floor.name] = true end
        end
    end
    if instName then
        -- Same zone on every floor, so changing floors doesn't reset anything.
        zone.id, zone.name = "instance:" .. tostring(instanceID or instName), instName
        zone.names[instName] = true
    end
    return zone
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

local Reconcile -- defined below; the landing check calls it

local UpdateLogRows -- defined in the quest log section below

local function UpdateTrackerSections()
    if QuestPinZoneTracker then
        QuestPinZoneTracker:SetHeader(zoneName or TRACKER_HEADER_QUESTS)
        QuestPinZoneTracker:MarkDirty()
        QuestPinPinnedTracker:MarkDirty()
        QuestPinReadyTracker:MarkDirty()
    end
    Safe(UpdateLogRows)
end

local function InFlight()
    return UnitOnTaxi("player") or IsFlying()
end

-- While flying, check once a second for landing (flying mounts have no landing event).
local landingTicker
local function WatchForLanding()
    if landingTicker then return end
    landingTicker = C_Timer.NewTicker(1, function()
        if not InFlight() then
            landingTicker:Cancel()
            landingTicker = nil
            Reconcile()
        end
    end)
end

function Reconcile()
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

    -- Which zone are we in? While flying, stay with the zone you took off from until you land.
    local zone
    if db.holdInFlight and curZone and InFlight() then
        zone = curZone
        WatchForLanding()
    else
        zone = CurrentZone()
    end
    curZone = zone
    local newZoneID = zone and zone.id
    if newZoneID ~= zoneID then
        zoneID = newZoneID
        zoneName = zone and zone.name
        wipe(dismissed)
    end

    -- Which quests are in it?
    wipe(inZone)
    if zone then
        if db.matchObjectives then
            for mapID in pairs(zone.maps) do
                for _, poi in ipairs(C_QuestLog.GetQuestsOnMap(mapID) or {}) do
                    if logZone[poi.questID] then inZone[poi.questID] = true end
                end
            end
        end
        for questID, logHeader in pairs(logZone) do
            if not inZone[questID] then
                if db.matchLogZone and zone.names[logHeader] then
                    inZone[questID] = true
                elseif db.matchObjectives then
                    local dest = Destination(questID)
                    if dest and zone.maps[dest.mapID] then inZone[questID] = true end
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
        Safe(Reconcile)
    end)
end

-- ---------------------------------------------------------------------------
-- Pins


local function SetPinned(questID, pinned)
    if not db or not questID then return end
    if pinned then
        db.pinned[questID] = true
        dismissed[questID] = nil
    else
        db.pinned[questID] = nil
    end
    Reconcile()
end

local function TogglePin(questID)
    SetPinned(questID, not (db and db.pinned[questID]))
end

-- ---------------------------------------------------------------------------
-- Tracker sections (Blizzard's quest module, filtered)

local Shared = {}

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

-- Blizzard only makes a quest's title clickable. Make the rest of the block (its objective lines)
-- act like the title too: left-click opens the quest in the quest log, right-click opens the menu.
local function BlockOnMouseUp(block, mouseButton)
    if block:IsMouseOver() then block:OnHeaderClick(mouseButton) end
end
local function BlockOnEnter(block) block:OnHeaderEnter() end
local function BlockOnLeave(block) block:OnHeaderLeave() end

local function MakeBlockClickable(block)
    if block.questPinClickable then return end
    block.questPinClickable = true
    block:EnableMouse(true)
    block:HookScript("OnMouseUp", BlockOnMouseUp)
    block:HookScript("OnEnter", BlockOnEnter)
    block:HookScript("OnLeave", BlockOnLeave)
end

-- Called by Blizzard's UpdateSingle before the objectives; the location line goes first.
local function AddLocationLine(block, isZoneSection)
    MakeBlockClickable(block)
    if db and db.showLocation then
        local text = LocationText(block.id, isZoneSection)
        if text then
            block:AddObjective("QuestPinLocation", text, nil, true, OBJECTIVE_DASH_STYLE_HIDE,
                OBJECTIVE_TRACKER_COLOR["Normal"])
        end
    end
end

function Shared:DoQuestObjectives(block, ...)
    Safe(AddLocationLine, block, self.isZoneSection)
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

-- Quests ready to turn in show in their own section instead of Pinned or the zone section.
local function IsReady(questID)
    return C_QuestLog.IsComplete(questID)
end

function QuestPinZoneTrackerMixin:ShouldDisplayQuest(quest)
    local questID = quest:GetID()
    -- Pinned quests show in the Pinned section instead.
    return inZone[questID] and not (db and db.pinned[questID]) and not IsReady(questID)
        and QuestObjectiveTrackerMixin.ShouldDisplayQuest(self, quest)
end

QuestPinPinnedTrackerMixin = CreateFromMixins(QuestObjectiveTrackerMixin, Shared, {
    headerText = PINNED_HEADER,
})

-- Only quests you pinned. Quests Blizzard auto-tracks (on accept, or when objectives update) never
-- show here; Reconcile untracks them if they aren't in your zone.
function QuestPinPinnedTrackerMixin:ShouldDisplayQuest(quest)
    local questID = quest:GetID()
    return db and db.pinned[questID] and not IsReady(questID)
        and QuestObjectiveTrackerMixin.ShouldDisplayQuest(self, quest)
end

-- Auto-quest popups ("click to complete") show once, in the zone section.
function QuestPinPinnedTrackerMixin:AddAutoQuestObjectives()
end

QuestPinReadyTrackerMixin = CreateFromMixins(QuestObjectiveTrackerMixin, Shared, {
    headerText = READY_HEADER,
})

-- Finished quests that would otherwise show in Pinned or the zone section.
function QuestPinReadyTrackerMixin:ShouldDisplayQuest(quest)
    local questID = quest:GetID()
    return IsReady(questID) and ((db and db.pinned[questID]) or inZone[questID])
        and QuestObjectiveTrackerMixin.ShouldDisplayQuest(self, quest)
end

function QuestPinReadyTrackerMixin:AddAutoQuestObjectives()
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

    -- Pinned, then the zone section, then Ready to turn in.
    local order = blizzard.uiOrder or 4
    QuestPinPinnedTracker.uiOrder = order - 0.5
    QuestPinZoneTracker.uiOrder = order
    QuestPinReadyTracker.uiOrder = order + 0.5

    container:RemoveModule(blizzard)
    manager.moduleToContainerMap[blizzard] = nil
    blizzard:Hide()

    manager:SetModuleContainer(QuestPinZoneTracker, container)
    manager:SetModuleContainer(QuestPinPinnedTracker, container)
    manager:SetModuleContainer(QuestPinReadyTracker, container)
    Reconcile()
end

-- ---------------------------------------------------------------------------
-- Quest log

-- The track box is Blizzard's own, but its tick means "pinned": zone quests that are tracked but
-- not pinned show an empty box. Blizzard shows and hides the tick itself, so we fade it instead.
-- Zone headers show how many of their quests are grey / green / yellow / orange / red, just left
-- of the +.
local DIFFICULTY_BUCKETS -- RelativeContentDifficulty -> 1 grey, 2 green, 3 yellow, 4 orange, 5 red
local BUCKET_COLORS = {}  -- bucket -> "ffRRGGBB"

local function SetUpDifficulty()
    local d = Enum and Enum.RelativeContentDifficulty
    if DIFFICULTY_BUCKETS or not d or not GetDifficultyColor then return DIFFICULTY_BUCKETS end
    DIFFICULTY_BUCKETS = {
        [d.Trivial] = 1, [d.Easy] = 2, [d.Fair] = 3, [d.Difficult] = 4, [d.Impossible] = 5,
    }
    for diff, bucket in pairs(DIFFICULTY_BUCKETS) do
        local c = GetDifficultyColor(diff)
        if c and c.r then
            BUCKET_COLORS[bucket] = ("ff%02x%02x%02x"):format(floor(c.r * 255 + 0.5), floor(c.g * 255 + 0.5), floor(c.b * 255 + 0.5))
        end
    end
    return DIFFICULTY_BUCKETS
end

-- questLogIndex of each header -> { grey, green, yellow, orange, red }
local function CountByHeader()
    local buckets = SetUpDifficulty()
    if not buckets or not C_PlayerInfo or not C_PlayerInfo.GetContentDifficultyQuestForPlayer then return end
    local counts, current = {}, nil
    for i = 1, C_QuestLog.GetNumQuestLogEntries() do
        local info = C_QuestLog.GetInfo(i)
        if info then
            if info.isHeader then
                current = { 0, 0, 0, 0, 0 }
                counts[i] = current
            elseif current and not info.isHidden and not info.isTask and not info.isBounty then
                local bucket = buckets[C_PlayerInfo.GetContentDifficultyQuestForPlayer(info.questID)]
                if bucket then current[bucket] = current[bucket] + 1 end
            end
        end
    end
    return counts
end

-- Only colors that have quests, e.g. "3/1" (green, orange); nil when there are none.
local function CountsText(c)
    local parts = {}
    for bucket = 1, 5 do
        if c[bucket] > 0 then
            parts[#parts + 1] = ("|c%s%d|r"):format(BUCKET_COLORS[bucket] or "ffffffff", c[bucket])
        end
    end
    if #parts > 0 then return table.concat(parts, "|cff808080/|r") end
end

local function UpdateLogHeaders()
    local pool = QuestScrollFrame and QuestScrollFrame.headerFramePool
    if not pool then return end
    local counts = CountByHeader()
    for header in pool:EnumerateActive() do
        local text = header.ButtonText
        local collapse = header.CollapseButton
        if text and collapse then
            local label = header.questPinCounts
            if not label then
                label = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                label:SetPoint("RIGHT", collapse, "LEFT", -4, 0)
                header.questPinCounts = label
                -- Keep the zone name from running under the counts.
                text:SetPoint("RIGHT", label, "LEFT", -4, 0)
            end
            local c = counts and counts[header.questLogIndex]
            local countsText = c and CountsText(c)
            if countsText then
                label:SetText(countsText)
                label:Show()
            else
                label:Hide()
            end
        end
    end
end

UpdateLogRows = function()
    if not db or not QuestScrollFrame or not QuestScrollFrame.titleFramePool then return end
    for button in QuestScrollFrame.titleFramePool:EnumerateActive() do
        local tick = button.Checkbox and button.Checkbox.CheckMark
        if tick then
            local questID = button.questID
            tick:SetAlpha((not questID or db.pinned[questID]) and 1 or 0)
        end
    end
    UpdateLogHeaders()
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
        GameTooltip:AddLine("Tick the box to pin it: tracked in every zone", 0.6, 0.6, 0.6)
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
    -- Untracking a quest (tracker "Stop tracking", shift-click) unpins it, and hides a zone quest
    -- until you leave the zone.
    local removedID, removedWasPinned
    hooksecurefunc(C_QuestLog, "RemoveQuestWatch", function(questID)
        if busy or not questID or not db then return end
        removedID, removedWasPinned = questID, db.pinned[questID]
        db.pinned[questID] = nil
        if inZone[questID] then dismissed[questID] = true end
        Refresh()
    end)

    -- The quest log's track box toggles the pin. Blizzard's click tracks or untracks the quest,
    -- so we turn that into pin / unpin afterwards.
    if QuestMapQuestOptions_TrackQuest then
        hooksecurefunc("QuestMapQuestOptions_TrackQuest", function(questID)
            if busy or not questID or not db then return end
            if C_QuestLog.GetQuestWatchType(questID) ~= nil then
                SetPinned(questID, true) -- ticked an untracked quest
            elseif removedID == questID and not removedWasPinned then
                SetPinned(questID, true) -- clicked a tracked zone quest whose box was empty
            else
                dismissed[questID] = nil -- unpinned: stays tracked if it's in your zone
                Reconcile()
            end
            removedID = nil
        end)
    end

    if QuestLogQuests_Update then hooksecurefunc("QuestLogQuests_Update", function() Safe(UpdateLogRows) end) end

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
    flight = { key = "holdInFlight", label = "Keep tracking your last zone while flying, until you land" },
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
        for _, name in ipairs({ "auto", "objectives", "logzone", "location", "flight" }) do
            Print(("/qpin %s - %s (%s)"):format(name, TOGGLES[name].label, OnOff(db[TOGGLES[name].key])))
        end
        Print("In the quest log, tick a quest's box (or right-click > Pin quest) to pin it.")
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
        self:RegisterEvent("QUEST_WATCH_LIST_CHANGED") -- untrack Blizzard's auto-tracked quests promptly
        self:RegisterEvent("QUEST_ACCEPTED")
        self:RegisterEvent("QUEST_REMOVED")
        self:RegisterEvent("QUEST_TURNED_IN")
        self:RegisterEvent("PLAYER_CONTROL_GAINED") -- flight path landing
    elseif event == "PLAYER_ENTERING_WORLD" then
        Install()
        Refresh(0.5)
    elseif event == "QUEST_ACCEPTED" then
        -- Some clients send (questLogIndex, questID), others just (questID).
        local a, b = ...
        local questID = b or a
        local zone = CurrentZone()
        if questID and zone and zone.name then db.giver[questID] = zone.name end
        Refresh()
    elseif event == "QUEST_TURNED_IN" then
        -- The tracker plays a turn-in animation first; lay the sections out again once it's done,
        -- so an emptied Ready to turn in section goes away.
        C_Timer.After(2, UpdateTrackerSections)
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
