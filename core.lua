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

-- core.lua: Addon initialization, event registration, and dialog dispatch
--
-- Key API findings (sourced from WoWQuestTTS project + live testing):
--
--   Gossip NPC body text:
--     C_GossipInfo.GetText()   -- CONFIRMED works on initial NPC click (your test)
--     GetGossipText()          -- older API alias, may also work
--     CrossExp in WoWQuestTTS wraps one of these as getGossipText()
--
--   Quest text APIs (working, confirmed by WoWQuestTTS which uses them extensively):
--     GetTitleText()           -- quest title
--     GetQuestText()           -- quest description (QUEST_DETAIL)
--     GetObjectiveText()       -- quest objective text
--     GetProgressText()        -- in-progress NPC text (QUEST_PROGRESS)
--     GetRewardText()          -- completion NPC text (QUEST_COMPLETE)
--     GetGreetingText()        -- multi-quest NPC greeting (QUEST_GREETING)
--
--   Gender detection (from WoWQuestTTS source):
--     UnitSex("questnpc")      -- primary: dedicated questnpc token, more reliable than "target"
--     UnitSex("npc")           -- secondary fallback
--     Returns: 1=unknown, 2=male, 3=female
--
--   Race detection:
--     UnitRace("questnpc")     -- returns localizedName, englishName, raceID
--     raceID is numeric for player races, nil for non-player-race NPCs
--     UnitCreatureType("questnpc") -- fallback for non-humanoid: "Beast", "Dragonkin" etc.
--
--   Frame visibility detection (from WoWQuestTTS - used to guard text reads):
--     GossipFrame:IsShown()
--     QuestFrameGreetingPanel:IsShown()
--     QuestFrameProgressPanel:IsShown()
--     QuestFrameRewardPanel:IsShown()
--     QuestFrame:IsShown()
--
--   Event triggers (from WoWQuestTTS - they hook QuestFrame OnEvent):
--     GOSSIP_SHOW              → gossip NPC body text via C_GossipInfo.GetText()
--     QUEST_GREETING           → GetGreetingText()
--     QUEST_DETAIL             → GetQuestText() + GetTitleText() + GetObjectiveText()
--     QUEST_PROGRESS           → GetProgressText()
--     QUEST_COMPLETE           → GetRewardText()
--     QuestFrame OnHide        → stop playback (WoWQuestTTS uses frame hook, we use QUEST_FINISHED)
--     GossipFrame OnHide       → stop playback
--
--   QUEST_FINISHED quirks:
--     Fires on accept AND decline. May fire twice. May fire immediately
--     after QUEST_DETAIL (movie/auto-accept quests). Guarded by dialog ID + 3s minimum.

RuneReaderVoice = RuneReaderVoice or {}

-- ── Event frame ──────────────────────────────────────────────────────────────

local eventFrame = CreateFrame("Frame", "RuneReaderVoiceEventFrame", UIParent)

local EVENTS = {
    "ADDON_LOADED",
    "PLAYER_LOGOUT",
    "GOSSIP_SHOW",
    "GOSSIP_CLOSED",
    "QUEST_DETAIL",
    "QUEST_PROGRESS",
    "QUEST_COMPLETE",
    "QUEST_GREETING",
    "QUEST_FINISHED",
    "ITEM_TEXT_BEGIN",
    "ITEM_TEXT_READY",
    "ITEM_TEXT_CLOSED",
    "TAXIMAP_CLOSED",
    "ADVENTURE_MAP_CLOSE",
    "MERCHANT_CLOSED",
    "TRAINER_CLOSED",
    "BANKFRAME_CLOSED",
    "MAIL_CLOSED",
    "AUCTION_HOUSE_CLOSED",
    "LOOT_CLOSED"
}

for _, ev in ipairs(EVENTS) do
    eventFrame:RegisterEvent(ev)
end

-- ── Internal state ────────────────────────────────────────────────────────────

