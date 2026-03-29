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

-- config.lua: Default settings and config initialization

RuneReaderVoice = RuneReaderVoice or {}
RuneReaderVoiceDB = RuneReaderVoiceDB or {}

RuneReaderVoice.defaultConfig = {
    -- QR display
    QRModuleSize    = 1,        -- pixel size of each QR module
    QRQuietZone     = 3,        -- quiet zone border in modules
    QRScale         = 1.0,      -- UI scale of the QR frame
    Ec_level        = 2,        -- QR error correction: 1=L 2=M 3=Q 4=H

    -- TTS chunking / timing
    ChunkDisplayTime = 0.10,    -- seconds each chunk is displayed (100ms default)
                                -- RuneReader reads at ~5ms; 100ms gives ample margin

    -- QR payload padding (keeps QR code the same size across all chunks)
    -- PadMode: "preset" uses a named size; "custom" uses PadCustomSize.
    -- PadPreset: "small"=50, "medium"=135, "large"=250
    -- PadCustomSize: raw bytes (before Base64), range 50-500
    -- All chunks in a session are padded to max(actualChunkSize, targetPadSize)
    -- so the QR matrix version never changes mid-session.
    -- PadPreset index: 0=Small(50) 1=Medium(135) 2=Large(250) 3=Custom(PadCustomSize)
    PadPreset     = 1,          -- 0=Small(50) 1=Medium(135) 2=Large(250) 3=Custom
    PadCustomSize = 135,        -- used when PadMode == "custom", range 50-500

    -- Speaker classification
    UseVoiceChatGender = true,  -- try C_VoiceChat for NPC gender before falling back to UnitSex
    DefaultSpeakerGender = 0,   -- 0=unknown/neutral, 1=male, 2=female

    -- Scope
    EnableQuestGreeting = true, -- voice NPC greeting text (GOSSIP_SHOW)
    EnableQuestDetail   = true, -- voice quest description (QUEST_DETAIL)
    EnableQuestProgress = true, -- voice quest progress text
    EnableQuestReward   = true, -- voice quest reward text
    EnableBooks         = false, -- voice in-game books (ITEM_TEXT) - Phase 2
    BookScanMode        = true,  -- scan all pages on open before dispatch; false = one page at a time

    -- Debug
    DEBUG = false,
    QRDEBUG = false,
}

-- ── Helpers ──────────────────────────────────────────────────────────────────

function RuneReaderVoice:InitConfig()
    RuneReaderVoiceDB = RuneReaderVoiceDB or {}
    for k, v in pairs(RuneReaderVoice.defaultConfig) do
        if RuneReaderVoiceDB[k] == nil then
            RuneReaderVoiceDB[k] = v
        end
    end
end

function RuneReaderVoice:Dbg(msg)
    if RuneReaderVoiceDB and RuneReaderVoiceDB.DEBUG then
        print("|cff00ccff[RuneReaderVoice]|r " .. tostring(msg))
    end
end

function RuneReaderVoice:QrDbg(msg)
    if RuneReaderVoiceDB and RuneReaderVoiceDB.QRDEBUG then
        print("|cff33ff99[RRV:QR]|r " .. tostring(msg))
    end
end

function RuneReaderVoice:QrDumpText(label, text)
    if not (RuneReaderVoiceDB and RuneReaderVoiceDB.QRDEBUG) then return end
    text = tostring(text or "")
    text = text:gsub("\r", "\\r"):gsub("\n", "\\n")
    local maxLen = 220
    local idx = 1
    local part = 1
    if #text == 0 then
        self:QrDbg(label .. ' = ""')
        return
    end
    while idx <= #text do
        local chunk = text:sub(idx, idx + maxLen - 1)
        self:QrDbg(string.format("%s [%d] len=%d text=%s", label, part, #chunk, chunk))
        idx = idx + maxLen
        part = part + 1
    end
end
