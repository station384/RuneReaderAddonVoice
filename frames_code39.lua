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

-- frames_code39.lua: Code39 GUID side-channel frame.
--
-- Critical WoW secret-value rule:
--   Runtime GUID values must not be inspected or transformed here.
--   No upper(), gsub(), len, tostring(), validation, parsing, encoding,
--   string-width measurement, or string-length measurement.
--   Only safe operation assumed for secret values is:
--       "literal prefix" .. secretGuid .. "literal suffix"

RuneReaderVoice = RuneReaderVoice or {}

local CODE39_FONT = [[Interface\AddOns\RuneReaderVoice\Fonts\LibreBarcode39-Regular-modified.otf]]

-- Runtime Code39 payload may contain a WoW secret value. Never measure it.
-- For layout, measure this fixed non-secret dummy string with GUID-like shape.
local CODE39_GUID_WIDTH_DUMMY = "*RRVG-Creature-0-00002-0-00-0000002-0000000000343246545*"
local MAX_CODE39_FONT_SIZE = 56
local CODE39_HORIZONTAL_PADDING = 2
local _guidPayload = nil

local function Code39Enabled()
    return RuneReaderVoiceDB and RuneReaderVoiceDB.Code39Enabled
end

local function GetFontSize()
    local n = 20 or tonumber(RuneReaderVoiceDB and RuneReaderVoiceDB.Code39FontSize) or 10
    if n < 10 then n = 10 end
    if n > MAX_CODE39_FONT_SIZE then n = MAX_CODE39_FONT_SIZE end
    return n
end

local function EnsureCode39Frame()
    if RuneReaderVoice.Code39Frame then return RuneReaderVoice.Code39Frame end

    local f = CreateFrame("Frame", "RuneReaderVoiceCode39Frame", UIParent, "BackdropTemplate")
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetIgnoreParentScale(true)
    f:SetBackdrop({ bgFile = "Interface/Buttons/WHITE8X8", tile = true })
    f:SetBackdropColor(0.3, 0.2, 0, 1)
    f:SetScale(1)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")

    local bar = f:CreateFontString(nil, "ARTWORK")
    bar:SetJustifyH("CENTER")
    bar:SetJustifyV("MIDDLE")
    bar:SetTextColor(0, 0, 0, 1)
    bar:SetTextHeight(5)
    bar:SetShadowOffset(0, 0)
    bar:SetShadowColor(0, 0, 0, 0)
    f.bar = bar

    local measure = f:CreateFontString(nil, "ARTWORK")
    measure:SetTextColor(0, 0, 0, 0)
    measure:SetAlpha(0)
    measure:SetShadowOffset(0, 0)
    measure:SetShadowColor(0, 0, 0, 0)
    measure:Hide()
    f.measure = measure

    local pos = RuneReaderVoiceDB and RuneReaderVoiceDB.Code39Position
    if pos then
        f:SetPoint(pos.point or "TOPLEFT", UIParent, pos.relativePoint or "TOPLEFT", pos.x or 0, pos.y or -120)
    else
        f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, -120)
    end

    f:SetScript("OnDragStart", function(self)
        if IsAltKeyDown() then self:StartMoving() end
    end)

    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relativePoint, xOfs, yOfs = self:GetPoint()
        RuneReaderVoiceDB.Code39Position = {
            point         = point,
            relativePoint = relativePoint,
            x             = xOfs,
            y             = yOfs,
        }
    end)

    RuneReaderVoice.Code39Frame = f
    f:Hide()
    return f
end

local function SetCode39Font(fontString, fontSize)
    fontString:SetFont(CODE39_FONT, fontSize, "")
    fontString:SetShadowOffset(0, 0)
    fontString:SetShadowColor(0, 0, 0, 0)
end

local function MeasureDummyGuidWidth(f, fontSize)
    SetCode39Font(f.measure, fontSize)
    f.measure:SetText(CODE39_GUID_WIDTH_DUMMY)

    local width = f.measure:GetStringWidth() or 0
    -- Width comes from fixed non-secret dummy text, so this comparison is safe.
    if width < 120 then width = 120 end
    if width > 1400 then width = 1400 end
    return math.floor(width + 4)
