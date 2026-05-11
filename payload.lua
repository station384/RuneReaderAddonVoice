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

-- payload.lua: Segment splitting, chunking, and QR payload encoding
--
-- Protocol v04 header (22 ASCII chars):
--   "RV" + VER(2) + DIALOG(4) + SEQ(2) + SEQTOTAL(2) + SUB(2) + SUBTOTAL(2) + FLAGS(2) + RACE(2) + NPC(6)
--
--   SEQ      : 0-based segment index within this dialog.
--   SEQTOTAL : total number of segments in this dialog. Known upfront from SplitSegments.
--   SUB      : 0-based barcode chunk index within this segment.
--   SUBTOTAL : total barcode chunks for this segment. SUB==SUBTOTAL-1 is the last chunk.
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
local PROTOCOL_VER    = "05"    -- bumped: SEQ/SEQTOTAL added, IDX→SUB, TOTAL→SUBTOTAL, header now 26 chars
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

local META_START = ""
local META_END   = ""

local function StripRealm(name)
    if not name or name == "" then return "" end
    local dash = name:find("-", 1, true)
    if dash then
        return name:sub(1, dash - 1)
    end
    return name
end

local function GetPlayerClassName()
    local _, classFile = UnitClass("player")
    if not classFile then return "" end

    local map = {
        WARRIOR = "Warrior",
        PALADIN = "Paladin",
        HUNTER = "Hunter",
        ROGUE = "Rogue",
        PRIEST = "Priest",
        DEATHKNIGHT = "Death Knight",
        SHAMAN = "Shaman",
        MAGE = "Mage",
        WARLOCK = "Warlock",
        MONK = "Monk",
        DRUID = "Druid",
        DEMONHUNTER = "Demon Hunter",
        EVOKER = "Evoker",
    }

    return map[classFile] or classFile
end

local function GetCurrentPlayerTitleText()
    if type(GetCurrentTitle) ~= "function" or type(GetTitleName) ~= "function" then
        return ""
    end

    local titleId = GetCurrentTitle()
    if not titleId or titleId <= 0 then
        return ""
    end

    local ok, titleText = pcall(GetTitleName, titleId)
    if not ok or not titleText then
        return ""
    end

    titleText = tostring(titleText or "")
    if titleText == "" then
        return ""
    end

    -- WoW title API returns the raw title fragment. Prefix titles conventionally end
    -- with a trailing space (example: "Chef "), while suffix titles do not
    -- (example: "Destroyer's End"). Convert that fragment into a full template so
    -- the client can reconstruct the in-game visible form with the player name.
    if titleText:match("%s$") then
        return titleText .. "%s"
    end

    return "%s, " .. titleText
end

local function GetCurrentNpcNameForMeta()
    local ok, result = pcall(function()
        local name = UnitName("npc") or UnitName("target") or UnitName("questnpc")
        if issecretvalue and issecretvalue(name) then
            return ""
        end
        return name
    end)
    if ok and result then return result end
    return ""
end

local function BuildDialogMetaPrefix()
    local fullName = UnitName("player") or ""
    local player = StripRealm(fullName)
    local realm = GetRealmName() or ""
    local className = GetPlayerClassName()
    local playerTitle = GetCurrentPlayerTitleText()
    local npcName = GetCurrentNpcNameForMeta()

    local parts = {}
    if player ~= "" then
        table.insert(parts, META_START .. "RRV:PLAYER=" .. player .. META_END)
    end
    if realm ~= "" then
        table.insert(parts, META_START .. "RRV:REALM=" .. realm .. META_END)
    end
    if className ~= "" then
        table.insert(parts, META_START .. "RRV:CLASS=" .. className .. META_END)
    end
    if playerTitle ~= "" then
        table.insert(parts, META_START .. "RRV:TITLE=" .. playerTitle .. META_END)
    end
    if npcName ~= "" then
        table.insert(parts, META_START .. "RRV:NPCNAME=" .. npcName .. META_END)
    end

    if #parts == 0 then return "" end
    return table.concat(parts, "")
end

