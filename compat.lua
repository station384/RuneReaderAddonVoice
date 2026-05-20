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

local function DetectFlavor()
    if ProjectEquals("WOW_PROJECT_MAINLINE") then return "retail" end
    if ProjectEquals("WOW_PROJECT_CLASSIC") then return "classic_era" end
    if ProjectEquals("WOW_PROJECT_BURNING_CRUSADE_CLASSIC") then return "classic_bcc" end
    if ProjectEquals("WOW_PROJECT_WRATH_CLASSIC") then return "classic_wrath" end
    if ProjectEquals("WOW_PROJECT_CATACLYSM_CLASSIC") then return "classic_cata" end
    if ProjectEquals("WOW_PROJECT_MISTS_CLASSIC") then return "classic_mists" end
    return "unknown"
end

Compat.Flavor = DetectFlavor()
Compat.IsRetail = Compat.Flavor == "retail"
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
