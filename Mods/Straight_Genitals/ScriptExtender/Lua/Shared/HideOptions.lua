--------------------------------------------------------------------------------
-- Straight Genitals - hide mismatched options (client + server)
--
-- In Character Creation (and the Magic Mirror), the "Private Parts" list is
-- built from CharacterCreationAppearanceVisual entries. The game shows an entry
-- when its RaceUUID, BodyType and BodyShape match the character being edited.
--
--   BodyType 0 = male body   (body types 2 / 4 in the CC UI; 4 = strong)
--   BodyType 1 = female body (body types 1 / 3 in the CC UI; 3 = strong)
--   BodyShape 0 = regular, 1 = strong
--
-- Every genital entry carries a tag saying what it is:
--   PENIS = d27831df-2891-42e4-b615-ae555404918b
--   VULVA = a0738fdf-ca0c-446f-a11d-6211ecac3291
--
-- Vanilla, BFPPSA, BG3SX (and any other genital mod) all use these same tags,
-- so instead of hard-coding a list of UUIDs, this script walks over every
-- loaded entry once the game data is loaded and hides the mismatched ones:
--   * penises on a female body (BodyType 1)
--   * vulvas  on a male body   (BodyType 0)
--
-- "Hiding" means pointing the entry's RaceUUID at a race that doesn't exist,
-- so it never matches anything in the CC list. The mesh (VisualResource) is
-- left alone, so nothing that already uses one of these visuals breaks.
--------------------------------------------------------------------------------

SG = {}

SG.LOG_PREFIX = "[Straight Genitals] "
SG.SLOT_NAME = "Private Parts"
SG.TAG_PENIS = "d27831df-2891-42e4-b615-ae555404918b"
SG.TAG_VULVA = "a0738fdf-ca0c-446f-a11d-6211ecac3291"
SG.BODYTYPE_MALE = 0
SG.BODYTYPE_FEMALE = 1

-- A made-up race UUID. No race uses it, so entries pointing at it never show.
SG.HIDDEN_RACE = "5a7e0f1c-9b3d-4e62-8f4a-2c1d7e9b0a35"
-- Fallback if RaceUUID can't be written for some reason: a body shape no
-- character has (vanilla only uses 0 and 1; custom races go up to ~3).
SG.HIDDEN_BODYSHAPE = 200

local CCAV = "CharacterCreationAppearanceVisual"
local LOG_PREFIX = SG.LOG_PREFIX

-- uuid -> { RaceUUID = original, BodyShape = original }, so changes can be undone
local originals = {}

local function hasTag(tags, wanted)
    if not tags then return false end
    for _, tag in pairs(tags) do
        if tag == wanted then return true end
    end
    return false
end

-- Returns "penis", "vulva" or nil
function SG.GenitalKind(resource)
    local penis = hasTag(resource.Tags, SG.TAG_PENIS)
    local vulva = hasTag(resource.Tags, SG.TAG_VULVA)
    if penis and not vulva then return "penis" end
    if vulva and not penis then return "vulva" end
    return nil
end

-- Is this genital the wrong kind for a character/body of the given BodyType?
function SG.IsMismatchedFor(resource, bodyType)
    local kind = SG.GenitalKind(resource)
    if kind == "penis" and bodyType == SG.BODYTYPE_FEMALE then return true end
    if kind == "vulva" and bodyType == SG.BODYTYPE_MALE then return true end
    return false
end

-- Race / body shape an entry had before we hid it
function SG.GetOriginalRace(uuid)
    local o = uuid and originals[uuid]
    return o and o.RaceUUID or nil
end

function SG.GetOriginalBodyShape(uuid)
    local o = uuid and originals[uuid]
    return o and o.BodyShape or nil
end

-- All "Private Parts" entry UUIDs (cached; the list doesn't change mid-game)
local privatePartsCache = nil
function SG.GetAllPrivateParts()
    if privatePartsCache then return privatePartsCache end
    local list = {}
    local ok, all = pcall(Ext.StaticData.GetAll, CCAV)
    if ok and all then
        for _, uuid in pairs(all) do
            local okR, res = pcall(Ext.StaticData.Get, uuid, CCAV)
            if okR and res and res.SlotName == SG.SLOT_NAME then
                list[#list + 1] = uuid
            end
        end
    end
    if #list > 0 then privatePartsCache = list end
    return list
end

local function hide(uuid, resource)
    if not originals[uuid] then
        originals[uuid] = { RaceUUID = resource.RaceUUID, BodyShape = resource.BodyShape }
    end

    if resource.RaceUUID == SG.HIDDEN_RACE or resource.BodyShape == SG.HIDDEN_BODYSHAPE then
        return true -- already hidden
    end

    local ok = pcall(function() resource.RaceUUID = SG.HIDDEN_RACE end)
    if ok and resource.RaceUUID == SG.HIDDEN_RACE then
        return true
    end

    ok = pcall(function() resource.BodyShape = SG.HIDDEN_BODYSHAPE end)
    return ok and resource.BodyShape == SG.HIDDEN_BODYSHAPE
end

local function apply(reason)
    privatePartsCache = nil
    local all = SG.GetAllPrivateParts()
    if #all == 0 then
        Ext.Utils.PrintWarning(LOG_PREFIX .. "No Private Parts options found yet (" .. tostring(reason) .. ")")
        return
    end

    local hiddenPenises, hiddenVulvas, failed = 0, 0, 0

    for _, uuid in ipairs(all) do
        local resource = Ext.StaticData.Get(uuid, CCAV)
        if resource and SG.IsMismatchedFor(resource, resource.BodyType) then
            if hide(uuid, resource) then
                if SG.GenitalKind(resource) == "penis" then
                    hiddenPenises = hiddenPenises + 1
                else
                    hiddenVulvas = hiddenVulvas + 1
                end
            else
                failed = failed + 1
            end
        end
    end

    local context = Ext.IsServer() and "server" or "client"
    Ext.Utils.Print(string.format(
        "%sHid %d penis option(s) on female bodies and %d vulva option(s) on male bodies (%s, %s).",
        LOG_PREFIX, hiddenPenises, hiddenVulvas, context, tostring(reason)))
    if failed > 0 then
        Ext.Utils.PrintWarning(string.format("%s%d option(s) could not be hidden.", LOG_PREFIX, failed))
    end
end

local function restore()
    local count = 0
    for uuid, orig in pairs(originals) do
        local resource = Ext.StaticData.Get(uuid, CCAV)
        if resource then
            pcall(function() resource.RaceUUID = orig.RaceUUID end)
            pcall(function() resource.BodyShape = orig.BodyShape end)
            count = count + 1
        end
    end
    originals = {}
    Ext.Utils.Print(string.format("%sRestored %d option(s).", LOG_PREFIX, count))
end

-- Run once the game data is loaded, and again on session load so entries from
-- every mod in the load order are covered no matter where this mod sits.
-- Running more than once is harmless.
Ext.Events.StatsLoaded:Subscribe(function() apply("StatsLoaded") end)
Ext.Events.SessionLoaded:Subscribe(function() apply("SessionLoaded") end)
Ext.Events.ResetCompleted:Subscribe(function() apply("ResetCompleted") end)

-- Script Extender console commands (for checking / testing):
--   !sg_apply    hide mismatched options again
--   !sg_restore  put everything back the way it was (until the next load)
Ext.RegisterConsoleCommand("sg_apply", function() apply("console") end)
Ext.RegisterConsoleCommand("sg_restore", function() restore() end)
