-- SPDX-License-Identifier: GPL-3.0-or-later
-- compat.lua: Runtime compatibility layer for Retail and Classic clients.

RuneReaderVoice = RuneReaderVoice or {}

local RRV = RuneReaderVoice

local Compat = {}
RRV.Compat = Compat

local function SafeCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d = pcall(fn, ...)
    if ok then return a, b, c, d end
    return nil
end

local function ProjectEquals(name)
    return _G[name] ~= nil and WOW_PROJECT_ID == _G[name]
end

-- Interface (.toc) version of the running client, e.g. 120100, 16001, 11509.
local function ReadInterfaceVersion()
    if type(GetBuildInfo) ~= "function" then return 0 end
    local ok, v = pcall(function() return select(4, GetBuildInfo()) end)
    if ok and type(v) == "number" and v > 0 then
        return v
    end
    return 0
end

-- Map an interface (.toc) version to a client flavor.
-- The interface number is the reliable signal: game types derived from the
-- Mainline client can report the same WOW_PROJECT_ID as Mainline (e.g. WoW
-- Forever reports 1, identical to Midnight) yet always carry a distinct
-- interface number.
--
--   >= 100000       retail / mainline (10.x, 11.x, 12.x Midnight, ...)
--   50000 - 59999   classic mists
--   40000 - 49999   classic cataclysm
--   30000 - 39999   classic wrath (incl. Titan Reforged 38xxx)
--   20000 - 29999   classic tbc
--   16000 - 19999   forever (1.60.x)
--   10000 - 15999   classic era (vanilla)
local function FlavorFromInterface(iface)
    if not iface or iface <= 0 then return nil end
    if iface >= 100000 then return "retail"        end
    if iface >= 50000  then return "classic_mists" end
    if iface >= 40000  then return "classic_cata"  end
    if iface >= 30000  then return "classic_wrath" end
    if iface >= 20000  then return "classic_bcc"   end
    if iface >= 16000  then return "forever"       end
    if iface >= 10000  then return "classic_era"   end
    return nil
end

local function DetectFlavor()
    -- Interface number first - see FlavorFromInterface for why.
    local flavor = FlavorFromInterface(ReadInterfaceVersion())
    if flavor then return flavor end

    -- Fallback when the interface number is unavailable.
    if ProjectEquals("WOW_PROJECT_MAINLINE")                then return "retail" end
    if ProjectEquals("WOW_PROJECT_CLASSIC")                 then return "classic_era" end
    if ProjectEquals("WOW_PROJECT_BURNING_CRUSADE_CLASSIC") then return "classic_bcc" end
    if ProjectEquals("WOW_PROJECT_WRATH_CLASSIC")           then return "classic_wrath" end
    if ProjectEquals("WOW_PROJECT_CATACLYSM_CLASSIC")       then return "classic_cata" end
    if ProjectEquals("WOW_PROJECT_MISTS_CLASSIC")           then return "classic_mists" end
    return "unknown"
end

Compat.Flavor = DetectFlavor()
-- Forever runs the Mainline UI/API, so treat it as mainline for API branching.
Compat.IsRetail  = (Compat.Flavor == "retail" or Compat.Flavor == "forever")
Compat.IsClassic = not Compat.IsRetail

function Compat:SafeCall(fn, ...)
    return SafeCall(fn, ...)
end

function Compat:RegisterEvent(frame, eventName)
    if not frame or not eventName then return false end
    local ok = pcall(function() frame:RegisterEvent(eventName) end)
    if not ok and RRV.Dbg then
        RRV:Dbg("Compat: event not available on " .. tostring(self.Flavor) .. ": " .. tostring(eventName))
    end
    return ok
end

function Compat:GetGossipText()
    if C_GossipInfo and C_GossipInfo.GetText then
        local t = SafeCall(C_GossipInfo.GetText)
        if t and #t > 0 then return t, "C_GossipInfo.GetText" end
    end
    if GetGossipText then
        local t = SafeCall(GetGossipText)
        if t and #t > 0 then return t, "GetGossipText" end
    end
    if GossipGreetingText and GossipGreetingText.GetText then
        local t = SafeCall(function() return GossipGreetingText:GetText() end)
        if t and #t > 0 then return t, "GossipGreetingText" end
    end
    return nil, nil
end

