-- RuneReaderVoice
-- Copyright (c) Michael Sutton 2025
-- Licensed under the GNU General Public License v3.0 (GPLv3)
-- You may use, modify, and distribute this file under the terms of the GPLv3 license.
-- See: https://www.gnu.org/licenses/gpl-3.0.en.html

-- payload.lua: Segment splitting, chunking, and QR payload encoding
--
-- Protocol v04 header (22 ASCII chars):
--   "RV" + VER(2) + DIALOG(4) + IDX(2) + TOTAL(2) + FLAGS(2) + RACE(2) + NPC(6)
--
--   DIALOG  : increments per NPC interaction, resets on login. Signals
--             context change (new NPC / new dialog block) to RuneReader.
--   IDX     : 0-based chunk index within this segment.
--   TOTAL   : total chunks in this segment. IDX==TOTAL-1 is the last chunk.
--   FLAGS   : speaker/control bitmask (see below).
--   RACE    : NPC race/creature type (see below).
--   NPC     : NPC ID extracted from the unit GUID (6 hex chars = 24 bits).
--             Zero-padded. "000000" if not a creature or GUID unavailable.
--             Parsed from segment 6 of the GUID:
--             e.g. Creature-0-3783-2858-37411-240068-00002972DF → 03A944 (240068 decimal)
--
-- FLAGS byte:
--   bit 0 = FLAG_NARRATOR  text is narrator voice (angle-bracket segment or system text)
--   bit 1 = GENDER_b0      } 00=unknown  01=male  10=female
--   bit 2 = GENDER_b1      }
--   bit 3 = FLAG_PREVIEW   preview/test packet - reader MUST discard, never speak
--   bit 4-7 reserved
--
-- RACE byte:
--   0x00        = unknown / undetectable  → narrator fallback voice
--   0x01-0x3F   = player race IDs (direct from UnitRace() raceID, up to 63 races)
--   0x40-0x4F   = reserved for future player races
--   0x50        = Humanoid (non-playable)
--   0x51        = Beast
--   0x52        = Dragonkin
--   0x53        = Undead (non-Forsaken)
--   0x54        = Demon
--   0x55        = Elemental
--   0x56        = Giant
--   0x57        = Mechanical
--   0x58        = Aberration
--   0x59-0xEF   = reserved creature types
--   0xF0-0xFF   = reserved for future protocol use
--   Anything not in a known range → narrator fallback
--
-- Segment splitting:
--   Dialog text containing <angle bracket> passages is split into separate segments.
--   Each segment has FLAG_NARRATOR set appropriately.
--   Brackets are stripped before encoding - RuneReader receives clean text for TTS.
--   Example: "Hello. <He frowns.> Leave now." → 3 segments: NPC / narrator / NPC
--
-- Payload:
--   Each chunk is space-padded to GetPadSize() raw bytes before Base64 encoding.
--   All chunks in a segment pad to the same length → QR version never changes.

RuneReaderVoice = RuneReaderVoice or {}

-- ── Protocol constants ────────────────────────────────────────────────────────

local MAGIC           = "RV"
local PROTOCOL_VER    = "04"    -- bumped: NPC(6) field added, header now 22 chars
local WORDS_PER_CHUNK = 50     -- target words per QR chunk

-- Creature type → RACE byte mapping for non-humanoid NPCs
local CREATURE_TYPE_RACE = {
    ["Humanoid"]    = 0x50,
    ["Beast"]       = 0x51,
    ["Dragonkin"]   = 0x52,
    ["Undead"]      = 0x53,
    ["Demon"]       = 0x54,
    ["Elemental"]   = 0x55,
    ["Giant"]       = 0x56,
    ["Mechanical"]  = 0x57,
    ["Aberration"]  = 0x58,
}

-- Pad size presets indexed to match config panel dropdown (0-based)
-- 0=Small(50) 1=Medium(135) 2=Large(250) 3=Custom(PadCustomSize)
local PAD_PRESETS = { [0]=50, [1]=135, [2]=250 }

-- Read current target pad size from DB on every call - never cached.
local function GetPadSize()
    local db = RuneReaderVoiceDB
    if not db then return 135 end
    local preset = db.PadPreset
    if preset == nil then return 135 end
    if preset == 3 then
        return math.max(50, math.min(500, tonumber(db.PadCustomSize) or 135))
    end
    return PAD_PRESETS[preset] or 135
end