local _activeDialogID       = nil   -- dialogID of whatever is currently displayed
local _questDetailDialogID  = nil   -- dialogID started by the last QUEST_DETAIL
local _questDetailOpen      = false -- true only while a QUEST_DETAIL dialog is considered open
local _bookActive           = false
local _bookScanning         = false -- true while collecting all pages before dispatch
local _bookNavigating       = 0     -- pages to skip during back-navigation after scan
local _bookDispatched       = false -- true after scan-mode dispatch; suppresses duplicate ITEM_TEXT_READY
local _bookPages            = {}    -- collected page texts during scan
local _bookSource           = nil   -- item name from first page

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Symbol	Description
-- '	primary stress
-- ,	secondary stress
-- %	unstressed syllable
-- =	put the primary stress on the preceding syllable
-- _:	short pause
-- _	a shorter pause
-- |	use to separate two adjacent characters, to prevent them from being considered as a single multi-character phoneme
-- ||	indicates a word boundary within a phonetic string

local phonics_ordered = {
    -- {"talons","tal'ens"},
    -- {"Blackwood Lake", "Black-wood Lake"},
    -- {"Stranglethorn", "Strangle-thorn"},
    -- {"Scholomance", "Scholo-mance"},
    -- {"Eversong", "Ever-song"},
    -- {"Duskwood", "Dusk-wood"},
    -- {"Alterac", "Alter-ack"},
    -- {"Arathi", "Arath-ee"},
    -- {"Dunmorogh", "Dun-mor-ogh"},
    -- {"Tirisfal", "Tiris-fall"},
    -- {"Silverpine", "Silver-pine"},
    -- {"Westfall", "West-fall"},
    -- {"Redridge", "Red-ridge"},
    -- {"Stormwind", "Storm-wind"},
    -- {"Elwynn", "El-win"},
    -- {"Stratholme", "Strath-olme"},
    -- {"recuperate", "recooperate"},
    -- {"destroy", "de-stroy"},
    -- {"immanent", "emm'a'nent"},
    -- {"supplies", "supplize"},
    -- {"Darnassus", "Dar-nassus"},
    -- {"Durotar", "Du-ro-tar"},
    -- {"Dustwallow", "Dust-wallow"},
    -- {"Feralas", "Fer-allas"},
    -- {"Maraudon", "Mar-row-don"},
    -- {"Tanaris", "Tan-ar-is"},
    -- {"Azshara", "Az-shar-ah"},

    -- -- Trolls.... 
    -- {"Atal'Aman", "A'tall'Ahhmahnn"},
    -- {"Amani", "Amahnee"},
    -- {"dese", "Dee's"},
    -- {" de ", " d'"},

    -- {"Zul'Farrak", "Zul-Farrack"},
    -- {"Zul'Gurub", "Zul-Gurub"},
    -- {"Atal'Gral", "A'tall'Grahl"},
    -- {"Atal'Dazar", "A'tall'Dahzar"},
    -- {"Atal'Jani", "A'tall'Jahnee"},
    -- {"Atal'Kah", "A'tall'Kah"},
    -- {"Atal'Ma", "A'tall'Mah"},
    -- {"Atal'Qor", "A'tall'Kor"},
    -- {"Atal'Raza", "A'tall'Rahzah"},
    -- {"Atal'Shanar", "A'tall'Shahnar"},         
    -- {"Atal'Thalar", "A'tall'Thahlar"},
    -- {"Atal'Voh", "A'tall'Voh"},
    -- {"Atal'Kaldan", "A'tall'Kaldan"},
    -- {"Atal'Zul", "A'tall'Zul"},

    -- {"Mechagon", "Mechah|g%hon"},

    --{"...", "..,"},


}

local function apply_phonics(text)
    for _, to in ipairs(phonics_ordered) do
        text = text:gsub(to[1], to[2])
       -- print (to[1], "->", to[2])
    end
    return text