local function PrependDialogMetaToSegments(segments, isPreview)
    if isPreview or not segments or #segments == 0 then return end
    local prefix = BuildDialogMetaPrefix()
    if prefix == "" then return end
    segments[1].text = prefix .. (segments[1].text or "")
end

-- Header length in protocol v05:
-- MAGIC(2) + VER(2) + DIALOG(4) + SEQ(2) + SEQTOTAL(2) + SUB(2) + SUBTOTAL(2) + FLAGS(2) + RACE(2) + NPC(6) = 26 chars
local HEADER_LEN = 26

local function GetPayloadSize()
    local payloadSize = GetPadSize() - HEADER_LEN
    if payloadSize < 1 then
        payloadSize = 1
    end
    return payloadSize
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
-- Falls back to creature type only when it is safe to do so.
-- Returns 0x00 (unknown) if nothing is safely detectable.
function RuneReaderVoice:GetNPCRaceByte()
    local ok, result = pcall(function()
        -- Try all unit tokens for a player raceID (1-63)
        local _, _, raceID = UnitRace("target")
        if not raceID then _, _, raceID = UnitRace("questnpc") end
        if not raceID then _, _, raceID = UnitRace("npc") end

        if raceID and raceID >= 1 and raceID <= 0x3F then
            return raceID
        end

        -- Secret values can make creature type unsafe to use as a table key in combat.
        -- If we do not have a safe player raceID, fall back to unknown instead of exploding.
        if InCombatLockdown and InCombatLockdown() then
            return 0x00
        end

        local creatureType = UnitCreatureType("target")
            or UnitCreatureType("questnpc")
            or UnitCreatureType("npc")

        if creatureType then
            local mapped = CREATURE_TYPE_RACE[creatureType]
            if mapped then return mapped end
        end

        return 0x00  -- unknown - RuneReader will use narrator/neutral fallback
    end)

    if ok and result then
        return result
    end

    return 0x00
end

-- ── NPC ID detection ──────────────────────────────────────────────────────────

-- Returns the NPC ID as a 6-char uppercase hex string (e.g. "03A944" for 240068).
-- Extracted from segment 6 of the unit GUID:
--   Creature-0-3783-2858-37411-240068-00002972DF
--   seg:  1   2   3    4     5      6           7
-- Only valid for Creature GUIDs. Returns "000000" for players, pets, objects,
-- or if the target is unavailable.
-- function RuneReaderVoice:GetNPCID()
--     local ok, result = pcall(function()
--         local guid = UnitGUID("target") or UnitGUID("questnpc") or UnitGUID("npc")
--         if not guid then return "000000" end

--         if InCombatLockdown() then
--             return "000000"
--         end

--         -- Only Creature GUIDs have an NPC ID in segment 6
--         local unitType = guid:match("^(%a+)-")
--         if unitType ~= "Creature" and unitType ~= "Vehicle" then return "000000" end

--         local npcIDStr = select(6, strsplit("-", guid))
--         local npcID = tonumber(npcIDStr)
--         if not npcID then return "000000" end

--         return string.format("%06X", npcID)
--     end)

--     if ok and result then
--         return result
--     end

--     return "000000"
-- end

