-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- This file is part of RuneReaderVoice.
--
-- Copyright (C) 2026 Michael Sutton
--
-- RuneReaderVoice is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.

-- frames_code39.lua: Code39 identity side-channel frames.
--
-- Critical WoW secret-value rule:
--   Runtime GUID/name values must not be inspected or transformed here.
--   No upper(), gsub(), len, tostring(), validation, parsing, encoding,
--   string-width measurement, or string-length measurement.
--   Only safe operation assumed for secret values is:
--       "literal prefix" .. secretValue .. "literal suffix"

RuneReaderVoice = RuneReaderVoice or {}

local CODE39_FONT = [[Interface\AddOns\RuneReaderVoice\Fonts\LibreBarcode39-Regular-modified.otf]]

-- Runtime Code39 payloads may contain WoW secret values. Never measure them.
-- Layout measures fixed non-secret dummy strings only.
local CODE39_GUID_WIDTH_DUMMY = "*RRVG-Creature-0-00002-0-00-0000002-0000000000343246545*"
local CODE39_NAME_WIDTH_DUMMY = "*RRVN-HIGH ABCDEFGHIJKLMNOPQRSTUVWXYZ*"
local MAX_CODE39_FONT_SIZE = 56
local CODE39_HORIZONTAL_PADDING = 2

local _guidPayload = nil
local _namePayload = nil

local function Code39Enabled()
    return RuneReaderVoiceDB and RuneReaderVoiceDB.Code39Enabled
end

local function GetFontSize()
    local n = 30 
    if n < 10 then n = 10 end
    if n > MAX_CODE39_FONT_SIZE then n = MAX_CODE39_FONT_SIZE end
    return n
end

local function SetCode39Font(fontString, fontSize)
    fontString:SetFont(CODE39_FONT, fontSize, "")
    fontString:SetShadowOffset(0, 0)
    fontString:SetShadowColor(0, 0, 0, 0)
end

local function SaveFramePosition(self)
    self:StopMovingOrSizing()
    local point, _, relativePoint, xOfs, yOfs = self:GetPoint()
    RuneReaderVoiceDB[self._rrvPositionKey] = {
        point         = point,
        relativePoint = relativePoint,
        x             = xOfs,
        y             = yOfs,
    }
end

local function ApplyFramePosition(f)
    local pos = RuneReaderVoiceDB and RuneReaderVoiceDB[f._rrvPositionKey]

    -- Backward migration: old single Code39Position becomes GUID frame position.
    if not pos and f._rrvPositionKey == "Code39GuidPosition" and RuneReaderVoiceDB then
        pos = RuneReaderVoiceDB.Code39Position
    end

    if pos then
        f:ClearAllPoints()
        f:SetPoint(pos.point or "TOPLEFT", UIParent, pos.relativePoint or "TOPLEFT", pos.x or 0, pos.y or f._rrvDefaultY)
    elseif not f._rrvPositionInitialized then
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", f._rrvDefaultX, f._rrvDefaultY)
        f._rrvPositionInitialized = true
    end
end

local function CreateOneCode39Frame(frameName, positionKey, defaultX, defaultY, dummyText)
    local f = CreateFrame("Frame", frameName, UIParent, "BackdropTemplate")
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetIgnoreParentScale(true)
    f:SetScale(1)
    f:SetBackdrop({ bgFile = "Interface/Buttons/WHITE8X8",
                    tile = true,
                    edgeSize = 0,
                    insets = {
                        left = 0,
                        right = 0,
                        top = 0,
                        bottom = 0
                    }
                })
    f:SetBackdropColor(0.3, 0.2, 0, 1)


    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")

    f._rrvPositionKey = positionKey
    f._rrvDefaultX = defaultX
    f._rrvDefaultY = defaultY
    f._rrvDummyText = dummyText

    local bar = f:CreateFontString(nil, "ARTWORK")
    bar:SetJustifyH("CENTER")
    bar:SetJustifyV("TOP")
    bar:SetTextColor(0, 0, 0, 1)
    bar:SetTextHeight(20)
    bar:SetShadowOffset(0, 0)
    bar:SetShadowColor(0, 0, 0, 0)
    if bar.SetWordWrap then bar:SetWordWrap(false) end
    if bar.SetNonSpaceWrap then bar:SetNonSpaceWrap(false) end
    f.bar = bar

    local measure = f:CreateFontString(nil, "ARTWORK")
    measure:SetTextColor(0, 0, 0, 0)
    measure:SetAlpha(0)
    measure:SetShadowOffset(0, 0)
    measure:SetShadowColor(0, 0, 0, 0)
    measure:Hide()
    f.measure = measure

    ApplyFramePosition(f)

    f:SetScript("OnDragStart", function(self)
        if IsAltKeyDown() then self:StartMoving() end
    end)

    f:SetScript("OnDragStop", SaveFramePosition)

    f:Hide()
    return f