end
local function CleanText(text)
    if not text then return nil end
    -- Strip WoW colour codes  |cffRRGGBB ... |r
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    -- Replace common zone names with hyphenated versions to improve TTS chunking.
    -- this functionality is moved to the client side for better performance and to preserve original text in the QR payload.
    -- the addon should not make any assumptions about the text content or structure, as this can vary widely across quests and NPCs. The TTS engine is better equipped to handle phonetic adjustments without risking unintended consequences in the displayed text.
    --text = apply_phonics(text)  


    -- Collapse whitespace / newlines
    --text = text:gsub("%s+", " ")

    -- text = text:gsub("[ \t\f\v]+", " ")
    -- text = text:gsub("%.%.%.","..")
    -- text = text:gsub("% %-% "," -- ")
    local m = text   --text:match("^%s*(.-)%s*$") 

    return m
end

-- DispatchDialog: split text into narrator/NPC segments, build QR sessions,
-- hand all sessions to StartDisplaySessions for cycling.
-- Returns: dialogID (for QUEST_FINISHED guard) or nil on empty text.
local function DispatchDialog(text)
    text = CleanText(text)
    if not text or #text == 0 then return nil end

    local db = RuneReaderVoiceDB
    if db and db.DEBUG then
        local words, chunks = RuneReaderVoice:MeasureText(text)
        RuneReaderVoice:Dbg(string.format(
            "Dispatch: raw=%d words=%d chunks=%d",
            #text, words, chunks
        ))
    end

    local dialogID, sessions = RuneReaderVoice:BuildDialogSessions(text, false)
    if not sessions or #sessions == 0 then
        RuneReaderVoice:Dbg("BuildDialogSessions returned empty")
        return nil
    end

    RuneReaderVoice:Dbg(string.format(
        "Dialog %04X: %d segment(s)", dialogID, #sessions
    ))

    _activeDialogID = dialogID
    RuneReaderVoice:StartDisplaySessions(dialogID, sessions)
    return dialogID
end

-- ── NPC info helpers ──────────────────────────────────────────────────────────

local function GetNPCGender()
    local sex = UnitSex("questnpc") or UnitSex("npc") or UnitSex("target") or 1
    if sex == 2 then return "male"
    elseif sex == 3 then return "female"
    else return "unknown" end
end

-- ── Gossip / NPC body text ────────────────────────────────────────────────────

