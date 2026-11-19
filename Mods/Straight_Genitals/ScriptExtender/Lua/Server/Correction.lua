--------------------------------------------------------------------------------
-- Straight Genitals - in-game correction (server only)
--
-- Watches characters' CharacterCreationAppearance.Visuals (where the game, and
-- mods like Immersive Nudity and BG3SX, put the "Private Parts" visual). If a
-- character ends up with the wrong genital for their body:
--   * a penis on a female body (BodyType 1), or
--   * a vulva on a male body   (BodyType 0)
-- it swaps it for the matching one for the same race, body type and body
-- shape. If no matching one exists for that race, the wrong one is removed.
--
-- It never ADDS a genital to someone who has none, so it can't fight a mod
-- (or the game) that intentionally leaves a character without one.
--------------------------------------------------------------------------------

local SG = SG
local LOG_PREFIX = SG.LOG_PREFIX

local CCAV = "CharacterCreationAppearanceVisual"

-- How long to wait after a change before checking, so another mod can finish
-- whatever it is doing (Immersive Nudity removes then adds; BG3SX swaps).
local CHECK_DELAY_MS = 300

-- Loop guard: if we have to fix the same character this many times within
-- the window, something else keeps putting the wrong one back. Stop and warn
-- instead of fighting it forever.
local MAX_FIXES = 5
local FIX_WINDOW_MS = 60000

local pendingChecks = {}   -- entity uuid -> true while a check is scheduled
local fixHistory = {}      -- entity uuid -> { timestamps }
local givenUp = {}         -- entity uuid -> true

local function Log(msg) Ext.Utils.Print(LOG_PREFIX .. msg) end
local function Warn(msg) Ext.Utils.PrintWarning(LOG_PREFIX .. msg) end

local function GetCCAV(uuid)
    local ok, res = pcall(Ext.StaticData.Get, uuid, CCAV)
    if ok then return res end
    return nil
end

local function GetName(resource)
    local ok, name = pcall(function()
        return Ext.Loca.GetTranslatedString(resource.DisplayName.Handle.Handle)
    end)
    if ok and name and name ~= "" then return name end
    return "?"
end

local function EntityUuid(entity)
    local ok, uuid = pcall(function() return entity.Uuid.EntityUuid end)
    if ok then return uuid end
    return nil
end

local function EntityLabel(entity)
    local uuid = EntityUuid(entity)
    local ok, name = pcall(function() return Osi.GetDisplayName(uuid) end)
    local display = nil
    if ok and name then
        local okLoca, text = pcall(Ext.Loca.GetTranslatedString, name)
        display = okLoca and text or nil
    end
    return string.format("%s (%s)", display or "?", tostring(uuid))
end

--------------------------------------------------------------------------------
-- Race lookup
--------------------------------------------------------------------------------

-- race tag -> race uuid, built from the Race static data so modded races work
local raceTagMap = nil

local function BuildRaceTagMap()
    if raceTagMap then return raceTagMap end
    raceTagMap = {}
    local ok, races = pcall(Ext.StaticData.GetAll, "Race")
    if ok and races then
        for _, raceId in pairs(races) do
            local okR, race = pcall(Ext.StaticData.Get, raceId, "Race")
            if okR and race and race.Tags then
                for _, tag in pairs(race.Tags) do
                    if not raceTagMap[tag] then raceTagMap[tag] = raceId end
                end
            end
        end
    end
    return raceTagMap
end

local function GetParentRace(raceId)
    local ok, race = pcall(Ext.StaticData.Get, raceId, "Race")
    if ok and race then
        local parent = race.ParentGuid
        if parent and parent ~= "" and parent ~= "00000000-0000-0000-0000-000000000000" then
            return parent
        end
    end
    return nil
end

