-- RuneReaderVoice
-- Copyright (c) Michael Sutton 2025
-- Licensed under the GNU General Public License v3.0 (GPLv3)
-- You may use, modify, and distribute this file under the terms of the GPLv3 license.
-- See: https://www.gnu.org/licenses/gpl-3.0.en.html

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

    -- Debug
    DEBUG = false,
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
