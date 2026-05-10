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
--
-- RuneReaderVoice is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with RuneReaderVoice. If not, see <https://www.gnu.org/licenses/>.

-- config_panel.lua: Settings UI using the retail Settings API

-- Preview text encoded into the QR while the options panel is open.
local PREVIEW_TEXT = "RuneReaderVoice preview"

-- Reference to the custom size slider initializer, for show/hide.
local _customSliderInitializer = nil

-- ── Panel creation ────────────────────────────────────────────────────────────

function RuneReaderVoice:CreateConfigPanel()
    RuneReaderVoiceDB = RuneReaderVoiceDB or {}
    local category = Settings.RegisterVerticalLayoutCategory("RuneReaderVoice")

    -- Single OnChanged handler for every setting.
    -- Writes value to DB, then calls ApplyConfig with the changed key.
    local function OnChanged(setting, value)
        local key = setting:GetVariable()
        RuneReaderVoiceDB[key] = value
        -- print("|cff00ccff[RRV]|r setting changed: " .. tostring(key) .. " = " .. tostring(value))
        -- Custom slider visibility driven by PadPreset
        if key == "PadPreset" then
            RuneReaderVoice:UpdateCustomSliderVisibility(value)
        end
        RuneReaderVoice:ApplyConfig(key)
    end

    local function AddCheckbox(key, label, tooltip, default)
        local s = Settings.RegisterAddOnSetting(
            category, label, key, RuneReaderVoiceDB, type(default), label, default)
        s:SetValueChangedCallback(OnChanged)
        Settings.CreateCheckbox(category, s, tooltip)
    end

    local function AddSlider(key, label, tooltip, default, min, max, step, fmt)
        local s = Settings.RegisterAddOnSetting(
            category, label, key, RuneReaderVoiceDB, type(default), label, default)
        s:SetValueChangedCallback(OnChanged)
        local opts = Settings.CreateSliderOptions(min, max, step)
        opts:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right,
            function(v) return string.format(fmt, v) end)
        local init = Settings.CreateSlider(category, s, opts, tooltip)
        return init
    end

    local function AddDropdown(key, label, tooltip, default, options)
        local s = Settings.RegisterAddOnSetting(
            category, label, key, RuneReaderVoiceDB, type(default), label, default)
        s:SetValueChangedCallback(OnChanged)
        local init = Settings.CreateDropdown(category, s, function()
            local c = Settings.CreateControlTextContainer()
            for i, txt in ipairs(options) do c:Add(i - 1, txt) end
            return c:GetData()
        end, tooltip)
        return init
    end

    -- ── Dialog scope ──────────────────────────────────────────────────────────
    AddCheckbox("EnableQuestGreeting", "Voice NPC Greeting",
        "Read NPC greeting/gossip text when talking to an NPC", true)
    AddCheckbox("EnableQuestDetail",   "Voice Quest Description",
        "Read quest description text", true)
    AddCheckbox("EnableQuestProgress", "Voice Quest Progress",
        "Read quest progress text", true)
    AddCheckbox("EnableQuestReward",   "Voice Quest Reward",
        "Read quest reward text", true)
    AddCheckbox("EnableBooks",         "Voice In-Game Books",
        "Read in-game books and readable items (experimental)", false)
    AddCheckbox("BookScanMode",        "  Scan Full Book on Open",
        "Scan all pages when a book opens, then read the full text from page 1. "
        .. "Disable to read one page at a time as you click through.", true)

    -- ── Speaker ───────────────────────────────────────────────────────────────
    AddCheckbox("UseVoiceChatGender", "Detect NPC Gender",
        "Detect NPC gender via UnitSex for voice selection", true)

    -- ── QR display ────────────────────────────────────────────────────────────
    AddSlider("QRScale",          "QR Frame Scale",
        "Visual scale of the QR frame. Reading is pixel-perfect regardless of scale.",
        2.0, 1.0, 4.0, 0.5, "%.2fx")

    AddSlider("QRModuleSize",     "QR Module Size (px)",
        "Pixel size of each QR module.",
        1, 1, 6, 1, "%d px")

    AddSlider("QRQuietZone",      "QR Quiet Zone (modules)",
        "White border around the QR code in modules. Minimum 3 recommended.",
        1, 1, 6, 1, "%d")

    AddSlider("ChunkDisplayTime", "Chunk Display Time",
        "Seconds each chunk is shown. RuneReader reads at ~5ms; 0.10s gives 20x margin.",
        0.10, 0.03, 0.50, 0.01, "%.2fs")

    -- ── Pad size ──────────────────────────────────────────────────────────────
    AddDropdown("PadPreset", "QR Pad Size",
        "Pads all chunks to a fixed size so QR code never resizes between chunks.",
        0, { "Small (50 bytes)", "Medium (135 bytes)", "Large (250 bytes)", "Custom" })

    _customSliderInitializer = AddSlider("PadCustomSize", "Custom Pad Size (bytes)",
        "Used when Pad Size is set to Custom. Range 50-500.",
        50, 50, 500, 5, "%d bytes")

    -- Set initial visibility of custom slider
    RuneReaderVoice:UpdateCustomSliderVisibility(RuneReaderVoiceDB.PadPreset or 1)

    -- ── Debug ─────────────────────────────────────────────────────────────────
    AddCheckbox("DEBUG", "Debug Logging", "Print debug info to chat", false)

    Settings.RegisterAddOnCategory(category)

    -- ── Live preview hooks ────────────────────────────────────────────────────
    if SettingsPanel then
        SettingsPanel:HookScript("OnShow", function()
            C_Timer.After(0.05, function()
                if SettingsPanel:IsShown() then
                    RuneReaderVoice:StartPreview()
                end
            end)
        end)
        SettingsPanel:HookScript("OnHide", function()
            RuneReaderVoice:StopPreview()
        end)
    end