-- Ordered list of race uuids to try when looking for a replacement
local function GetRaceCandidates(entity, wrongId)
    local list, seen = {}, {}
    local function add(race)
        if race and race ~= "" and not seen[race] then
            seen[race] = true
            list[#list + 1] = race
            local parent = GetParentRace(race)
            if parent and not seen[parent] then
                seen[parent] = true
                list[#list + 1] = parent
            end
        end
    end

    -- Player characters
    pcall(function() add(entity.CharacterCreationStats.Race) end)
    pcall(function() add(entity.CharacterCreationStats.SubRace) end)

    -- NPCs (and players) carry race tags
    local map = BuildRaceTagMap()
    pcall(function()
        for _, tag in pairs(entity.ServerRaceTag.Tags) do add(map[tag]) end
    end)
    pcall(function()
        for _, tag in pairs(entity.Tag.Tags) do add(map[tag]) end
    end)

    -- Last resort: whatever race the wrong genital was made for (its real
    -- race, from before Straight Genitals hid it from Character Creation)
    add(SG.GetOriginalRace(wrongId))
    pcall(function()
        local race = GetCCAV(wrongId).RaceUUID
        if race ~= SG.HIDDEN_RACE then add(race) end
    end)

    return list
end

--------------------------------------------------------------------------------
-- Replacement lookup
--------------------------------------------------------------------------------

-- Prefer the plain vanilla-named options, then anything except "Default".
local function Score(resource, wantKind)
    local name = GetName(resource)
    if wantKind == "penis" and name == "Penis" then return 3 end
    if wantKind == "vulva" and name == "Vulva" then return 3 end
    if name ~= "Default" then return 2 end
    return 1
end

local function FindReplacement(entity, bodyType, bodyShape, wrongId)
    local wantKind = (bodyType == SG.BODYTYPE_FEMALE) and "vulva" or "penis"

    -- Group correct-kind options by race once per call
    local byRace = {}
    for _, uuid in pairs(SG.GetAllPrivateParts()) do
        local res = GetCCAV(uuid)
        if res and res.BodyType == bodyType and res.BodyShape == bodyShape
            and SG.GenitalKind(res) == wantKind then
            local race = res.RaceUUID
            byRace[race] = byRace[race] or {}
            table.insert(byRace[race], { uuid = uuid, score = Score(res, wantKind) })
        end
    end

    for _, race in ipairs(GetRaceCandidates(entity, wrongId)) do
        local options = byRace[race]
        if options and #options > 0 then
            table.sort(options, function(a, b)
                if a.score ~= b.score then return a.score > b.score end
                return a.uuid < b.uuid
            end)
            return options[1].uuid, race
        end
    end
    return nil, nil
end

--------------------------------------------------------------------------------
-- BG3SX remembers a favourite genital per character and re-applies it after
-- scenes. If that remembered one is the wrong kind, update it too, so BG3SX
-- doesn't keep putting the wrong one back. Silently does nothing without BG3SX.
--------------------------------------------------------------------------------
local function FixBG3SXMemory(entity, wrongIds, replacement)
    pcall(function()
        local vars = entity.Vars
        local outOfSex = vars.BG3SX_OutOfSexGenital
        if outOfSex and wrongIds[outOfSex] then
            vars.BG3SX_OutOfSexGenital = replacement
        end
        local sexGenital = vars.BG3SX_SexGenital
        if sexGenital then
            local res = GetCCAV(sexGenital)
            if res and SG.IsMismatchedFor(res, entity.BodyType.BodyType) then
                vars.BG3SX_SexGenital = nil -- let BG3SX pick a matching one
            end
        end
    end)
end

--------------------------------------------------------------------------------
-- Check / fix one character
--------------------------------------------------------------------------------

local function RecordFix(uuid)
    local now = Ext.Utils.MonotonicTime()
    local history = fixHistory[uuid] or {}
    local recent = {}
    for _, t in ipairs(history) do
        if now - t < FIX_WINDOW_MS then recent[#recent + 1] = t end
    end
    recent[#recent + 1] = now
    fixHistory[uuid] = recent
    return #recent
end

-- Returns true if something was changed
local function CheckEntity(entity)
    if not entity then return false end
    local uuid = EntityUuid(entity)
    if not uuid or givenUp[uuid] then return false end

    local okBT, bodyType = pcall(function() return entity.BodyType.BodyType end)
    if not okBT or (bodyType ~= SG.BODYTYPE_MALE and bodyType ~= SG.BODYTYPE_FEMALE) then
        return false
    end

    local okV, visuals = pcall(function() return entity.CharacterCreationAppearance.Visuals end)
    if not okV or not visuals then return false end

    -- Find wrong genitals
    local wrong, wrongIds = {}, {}
    for _, id in pairs(visuals) do
        local res = GetCCAV(id)
        if res and res.SlotName == SG.SLOT_NAME and SG.IsMismatchedFor(res, bodyType) then
            wrong[#wrong + 1] = { id = id, res = res }
            wrongIds[id] = true
        end
    end
    if #wrong == 0 then return false end

    -- Loop guard
    if RecordFix(uuid) > MAX_FIXES then
        givenUp[uuid] = true
        Warn(string.format(
            "Something keeps giving %s the wrong genital (%d times in %ds). Leaving them alone this session. Check your other mods' scripts.",
            EntityLabel(entity), MAX_FIXES, FIX_WINDOW_MS // 1000))
        return false
    end

    local okBS, bodyShape = pcall(function() return entity.CharacterCreationStats.BodyShape end)
    if not okBS or bodyShape == nil then
        bodyShape = wrong[1].res.BodyShape or 0
        if bodyShape == SG.HIDDEN_BODYSHAPE then bodyShape = SG.GetOriginalBodyShape(wrong[1].id) or 0 end
    end

    local replacement = FindReplacement(entity, bodyType, bodyShape, wrong[1].id)

    -- Rebuild the visuals list without the wrong genital(s); add replacement
    -- unless the character already has a correct one.
    local newVisuals, hasCorrect = {}, false
    for _, id in pairs(visuals) do
        if not wrongIds[id] then
            newVisuals[#newVisuals + 1] = id
            local res = GetCCAV(id)
            if res and res.SlotName == SG.SLOT_NAME and SG.GenitalKind(res) ~= nil then
                hasCorrect = true
            end
        end
    end
    if replacement and not hasCorrect then
        newVisuals[#newVisuals + 1] = replacement
    end

    local okSet = pcall(function() entity.CharacterCreationAppearance.Visuals = newVisuals end)
    if not okSet then
        Warn("Could not change visuals for " .. EntityLabel(entity))
        return false
    end
    pcall(function() entity:Replicate("CharacterCreationAppearance") end)
    pcall(function() entity:Replicate("GameObjectVisual") end)

    if replacement and not hasCorrect then
        FixBG3SXMemory(entity, wrongIds, replacement)
    end

    local wrongNames = {}
    for _, w in ipairs(wrong) do wrongNames[#wrongNames + 1] = GetName(w.res) .. " " .. w.id end
    if hasCorrect then
        Log(string.format("%s: removed wrong genital [%s] (already had a correct one).",
            EntityLabel(entity), table.concat(wrongNames, ", ")))
    elseif replacement then
        Log(string.format("%s: replaced wrong genital [%s] with %s %s.",
            EntityLabel(entity), table.concat(wrongNames, ", "), GetName(GetCCAV(replacement)), replacement))
    else
        Warn(string.format("%s: removed wrong genital [%s]; no matching one exists for their race/body.",
            EntityLabel(entity), table.concat(wrongNames, ", ")))
    end
    return true
end

local function ScheduleCheck(entity, delay)
    local uuid = EntityUuid(entity)
    if not uuid or pendingChecks[uuid] or givenUp[uuid] then return end
    pendingChecks[uuid] = true
    Ext.Timer.WaitFor(delay or CHECK_DELAY_MS, function()
        pendingChecks[uuid] = nil
        local fresh = Ext.Entity.Get(uuid)
        local ok, err = pcall(CheckEntity, fresh)
        if not ok then Warn("Check failed for " .. tostring(uuid) .. ": " .. tostring(err)) end
    end)
end

local function CheckAll(reason)
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "CharacterCreationAppearance")
    if not ok or not entities then return end
    local fixed = 0
    for _, entity in pairs(entities) do
        local okC, changed = pcall(CheckEntity, entity)
        if okC and changed then fixed = fixed + 1 end
    end
    Log(string.format("Checked %d character(s), fixed %d (%s).", #entities, fixed, reason))
end

--------------------------------------------------------------------------------
-- Hooks
--------------------------------------------------------------------------------

-- 1) Any time a character's appearance visuals change. Immersive Nudity and
--    BG3SX both replicate CharacterCreationAppearance after editing it.
local function OnAppearanceChanged(entity)
    ScheduleCheck(entity)
end

local subscribed = false
if Ext.Entity.OnChange then
    subscribed = pcall(Ext.Entity.OnChange, "CharacterCreationAppearance", OnAppearanceChanged)
end
if not subscribed and Ext.Entity.Subscribe then
    subscribed = pcall(Ext.Entity.Subscribe, "CharacterCreationAppearance", OnAppearanceChanged)
end
if not subscribed then
    Warn("Could not watch appearance changes; only load-time and status-based checks will run. Update Script Extender.")
end

-- 2) Immersive Nudity marks stripped characters with this status. Check them
--    shortly after, and once more later in case it applies genitals on a timer.
local IMMERSIVE_NUDITY_STATUS = "INSP_STRIPPED_VISUALS"
Ext.Osiris.RegisterListener("StatusApplied", 4, "after", function(target, status)
    if status == IMMERSIVE_NUDITY_STATUS then
        local entity = Ext.Entity.Get(target)
        if entity then
            ScheduleCheck(entity, 500)
            Ext.Timer.WaitFor(2500, function()
                local fresh = Ext.Entity.Get(target)
                if fresh then ScheduleCheck(fresh, 0) end
            end)
        end
    end
end)

-- 3) After loading a save / entering a level, sweep everyone once.
Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "after", function()
    Ext.Timer.WaitFor(3000, function() CheckAll("level loaded") end)
end)

-- Console commands:
--   !sg_fix     check every loaded character now
--   !sg_unblock let the loop guard try again on characters it gave up on
Ext.RegisterConsoleCommand("sg_fix", function() CheckAll("console") end)
Ext.RegisterConsoleCommand("sg_unblock", function()
    givenUp = {}
    fixHistory = {}
    Log("Loop guard reset.")
end)
