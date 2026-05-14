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

-- frames_rrvbarcode.lua: RuneReader Barcode font identity side-channel frames.
--
-- Replaces frames_code39.lua. Uses RuneReaderBarcode-Regular.ttf instead of
-- LibreBarcode39. Start/stop marker is § (byte 0xA7, decimal 167).
--
-- Critical WoW secret-value rule:
--   Runtime GUID/name values must not be inspected or transformed here.
--   No upper(), gsub(), len, tostring(), validation, parsing, encoding,
--   string-width measurement, or string-length measurement on secret values.
--   Only safe operation on secret values is:
--       "literal prefix" .. secretValue .. "literal suffix"

RuneReaderVoice = RuneReaderVoice or {}

local RRVB_FONT         = [[Interface\AddOns\RuneReaderVoice\Fonts\RuneReaderBarcode-Regular.ttf]]
local RRVB_START_STOP   = "\194\167"   -- § U+00A7, byte 0xA7 — start/stop marker

-- Dummy strings for frame width measurement only.
-- Must never be the real secret payload. Width is measured on these fixed
-- strings so Lua never calls GetStringWidth on a secret value.
local RRVB_COMBINED_WIDTH_DUMMY = "\194\167RRVX-G=Creature-0-00002-0-00-0000002-0000000000343246545;N=HIGH ABCDEFGHIJKLMNOPQRSTUVWXYZ\194\167"

local RRVB_FONT_SIZE   = 12     -- barcode font size
local RRVB_WRAP_WIDTH  = 100   -- GUID frame wrap width in pixels (0 = no wrap)
local RRVB_WRAP_ROWS = 4
local RRVB_HORIZONTAL_PADDING = 2
local RRVB_INSET = 5            -- quiet zone padding around barcode content
local RRVB_LINE_SPACING = 2     -- line spacing adjustment when wrapped (pixels between lines)

local _combinedPayload = nil

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function RrvbEnabled()
    return RuneReaderVoiceDB and RuneReaderVoiceDB.RrvbEnabled
end

local function GetFontSize()
    return RRVB_FONT_SIZE
end

local function SetRrvbFont(fontString, fontSize)
    fontString:SetFont(RRVB_FONT, fontSize, "")
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
    if pos then
        f:ClearAllPoints()
        f:SetPoint(pos.point or "TOPLEFT", UIParent, pos.relativePoint or "TOPLEFT", pos.x or 0, pos.y or f._rrvDefaultY)
    elseif not f._rrvPositionInitialized then
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", f._rrvDefaultX, f._rrvDefaultY)
        f._rrvPositionInitialized = true
    end
end

-- ── Frame creation ────────────────────────────────────────────────────────────

local function CreateOneRrvbFrame(frameName, positionKey, defaultX, defaultY, dummyText)
    local f = CreateFrame("Frame", frameName, UIParent, "BackdropTemplate")
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetIgnoreParentScale(true)
    f:SetScale(1)
    f:SetBackdrop({
        bgFile = "Interface/Buttons/WHITE8X8",
        tile   = true,
        edgeSize = 0,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    })
    f:SetBackdropColor(0.3, 0.2, 0, 1)   -- same gray/brown background as Code39 frames

    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")

    f._rrvPositionKey          = positionKey
    f._rrvDefaultX             = defaultX
    f._rrvDefaultY             = defaultY
    f._rrvDummyText            = dummyText
    f._rrvPositionInitialized  = false

    local bar = f:CreateFontString(nil, "ARTWORK")
    bar:SetJustifyH("LEFT")
    bar:SetJustifyV("TOP")
    bar:SetTextColor(0, 0, 0, 1)
    bar:SetShadowOffset(0, 0)
    bar:SetShadowColor(0, 0, 0, 0)
    if bar.SetWordWrap    then bar:SetWordWrap(false)    end
    if bar.SetNonSpaceWrap then bar:SetNonSpaceWrap(false) end
    if bar.SetSpacing     then bar:SetSpacing(0)         end
    f.bar = bar

    -- Invisible measure string — measures fixed dummy text only, never secrets.
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