function Compat:GetGreetingText()  return SafeCall(GetGreetingText) or "" end
function Compat:GetQuestTitle()    return SafeCall(GetTitleText) or "" end
function Compat:GetQuestText()     return SafeCall(GetQuestText) or "" end
function Compat:GetObjectiveText() return SafeCall(GetObjectiveText) or "" end
function Compat:GetProgressText()  return SafeCall(GetProgressText) or "" end
function Compat:GetRewardText()    return SafeCall(GetRewardText) or "" end

-- ── Client / quest identity ───────────────────────────────────────────────────

-- Interface (TOC) version of the running client, e.g. 120007, 11507, 50500.
-- Cached after the first read. Returns 0 when unavailable.
local _cachedBuildVersion = nil

function Compat:GetBuildVersion()
    if _cachedBuildVersion ~= nil then return _cachedBuildVersion end
    _cachedBuildVersion = ReadInterfaceVersion()
    return _cachedBuildVersion
end

-- Quest ID for the quest currently shown in the quest frame.
-- Tries the modern API first, then the classic global. Returns a positive
-- integer, or nil when no quest is active or the value is unavailable/secret.
function Compat:GetQuestID()
    local ok, result = pcall(function()
        local id
        if C_QuestLog and C_QuestLog.GetQuestIDForQuestFrame then
            id = C_QuestLog.GetQuestIDForQuestFrame()
        end
        if (not id or id == 0) and type(GetQuestID) == "function" then
            id = GetQuestID()
        end

        if id == nil then return nil end
        if issecretvalue and issecretvalue(id) then return nil end

        id = tonumber(id)
        if id and id > 0 then return id end
        return nil
    end)

    if ok then return result end
    return nil
end

function Compat:GetItemText()
    return SafeCall(ItemTextGetText) or ""
end

function Compat:GetItemName()
    return SafeCall(ItemTextGetItem) or ""
end

function Compat:GetItemPage()
    return SafeCall(ItemTextGetPage) or 1
end

function Compat:HasNextItemPage()
    if ItemTextHasNextPage then
        local v = SafeCall(ItemTextHasNextPage)
        return not not v, true
    end
    return nil, false
end

function Compat:NextItemPage()
    if not ItemTextNextPage then return false end
    SafeCall(ItemTextNextPage)
    return true
end

function Compat:PrevItemPage()
    if not ItemTextPrevPage then return false end
    SafeCall(ItemTextPrevPage)
    return true
end

function Compat:GetDisplayedItemText()
    if ItemTextPageText and ItemTextPageText.GetText then
        return SafeCall(function() return ItemTextPageText:GetText() end) or ""
    end
    return ""
end

local UnitTokens = { "target", "questnpc", "npc" }

function Compat:GetUnitSex()
    for _, token in ipairs(UnitTokens) do
        local sex = SafeCall(UnitSex, token)
        if (issecretvalue(sex)) then return 0 end
        if sex then return sex end
    end
    return 1
end

function Compat:GetNPCGender()
    local sex = self:GetUnitSex()

    if sex == 2 then return "male" end
    if sex == 3 then return "female" end
    return "unknown"
end

function Compat:GetRaceID()
    for _, token in ipairs(UnitTokens) do
        local _, _, raceID = SafeCall(UnitRace, token)
        if raceID then return raceID, token end
    end
    return nil, nil
end

function Compat:GetCreatureType()
    for _, token in ipairs(UnitTokens) do
        local creatureType = SafeCall(UnitCreatureType, token)
        if creatureType then return creatureType, token end
    end
    return nil, nil
end

function Compat:GetUnitGUID()
    -- Preserve previous addon priority: npc first, then target, then questnpc.
    return SafeCall(UnitGUID, "npc") or SafeCall(UnitGUID, "target") or SafeCall(UnitGUID, "questnpc")
end

function Compat:GetUnitName()
    return SafeCall(UnitName, "target") or SafeCall(UnitName, "npc") or SafeCall(UnitName, "questnpc")
end

function Compat:HookOnHide(frame, callback)
    if not frame or not frame.HookScript then return false end
    local ok = pcall(function() frame:HookScript("OnHide", callback) end)
    return ok
end

RRV.Flavor = Compat.Flavor
RRV.IsRetail = Compat.IsRetail
RRV.IsClassic = Compat.IsClassic
