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

-- frames_qr.lua: QR frame creation, texture rendering, and chunk cycling
--
-- Performance design:
--   1. QR matrices are pre-encoded at StartDisplay time (not in the OnUpdate hot path).
--      The QR encoder is pure Lua and expensive; doing it once per session instead of
--      once per chunk advance eliminates the main CPU spike.
--   2. OnUpdate is registered only while display is active and unregistered when idle.
--      This removes the per-frame overhead entirely between dialog interactions.
--   3. UpdateTextures diffs against the previous matrix and only calls SetColorTexture
--      on modules that actually changed. Static QR structure (finder patterns, timing,
--      alignment) is identical across chunks — only the data region changes.
--   4. Hot-path locals: _displayActive, _chunkTimer, _displayTime, _numChunks are
--      all upvalue locals, avoiding table lookups inside OnUpdate.
--   5. C_EncodingUtil availability is tested once at load time, not per call.

RuneReaderVoice = RuneReaderVoice or {}

-- ── Module-level state (upvalue locals for hot-path access) ──────────────────

local _matrices      = {}      -- pre-encoded QR matrices, indexed 1..N
local _numChunks     = 0
local _chunkIndex    = 1
local _chunkTimer    = 0.0
local _displayTime   = 0.10    -- updated from DB at StartDisplay
local _displayActive = false
local _prevMatrix    = nil     -- last rendered matrix, for diff-update

-- ── Frame creation ────────────────────────────────────────────────────────────

function RuneReaderVoice:CreateQRFrame()
    if RuneReaderVoice.QRFrame then
        return
    end

    local db = RuneReaderVoiceDB
    local moduleSize = db.QRModuleSize or 2
    local quietZone  = db.QRQuietZone  or 3
    local placeholderSize = 21
    local totalPx = (placeholderSize + 2 * quietZone) * moduleSize

    local f = CreateFrame("Frame", "RuneReaderVoiceQRFrame", UIParent, "BackdropTemplate")
    f:SetSize(totalPx, totalPx)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetIgnoreParentScale(true)
    f:SetScale(db.QRScale or 1.0)
    f:SetBackdrop({ bgFile = "Interface/Tooltips/UI-Tooltip-Background", tile = true })
    f:SetBackdropColor(1, 1, 1, 1)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")

    if db.QRPosition then
        local pos = db.QRPosition
        f:ClearAllPoints()
        f:SetPoint(pos.point or "TOPLEFT", UIParent, pos.relativePoint or "TOPLEFT", pos.x or 0, pos.y or 0)
    else
        f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
    end

    f:SetScript("OnDragStart", function(self)
        if IsAltKeyDown() then self:StartMoving() end
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relativePoint, xOfs, yOfs = self:GetPoint()
        RuneReaderVoiceDB.QRPosition = {
            point         = point,
            relativePoint = relativePoint,
            x             = xOfs,
            y             = yOfs,
        }
    end)

    f.textures   = {}
    f.qrSize     = 0    -- current texture pool side length

    -- OnUpdate is NOT registered here. It is registered only when display starts
    -- and unregistered when display stops, so it costs nothing between dialogs.

    RuneReaderVoice.QRFrame = f
    f:Hide()
end

function RuneReaderVoice:DestroyQRFrame()
    local f = RuneReaderVoice.QRFrame
    if f then
        f:SetScript("OnUpdate", nil)
        f:Hide()
        f:SetParent(nil)
        RuneReaderVoice.QRFrame = nil
    end
    _displayActive   = false
    _matrices        = {}
    _numChunks       = 0
    _chunkIndex      = 1
    _prevMatrix      = nil
    _segmentQueue    = {}
    _segmentIndex    = 1
    _currentDialogID = nil
end

-- ── Texture pool management ───────────────────────────────────────────────────

-- Rebuild the texture pool only when the QR matrix side length changes.
-- With fixed padding this should happen at most once per session (on first
-- StartDisplay after the addon loads or after a QRModuleSize/QuietZone change).
local function RebuildTexturePool(f, qrSize)
    local db         = RuneReaderVoiceDB
    local moduleSize = db.QRModuleSize or 2
    local quietZone  = db.QRQuietZone  or 3

    -- Release old textures
    if f.textures then
        for _, tex in ipairs(f.textures) do
            tex:Hide()
            tex:SetParent(nil)
        end
        wipe(f.textures)
    end
    f.textures = {}

    local totalPx = (qrSize + 2 * quietZone) * moduleSize
    f:SetSize(totalPx, totalPx)

    for y = 1, qrSize do
        for x = 1, qrSize do
            local tex = f:CreateTexture(nil, "ARTWORK")
            tex:SetSize(moduleSize, moduleSize)
            tex:SetPoint("TOPLEFT",
                (x - 1 + quietZone) * moduleSize,
                -((y - 1 + quietZone) * moduleSize)
            )
            tex:Show()
            table.insert(f.textures, tex)
        end
    end

    f.qrSize = qrSize
    RuneReaderVoice:Dbg(string.format(
        "RebuildTexturePool: qrSize=%d modules=%d totalPx=%d",
        qrSize, qrSize * qrSize, totalPx
    ))