function RuneReaderVoice:GetNPCID()
        local ok, result = pcall(function()
        
            --print("GUID",UnitGUID("target"))
        
            local guid = UnitGUID("npc") or UnitGUID("target") or UnitGUID("questnpc") 
            if issecretvalue(guid) then  
              --      print("GUID is Secret") 
                    return "000000" 
                end
                
            if not guid then return "000000" end

            local unitType = guid:match("^(%a+)-")
            --print ("UnitType:", unitType)
            if unitType ~= "Creature" and unitType ~= "Vehicle" then
              --  print("returning 000000")
                return "000000"
            end

        local npcIDStr = select(6, strsplit("-", guid))
        --print("npcIDStr:", npcIDStr)
        local npcID = tonumber(npcIDStr or "", 10)
        --print("npcID:", npcID)

        if not npcID or npcID < 0 or npcID > 0xFFFFFF then
         --   print ("not npcID or npcID < 0 or npcID > 0xFFFFFF:", "evaled true")
            return "000000"
        end

        return string.format("%06X", npcID)
    end)
    --print("value of ok:", ok)
    --print("value of result:", result)
    if ok and result then
        return result
    end

    return "000000"
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


    -- Quest Title split: If it exists it is always the first line and should be spoken by the narrator. 
    -- (ASCII SOH — never appears in WoW dialog text). Find it, split there:
    --   • everything after   → new narrator segment (\1 byte stripped) up to and including the \n

    -- Find the end of the first line first, then look for \1 only within it.
    local firstLineEnd = text:find("\n", 1, true) or #text
    local questStart   = text:find("\1", 1, true)

    if questStart and questStart <= firstLineEnd then
        -- Title text: everything on the first line before the \1 sentinel
        local titlePart    = text:sub(1, questStart - 1)

        -- Narrator text: everything on the first line after the \1, up to (not including) the \n
        local narratorPart = text:sub(questStart + 1, firstLineEnd)

        -- Body: everything after the first line's newline (skip the \n itself)
        text = text:sub(firstLineEnd + 1)

        -- Emit title as narrator (the quest title itself)
        if titlePart and #titlePart > 0 then
            table.insert(segments, { text = titlePart, isNarrator = true })
        end

        -- Emit the inline narrator annotation from the first line (if any)
        if narratorPart and #narratorPart > 0 then
            table.insert(segments, { text = narratorPart, isNarrator = true })
        end
    end    -- Main quest Body
    -- Walk through text finding <...> or [...] spans
    local pos = 1
    while pos <= #text do
        local angleStart  = text:find("<", pos, true)
        local squareStart = text:find("[", pos, true)

        local bracketStart, bracketEnd
        if angleStart and squareStart then
            if angleStart < squareStart then
                bracketStart = angleStart
                bracketEnd   = text:find(">", bracketStart + 1, true)
            else
                bracketStart = squareStart
                bracketEnd   = text:find("]", bracketStart + 1, true)
            end
        elseif angleStart then
            bracketStart = angleStart
            bracketEnd   = text:find(">", bracketStart + 1, true)
        elseif squareStart then
            bracketStart = squareStart
            bracketEnd   = text:find("]", bracketStart + 1, true)
        end

        if bracketStart and bracketEnd then
            -- NPC speech before the bracket (if any)
            if bracketStart > pos then
                local before = text:sub(pos, bracketStart - 1)
                if before and #before > 0 then
                    table.insert(segments, { text = before, isNarrator = false })
                end
            end

            -- Narrator segment: content inside brackets (brackets stripped)
            local narrator = text:sub(bracketStart + 1, bracketEnd - 1)
            if narrator and #narrator > 0 then
                table.insert(segments, { text = narrator, isNarrator = true })
            end

            pos = bracketEnd + 1
        else
            -- No more brackets - remainder is NPC speech
            local remainder = text:sub(pos)
            if remainder and #remainder > 0 then
                table.insert(segments, { text = remainder, isNarrator = false })
            end
            break
        end
    end

    -- Quest Objective split: the objective text is always appended at the end,
    -- so it will be in the last segment. core.lua prefixes it with a \1 sentinel
    -- (ASCII SOH — never appears in WoW dialog text). Find it, split there:
    --   • everything before  → remains as NPC speech (update last segment, or drop if empty)
    --   • everything after   → new narrator segment (\1 byte stripped)
    if #segments > 0 then
        local lastSeg    = segments[#segments]
        local questStart = lastSeg.text:find("\1", 1, true)
        if questStart then
            local npcPart = lastSeg.text:sub(1, questStart - 1)

            -- Narrator part: skip the \1 byte, then trim.
            -- Two options — pick whichever sounds better.
            -- Leaving Option B in the code for now so I can flip to either and see how each one "feels" in-game.
            -- Option A (no announcement): narrator reads only the objective text.
            --   e.g. "Collect 5 apples and return to Thrall."
            local narratorPart = lastSeg.text:sub(questStart + 1)
            --
            -- Option B (with announcement): narrator announces then reads.
            --   e.g. "Quest Objectives. Collect 5 apples and return to Thrall."
            -- local narratorPart = ("Quest Objectives. " .. lastSeg.text:sub(questStart + 1))

            -- Update or remove the last segment
            if npcPart and #npcPart > 0 then
                segments[#segments].text = npcPart
            else
                table.remove(segments)
            end

            -- Append the narrator segment for the objective text
            if narratorPart and #narratorPart > 0 then
                table.insert(segments, { text = narratorPart, isNarrator = true })
            end
        end
    end

    -- Fallback: if nothing parsed (shouldn't happen), return whole text as NPC
    if #segments == 0 then
        table.insert(segments, { text = text, isNarrator = false })
    end

    return segments
end

-- -- ── Base64 encoding ───────────────────────────────────────────────────────────

-- local _b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
-- local _nativeB64 = (C_EncodingUtil and C_EncodingUtil.EncodeBase64) or nil
-- local _band   = bit.band
-- local _rshift = bit.rshift
-- local _lshift = bit.lshift
-- local _bor    = bit.bor

-- local function Base64Encode(data)
--     if _nativeB64 then
--         local result = _nativeB64(data)
--         if result then return result end
--     end
--     local band   = _band
--     local rshift = _rshift
--     local lshift = _lshift
--     local bor    = _bor
--     local result = {}
--     local padding = 2 - ((#data - 1) % 3)
--     data = data .. string.rep("\0", padding)
--     for i = 1, #data, 3 do
--         local a, b, c = data:byte(i, i + 2)
--         local idx1 = rshift(a, 2) + 1
--         local idx2 = bor(lshift(band(a, 3), 4), rshift(b, 4)) + 1
--         local idx3 = bor(lshift(band(b, 15), 2), rshift(c, 6)) + 1
--         local idx4 = band(c, 63) + 1
--         result[#result + 1] = _b64chars:sub(idx1, idx1)
--             .. _b64chars:sub(idx2, idx2)
--             .. _b64chars:sub(idx3, idx3)
--             .. _b64chars:sub(idx4, idx4)
--     end
--     local encoded = table.concat(result)
--     if padding == 2 then
--         encoded = encoded:sub(1, -3) .. "=="
--     elseif padding == 1 then
--         encoded = encoded:sub(1, -2) .. "="
--     end
--     return encoded
-- end

-- ── Fixed-size padding ────────────────────────────────────────────────────────

local function PadToFixed(text, target)
    target = target or GetPayloadSize()
    local len = #text
    if len >= target then
        return text:sub(1, target)
    end
    return text .. string.rep(" ", target - len)
end


-- ── Byte-stream chunking ─────────────────────────────────────────────────────
-- Splits text into fixed-size raw byte chunks that fit within the payload portion of a QR block.
-- No word-boundary logic is used. The source text is treated as a byte stream.
-- This preserves every byte in order and makes chunk boundaries deterministic.
local function SplitIntoByteChunks(text)
    local target = GetPayloadSize()
    local chunks = {}
    local textLen = #text
    local chunkStart = 1

    if textLen == 0 then
        table.insert(chunks, text)
        return chunks
    end

    while chunkStart <= textLen do
        local chunkEnd = math.min(chunkStart + target - 1, textLen)
        table.insert(chunks, text:sub(chunkStart, chunkEnd))
        chunkStart = chunkEnd + 1
    end

    return chunks
end



-- ── Build QR strings for a single segment ────────────────────────────────────

local function BuildSegmentQRStrings(dialogID, seq, seqTotal, flags, raceByte, npcID, text)
    local rawChunks   = SplitIntoByteChunks(text)
    local subTotal    = #rawChunks

    RuneReaderVoice:QrDbg(string.format(
        "BuildSegmentQRStrings: dialog=%04X seq=%d/%d rawLen=%d chunks=%d payload=%d total=%d flags=%02X race=%02X npc=%s",
        dialogID, seq, seqTotal, #text, subTotal, GetPayloadSize(), GetPadSize(), flags, raceByte, npcID
    ))
    RuneReaderVoice:QrDumpText(string.format("Segment dialog=%04X seq=%d source", dialogID, seq), text)
    if subTotal > 255 then
        RuneReaderVoice:Dbg("WARNING: clamping " .. subTotal .. " chunks to 255")
        subTotal = 255
    end

    local qrStrings = {}
    for i = 1, math.min(#rawChunks, 255) do
        local padded  = PadToFixed(rawChunks[i], GetPayloadSize())
        --local encoded = Base64Encode(padded)

        -- Header: MAGIC(2) + VER(2) + DIALOG(4) + SEQ(2) + SEQTOTAL(2) + SUB(2) + SUBTOTAL(2) + FLAGS(2) + RACE(2) + NPC(6) = 26 chars
        local header = MAGIC
            .. PROTOCOL_VER
            .. ToHex4(dialogID)
            .. ToHex2(seq)
            .. ToHex2(seqTotal)
            .. ToHex2(i - 1)
            .. ToHex2(subTotal)
            .. ToHex2(flags)
            .. ToHex2(raceByte)
            .. npcID

        table.insert(qrStrings, header .. padded)

        RuneReaderVoice:Dbg(string.format(
            "Chunk seq=%d/%d sub=%d/%d dialog=%04X flags=%02X race=%02X npc=%s raw=%d qr=%d",
            seq, seqTotal, i - 1, subTotal, dialogID, flags, raceByte, npcID,
            #rawChunks[i], #header + #padded
        ))
        RuneReaderVoice:QrDumpText(string.format("Chunk dialog=%04X seq=%d sub=%d raw", dialogID, seq, i - 1), rawChunks[i])
        RuneReaderVoice:QrDbg(string.format("Chunk dialog=%04X seq=%d sub=%d header=%s", dialogID, seq, i - 1, header))
    end

    return qrStrings
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Build all segments for a dialog block. Splits on <narrator> passages.
-- Returns: dialogID (number), array of sessions
--   Each session: { sessionID=number, qrStrings=array, isNarrator=bool }
-- isPreview: if true sets FLAG_PREVIEW so reader discards the packet.
function RuneReaderVoice:BuildDialogSessions(text, isPreview, npcIDOverride, raceByteOverride)
    if not text or #text == 0 then return nil, nil end

    local dialogID = NextDialogID()
    local raceByte = raceByteOverride or (isPreview and 0x00 or RuneReaderVoice:GetNPCRaceByte())
    local npcID    = npcIDOverride or (isPreview and "000000" or RuneReaderVoice:GetNPCID())
    local code39GuidPayload, code39NamePayload = nil, nil
    if RuneReaderVoice.BuildCode39SideChannel then
        code39GuidPayload, code39NamePayload = RuneReaderVoice:BuildCode39SideChannel(isPreview)
    end
    local segments = RuneReaderVoice:SplitSegments(text)
    PrependDialogMetaToSegments(segments, isPreview)
    local seqTotal = #segments      -- known upfront before any encoding begins

    RuneReaderVoice:QrDbg(string.format("BuildDialogSessions: dialog=%04X rawLen=%d segments=%d preview=%s", dialogID, #text, seqTotal, tostring(isPreview)))
    RuneReaderVoice:QrDumpText(string.format("Dialog %04X full text", dialogID), text)
    local sessions = {}

    for seq0, seg in ipairs(segments) do
        local seq       = seq0 - 1   -- convert to 0-based
        local flags     = RuneReaderVoice:BuildSpeakerFlags(seg.isNarrator, isPreview)
        RuneReaderVoice:QrDumpText(string.format("Dialog %04X segment %d text narrator=%s", dialogID, seq, tostring(seg.isNarrator)), seg.text)
        local qrStrings = BuildSegmentQRStrings(dialogID, seq, seqTotal, flags, raceByte, npcID, seg.text)

        table.insert(sessions, {
            qrStrings  = qrStrings,
            isNarrator = seg.isNarrator,
        })

        RuneReaderVoice:Dbg(string.format(
            "Segment seq=%d/%d dialog=%04X narrator=%s chunks=%d race=%02X npc=%s",
            seq, seqTotal, dialogID, tostring(seg.isNarrator), #qrStrings, raceByte, npcID
        ))
--    print(string.format(
--             "[RRV] Segment seq=%d/%d dialog=%04X narrator=%s chunks=%d race=%02X npc=%s text=|%s|",
--             seq, seqTotal, dialogID, tostring(seg.isNarrator), #qrStrings, raceByte, npcID,
--             seg.text:sub(1, 60)
--         ))
        
    end

    return dialogID, sessions, code39GuidPayload, code39NamePayload
end


-- Build all segments for a dialog block from explicit structured segments.
-- segments: array of { text=string, isNarrator=bool }
function RuneReaderVoice:BuildDialogSessionsFromSegments(segments, isPreview, npcIDOverride, raceByteOverride)
    if not segments or #segments == 0 then return nil, nil end

    local filtered = {}
    for _, seg in ipairs(segments) do
        local text = seg and seg.text or nil
        if text and #text > 0 then
            table.insert(filtered, { text = text, isNarrator = not not seg.isNarrator })
        end
    end

    if #filtered == 0 then return nil, nil end

    PrependDialogMetaToSegments(filtered, isPreview)

    local dialogID = NextDialogID()
    local raceByte = raceByteOverride or (isPreview and 0x00 or RuneReaderVoice:GetNPCRaceByte())
    local npcID    = npcIDOverride or (isPreview and "000000" or RuneReaderVoice:GetNPCID())
    local code39GuidPayload, code39NamePayload = nil, nil
    if RuneReaderVoice.BuildCode39SideChannel then
        code39GuidPayload, code39NamePayload = RuneReaderVoice:BuildCode39SideChannel(isPreview)
    end
    local seqTotal = #filtered

    RuneReaderVoice:QrDbg(string.format("BuildDialogSessionsFromSegments: dialog=%04X segments=%d preview=%s", dialogID, seqTotal, tostring(isPreview)))
    local sessions = {}

    for seq0, seg in ipairs(filtered) do
        local seq       = seq0 - 1
        local flags     = RuneReaderVoice:BuildSpeakerFlags(seg.isNarrator, isPreview)
        RuneReaderVoice:QrDumpText(string.format("Dialog %04X explicit segment %d text narrator=%s", dialogID, seq, tostring(seg.isNarrator)), seg.text)
        local qrStrings = BuildSegmentQRStrings(dialogID, seq, seqTotal, flags, raceByte, npcID, seg.text)

        table.insert(sessions, {
            qrStrings  = qrStrings,
            isNarrator = seg.isNarrator,
        })

        RuneReaderVoice:Dbg(string.format(
            "Explicit segment seq=%d/%d dialog=%04X narrator=%s chunks=%d race=%02X npc=%s",
            seq, seqTotal, dialogID, tostring(seg.isNarrator), #qrStrings, raceByte, npcID
        ))
    end

    return dialogID, sessions, code39GuidPayload, code39NamePayload
end

-- -- Legacy single-session builder kept for preview (single-segment text only).
-- -- Preview text never has <brackets> or objective splits so seqTotal is always 1.
-- function RuneReaderVoice:BuildPayloadChunks(text, isNarrator, isPreview)
--     if not text or #text == 0 then return nil, nil end

--     local dialogID  = NextDialogID()
--     local flags     = RuneReaderVoice:BuildSpeakerFlags(isNarrator, isPreview)
--     local raceByte  = 0x00      -- preview always unknown race
--     local npcID     = "000000"  -- preview has no NPC
--     local qrStrings = BuildSegmentQRStrings(dialogID, 0, 1, flags, raceByte, npcID, text)

--     return dialogID, qrStrings
-- end

-- Measurement helper for /rrv measure command.
function RuneReaderVoice:MeasureText(text)
    if not text or #text == 0 then return 0, 0, 0, 0 end
    local chunks    = SplitIntoByteChunks(text)
    local wordCount = select(2, text:gsub("%S+", ""))
    local totalRaw  = 0
    for _, chunk in ipairs(chunks) do totalRaw = totalRaw + #chunk end
    local avgRaw = #chunks > 0 and math.floor(totalRaw / #chunks) or 0
    local qrLen  = HEADER_LEN + GetPayloadSize()
    return wordCount, #chunks, avgRaw, qrLen
end