-- ── Lazy frame accessors ──────────────────────────────────────────────────────

local function EnsureCombinedFrame()
    if RuneReaderVoice.RrvbGuidFrame then return RuneReaderVoice.RrvbGuidFrame end
    RuneReaderVoice.RrvbGuidFrame = CreateOneRrvbFrame(
        "RuneReaderVoiceRrvbCombinedFrame",
        "RrvbGuidPosition",
        0, -120,
        RRVB_COMBINED_WIDTH_DUMMY
    )
    return RuneReaderVoice.RrvbGuidFrame
end

-- ── Layout ────────────────────────────────────────────────────────────────────

local function MeasureDummyWidth(f, fontSize)
    SetRrvbFont(f.measure, fontSize)
    f.measure:SetText(f._rrvDummyText)
    local width = f.measure:GetStringWidth() or 0
    -- Clamp: dummy text only, safe to compare.
    if width < 60  then width = 60  end
    if width > 1400 then width = 1400 end
    return math.floor(width + 4)
end

local function LayoutOneFrame(f, payload, fontSize, wrapWidth)
    ApplyFramePosition(f)
    SetRrvbFont(f.bar, fontSize)
  
    if wrapWidth and wrapWidth > 0 then
        -- Wrap mode: constrain to fixed pixel width, allow multi-line height.
        local frameWidth  = wrapWidth + (RRVB_INSET * 2)
        local frameHeight = (fontSize + 4) * RRVB_WRAP_ROWS + (RRVB_INSET * 2)

        f:SetSize(frameWidth, frameHeight)

        f.bar:ClearAllPoints()
        f.bar:SetWidth(wrapWidth)
        f.bar:SetHeight(frameHeight - (RRVB_INSET * 2))
        f.bar:SetPoint("TOPLEFT", f, "TOPLEFT", RRVB_INSET, -RRVB_INSET)

        if f.bar.SetWordWrap    then f.bar:SetWordWrap(true)    end
        if f.bar.SetNonSpaceWrap then f.bar:SetNonSpaceWrap(true) end
        if f.bar.SetSpacing     then f.bar:SetSpacing(RRVB_LINE_SPACING) end
    else
        -- Normal single-line mode.
        local barWidth    = MeasureDummyWidth(f, fontSize)
        local frameWidth  = barWidth + (RRVB_INSET * 2)
        local frameHeight = fontSize + (RRVB_INSET * 2)

        f:SetSize(frameWidth, frameHeight)

        f.bar:ClearAllPoints()
        f.bar:SetWidth(barWidth)
        f.bar:SetHeight(fontSize)
        f.bar:SetPoint("TOPLEFT", f, "TOPLEFT", RRVB_INSET, -RRVB_INSET)

        if f.bar.SetWordWrap    then f.bar:SetWordWrap(false)    end
        if f.bar.SetNonSpaceWrap then f.bar:SetNonSpaceWrap(false) end
    end

    -- Secret-safe: payload already has start/stop markers applied before this call.
    -- Do not inspect or measure after SetText.
    f.bar:SetText(payload)
    f:Show()
end

-- ── Public API ────────────────────────────────────────────────────────────────

function RuneReaderVoice:CreateRrvbFrame()
    EnsureCombinedFrame()
end

function RuneReaderVoice:DestroyRrvbFrame()
    local guidFrame = RuneReaderVoice.RrvbGuidFrame
    if guidFrame then
        guidFrame:Hide()
        guidFrame:SetParent(nil)
        RuneReaderVoice.RrvbGuidFrame = nil
    end

    local nameFrame = RuneReaderVoice.RrvbNameFrame
    if nameFrame then
        nameFrame:Hide()
        nameFrame:SetParent(nil)
        RuneReaderVoice.RrvbNameFrame = nil
    end

    _combinedPayload = nil
end

function RuneReaderVoice:HideRrvbFrame()
    _combinedPayload = nil

    local guidFrame = RuneReaderVoice.RrvbGuidFrame
    if guidFrame then guidFrame:Hide() end

    local nameFrame = RuneReaderVoice.RrvbNameFrame
    if nameFrame then nameFrame:Hide() end