local function GetGossipBodyText()
    if C_GossipInfo and C_GossipInfo.GetText then
        local t = CleanText(C_GossipInfo.GetText() .. "\n")
        if t and #t > 0 then
            RuneReaderVoice:Dbg("Gossip text from C_GossipInfo.GetText: " .. #t .. " chars")
            return t
        end
    end
    if GetGossipText then
        local t = CleanText(GetGossipText() .. "\n")
        if t and #t > 0 then
            RuneReaderVoice:Dbg("Gossip text from GetGossipText: " .. #t .. " chars")
            return t
        end
    end
    if GossipGreetingText then
        local t = CleanText(GossipGreetingText:GetText() .. "\n")
        if t and #t > 0 then
            RuneReaderVoice:Dbg("Gossip text from GossipGreetingText FontString: " .. #t .. " chars")
            return t
        end
    end
    RuneReaderVoice:Dbg("GetGossipBodyText: no text found from any source")
    return nil
end

-- ── Event handlers ────────────────────────────────────────────────────────────

local handlers = {}

handlers.ADDON_LOADED = function(addonName)
    if addonName ~= "RuneReaderVoice" then return end
        _activeDialogID = nil
    _questDetailDialogID = nil
    _questDetailOpen = false
    RuneReaderVoice:InitConfig()
    RuneReaderVoice:CreateQRFrame()
    RuneReaderVoice:CreateConfigPanel()
    RuneReaderVoice:ApplyConfig()
    RuneReaderVoice:HookWindowClose()
    print("|cff00ccff[RuneReaderVoice]|r Loaded.  /rrv for commands.")
end

handlers.PLAYER_LOGOUT = function() end

-- ── Gossip ────────────────────────────────────────────────────────────────────
handlers.GOSSIP_SHOW = function(arg1)
    local db = RuneReaderVoiceDB
    if not db or not db.EnableQuestGreeting then return end
    if arg1 == false then return end

    -- Defer one frame - gossip APIs populate after the event fires
    C_Timer.After(0, function()
        local text = GetGossipBodyText()
        if not text then return end
        RuneReaderVoice:Dbg("GOSSIP_SHOW: " .. #text .. " chars  gender=" .. GetNPCGender())
        DispatchDialog(text)
    end)
end



-- Immediate stop — unambiguous frame close, no new dialog expected imminently.
local function StopOnFrameClose(eventName)
    RuneReaderVoice:Dbg(eventName .. " -> StopDisplay")
    RuneReaderVoice:StopDisplay()
    _activeDialogID = nil
end

-- Delayed stop — frame may briefly hide/reshow (e.g. gossip option navigation).
-- Uses same 3s guard pattern as QUEST_FINISHED: only stops if the dialog hasn't
-- changed by the time the timer fires.
local function StopOnFrameCloseDelayed(eventName, delay)
    local dialogAtClose = _activeDialogID
    if not dialogAtClose then return end
    RuneReaderVoice:Dbg(eventName .. " -> deferred stop in " .. delay .. "s for dialog " .. dialogAtClose)
    C_Timer.After(delay, function()
        if _activeDialogID == dialogAtClose then
            RuneReaderVoice:StopDisplay()
            _activeDialogID = nil
            RuneReaderVoice:Dbg(eventName .. " -> deferred stop fired")
        else
            RuneReaderVoice:Dbg(eventName .. " -> deferred stop cancelled (dialog changed)")
        end
    end)
end

-- GOSSIP_CLOSED fires on every gossip option navigation, not just final close.
-- Use a short delay so a new GOSSIP_SHOW (which sets a new _activeDialogID) can
-- arrive and cancel the stop before it fires.
handlers.GOSSIP_CLOSED         = function() StopOnFrameCloseDelayed("GOSSIP_CLOSED", 0.5) end
handlers.TAXIMAP_CLOSED        = function() StopOnFrameClose("TAXIMAP_CLOSED") end
handlers.ADVENTURE_MAP_CLOSE   = function() StopOnFrameClose("ADVENTURE_MAP_CLOSE") end
handlers.MERCHANT_CLOSED       = function() StopOnFrameClose("MERCHANT_CLOSED") end
handlers.TRAINER_CLOSED        = function() StopOnFrameClose("TRAINER_CLOSED") end
handlers.BANKFRAME_CLOSED      = function() StopOnFrameClose("BANKFRAME_CLOSED") end
handlers.MAIL_CLOSED           = function() StopOnFrameClose("MAIL_CLOSED") end
handlers.AUCTION_HOUSE_CLOSED  = function() StopOnFrameClose("AUCTION_HOUSE_CLOSED") end
handlers.LOOT_CLOSED           = function() StopOnFrameClose("LOOT_CLOSED") end
-- QUEST_LOG_UPDATE fires too frequently for reliable close detection and is
-- covered by the QuestFrame:OnHide hook in HookWindowClose.
-- ── Quest greeting (multi-quest NPC) ─────────────────────────────────────────
handlers.QUEST_GREETING = function()
    local db = RuneReaderVoiceDB
    if not db or not db.EnableQuestGreeting then return end
    local text = CleanText(GetGreetingText() .. "\n")
    if not text or #text == 0 then return end
    RuneReaderVoice:Dbg("QUEST_GREETING: " .. #text .. " chars")
    DispatchDialog(text)
end

-- ── Quest detail ──────────────────────────────────────────────────────────────
handlers.QUEST_DETAIL = function()
    local db = RuneReaderVoiceDB
    if not db or not db.EnableQuestDetail then return end

    -- Ignore repeated QUEST_DETAIL while the same quest-detail window is still open.
    -- The game can re-fire QUEST_DETAIL periodically without the dialog actually changing.
    if _questDetailOpen then
        RuneReaderVoice:Dbg("QUEST_DETAIL: ignored because quest detail is already open")
        return
    end

    local title     = nil
    -- Say the title in the narrator voice
    if (GetTitleText() or "") ~= "" then 
        title = CleanText("\1" .. GetTitleText() .. "\n")
    end 

    -- say quest text in NPC voice
    local questText = CleanText(GetQuestText() .. "\n")
    --print ("GetQuestText: [" .. tostring(questText) .. "]")
    local objective = nil
    
    -- say the objective text in the narrator voice, if it exists. Many quests don't have this field, and it's often redundant with the quest text, so it's better to skip it when empty.
    if (GetObjectiveText() or "") ~= "" then
         objective = CleanText("\1" .. GetObjectiveText() .. "\n")
    end
    
    local parts = {}
    if title     and #title     > 0 then table.insert(parts, title) end
    if questText and #questText > 0 then table.insert(parts, questText) end
    if objective and #objective > 0 then table.insert(parts, objective) end

    local combined = table.concat(parts, "  ")
    if #combined == 0 then
        RuneReaderVoice:Dbg("QUEST_DETAIL: no text")
        return
    end

    RuneReaderVoice:Dbg("QUEST_DETAIL: " .. #combined .. " chars  gender=" .. GetNPCGender())

    local did = DispatchDialog(combined)
    if did then
        _questDetailDialogID = did
        _questDetailOpen = true
        RuneReaderVoice:Dbg("QUEST_DETAIL: opened dialog " .. did)
    end
end

-- ── Quest progress ────────────────────────────────────────────────────────────
handlers.QUEST_PROGRESS = function()
    local db = RuneReaderVoiceDB
    if not db or not db.EnableQuestProgress then return end
    local text = CleanText(GetProgressText() .. "\n")
    if not text or #text == 0 then return end
    RuneReaderVoice:Dbg("QUEST_PROGRESS: " .. #text .. " chars")
    DispatchDialog(text)
end

-- ── Quest complete / reward ───────────────────────────────────────────────────
handlers.QUEST_COMPLETE = function()
    local db = RuneReaderVoiceDB
    if not db or not db.EnableQuestReward then return end
    local text = CleanText(GetRewardText() .. "\n")
    if not text or #text == 0 then return end
    RuneReaderVoice:Dbg("QUEST_COMPLETE: " .. #text .. " chars")
    DispatchDialog(text)
end

-- ── Quest finished ────────────────────────────────────────────────────────────
-- Fires on accept OR decline. May fire twice. May fire immediately after
-- QUEST_DETAIL for movie/auto-accept quests.
-- Strategy: 3 second minimum display time, then stop only if dialog unchanged.
handlers.QUEST_FINISHED = function()
    local dialogAtFinish = _activeDialogID

    -- Mark quest-detail as closed immediately so the next QUEST_DETAIL can open a new dialog.
    _questDetailOpen = false

    if not dialogAtFinish then
        _questDetailDialogID = nil
        RuneReaderVoice:Dbg("QUEST_FINISHED: no active dialog; quest detail marked closed")
        return
    end

    RuneReaderVoice:Dbg("QUEST_FINISHED: will stop dialog " .. dialogAtFinish .. " in 3s")

    C_Timer.After(3.0, function()
        if _activeDialogID == dialogAtFinish then
            RuneReaderVoice:StopDisplay()
            _activeDialogID      = nil
            _questDetailDialogID = nil
            RuneReaderVoice:Dbg("QUEST_FINISHED: stopped display")
        end
    end)
end

-- ── Books ─────────────────────────────────────────────────────────────────────
-- Full-scan strategy: on ITEM_TEXT_BEGIN, scan all pages by calling
-- ItemTextNextPage() to collect every page's text, then navigate back to
-- page 1 and dispatch the full book as a single dialog.
-- The player sees the QR appear on page 1 with the complete text already
-- encoded — no need to click through pages to hear the whole book.
--
-- Scan state machine:
--   _bookScanning = true  → ITEM_TEXT_READY collects text, advances to next page
--   _bookScanning = false → ITEM_TEXT_READY in normal display mode (ignored, text
--                           already dispatched from scan)

handlers.ITEM_TEXT_BEGIN = function()
    local db = RuneReaderVoiceDB
    if not db or not db.EnableBooks then return end

    _bookActive   = true
    _bookPages    = {}
    _bookSource   = nil

    if db.BookScanMode then
        _bookScanning = true
        RuneReaderVoice:Dbg("ITEM_TEXT_BEGIN: full-scan mode starting")
    else
        _bookScanning = false
        RuneReaderVoice:Dbg("ITEM_TEXT_BEGIN: per-page mode")
    end
    -- ITEM_TEXT_READY fires immediately after for the first page.
end

handlers.ITEM_TEXT_READY = function()
    local db = RuneReaderVoiceDB
    if not db or not db.EnableBooks then return end
    if not _bookActive then return end

    local text   = CleanText(ItemTextGetText())
    local pageNum = (ItemTextGetPage and ItemTextGetPage()) or 1

    if _bookScanning then
        -- Scan mode: collect this page and advance
        if not text or #text == 0 then
            RuneReaderVoice:Dbg("ITEM_TEXT_READY (scan): empty page " .. pageNum .. ", ending scan")
            -- treat as last page
        else
            if pageNum == 1 then
                _bookSource = CleanText(ItemTextGetItem())
            end
            RuneReaderVoice:Dbg("ITEM_TEXT_READY (scan): collected page " .. pageNum .. " (" .. #text .. " chars)")
            table.insert(_bookPages, text)
        end

        -- Try to advance to next page
        local hasNext = ItemTextNextPage and ItemTextNextPage()
        if hasNext then
            -- ITEM_TEXT_READY will fire again for the next page
            RuneReaderVoice:Dbg("ITEM_TEXT_READY (scan): advancing to next page")
            return
        end

        -- No more pages — scan complete. Now navigate back to page 1.
        RuneReaderVoice:Dbg("ITEM_TEXT_READY (scan): scan complete, " .. #_bookPages .. " pages collected")
        _bookScanning = false

        -- Navigate back to page 1 if we advanced past it.
        -- ItemTextPrevPage() is available in modern WoW clients.
        -- _bookNavigating suppresses the ITEM_TEXT_READY that fires on the next
        -- frame as a result of the programmatic navigation.
        if pageNum > 1 then
            if ItemTextPrevPage then
                -- Each PrevPage call may fire ITEM_TEXT_READY; suppress them all.
                _bookNavigating = pageNum - 1
                for _ = 1, pageNum - 1 do
                    ItemTextPrevPage()
                end
                RuneReaderVoice:Dbg("ITEM_TEXT_READY (scan): navigating back " .. (pageNum-1) .. " page(s)")
            else
                RuneReaderVoice:Dbg("ITEM_TEXT_READY (scan): ItemTextPrevPage unavailable, staying on last page")
            end
        end

        -- Assemble full book text and dispatch
        if #_bookPages == 0 then
            RuneReaderVoice:Dbg("ITEM_TEXT_READY (scan): no pages collected, aborting")
            return
        end

        local parts = {}
        if _bookSource and #_bookSource > 0 then
            table.insert(parts, "\1" .. _bookSource .. "\n")
        end
        for _, pageText in ipairs(_bookPages) do
            table.insert(parts, pageText)
        end

        local full = table.concat(parts, "\n\n")
        RuneReaderVoice:Dbg("ITEM_TEXT_READY (scan): dispatching " .. #full .. " chars (" .. #_bookPages .. " pages)")
        DispatchDialog(full)

        -- Suppress any further ITEM_TEXT_READY until user manually turns page
        _bookDispatched = true

        -- Clear scan state
        _bookPages  = {}
        _bookSource = nil
        return
    end

    -- Suppress ITEM_TEXT_READY events that fire during programmatic back-navigation.
    if _bookNavigating > 0 then
        _bookNavigating = _bookNavigating - 1
        RuneReaderVoice:Dbg("ITEM_TEXT_READY: suppressed (back-nav, remaining=" .. _bookNavigating .. ")")
        return
    end

    -- Suppress duplicate ITEM_TEXT_READY events WoW fires after scan-mode dispatch.
    -- _bookDispatched is cleared when the user manually turns a page (pageNum changes).
    if _bookDispatched then
        RuneReaderVoice:Dbg("ITEM_TEXT_READY: suppressed (already dispatched page " .. pageNum .. ")")
        return
    end

    -- Per-page mode (BookScanMode disabled): dispatch each page as shown.
    if not text or #text == 0 then return end
    local source = CleanText(ItemTextGetItem())
    local full = (pageNum == 1 and source and #source > 0)
        and ("\1" .. source .. "\n" .. text)
        or  text
    -- User manually navigated — clear dispatched flag so future pages are processed
    _bookDispatched = false
    RuneReaderVoice:Dbg("ITEM_TEXT_READY (per-page): page " .. pageNum .. " (" .. #full .. " chars)")
    DispatchDialog(full)
end

handlers.ITEM_TEXT_CLOSED = function()
    _bookActive      = false
    _bookScanning    = false
    _bookNavigating  = 0
    _bookDispatched  = false
    _bookPages       = {}
    _bookSource      = nil
    RuneReaderVoice:StopDisplay()
    _activeDialogID = nil
    RuneReaderVoice:Dbg("ITEM_TEXT_CLOSED")
end

-- ── Window close hooks ───────────────────────────────────────────────────────
-- Hook OnHide on the actual Blizzard dialog frames. These fire unconditionally
-- on every close path: Escape key, clicking away, Accept, Decline, clicking X.
function RuneReaderVoice:HookWindowClose()
    if GossipFrame then
        GossipFrame:HookScript("OnHide", function()
            if RuneReaderVoice:IsPreviewActive() then return end
            -- Use delayed stop — gossip frame hides briefly during option navigation
            -- before reshowing with the same or a new NPC dialog. The 0.5s delay
            -- allows a new GOSSIP_SHOW to arrive and set a new _activeDialogID,
            -- which cancels the deferred stop before it fires.
            StopOnFrameCloseDelayed("GossipFrame:OnHide", 0.5)
        end)
    end

    if QuestFrame then
        QuestFrame:HookScript("OnHide", function()
            if RuneReaderVoice:IsPreviewActive() then return end
            RuneReaderVoice:Dbg("QuestFrame:OnHide -> StopDisplay")
            -- If QUEST_FINISHED timer is already scheduled for this dialog, let it run.
            if _questDetailDialogID and _questDetailDialogID == _activeDialogID then
                RuneReaderVoice:Dbg("QuestFrame:OnHide: QUEST_FINISHED timer pending, skipping")
            else
                RuneReaderVoice:StopDisplay()
                _activeDialogID = nil
                _questDetailDialogID = nil
                _questDetailOpen = false
            end
        end)
    end

    if ItemTextFrame then
        ItemTextFrame:HookScript("OnHide", function()
            if RuneReaderVoice:IsPreviewActive() then return end
            RuneReaderVoice:Dbg("ItemTextFrame:OnHide -> StopDisplay")
            _bookActive     = false
            RuneReaderVoice:StopDisplay()
            _activeDialogID = nil
        end)
    end

    RuneReaderVoice:Dbg("HookWindowClose: hooks registered")
end

-- ── Main event dispatcher ─────────────────────────────────────────────────────

eventFrame:SetScript("OnEvent", function(self, event, ...)
    local handler = handlers[event]
    if handler then handler(...) end
end)

-- ── Slash commands ────────────────────────────────────────────────────────────

SLASH_RUNEREADERVOICE1 = "/rrv"
SLASH_RUNEREADERVOICE2 = "/runereadervoice"

SlashCmdList["RUNEREADERVOICE"] = function(msg)
    msg = msg and msg:lower():match("^%s*(.-)%s*$") or ""

    if msg == "debug" then
        RuneReaderVoiceDB.DEBUG = not RuneReaderVoiceDB.DEBUG
        print("|cff00ccff[RuneReaderVoice]|r Debug: " .. (RuneReaderVoiceDB.DEBUG and "ON" or "OFF"))

    elseif msg == "stop" then
        RuneReaderVoice:StopDisplay()
        _activeDialogID = nil
        print("|cff00ccff[RuneReaderVoice]|r Display stopped.")

    elseif msg == "test" then
        -- Test text with a narrator segment to exercise segment splitting
        local testText = "Stranger! You have arrived at last. "
                      .. "<He places a weathered hand on your shoulder.> "
                      .. "The naaru have spoken of your coming. There is much work to be done."
        DispatchDialog(testText)
        print("|cff00ccff[RuneReaderVoice]|r Test payload dispatched (" .. #testText .. " chars, narrator split).")

    elseif msg == "measure" then
        local testText = "Stranger! You have arrived at last. The naaru have spoken of your coming. "
                      .. "There is much work to be done in Shattrath City."
        local words, chunks, padTarget, qrLen = RuneReaderVoice:MeasureText(testText)
        print(string.format(
            "|cff00ccff[RuneReaderVoice]|r raw=%d  words=%d  chunks=%d  padTarget=%d bytes  QR payload=%d chars",
            #testText, words, chunks, padTarget, qrLen
        ))
        print(string.format(
            "|cff00ccff[RuneReaderVoice]|r (presets: Small=50->%d, Medium=135->%d, Large=250->%d QR chars)",
            20 + math.ceil(50 * 4 / 3),
            20 + math.ceil(135 * 4 / 3),
            20 + math.ceil(250 * 4 / 3)
        ))

    elseif msg == "race" then
        local _, _, raceID_t  = UnitRace("target")
        local _, _, raceID_qn = UnitRace("questnpc")
        local _, _, raceID_n  = UnitRace("npc")
        local ct_t  = UnitCreatureType("target")
        local ct_qn = UnitCreatureType("questnpc")
        local ct_n  = UnitCreatureType("npc")
        local raceByte = RuneReaderVoice:GetNPCRaceByte()
        local npcID    = RuneReaderVoice:GetNPCID()
        local guid     = UnitGUID("target") or UnitGUID("questnpc") or "nil"
        print("|cff00ccff[RuneReaderVoice]|r === NPC Race Info ===")
        print("  GUID: " .. guid)
        print("  UnitRace: target=" .. tostring(raceID_t) .. "  questnpc=" .. tostring(raceID_qn) .. "  npc=" .. tostring(raceID_n))
        print("  UnitCreatureType: target=" .. tostring(ct_t) .. "  questnpc=" .. tostring(ct_qn) .. "  npc=" .. tostring(ct_n))
        print("  RACE byte: " .. string.format("0x%02X", raceByte))
        print("  NPC ID: " .. npcID)
        print("  Gender: " .. GetNPCGender())

    elseif msg == "gossip" then
        print("|cff00ccff[RuneReaderVoice]|r === Gossip Text Sources ===")
        if C_GossipInfo and C_GossipInfo.GetText then
            print("  C_GossipInfo.GetText: [" .. tostring(CleanText(C_GossipInfo.GetText())) .. "]")
        else
            print("  C_GossipInfo.GetText: (not available)")
        end
        if GetGossipText then
            print("  GetGossipText: [" .. tostring(CleanText(GetGossipText())) .. "]")
        end
        if GossipGreetingText then
            print("  GossipGreetingText FontString: [" .. tostring(CleanText(GossipGreetingText:GetText())) .. "]")
        end
        if GetGreetingText then
            print("  GetGreetingText: [" .. tostring(CleanText(GetGreetingText())) .. "]")
        end
        print("  GossipFrame shown: " .. tostring(GossipFrame and GossipFrame:IsShown()))
        print("  NPC gender: " .. GetNPCGender())
        print("  Active dialog: " .. tostring(_activeDialogID))

    else
        print("|cff00ccff[RuneReaderVoice]|r Commands:")
        print("  /rrv test    - display a test QR payload (includes narrator segment)")
        print("  /rrv measure - show chunk/QR size stats")
        print("  /rrv stop    - hide the QR frame")
        print("  /rrv debug   - toggle debug logging")
        print("  /rrv race    - show detected race/creature info (use while dialog open)")
        print("  /rrv gossip  - dump all NPC text sources (use while dialog open)")
    end
end