end

-- ── Custom slider visibility ──────────────────────────────────────────────────

function RuneReaderVoice:UpdateCustomSliderVisibility(presetIndex)
    if _customSliderInitializer and _customSliderInitializer.SetShown then
        _customSliderInitializer:SetShown(presetIndex == 3)
    end
end

-- ── ApplyConfig ───────────────────────────────────────────────────────────────
-- Called on load (changedKey=nil) and on every setting change.
-- Strategy: destroy and recreate the QR frame so all DB values are picked up
-- fresh with zero stale state. Position is preserved via RuneReaderVoiceDB.QRPosition.

function RuneReaderVoice:ApplyConfig(changedKey)
    local db = RuneReaderVoiceDB
    if not db then return end

    -- ChunkDisplayTime only affects the cycle speed upvalue - no frame rebuild needed.
    if changedKey == "ChunkDisplayTime" then
        RuneReaderVoice:SetDisplayTime(db.ChunkDisplayTime or 0.10)
        return
    end

    -- Non-visual settings don't affect the QR frame at all.
    local nonVisual = {
        EnableQuestGreeting = true,
        EnableQuestDetail   = true,
        EnableQuestProgress = true,
        EnableQuestReward   = true,
        EnableBooks         = true,
        UseVoiceChatGender  = true,
        DEBUG               = true,
    }
    if changedKey and nonVisual[changedKey] then return end

    -- All visual settings: destroy and recreate the frame from scratch.
    local wasPreviewActive = RuneReaderVoice:IsPreviewActive()
    RuneReaderVoice:DestroyQRFrame()
    RuneReaderVoice:CreateQRFrame()

    -- Restart preview if it was showing so the user sees the change immediately.
    if wasPreviewActive then
        RuneReaderVoice:StartPreview()
    end
end

-- ── Preview ───────────────────────────────────────────────────────────────────

RuneReaderVoice._previewActive = false

function RuneReaderVoice:IsPreviewActive()
    return RuneReaderVoice._previewActive
end

function RuneReaderVoice:IsSettingsPanelOpen()
    return SettingsPanel and SettingsPanel:IsShown()
end

function RuneReaderVoice:StartPreview()
    -- isPreview=true sets FLAG_PREVIEW (bit 3) in header so reader ignores it
    local dialogID, sessions, code39GuidPayload = RuneReaderVoice:BuildDialogSessions(PREVIEW_TEXT, true)
    if not sessions or #sessions == 0 then return end
    RuneReaderVoice._previewActive = true
    RuneReaderVoice:StartDisplaySessions(dialogID, sessions, code39GuidPayload)
    RuneReaderVoice:Dbg("Preview started")
end

function RuneReaderVoice:StopPreview()
    if not RuneReaderVoice._previewActive then return end
    RuneReaderVoice._previewActive = false
    RuneReaderVoice:StopDisplay()
    RuneReaderVoice:Dbg("Preview stopped")
end