-- Speaker / control flag bits
local FLAG_NARRATOR  = 1    -- bit 0
local GENDER_MALE    = 2    -- bit 1
local GENDER_FEMALE  = 4    -- bit 2
local FLAG_PREVIEW   = 8    -- bit 3

-- ── Counters ──────────────────────────────────────────────────────────────────
-- Resets to 0 on login (module load). Wraps at 0xFFFF.

local _dialogCounter  = 0   -- increments once per NPC interaction (per DispatchDialog call)

local function NextDialogID()
    _dialogCounter = (_dialogCounter + 1) % 0xFFFF
    return _dialogCounter
end

local function ToHex2(n)  return string.format("%02X", n % 256)     end
local function ToHex4(n)  return string.format("%04X", n % 0x10000) end

-- ── Race detection ────────────────────────────────────────────────────────────

-- Returns the RACE byte for the current NPC.
-- Prioritises "target" since the player must target the NPC to open dialog.
-- "questnpc" and "npc" tokens are tried as well but are often unpopulated.
-- Falls back to creature type if no player raceID is available.
-- Returns 0x00 (unknown) if nothing is detectable.
function RuneReaderVoice:GetNPCRaceByte()
    -- Try all unit tokens for a player raceID (1-63)
    local _, _, raceID = UnitRace("target")
    if not raceID then _, _, raceID = UnitRace("questnpc") end
    if not raceID then _, _, raceID = UnitRace("npc") end

    if raceID and raceID >= 1 and raceID <= 0x3F then
        return raceID
    end

    -- No player raceID - try creature type (target first, same reasoning)
    local creatureType = UnitCreatureType("target")
        or UnitCreatureType("questnpc")
        or UnitCreatureType("npc")

    if creatureType then
        local mapped = CREATURE_TYPE_RACE[creatureType]
        if mapped then return mapped end
    end

    return 0x00  -- unknown - RuneReader will use narrator/neutral fallback
end

-- ── NPC ID detection ──────────────────────────────────────────────────────────

-- Returns the NPC ID as a 6-char uppercase hex string (e.g. "03A944" for 240068).
-- Extracted from segment 6 of the unit GUID:
--   Creature-0-3783-2858-37411-240068-00002972DF
--   seg:  1   2   3    4     5      6           7
-- Only valid for Creature GUIDs. Returns "000000" for players, pets, objects,
-- or if the target is unavailable.
function RuneReaderVoice:GetNPCID()
    local guid = UnitGUID("target") or UnitGUID("questnpc") or UnitGUID("npc")
    if not guid then return "000000" end

    -- Only Creature GUIDs have an NPC ID in segment 6
    local unitType = guid:match("^(%a+)-")
    if unitType ~= "Creature" and unitType ~= "Vehicle" then return "000000" end

    local npcIDStr = select(6, strsplit("-", guid))
    local npcID = tonumber(npcIDStr)
    if not npcID then return "000000" end

    return string.format("%06X", npcID)
end

function RuneReaderVoice:BuildSpeakerFlags(isNarrator, isPreview)
    if isNarrator then
        local flags = FLAG_NARRATOR
        if isPreview then flags = bit.bor(flags, FLAG_PREVIEW) end
        return flags  -- narrator has no gender
    end

    local flags = 0
    -- UnitSex: 1=unknown, 2=male, 3=female
    local sex = UnitSex("target") or UnitSex("questnpc") or UnitSex("npc") or 1
    if sex == 2 then
        flags = flags + GENDER_MALE
    elseif sex == 3 then
        flags = flags + GENDER_FEMALE
    end
    if isPreview then flags = bit.bor(flags, FLAG_PREVIEW) end
    return flags
end

-- ── Segment splitting ─────────────────────────────────────────────────────────
-- Splits dialog text into narrator and NPC speech segments.
-- <Angle bracket> passages become narrator segments; brackets are stripped.
-- Returns array of { text=string, isNarrator=bool }
--
-- Examples:
--   "Hello. <He frowns.> Leave now."
--   → { {text="Hello.", isNarrator=false},
--       {text="He frowns.", isNarrator=true},
--       {text="Leave now.", isNarrator=false} }
--
--   "Welcome, adventurer."   (no brackets)
--   → { {text="Welcome, adventurer.", isNarrator=false} }
--
--   "<Ethereal voice whispers.> You must not fail."
--   → { {text="Ethereal voice whispers.", isNarrator=true},
--       {text="You must not fail.", isNarrator=false} }