end

local function EnsureGuidFrame()
    if RuneReaderVoice.Code39GuidFrame then return RuneReaderVoice.Code39GuidFrame end
    RuneReaderVoice.Code39GuidFrame = CreateOneCode39Frame(
        "RuneReaderVoiceCode39GuidFrame",
        "Code39GuidPosition",
        0,
        -120,
        CODE39_GUID_WIDTH_DUMMY
    )
    return RuneReaderVoice.Code39GuidFrame
end

local function EnsureNameFrame()
    if RuneReaderVoice.Code39NameFrame then return RuneReaderVoice.Code39NameFrame end
    RuneReaderVoice.Code39NameFrame = CreateOneCode39Frame(
        "RuneReaderVoiceCode39NameFrame",
        "Code39NamePosition",
        0,
        -145,
        CODE39_NAME_WIDTH_DUMMY
    )
    return RuneReaderVoice.Code39NameFrame
end

local function MeasureDummyCode39Width(f, fontSize)
    SetCode39Font(f.measure, fontSize)
    f.measure:SetText(f._rrvDummyText)
    local width = f.measure:GetStringWidth() or 0

    -- Width comes from fixed non-secret dummy text, so these comparisons are safe.
    if width < 120 then width = 120 end
    if width > 1400 then width = 1400 end
    return math.floor(width + 4)
end

local function LayoutOneCode39Frame(f, payload, fontSize)
    ApplyFramePosition(f)
    SetCode39Font(f.bar, fontSize)

    -- Secret-safe: measure fixed dummy text only, never real payload.
    local barWidth = MeasureDummyCode39Width(f, fontSize)
    local frameWidth = barWidth + (CODE39_HORIZONTAL_PADDING * 2)
    local frameHeight = (fontSize / 8)

    f:SetSize(frameWidth, frameHeight)

    f.bar:ClearAllPoints()
    f.bar:SetWidth(barWidth)
    f.bar:SetHeight(10)
    f.bar:SetHeight(fontSize)
    f.bar:SetPoint("CENTER", f, "TOP", 0, 0)

    -- Secret-safe: fixed prefix/suffix were already applied before this point.
    -- Do not inspect or measure value after SetText.
    f.bar:SetText(payload)
    f:Show()
end

function RuneReaderVoice:CreateCode39Frame()
    EnsureGuidFrame()
    EnsureNameFrame()
end

function RuneReaderVoice:DestroyCode39Frame()
    local guidFrame = RuneReaderVoice.Code39GuidFrame
    if guidFrame then
        guidFrame:Hide()
        guidFrame:SetParent(nil)
        RuneReaderVoice.Code39GuidFrame = nil
    end

    local nameFrame = RuneReaderVoice.Code39NameFrame
    if nameFrame then
        nameFrame:Hide()
        nameFrame:SetParent(nil)
        RuneReaderVoice.Code39NameFrame = nil
    end

    -- Old single-frame field cleanup if present from earlier builds.
    local oldFrame = RuneReaderVoice.Code39Frame
    if oldFrame then
        oldFrame:Hide()
        oldFrame:SetParent(nil)
        RuneReaderVoice.Code39Frame = nil
    end

    _guidPayload = nil
    _namePayload = nil