end

-- ── Texture update (diff-based) ───────────────────────────────────────────────
-- Only calls SetColorTexture on modules whose value changed from the last frame.
-- The QR finder patterns, timing strips, and alignment patterns are identical
-- across all chunks in a session, so typically only ~20-30% of modules update.

local _BLACK = { 0, 0, 0, 1 }   -- cached to avoid table creation; SetColorTexture takes 4 args
local _WHITE = { 1, 1, 1, 0 }

local function UpdateTextures(f, matrix, prevMatrix)
    local textures = f.textures
    local qrSize   = #matrix
    local changed  = 0

    for y = 1, qrSize do
        local row     = matrix[y]
        local prevRow = prevMatrix and prevMatrix[y]
        for x = 1, qrSize do
            local val     = row[x]
            local prevVal = prevRow and prevRow[x]
            if val ~= prevVal then
                local tex = textures[(y - 1) * qrSize + x]
                if val > 0 then
                    tex:SetColorTexture(0, 0, 0, 1)
                else
                    tex:SetColorTexture(1, 1, 1, 0)
                end
                changed = changed + 1
            end
        end
    end

   -- RuneReaderVoice:Dbg("UpdateTextures: " .. changed .. " of " .. (qrSize*qrSize) .. " modules changed")
end

-- Full (non-diff) texture paint, used for the very first frame of a session.
local function PaintAllTextures(f, matrix)
    local textures = f.textures
    local qrSize   = #matrix
    for y = 1, qrSize do
        local row = matrix[y]
        for x = 1, qrSize do
            local tex = textures[(y - 1) * qrSize + x]
            if row[x] > 0 then
                tex:SetColorTexture(0, 0, 0, 1)
            else
                tex:SetColorTexture(1, 1, 1, 0)
            end
        end
    end
end

-- ── QR encoding ───────────────────────────────────────────────────────────────

local function EncodeQR(str)
    local ecLevel = (RuneReaderVoiceDB and RuneReaderVoiceDB.Ec_level) or 2
    local ok, matrix = QRencode.qrcode(str, ecLevel, 4)
    if not ok then
        RuneReaderVoice:Dbg("QR encode failed: " .. tostring(matrix))
        return nil
    end
    return matrix
end

-- ── Public: live config update ───────────────────────────────────────────────

-- Called by ApplyConfig when ChunkDisplayTime changes while display may be active.
-- Updates the upvalue read by the OnUpdate closure without restarting the session.
function RuneReaderVoice:SetDisplayTime(seconds)
    _displayTime = seconds or 0.10
end

-- Called by ApplyConfig when QRModuleSize or QRQuietZone changes.
-- If a session is active, immediately repaints with the current matrix using the
-- new module size. If idle, the next StartDisplay will pick up the new values.
function RuneReaderVoice:RefreshTexturePool()
    local f = RuneReaderVoice.QRFrame
    if not f then return end

    -- Only act if we have a rendered matrix to work from
    if not _displayActive or not _prevMatrix then return end

    local qrSize = #_prevMatrix
    -- f.qrSize was set to 0 by the caller; RebuildTexturePool will trigger
    if f.qrSize ~= qrSize then
        RebuildTexturePool(f, qrSize)
    end
    PaintAllTextures(f, _prevMatrix)
    RuneReaderVoice:Dbg("RefreshTexturePool: repainted at new module size")
end

-- ── Session queue ────────────────────────────────────────────────────────────
-- StartDisplaySessions accepts a full dialog block (multiple segments/sessions)
-- and cycles through them in order. Each segment plays all its chunks to
-- completion before advancing to the next segment.
--
-- Queue state lives here as upvalue locals alongside the existing display state.

local _segmentQueue    = {}    -- stable array of { qrStrings } for the active dialog
local _segmentIndex    = 1     -- 1-based Lua index into _segmentQueue
local _currentDialogID = nil   -- dialogID of the active queue; used to cancel on stop

-- Protocol indexing reminder:
--   SEQ and SUB inside the QR payload are 0-based indexes.
--   SEQTOTAL and SUBTOTAL are counts, not max indexes.
--
-- Display state here uses normal Lua 1-based array indexes for tables, but the
-- logical playback order must still mirror the protocol hierarchy:
--   advance SUB within the current SEQ first
--   then advance to the next SEQ
--   after the last SUB of the last SEQ, wrap back to the first SEQ/SUB and
--   repeat the entire dialog while it remains on screen.

-- Start the currently selected segment from the active dialog queue.
local function StartCurrentSegment()
    local current = _segmentQueue[_segmentIndex]
    if not current then
        RuneReaderVoice:Dbg("SegmentQueue: no current segment, display done")
        RuneReaderVoice:StopDisplay()
        return
    end

    RuneReaderVoice:Dbg(string.format(
        "SegmentQueue: starting segment %d/%d (%d chunks)",
        _segmentIndex, #_segmentQueue, #current.qrStrings
    ))
    RuneReaderVoice:StartDisplay(current.qrStrings)
end