end

local function ApplySavedOrDefaultPosition(f)
    local pos = RuneReaderVoiceDB and RuneReaderVoiceDB.Code39Position
    if pos then
        f:ClearAllPoints()
        f:SetPoint(pos.point or "TOPLEFT", UIParent, pos.relativePoint or "TOPLEFT", pos.x or 0, pos.y or -120)
    elseif not f._rrvPositionInitialized then
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, -120)
        f._rrvPositionInitialized = true
    end
end

function RuneReaderVoice:CreateCode39Frame()
    EnsureCode39Frame()
end

function RuneReaderVoice:DestroyCode39Frame()
    local f = RuneReaderVoice.Code39Frame
    if f then
        f:Hide()
        f:SetParent(nil)
        RuneReaderVoice.Code39Frame = nil
    end
    _guidPayload = nil
end

function RuneReaderVoice:HideCode39Frame()
    _guidPayload = nil
    local f = RuneReaderVoice.Code39Frame
    if f then f:Hide() end
end

function RuneReaderVoice:ShowCode39Guid(guidPayload)
    _guidPayload = guidPayload

    if not Code39Enabled() or not guidPayload then
        RuneReaderVoice:HideCode39Frame()
        return
    end

    local f = EnsureCode39Frame()
    local fontSize = GetFontSize()

    ApplySavedOrDefaultPosition(f)
    SetCode39Font(f.bar, fontSize)

    -- Secret-safe: measure fixed dummy text only, never the real GUID payload.
    local barWidth = MeasureDummyGuidWidth(f, fontSize)
    local frameWidth = barWidth + (CODE39_HORIZONTAL_PADDING * 2)
    local frameHeight = (fontSize / 4) 

    f:SetSize(frameWidth, frameHeight)

    f.bar:ClearAllPoints()
    f.bar:SetWidth(barWidth)
    f.bar:SetHeight(fontSize)
    f.bar:SetPoint("CENTER", f, "CENTER", 0, 0)

    -- Secret-safe: fixed prefix/suffix were already applied before this point.
    -- Do not inspect or measure this value after SetText.
    f.bar:SetText(guidPayload)

    f:Show()
end

function RuneReaderVoice:RefreshCode39Frame()
    if _guidPayload then
        RuneReaderVoice:ShowCode39Guid(_guidPayload)
    end
end

function RuneReaderVoice:ResetCode39Position()
    RuneReaderVoiceDB.Code39Position = nil
    local f = EnsureCode39Frame()
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, -120)
    f._rrvPositionInitialized = true
    if _guidPayload then
        RuneReaderVoice:ShowCode39Guid(_guidPayload)
    end
end

function RuneReaderVoice:GetCurrentNpcGuidForCode39()
    local ok, result = pcall(function()
        return UnitGUID("npc") or UnitGUID("target") or UnitGUID("questnpc")
    end)
    if ok and result then return result end
    return nil
end

function RuneReaderVoice:BuildCode39SideChannel(isPreview)
    if isPreview or not Code39Enabled() then return nil end

    local guid = RuneReaderVoice:GetCurrentNpcGuidForCode39()
    if not guid then return nil end

    -- GUID only. Do not inspect, normalize, sanitize, measure, or otherwise touch it.
    -- Secret-safe operation is limited to wrapping fixed literals around the value.
    return "*RRVG-" .. guid .. "*"
end

function RuneReaderVoice:ShowCode39Test()
    RuneReaderVoiceDB.Code39Enabled = true
    local guidPayload = "*RRVG-Creature-0-3779-0-90-235481-00007B5082*"
    RuneReaderVoice:ShowCode39Guid(guidPayload)
    print(string.format("|cff00ccff[RuneReaderVoice]|r Code39 GUID test shown. fontSize=%d", GetFontSize()))
end