end

function RuneReaderVoice:HideCode39Frame()
    _guidPayload = nil
    _namePayload = nil

    local guidFrame = RuneReaderVoice.Code39GuidFrame
    if guidFrame then guidFrame:Hide() end

    local nameFrame = RuneReaderVoice.Code39NameFrame
    if nameFrame then nameFrame:Hide() end

    local oldFrame = RuneReaderVoice.Code39Frame
    if oldFrame then oldFrame:Hide() end
end

function RuneReaderVoice:ShowCode39Identity(guidPayload, namePayload)
    _guidPayload = guidPayload
    _namePayload = namePayload

    if not Code39Enabled() or not guidPayload then
        RuneReaderVoice:HideCode39Frame()
        return
    end

    local fontSize = GetFontSize()

    LayoutOneCode39Frame(EnsureGuidFrame(), guidPayload, fontSize)

    if namePayload then
        LayoutOneCode39Frame(EnsureNameFrame(), namePayload, fontSize)
    else
        local nameFrame = RuneReaderVoice.Code39NameFrame
        if nameFrame then nameFrame:Hide() end
    end
end

-- Backward-compatible helper for older call sites/tests.
function RuneReaderVoice:ShowCode39Guid(guidPayload)
    RuneReaderVoice:ShowCode39Identity(guidPayload, nil)
end

function RuneReaderVoice:RefreshCode39Frame()
    if _guidPayload then
        RuneReaderVoice:ShowCode39Identity(_guidPayload, _namePayload)
    end
end

function RuneReaderVoice:ResetCode39Position()
    RuneReaderVoiceDB.Code39Position = nil
    RuneReaderVoiceDB.Code39GuidPosition = nil
    RuneReaderVoiceDB.Code39NamePosition = nil

    local guidFrame = EnsureGuidFrame()
    guidFrame:ClearAllPoints()
    guidFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, -120)
    guidFrame._rrvPositionInitialized = true

    local nameFrame = EnsureNameFrame()
    nameFrame:ClearAllPoints()
    nameFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, -145)
    nameFrame._rrvPositionInitialized = true

    if _guidPayload then
        RuneReaderVoice:ShowCode39Identity(_guidPayload, _namePayload)
    end
end

function RuneReaderVoice:GetCurrentNpcGuidForCode39()
    local ok, result = pcall(function()
        return UnitGUID("npc") or UnitGUID("target") or UnitGUID("questnpc")
    end)
    if ok and result then return result end
    return nil
end

function RuneReaderVoice:GetCurrentNpcNameForCode39()
    local ok, result = pcall(function()
        return UnitName("npc") or UnitName("target") or UnitName("questnpc")
    end)
    if ok and result then return result end
    return nil
end

function RuneReaderVoice:BuildCode39SideChannel(isPreview)
    if isPreview or not Code39Enabled() then return nil, nil end

    local guid = RuneReaderVoice:GetCurrentNpcGuidForCode39()
    if not guid then return nil, nil end

    local name = RuneReaderVoice:GetCurrentNpcNameForCode39()

    -- Do not inspect, normalize, sanitize, measure, or otherwise touch GUID/name.
    -- Secret-safe operation is limited to wrapping fixed literals around values.
    local guidPayload = "*RRVG-" .. guid .. "*"
    local namePayload = nil
    if name then
        namePayload = "*RRVN-" .. name .. "*"
    end

    return guidPayload, namePayload
end

function RuneReaderVoice:ShowCode39Test()
    RuneReaderVoiceDB.Code39Enabled = true
    local guidPayload = "*RRVG-Creature-0-3779-0-90-235481-00007B5082*"
    local namePayload = "*RRVN-Lor Themar Theron*"
    RuneReaderVoice:ShowCode39Identity(guidPayload, namePayload)
    print(string.format("|cff00ccff[RuneReaderVoice]|r Code39 identity test shown. fontSize=%d", GetFontSize()))
end