-- Advance to the next top-level SEQ in the active dialog, wrapping to the first
-- SEQ after the final SEQ so the whole dialog repeats.
local function AdvanceSegmentQueue()
    if #_segmentQueue == 0 then
        RuneReaderVoice:Dbg("SegmentQueue: empty, display done")
        RuneReaderVoice:StopDisplay()
        return
    end

    _segmentIndex = _segmentIndex + 1
    if _segmentIndex > #_segmentQueue then
        _segmentIndex = 1
    end

    StartCurrentSegment()
end

-- StartDisplaySessions: entry point for multi-segment dialog blocks.
-- Called by core.lua DispatchDialog. Stores the full dialog block and kicks off
-- the first segment. Unlike the older one-shot queue, this state is stable so
-- the full dialog can wrap back to SEQ 0 after the last SEQ completes.
function RuneReaderVoice:StartDisplaySessions(dialogID, sessions)
    if not sessions or #sessions == 0 then return end

    -- Cancel any previous queue
    _segmentQueue    = {}
    _segmentIndex    = 1
    _currentDialogID = dialogID

    -- Store all segments in order. These correspond to payload SEQ values in
    -- ascending order, but are stored as 1-based Lua array entries.
    for _, sess in ipairs(sessions) do
        table.insert(_segmentQueue, {
            qrStrings = sess.qrStrings,
        })
    end

    RuneReaderVoice:Dbg(string.format(
        "StartDisplaySessions: dialog=%04X segments=%d", dialogID, #_segmentQueue
    ))

    StartCurrentSegment()
end

-- ── Public: start / stop display ─────────────────────────────────────────────

-- StartDisplay pre-encodes ALL QR matrices up front so the OnUpdate hot path
-- only needs to index into _matrices[] and call UpdateTextures.
function RuneReaderVoice:StartDisplay(chunks)
    if not chunks or #chunks == 0 then return end

    -- Stop any previous OnUpdate before rebuilding state
    local f = RuneReaderVoice.QRFrame
    if f then f:SetScript("OnUpdate", nil) end

    _displayActive = false   -- guard off while we rebuild
    _matrices      = {}
    _chunkIndex    = 1
    _chunkTimer    = 0.0
    _prevMatrix    = nil
    _displayTime   = (RuneReaderVoiceDB and RuneReaderVoiceDB.ChunkDisplayTime) or 0.10

    RuneReaderVoice:Dbg(string.format(
        "StartDisplay chunks=%d  pre-encoding...", #chunks
    ))

    local t0 = debugprofilestop and debugprofilestop() or 0
    for i, chunkStr in ipairs(chunks) do
        local matrix = EncodeQR(chunkStr)
        if not matrix then
            RuneReaderVoice:Dbg("  chunk " .. i .. " encode FAILED, skipping")
        end
        _matrices[i] = matrix
    end
    _numChunks = #chunks
    if debugprofilestop then
        RuneReaderVoice:Dbg(string.format(
            "  pre-encode done: %.1f ms for %d chunks",
            debugprofilestop() - t0, _numChunks
        ))
    end

    if not f then
        RuneReaderVoice:CreateQRFrame()
        f = RuneReaderVoice.QRFrame
    end

    local firstMatrix = _matrices[1]
    if firstMatrix then
        local qrSize = #firstMatrix
        if f.qrSize ~= qrSize then
            RebuildTexturePool(f, qrSize)
        end
        PaintAllTextures(f, firstMatrix)
        _prevMatrix = firstMatrix
    end

    f:Show()
    _displayActive = true

    -- Cycles through SUB chunks sequentially within the current SEQ segment.
    -- When the last SUB of the current SEQ is reached, advance to the next SEQ.
    -- After the last SUB of the last SEQ, wrap back to the first SEQ so the
    -- entire dialog repeats until stopped externally by an OnHide hook or
    -- QUEST_FINISHED.
    f:SetScript("OnUpdate", function(self, elapsed)
        if not _displayActive then return end

        _chunkTimer = _chunkTimer + elapsed
        if _chunkTimer < _displayTime then return end
        _chunkTimer = 0.0

        _chunkIndex = _chunkIndex + 1

        if _chunkIndex > _numChunks then
            if #_segmentQueue > 1 then
                _displayActive = false
                AdvanceSegmentQueue()
                return
            elseif #_segmentQueue == 1 then
                _chunkIndex = 1
            else
                RuneReaderVoice:Dbg("SegmentQueue: empty during chunk advance, stopping")
                RuneReaderVoice:StopDisplay()
                return
            end
        end

        local matrix = _matrices[_chunkIndex]
        if not matrix then return end

        UpdateTextures(self, matrix, _prevMatrix)
        _prevMatrix = matrix
    end)
end

function RuneReaderVoice:StopDisplay()
    _displayActive   = false
    _matrices        = {}
    _numChunks       = 0
    _prevMatrix      = nil
    _segmentQueue    = {}
    _segmentIndex    = 1
    _currentDialogID = nil
    local f = RuneReaderVoice.QRFrame
    if f then
        f:SetScript("OnUpdate", nil)
        f:Hide()
    end
    RuneReaderVoice:Dbg("StopDisplay")
end