end

function RuneReaderVoice:ShowRrvbIdentity(combinedPayload, legacyNamePayload)
    -- legacyNamePayload intentionally ignored. RRVB now uses one combined block:
    --   §RRVX-G=<guid>;N=<name>§
    _combinedPayload = combinedPayload

    if not RrvbEnabled() or not combinedPayload then
        RuneReaderVoice:HideRrvbFrame()
        return
    end

    local fontSize = GetFontSize()
    local wrapWidth = RRVB_WRAP_WIDTH

    LayoutOneFrame(EnsureCombinedFrame(), combinedPayload, fontSize, wrapWidth > 0 and wrapWidth or nil)

    -- Old two-frame path is disabled, but hide stale name frame if it exists from an older session/version.
    local nameFrame = RuneReaderVoice.RrvbNameFrame
    if nameFrame then nameFrame:Hide() end
end

function RuneReaderVoice:RefreshRrvbFrame()
    if _combinedPayload then
        RuneReaderVoice:ShowRrvbIdentity(_combinedPayload, nil)
    end
end

function RuneReaderVoice:ResetRrvbPosition()
    RuneReaderVoiceDB.RrvbGuidPosition = nil
    RuneReaderVoiceDB.RrvbNamePosition = nil

    local guidFrame = EnsureCombinedFrame()
    guidFrame:ClearAllPoints()
    guidFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, -120)
    guidFrame._rrvPositionInitialized = true

    RuneReaderVoiceDB.RrvbNamePosition = nil
    local nameFrame = RuneReaderVoice.RrvbNameFrame
    if nameFrame then nameFrame:Hide() end

    if _combinedPayload then
        RuneReaderVoice:ShowRrvbIdentity(_combinedPayload, nil)
    end
end

-- ── Side-channel payload builders ────────────────────────────────────────────

function RuneReaderVoice:GetCurrentNpcGuidForRrvb()
    local ok, result = pcall(function()
        return  UnitGUID("target") or UnitGUID("npc") or UnitGUID("questnpc")
    end)
    if ok and result then return result end
    return nil
end

function RuneReaderVoice:GetCurrentNpcNameForRrvb()
    local ok, result = pcall(function()
        return UnitName("target") or UnitName("npc") or  UnitName("questnpc")
    end)
    if ok and result then return result end
    return nil
end

function RuneReaderVoice:BuildRrvbSideChannel(isPreview)
    if isPreview or not RrvbEnabled() then return nil, nil end

    local guid = RuneReaderVoice:GetCurrentNpcGuidForRrvb()
    if not guid then return nil, nil end

    local name = RuneReaderVoice:GetCurrentNpcNameForRrvb()

    -- Secret-safe: only fixed literal concat on secret values.
    -- No inspection, normalization, measurement, escaping, or transformation.
    -- Combined payload format:
    --   RRVX-G=<guid>;N=<name>
    -- If name is unavailable, emit an empty N= field.
    local combinedPayload = nil
    if name then
        combinedPayload = RRVB_START_STOP .. "RRVX-G=" .. guid .. ";N=" .. name .. RRVB_START_STOP
    else
        combinedPayload = RRVB_START_STOP .. "RRVX-G=" .. guid .. ";N=" .. RRVB_START_STOP
    end

    return combinedPayload, nil
end

-- ── Test helper ───────────────────────────────────────────────────────────────

function RuneReaderVoice:ShowRrvbTest()
    RuneReaderVoiceDB.RrvbEnabled = true
    local combinedPayload = RRVB_START_STOP .. "RRVX-G=Creature-0-3779-0-90-235481-00007B5082;N=Lor Themar Theron" .. RRVB_START_STOP
    RuneReaderVoice:ShowRrvbIdentity(combinedPayload, nil)
    print(string.format("|cff00ccff[RuneReaderVoice]|r RRVB combined identity test shown. fontSize=%d", GetFontSize()))
end