function RuneReaderVoice:SplitSegments(text)
    if not text or #text == 0 then return {} end

    local segments = {}

    -- Walk through text finding <...> spans
    local pos = 1
    while pos <= #text do
        local bracketStart, bracketEnd = text:find("<(.-)>", pos)

        if bracketStart then
            -- NPC speech before the bracket (if any)
            if bracketStart > pos then
                local before = text:sub(pos, bracketStart - 1):match("^%s*(.-)%s*$")
                if before and #before > 0 then
                    table.insert(segments, { text = before, isNarrator = false })
                end
            end

            -- Narrator segment: content inside brackets (brackets stripped)
            local narrator = text:sub(bracketStart + 1, bracketEnd - 1):match("^%s*(.-)%s*$")
            if narrator and #narrator > 0 then
                table.insert(segments, { text = narrator, isNarrator = true })
            end

            pos = bracketEnd + 1
        else
            -- No more brackets - remainder is NPC speech
            local remainder = text:sub(pos):match("^%s*(.-)%s*$")
            if remainder and #remainder > 0 then
                table.insert(segments, { text = remainder, isNarrator = false })
            end
            break
        end
    end

    -- Fallback: if nothing parsed (shouldn't happen), return whole text as NPC
    if #segments == 0 then
        table.insert(segments, { text = text, isNarrator = false })
    end

    return segments
end

-- ── Base64 encoding ───────────────────────────────────────────────────────────

local _b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local _nativeB64 = (C_EncodingUtil and C_EncodingUtil.EncodeBase64) or nil
local _band   = bit.band
local _rshift = bit.rshift
local _lshift = bit.lshift
local _bor    = bit.bor

local function Base64Encode(data)
    if _nativeB64 then
        local result = _nativeB64(data)
        if result then return result end
    end
    local band   = _band
    local rshift = _rshift
    local lshift = _lshift
    local bor    = _bor
    local result = {}
    local padding = 2 - ((#data - 1) % 3)
    data = data .. string.rep("\0", padding)
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        local idx1 = rshift(a, 2) + 1
        local idx2 = bor(lshift(band(a, 3), 4), rshift(b, 4)) + 1
        local idx3 = bor(lshift(band(b, 15), 2), rshift(c, 6)) + 1
        local idx4 = band(c, 63) + 1
        result[#result + 1] = _b64chars:sub(idx1, idx1)
            .. _b64chars:sub(idx2, idx2)
            .. _b64chars:sub(idx3, idx3)
            .. _b64chars:sub(idx4, idx4)
    end
    local encoded = table.concat(result)
    if padding == 2 then
        encoded = encoded:sub(1, -3) .. "=="
    elseif padding == 1 then
        encoded = encoded:sub(1, -2) .. "="
    end
    return encoded
end

-- ── Fixed-size padding ────────────────────────────────────────────────────────

local function PadToFixed(text)
    local target = GetPadSize()
    local len = #text
    if len >= target then
        local truncated = text:sub(1, target)
        local lastSpace = truncated:match(".*()%s")
        if lastSpace and lastSpace > 1 then
            truncated = text:sub(1, lastSpace - 1)
        end
        return truncated .. string.rep(" ", target - #truncated)
    else
        return text .. string.rep(" ", target - len)
    end
end


-- ── Word-boundary chunking ────────────────────────────────────────────────────
-- Splits text into chunks that fit within GetPadSize() bytes each.
-- Splits only on word boundaries (never mid-word).
-- Preserves original inter-word spacing so TTS pausing is unaffected.
local function SplitIntoWordChunks(text)
    local target = GetPadSize()
    local chunks = {}
    local chunkStart = 1
    local lastWordEnd = 0
    local pos = 1

    while pos <= #text do
        -- Find next word
        local word_start, word_end = text:find("%S+", pos)
        if not word_start then break end

        -- Would including this word push the chunk over target?
        local chunkLen = word_end - chunkStart + 1
        if chunkLen > target and lastWordEnd >= chunkStart then
            -- Emit chunk up to end of last word, preserving original spacing
            table.insert(chunks, text:sub(chunkStart, lastWordEnd))
            -- Next chunk starts at the beginning of this word
            chunkStart = word_start
        end

        lastWordEnd = word_end
        pos = word_end + 1
    end

    -- Emit the final chunk
    if lastWordEnd >= chunkStart then
        table.insert(chunks, text:sub(chunkStart, lastWordEnd))
    end

    -- Fallback: if nothing was produced, return whole text as one chunk
    if #chunks == 0 then
        table.insert(chunks, text)
    end

    return chunks
end



-- ── Build QR strings for a single segment ────────────────────────────────────

local function BuildSegmentQRStrings(dialogID, flags, raceByte, npcID, text)
    local rawChunks   = SplitIntoWordChunks(text)
    local totalChunks = #rawChunks
    if totalChunks > 255 then
        RuneReaderVoice:Dbg("WARNING: clamping " .. totalChunks .. " chunks to 255")
        totalChunks = 255
    end

    local qrStrings = {}
    for i = 1, math.min(#rawChunks, 255) do
        local padded  = PadToFixed(rawChunks[i])
        local encoded = Base64Encode(padded)

        -- Header: MAGIC(2) + VER(2) + DIALOG(4) + IDX(2) + TOTAL(2) + FLAGS(2) + RACE(2) + NPC(6) = 22 chars
        local header = MAGIC
            .. PROTOCOL_VER
            .. ToHex4(dialogID)
            .. ToHex2(i - 1)
            .. ToHex2(totalChunks)
            .. ToHex2(flags)
            .. ToHex2(raceByte)
            .. npcID

        table.insert(qrStrings, header .. encoded)

        RuneReaderVoice:Dbg(string.format(
            "Chunk %d/%d dialog=%04X flags=%02X race=%02X npc=%s raw=%d qr=%d",
            i, totalChunks, dialogID, flags, raceByte, npcID,
            #rawChunks[i], #header + #encoded
        ))
    end

    return qrStrings
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Build all segments for a dialog block. Splits on <narrator> passages.
-- Returns: dialogID (number), array of sessions
--   Each session: { sessionID=number, qrStrings=array, isNarrator=bool }
-- isPreview: if true sets FLAG_PREVIEW so reader discards the packet.
function RuneReaderVoice:BuildDialogSessions(text, isPreview)
    if not text or #text == 0 then return nil, nil end

    local dialogID = NextDialogID()
    local raceByte = isPreview and 0x00 or RuneReaderVoice:GetNPCRaceByte()
    local npcID    = isPreview and "000000" or RuneReaderVoice:GetNPCID()
    local segments = RuneReaderVoice:SplitSegments(text)
    local sessions = {}

    for _, seg in ipairs(segments) do
        local flags     = RuneReaderVoice:BuildSpeakerFlags(seg.isNarrator, isPreview)
        local qrStrings = BuildSegmentQRStrings(dialogID, flags, raceByte, npcID, seg.text)

        table.insert(sessions, {
            qrStrings  = qrStrings,
            isNarrator = seg.isNarrator,
        })

        RuneReaderVoice:Dbg(string.format(
            "Segment dialog=%04X narrator=%s chunks=%d race=%02X npc=%s",
            dialogID, tostring(seg.isNarrator), #qrStrings, raceByte, npcID
        ))
    end

    return dialogID, sessions
end

-- Legacy single-session builder kept for preview (single-segment text only).
-- Preview text never has <brackets> so no splitting needed.
function RuneReaderVoice:BuildPayloadChunks(text, isNarrator, isPreview)
    if not text or #text == 0 then return nil, nil end

    local dialogID  = NextDialogID()
    local flags     = RuneReaderVoice:BuildSpeakerFlags(isNarrator, isPreview)
    local raceByte  = 0x00      -- preview always unknown race
    local npcID     = "000000"  -- preview has no NPC
    local qrStrings = BuildSegmentQRStrings(dialogID, flags, raceByte, npcID, text)

    return dialogID, qrStrings
end

-- Measurement helper for /rrv measure command.
function RuneReaderVoice:MeasureText(text)
    if not text or #text == 0 then return 0, 0, 0, 0 end
    local chunks    = SplitIntoWordChunks(text)
    local wordCount = select(2, text:gsub("%S+", ""))
    local totalRaw  = 0
    for _, chunk in ipairs(chunks) do totalRaw = totalRaw + #chunk end
    local avgRaw = #chunks > 0 and math.floor(totalRaw / #chunks) or 0
    local qrLen  = 22 + #Base64Encode(string.rep(" ", GetPadSize()))
    return wordCount, #chunks, avgRaw, qrLen
end
