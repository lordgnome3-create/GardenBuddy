-------------------------------------------------------------------------------
-- GardenBuddy.lua  v2.0
-- Turtle WoW Garden Planter Tracker
--
-- Lua 5.0 / WoW 1.12 notes:
--   string.match -> use string.find with captures
--   strtrim      -> use local GB_Trim()
--   UNIT_SPELLCAST_SUCCEEDED -> does not exist; use SPELLCAST_START/STOP
--
-- Phase tracking (v2.0):
--   Planters are numbered 1, 2, 3... in order of creation.
--   When a phase timer expires the display shows CLICK! and the timer freezes.
--   Any SPELLCAST_STOP from the player advances the LOWEST-NUMBERED planter
--   that is in the CLICK! state (phaseReady=true).  This means it doesn't
--   matter which physical planter you click - it always updates the queue in
--   order from Planter 1 upward.
--   If no planter is ready and the spell looks like a planting cast, a new
--   planter is added to the end of the queue.
-------------------------------------------------------------------------------

GARDENBUDDY_VERSION = "2.0.1"

local GB_PHASE_NAMES = {
    [1] = "Seedling",
    [2] = "Sprouting",
    [3] = "Growing",
    [4] = "Maturing",
    [5] = "Harvest Ready",
}
local GB_TOTAL_PHASES = 5
local GB_PHASE_DUR    = 546     -- 9 minutes 6 seconds per phase

local GB_MAX_PLANTERS     = 20
local GB_FRAME_W          = 330
local GB_ROW_H            = 22
local GB_MAX_VISIBLE_ROWS = 8
local GB_PAD              = 14
local GB_COL_DEL          = 16
local GB_COL_NAME         = 80
local GB_COL_PHASE        = 84
local GB_COL_TIME         = 68
local GB_COL_LEFT         = 52
local GB_MINIMAP_RADIUS   = 80

-------------------------------------------------------------------------------
-- SOUNDS
-- All paths verified against vanilla WoW 1.12 client sound files.
-- Volume is controlled via Sound_SFXVolume CVar (wrapped in pcall for safety).
-------------------------------------------------------------------------------
local GB_SOUNDS = {
    { label = "Level Up",   file = "Sound\\Interface\\LevelUp.wav"          },
    { label = "Quest Done", file = "Sound\\Interface\\iQuestComplete.wav"   },
    { label = "Whisper",    file = "Sound\\Interface\\iTellMessage.wav"     },
    { label = "Loot",       file = "Sound\\Interface\\iPickUpItem.wav"      },
    { label = "Raid Warn",  file = "Sound\\Interface\\RaidWarning.wav"      },
    { label = "None",       file = nil                                      },
}
local GB_DEFAULT_VOLUME = 1.0   -- fraction 0.0-1.0, stored in DB

-------------------------------------------------------------------------------
-- SPELL DETECTION
-- SPELLCAST_START: save the spell name.
-- SPELLCAST_STOP:  act on the saved spell.
-- SPELLCAST_FAILED / INTERRUPTED: discard saved spell.
--
-- On SPELLCAST_STOP we first check if any planter is phase-ready (CLICK!).
-- If so, advance the lowest-numbered one.  Only if nothing is ready do we
-- check whether the spell looks like a new planting and add a planter.
-------------------------------------------------------------------------------
local GB_PLANT_WORDS = { "plant", "seed", "sow", "garden", "planter", "cultivat" }
local GB_DETECT_COOLDOWN = 4   -- seconds, guards against duplicate new-planter adds

local GB = {}
GB.rows          = {}
GB.scrollOfs     = 0
GB.updateTimer   = 0
GB.initialized   = false
GB.lastPlantTime = 0
GB.pendingSpell  = nil    -- set by SPELLCAST_START, consumed by SPELLCAST_STOP

-------------------------------------------------------------------------------
-- SAVED-VARIABLE DEFAULTS
-------------------------------------------------------------------------------
local function GB_GetDefaults()
    return {
        soundEnabled  = true,
        soundIndex    = 1,
        soundVolume   = GB_DEFAULT_VOLUME,
        planters      = {},
        nextId        = 1,
        planterCount  = 0,   -- running count for "Planter N" naming
        posX          = 200,
        posY          = -200,
        minimized     = false,
        minimapAngle  = 195,
    }
end

-------------------------------------------------------------------------------
-- UTILITIES
-------------------------------------------------------------------------------
local function GB_Trim(s)
    if not s then return "" end
    return string.gsub(s, "^%s*(.-)%s*$", "%1")
end

local function GB_FormatTime(secs)
    if secs <= 0 then return "00:00" end
    local m = math.floor(secs / 60)
    local s = math.floor(math.mod(secs, 60))
    return string.format("%02d:%02d", m, s)
end

-- Migrate a planter from old plantedAt format to new phaseStartTime format.
local function GB_MigratePlanter(p)
    if p.phaseStartTime then return end
    local elapsed = 0
    if p.plantedAt then elapsed = GetTime() - p.plantedAt end
    local phase = math.floor(elapsed / GB_PHASE_DUR) + 1
    if phase < 1 then phase = 1 end
    if phase > GB_TOTAL_PHASES then phase = GB_TOTAL_PHASES end
    p.currentPhase     = phase
    p.lastKnownPhase   = phase
    local phaseElap    = math.mod(elapsed, GB_PHASE_DUR)
    p.phaseStartTime   = GetTime() - phaseElap
    p.phaseReady       = (elapsed >= phase * GB_PHASE_DUR)
    p.phaseReadyAlerted = p.phaseReady
    p.plantedAt        = nil
end

-- Returns currentPhase, secondsRemaining, phasesLeft
local function GB_GetStatus(p)
    if p.phaseReady then
        return p.currentPhase, 0, GB_TOTAL_PHASES - p.currentPhase
    end
    local elapsed = GetTime() - p.phaseStartTime
    if elapsed >= GB_PHASE_DUR then
        p.phaseReady = true
        return p.currentPhase, 0, GB_TOTAL_PHASES - p.currentPhase
    end
    return p.currentPhase, GB_PHASE_DUR - elapsed, GB_TOTAL_PHASES - p.currentPhase
end

-------------------------------------------------------------------------------
-- SOUND
-- Uses Sound_SFXVolume CVar wrapped in pcall so it can never crash the addon.
-------------------------------------------------------------------------------
local function GB_SetSFXVolume(vol)
    -- pcall silently fails if the CVar doesn't exist in this build
    pcall(SetCVar, "Sound_SFXVolume", tostring(vol))
end

local function GB_GetSFXVolume()
    local ok, val = pcall(GetCVar, "Sound_SFXVolume")
    if ok and val then return tonumber(val) or 1.0 end
    return 1.0
end

local GB_savedSFXVolume = nil

local function GB_PlayChime()
    if not GardenBuddyDB.soundEnabled then return end
    local s = GB_SOUNDS[GardenBuddyDB.soundIndex]
    if not s or not s.file then return end

    local targetVol = GardenBuddyDB.soundVolume or GB_DEFAULT_VOLUME
    GB_savedSFXVolume = GB_GetSFXVolume()
    GB_SetSFXVolume(targetVol)
    PlaySoundFile(s.file)

    -- Restore SFX volume ~0.5s later using a temporary frame
    local t = 0
    local rf = CreateFrame("Frame")
    rf:SetScript("OnUpdate", function()
        t = t + arg1
        if t >= 0.5 then
            if GB_savedSFXVolume then
                GB_SetSFXVolume(GB_savedSFXVolume)
                GB_savedSFXVolume = nil
            end
            this:SetScript("OnUpdate", nil)
        end
    end)
end

local function GB_CheckAlerts()
    if not GardenBuddyDB or not GardenBuddyDB.planters then return end
    for _, p in ipairs(GardenBuddyDB.planters) do
        GB_MigratePlanter(p)
        -- Phase advance notification (lastKnownPhase < currentPhase)
        if (p.lastKnownPhase or 1) < p.currentPhase then
            p.lastKnownPhase = p.currentPhase
            GB_PlayChime()
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff55ff55[GardenBuddy]|r |cffddffdd" .. p.name ..
                "|r advanced to |cff55ff55" ..
                (GB_PHASE_NAMES[p.currentPhase] or "Phase "..p.currentPhase) .. "|r")
        end
        -- Phase-ready notification (timer just expired)
        if p.phaseReady and not p.phaseReadyAlerted then
            p.phaseReadyAlerted = true
            GB_PlayChime()
            if p.currentPhase >= GB_TOTAL_PHASES then
                DEFAULT_CHAT_FRAME:AddMessage(
                    "|cff55ff55[GardenBuddy]|r |cffddffdd" .. p.name ..
                    "|r is ready to |cff00ff44HARVEST!|r")
            else
                DEFAULT_CHAT_FRAME:AddMessage(
                    "|cff55ff55[GardenBuddy]|r |cffddffdd" .. p.name ..
                    "|r phase done - |cffffaa00click planter to advance.|r")
            end
        end
    end
end

-------------------------------------------------------------------------------
-- PLANTER MANAGEMENT
-------------------------------------------------------------------------------
function GB_AddPlanter(name)
    local db = GardenBuddyDB
    -- Auto-number: if no name given, use "Planter N"
    if not name or strlen(name) == 0 then
        db.planterCount = (db.planterCount or 0) + 1
        name = "Planter " .. db.planterCount
    end
    if table.getn(db.planters) >= GB_MAX_PLANTERS then
        DEFAULT_CHAT_FRAME:AddMessage("|cff55ff55[GardenBuddy]|r Max planters reached.")
        return
    end
    local p = {
        name              = name,
        id                = db.nextId,
        currentPhase      = 1,
        lastKnownPhase    = 0,   -- 0 so first-tick fires the "advanced to Seedling" alert
        phaseStartTime    = GetTime(),
        phaseReady        = false,
        phaseReadyAlerted = false,
    }
    db.nextId = db.nextId + 1
    table.insert(db.planters, p)
    DEFAULT_CHAT_FRAME:AddMessage(
        "|cff55ff55[GardenBuddy]|r Tracking: |cffddffdd" .. name .. "|r")
    if GardenBuddyMainFrame then
        GardenBuddyMainFrame:Show()
        GB_RefreshDisplay()
    end
end

function GB_RemovePlanter(idx)
    if not GardenBuddyDB.planters[idx] then return end
    local name = GardenBuddyDB.planters[idx].name
    table.remove(GardenBuddyDB.planters, idx)
    DEFAULT_CHAT_FRAME:AddMessage(
        "|cff55ff55[GardenBuddy]|r Removed: |cffddffdd" .. name .. "|r")
    GB_RefreshDisplay()
end

-- Advance planter at index idx to its next phase, restarting the timer.
function GB_AdvancePlanter(idx)
    local p = GardenBuddyDB.planters[idx]
    if not p then return end
    if p.currentPhase >= GB_TOTAL_PHASES then
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff55ff55[GardenBuddy]|r |cffddffdd" .. p.name ..
            "|r is already at the final phase.")
        return
    end
    p.currentPhase      = p.currentPhase + 1
    p.phaseStartTime    = GetTime()
    p.phaseReady        = false
    p.phaseReadyAlerted = false
    -- lastKnownPhase update handled by GB_CheckAlerts on next tick
    GB_RefreshDisplay()
end

-- Returns the index of the lowest-numbered planter that is phase-ready,
-- or nil if none are ready.
local function GB_FirstReadyIndex()
    for i, p in ipairs(GardenBuddyDB.planters) do
        if p.phaseReady and p.currentPhase < GB_TOTAL_PHASES then
            return i
        end
    end
    return nil
end

-------------------------------------------------------------------------------
-- SPELL HELPERS
-------------------------------------------------------------------------------
local function GB_SpellMatchesWords(spellName, words)
    if not spellName or type(spellName) ~= "string" then return false end
    local lower = strlower(spellName)
    for _, w in ipairs(words) do
        if strfind(lower, w, 1, true) then return true end
    end
    return false
end

local function GB_SeedNameFromSpell(spellName)
    if not spellName then return nil end
    local prefixes = { "plant ", "sow ", "cultivate ", "use ", "place " }
    local lower = strlower(spellName)
    for _, pre in ipairs(prefixes) do
        if strfind(lower, pre, 1, true) == 1 then
            local s = strsub(spellName, strlen(pre) + 1)
            if strlen(s) > 0 then return s end
        end
    end
    return spellName
end

-- Called from SPELLCAST_STOP. Decides whether to advance a ready planter
-- or add a new one, or do nothing.
local function GB_OnSpellcastStop(spellName)
    -- Priority 1: advance the first ready planter, no matter what spell it was.
    local readyIdx = GB_FirstReadyIndex()
    if readyIdx then
        GB_AdvancePlanter(readyIdx)
        return
    end
    -- Priority 2: if cooldown has passed and spell looks like planting, add new.
    local now = GetTime()
    if (now - GB.lastPlantTime) >= GB_DETECT_COOLDOWN then
        local sn = (type(spellName) == "string") and spellName or ""
        if GB_SpellMatchesWords(sn, GB_PLANT_WORDS) then
            GB.lastPlantTime = now
            local db = GardenBuddyDB
            db.planterCount = (db.planterCount or 0) + 1
            GB_AddPlanter("Planter " .. db.planterCount)
            -- Undo the double-count from GB_AddPlanter's auto-number fallback
            -- by setting the name directly (AddPlanter already inserted it)
            -- Actually let's just let AddPlanter name it; prevent double count:
            -- We incremented planterCount above then AddPlanter does NOT increment
            -- (because we passed a non-empty name). Correct.
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff55ff55[GardenBuddy]|r Auto-detected planting!")
        end
    end
end

-------------------------------------------------------------------------------
-- ROW CREATION
-- Right-click the row to manually advance that planter's phase.
-------------------------------------------------------------------------------
local function GB_CreateRow(parent, rowIdx)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(GB_ROW_H)
    row:SetPoint("TOPLEFT",  parent, "TOPLEFT",  0, -((rowIdx-1)*GB_ROW_H))
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -((rowIdx-1)*GB_ROW_H))
    row:EnableMouse(true)

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(row)
    if math.mod(rowIdx, 2) == 0 then bg:SetTexture(0,0,0,0.22)
    else bg:SetTexture(0.06,0.16,0.06,0.22) end

    row:SetScript("OnMouseUp", function()
        if arg1 == "RightButton" and row.planterIdx then
            GB_AdvancePlanter(row.planterIdx)
        end
    end)
    row:SetScript("OnEnter", function()
        if row.planterIdx then
            local p = GardenBuddyDB.planters[row.planterIdx]
            if p and p.currentPhase < GB_TOTAL_PHASES then
                GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
                GameTooltip:SetText("|cffffaa00Right-click|r to manually advance phase", 1,1,1)
                GameTooltip:Show()
            end
        end
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Delete button (plain Frame to avoid Button-only API issues in 1.12)
    local del = CreateFrame("Frame", nil, row)
    del:SetWidth(GB_COL_DEL) ; del:SetHeight(GB_ROW_H-2)
    del:SetPoint("LEFT", row, "LEFT", 2, 0)
    del:EnableMouse(true)

    local delHL = del:CreateTexture(nil, "HIGHLIGHT")
    delHL:SetTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
    delHL:SetPoint("TOPLEFT",     del, "TOPLEFT",     0, 0)
    delHL:SetPoint("BOTTOMRIGHT", del, "BOTTOMRIGHT", 0, 0)

    local delTxt = del:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    delTxt:SetPoint("CENTER", del, "CENTER", 0, 0)
    delTxt:SetJustifyH("CENTER")
    delTxt:SetText("|cffff5555x|r")

    del:SetScript("OnMouseUp", function()
        if row.planterIdx then GB_RemovePlanter(row.planterIdx) end
    end)
    del:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText("Remove planter", 1,1,1)
        GameTooltip:Show()
    end)
    del:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local xOfs = GB_COL_DEL + 4

    local nameFs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameFs:SetWidth(GB_COL_NAME)
    nameFs:SetPoint("LEFT", row, "LEFT", xOfs, 0)
    nameFs:SetJustifyH("LEFT")
    xOfs = xOfs + GB_COL_NAME + 4

    local phaseFs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    phaseFs:SetWidth(GB_COL_PHASE)
    phaseFs:SetPoint("LEFT", row, "LEFT", xOfs, 0)
    phaseFs:SetJustifyH("LEFT")
    xOfs = xOfs + GB_COL_PHASE + 4

    local timeFs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    timeFs:SetWidth(GB_COL_TIME)
    timeFs:SetPoint("LEFT", row, "LEFT", xOfs, 0)
    timeFs:SetJustifyH("CENTER")
    xOfs = xOfs + GB_COL_TIME + 4

    local leftFs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    leftFs:SetWidth(GB_COL_LEFT)
    leftFs:SetPoint("LEFT", row, "LEFT", xOfs, 0)
    leftFs:SetJustifyH("CENTER")

    row.nameFs  = nameFs
    row.phaseFs = phaseFs
    row.timeFs  = timeFs
    row.leftFs  = leftFs
    row:Hide()
    return row
end

-------------------------------------------------------------------------------
-- FRAME HEIGHT
-------------------------------------------------------------------------------
local function GB_CalcFrameHeight()
    return GB_PAD + 24 + 6 + 18 + 4 + (GB_MAX_VISIBLE_ROWS*GB_ROW_H) + 6 + 24 + GB_PAD
end

-------------------------------------------------------------------------------
-- MAIN FRAME
-------------------------------------------------------------------------------
local function GB_CreateMainFrame()
    local fh = GB_CalcFrameHeight()
    local f  = CreateFrame("Frame", "GardenBuddyMainFrame", UIParent)
    f:SetWidth(GB_FRAME_W) ; f:SetHeight(fh)
    f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", GardenBuddyDB.posX, GardenBuddyDB.posY)
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile=true, tileSize=32, edgeSize=32,
        insets={left=11,right=12,top=12,bottom=11},
    })
    f:SetBackdropColor(0.04,0.12,0.04,0.95)
    f:SetFrameStrata("MEDIUM")
    f:EnableMouse(true) ; f:SetMovable(true) ; f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() this:StartMoving() end)
    f:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        local _,_,_,x,y = this:GetPoint()
        GardenBuddyDB.posX=x ; GardenBuddyDB.posY=y
    end)

    -- Title bar
    local tb = CreateFrame("Frame", nil, f)
    tb:SetHeight(24)
    tb:SetPoint("TOPLEFT",  f,"TOPLEFT",  GB_PAD,       -GB_PAD)
    tb:SetPoint("TOPRIGHT", f,"TOPRIGHT", -(GB_PAD+38), -GB_PAD)
    local tbBg = tb:CreateTexture(nil,"BACKGROUND")
    tbBg:SetAllPoints(tb) ; tbBg:SetTexture(0.05,0.28,0.05,0.88)
    local titleFs = tb:CreateFontString(nil,"OVERLAY","GameFontNormal")
    titleFs:SetPoint("CENTER",tb,"CENTER",0,0)
    titleFs:SetText("|cff33dd33* |r|cffddffddGarden Buddy|r|cff33dd33 *|r")
    local verFs = tb:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    verFs:SetPoint("RIGHT",tb,"RIGHT",-6,0)
    verFs:SetText("|cff668866v"..GARDENBUDDY_VERSION.."|r")

    local closeBtn = CreateFrame("Button","GardenBuddyCloseBtn",f,"UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT",f,"TOPRIGHT",-4,-4)
    closeBtn:SetScript("OnClick", function() GardenBuddyMainFrame:Hide() end)

    local minBtn = CreateFrame("Button","GardenBuddyMinBtn",f)
    minBtn:SetWidth(16) ; minBtn:SetHeight(16)
    minBtn:SetPoint("TOPRIGHT",closeBtn,"TOPLEFT",-2,0)
    minBtn:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
    minBtn:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
    minBtn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
    minBtn:SetScript("OnClick", function() GB_ToggleMinimize() end)
    minBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this,"ANCHOR_RIGHT")
        GameTooltip:SetText("Minimize / Restore",1,1,1) ; GameTooltip:Show()
    end)
    minBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Column headers
    local hdrY = -(GB_PAD+24+6)
    local hdrFrame = CreateFrame("Frame",nil,f)
    hdrFrame:SetHeight(18)
    hdrFrame:SetPoint("TOPLEFT",  f,"TOPLEFT",  GB_PAD, hdrY)
    hdrFrame:SetPoint("TOPRIGHT", f,"TOPRIGHT", -GB_PAD,hdrY)
    local hdrBg = hdrFrame:CreateTexture(nil,"BACKGROUND")
    hdrBg:SetAllPoints(hdrFrame) ; hdrBg:SetTexture(0.08,0.26,0.08,0.82)
    local function MakeHdr(lbl,width,xOfs,justify)
        local fs = hdrFrame:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        fs:SetWidth(width)
        fs:SetPoint("LEFT",hdrFrame,"LEFT",xOfs,0)
        fs:SetText("|cffaaffaa"..lbl.."|r")
        fs:SetJustifyH(justify or "LEFT")
    end
    local hx = GB_COL_DEL+6
    MakeHdr("Planter",  GB_COL_NAME, hx)           ; hx=hx+GB_COL_NAME+4
    MakeHdr("Phase",    GB_COL_PHASE,hx)           ; hx=hx+GB_COL_PHASE+4
    MakeHdr("Remaining",GB_COL_TIME, hx,"CENTER")  ; hx=hx+GB_COL_TIME+4
    MakeHdr("Left",     GB_COL_LEFT, hx,"CENTER")
    f.hdrFrame = hdrFrame

    local contentY = hdrY-18-4
    local contentH = GB_MAX_VISIBLE_ROWS*GB_ROW_H
    local content  = CreateFrame("Frame",nil,f)
    content:SetHeight(contentH)
    content:SetPoint("TOPLEFT",  f,"TOPLEFT",  GB_PAD, contentY)
    content:SetPoint("TOPRIGHT", f,"TOPRIGHT", -GB_PAD,contentY)
    f.content = content

    local noPlFs = content:CreateFontString(nil,"OVERLAY","GameFontNormal")
    noPlFs:SetPoint("CENTER",content,"CENTER",0,0)
    noPlFs:SetText("|cff668866No active planters.\nClick the minimap icon or type |r|cffddffdd/gb add|r")
    noPlFs:Hide()
    f.noPlText = noPlFs

    local upArrow = CreateFrame("Button",nil,f)
    upArrow:SetWidth(14) ; upArrow:SetHeight(14)
    upArrow:SetPoint("TOPRIGHT",content,"TOPRIGHT",16,0)
    upArrow:SetNormalTexture("Interface\\Buttons\\Arrow-Up-Up")
    upArrow:SetPushedTexture("Interface\\Buttons\\Arrow-Up-Down")
    upArrow:SetScript("OnClick", function()
        if GB.scrollOfs>0 then GB.scrollOfs=GB.scrollOfs-1 ; GB_RefreshDisplay() end
    end)
    local downArrow = CreateFrame("Button",nil,f)
    downArrow:SetWidth(14) ; downArrow:SetHeight(14)
    downArrow:SetPoint("BOTTOMRIGHT",content,"BOTTOMRIGHT",16,0)
    downArrow:SetNormalTexture("Interface\\Buttons\\Arrow-Down-Up")
    downArrow:SetPushedTexture("Interface\\Buttons\\Arrow-Down-Down")
    downArrow:SetScript("OnClick", function()
        local tot = table.getn(GardenBuddyDB.planters)
        if GB.scrollOfs+GB_MAX_VISIBLE_ROWS < tot then
            GB.scrollOfs=GB.scrollOfs+1 ; GB_RefreshDisplay()
        end
    end)
    f.upArrow=upArrow ; f.downArrow=downArrow

    for i=1,GB_MAX_VISIBLE_ROWS do GB.rows[i]=GB_CreateRow(content,i) end

    local sepY = contentY-contentH-3
    local sep  = f:CreateTexture(nil,"ARTWORK")
    sep:SetHeight(2)
    sep:SetPoint("TOPLEFT",  f,"TOPLEFT",  GB_PAD+4,  sepY)
    sep:SetPoint("TOPRIGHT", f,"TOPRIGHT", -GB_PAD-4, sepY)
    sep:SetTexture(0.15,0.45,0.15,0.8)

    local addBtn = CreateFrame("Button","GardenBuddyAddBtn",f,"GameMenuButtonTemplate")
    addBtn:SetWidth(100) ; addBtn:SetHeight(22)
    addBtn:SetPoint("BOTTOMLEFT",f,"BOTTOMLEFT",GB_PAD,GB_PAD+2)
    addBtn:SetText("|cff55ff55+ Add Planter|r")
    addBtn:SetScript("OnClick", function() GB_ShowAddDialog() end)

    local settBtn = CreateFrame("Button","GardenBuddySettBtn",f,"GameMenuButtonTemplate")
    settBtn:SetWidth(72) ; settBtn:SetHeight(22)
    settBtn:SetPoint("LEFT",addBtn,"RIGHT",4,0)
    settBtn:SetText("Settings")
    settBtn:SetScript("OnClick", function() GB_ToggleSettings() end)

    local soundBtn = CreateFrame("Button","GardenBuddySoundBtn",f,"GameMenuButtonTemplate")
    soundBtn:SetWidth(118) ; soundBtn:SetHeight(22)
    soundBtn:SetPoint("BOTTOMRIGHT",f,"BOTTOMRIGHT",-GB_PAD,GB_PAD+2)
    soundBtn:SetScript("OnClick", function() GB_CycleSound() end)
    soundBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this,"ANCHOR_TOP")
        GameTooltip:SetText("Quick-cycle alert sound\nFor volume use Settings",1,1,1)
        GameTooltip:Show()
    end)
    soundBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.soundBtn = soundBtn

    f:SetScript("OnUpdate", function()
        GB.updateTimer = GB.updateTimer + arg1
        if GB.updateTimer >= 1.0 then
            GB.updateTimer = 0
            GB_CheckAlerts()
            if GardenBuddyMainFrame:IsShown() and not GardenBuddyDB.minimized then
                GB_RefreshDisplay()
            end
        end
    end)

    GB_UpdateSoundBtn()
    return f
end

-------------------------------------------------------------------------------
-- SETTINGS PANEL
-- Sound picker + visual volume bar (uses Sound_SFXVolume CVar via pcall).
-------------------------------------------------------------------------------
local function GB_CreateSettingsPanel()
    local p = CreateFrame("Frame","GardenBuddySettings",UIParent)
    p:SetWidth(270) ; p:SetHeight(200)
    p:SetPoint("CENTER",UIParent,"CENTER",0,0)
    p:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile=true, tileSize=32, edgeSize=32,
        insets={left=11,right=12,top=12,bottom=11},
    })
    p:SetBackdropColor(0.04,0.12,0.04,0.98)
    p:SetFrameStrata("DIALOG")
    p:EnableMouse(true) ; p:SetMovable(true)
    p:RegisterForDrag("LeftButton")
    p:SetScript("OnDragStart", function() this:StartMoving() end)
    p:SetScript("OnDragStop",  function() this:StopMovingOrSizing() end)

    local titleFs = p:CreateFontString(nil,"OVERLAY","GameFontNormal")
    titleFs:SetPoint("TOP",p,"TOP",0,-16)
    titleFs:SetText("|cff55ff55Garden Buddy Settings|r")

    local closeX = CreateFrame("Button",nil,p,"UIPanelCloseButton")
    closeX:SetPoint("TOPRIGHT",p,"TOPRIGHT",-4,-4)
    closeX:SetScript("OnClick", function() GardenBuddySettings:Hide() end)

    -- ---- Sound picker ----
    local sndLabel = p:CreateFontString(nil,"OVERLAY","GameFontNormal")
    sndLabel:SetPoint("TOPLEFT",p,"TOPLEFT",18,-44)
    sndLabel:SetText("|cffaaffaaAlert Sound:|r")

    local sndPrev = CreateFrame("Button",nil,p,"GameMenuButtonTemplate")
    sndPrev:SetWidth(26) ; sndPrev:SetHeight(20)
    sndPrev:SetPoint("TOPLEFT",p,"TOPLEFT",18,-63)
    sndPrev:SetText("<")
    sndPrev:SetScript("OnClick", function()
        local db=GardenBuddyDB
        db.soundIndex = db.soundIndex - 1
        if db.soundIndex < 1 then db.soundIndex = table.getn(GB_SOUNDS) end
        local s=GB_SOUNDS[db.soundIndex] ; db.soundEnabled = s and s.file~=nil
        GB_UpdateSettingsPanel() ; GB_UpdateSoundBtn()
    end)

    local sndName = p:CreateFontString(nil,"OVERLAY","GameFontNormal")
    sndName:SetWidth(112)
    sndName:SetPoint("LEFT",sndPrev,"RIGHT",4,0)
    sndName:SetJustifyH("CENTER")
    p.sndName = sndName

    local sndNext = CreateFrame("Button",nil,p,"GameMenuButtonTemplate")
    sndNext:SetWidth(26) ; sndNext:SetHeight(20)
    sndNext:SetPoint("LEFT",sndName,"RIGHT",4,0)
    sndNext:SetText(">")
    sndNext:SetScript("OnClick", function()
        local db=GardenBuddyDB
        db.soundIndex = math.mod(db.soundIndex,table.getn(GB_SOUNDS))+1
        local s=GB_SOUNDS[db.soundIndex] ; db.soundEnabled = s and s.file~=nil
        GB_UpdateSettingsPanel() ; GB_UpdateSoundBtn()
    end)

    local testBtn = CreateFrame("Button",nil,p,"GameMenuButtonTemplate")
    testBtn:SetWidth(46) ; testBtn:SetHeight(20)
    testBtn:SetPoint("LEFT",sndNext,"RIGHT",6,0)
    testBtn:SetText("Test")
    testBtn:SetScript("OnClick", function() GB_PlayChime() end)

    -- ---- Volume bar ----
    local volLabel = p:CreateFontString(nil,"OVERLAY","GameFontNormal")
    volLabel:SetPoint("TOPLEFT",p,"TOPLEFT",18,-96)
    volLabel:SetText("|cffaaffaaAlert Volume:|r")

    -- Volume minus button
    local volMinus = CreateFrame("Button",nil,p,"GameMenuButtonTemplate")
    volMinus:SetWidth(26) ; volMinus:SetHeight(20)
    volMinus:SetPoint("TOPLEFT",p,"TOPLEFT",18,-115)
    volMinus:SetText("-")
    volMinus:SetScript("OnClick", function()
        local v = GardenBuddyDB.soundVolume or GB_DEFAULT_VOLUME
        v = math.floor((v - 0.1)*10+0.5)/10
        if v < 0.0 then v = 0.0 end
        GardenBuddyDB.soundVolume = v
        GB_UpdateSettingsPanel()
    end)

    -- Volume bar background
    local barBg = p:CreateTexture(nil,"BACKGROUND")
    barBg:SetHeight(14)
    barBg:SetPoint("LEFT",volMinus,"RIGHT",4,0)
    barBg:SetWidth(130)
    barBg:SetTexture(0,0,0,0.5)

    -- Volume bar fill (green) - stored on panel so GB_UpdateSettingsPanel can reach it
    local barFill = p:CreateTexture(nil,"ARTWORK")
    barFill:SetHeight(14)
    barFill:SetPoint("LEFT",volMinus,"RIGHT",4,0)
    barFill:SetTexture(0.2,0.8,0.2,0.8)
    p.barFill = barFill

    -- Volume percent text
    local volPct = p:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    volPct:SetPoint("LEFT",barBg,"RIGHT",4,0)
    volPct:SetJustifyH("LEFT")
    volPct:SetWidth(36)
    p.volPct = volPct

    -- Volume plus button
    local volPlus = CreateFrame("Button",nil,p,"GameMenuButtonTemplate")
    volPlus:SetWidth(26) ; volPlus:SetHeight(20)
    volPlus:SetPoint("LEFT",volPct,"RIGHT",2,0)
    volPlus:SetText("+")
    volPlus:SetScript("OnClick", function()
        local v = GardenBuddyDB.soundVolume or GB_DEFAULT_VOLUME
        v = math.floor((v + 0.1)*10+0.5)/10
        if v > 1.0 then v = 1.0 end
        GardenBuddyDB.soundVolume = v
        GB_UpdateSettingsPanel()
    end)

    local volNote = p:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    volNote:SetPoint("TOPLEFT",p,"TOPLEFT",18,-137)
    volNote:SetTextColor(0.7,0.7,0.7)
    volNote:SetText("Controls SFX volume only during alert playback.")

    -- ---- Info ----
    local infoFs = p:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    infoFs:SetPoint("TOPLEFT",p,"TOPLEFT",18,-156)
    infoFs:SetText("|cff668866Right-click a row to manually advance its phase.|r")
    local infoFs2 = p:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    infoFs2:SetPoint("TOPLEFT",p,"TOPLEFT",18,-170)
    infoFs2:SetText("|cff668866Planters advance in numbered order (1 first).|r")

    local doneBtn = CreateFrame("Button",nil,p,"GameMenuButtonTemplate")
    doneBtn:SetWidth(80) ; doneBtn:SetHeight(22)
    doneBtn:SetPoint("BOTTOM",p,"BOTTOM",0,12)
    doneBtn:SetText("Close")
    doneBtn:SetScript("OnClick", function() GardenBuddySettings:Hide() end)

    p:Hide()
    return p
end

function GB_UpdateSettingsPanel()
    local p = GardenBuddySettings
    if not p then return end
    local db  = GardenBuddyDB
    local snd = GB_SOUNDS[db.soundIndex]
    if snd and snd.file then
        p.sndName:SetText("|cff55ff55"..snd.label.."|r")
    else
        p.sndName:SetText("|cffff5555Off|r")
    end
    local v    = db.soundVolume or GB_DEFAULT_VOLUME
    local pct  = math.floor(v*100+0.5)
    local barW = math.floor(v*130+0.5)
    if barW < 1 then barW = 1 end
    p.barFill:SetWidth(barW)
    p.volPct:SetText(pct.."%")
end

function GB_ToggleSettings()
    if not GardenBuddySettings then
        GardenBuddySettings = GB_CreateSettingsPanel()
    end
    if GardenBuddySettings:IsShown() then
        GardenBuddySettings:Hide()
    else
        GB_UpdateSettingsPanel()
        GardenBuddySettings:Show()
    end
end

-------------------------------------------------------------------------------
-- MINIMAP BUTTON
-------------------------------------------------------------------------------
local function GB_UpdateMinimapPos()
    local btn = GardenBuddyMinimapBtn
    if not btn then return end
    local angle = math.rad(GardenBuddyDB.minimapAngle or 195)
    btn:SetPoint("CENTER",Minimap,"CENTER",
        math.cos(angle)*GB_MINIMAP_RADIUS, math.sin(angle)*GB_MINIMAP_RADIUS)
end

local function GB_CreateMinimapButton()
    local btn = CreateFrame("Button","GardenBuddyMinimapBtn",Minimap)
    btn:SetWidth(31) ; btn:SetHeight(31)
    btn:SetFrameStrata("MEDIUM") ; btn:SetFrameLevel(8)
    btn:SetClampedToScreen(true)
    btn:SetNormalTexture("Interface\\Icons\\INV_Misc_Herb_Firebloom")
    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    btn:SetPushedTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local border = btn:CreateTexture(nil,"OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetWidth(54) ; border:SetHeight(54)
    border:SetPoint("TOPLEFT",btn,"TOPLEFT",-11.5,11.5)

    local isDragging = false
    btn:RegisterForClicks("LeftButtonUp","RightButtonUp")
    btn:SetScript("OnMouseDown", function()
        if arg1=="LeftButton" then isDragging=false end
    end)
    btn:SetScript("OnUpdate", function()
        if not IsMouseButtonDown("LeftButton") then return end
        local mx,my = Minimap:GetCenter()
        local cx,cy = GetCursorPosition()
        local s = UIParent:GetScale()
        cx=cx/s ; cy=cy/s
        local newAngle = math.deg(math.atan2(cy-my,cx-mx))
        if not isDragging then
            local diff = math.abs(newAngle-(GardenBuddyDB.minimapAngle or 195))
            if diff>180 then diff=360-diff end
            if diff>5 then isDragging=true end
        end
        if isDragging then
            GardenBuddyDB.minimapAngle=newAngle ; GB_UpdateMinimapPos()
        end
    end)
    btn:SetScript("OnClick", function()
        if isDragging then isDragging=false ; return end
        if arg1=="RightButton" then
            GB_ShowAddDialog()
        else
            if GardenBuddyMainFrame:IsShown() then GardenBuddyMainFrame:Hide()
            else GardenBuddyMainFrame:Show() ; GB_RefreshDisplay() end
        end
    end)
    btn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this,"ANCHOR_LEFT")
        GameTooltip:AddLine("|cff55ff55Garden Buddy|r",1,1,1)
        GameTooltip:AddLine("Left-click:  Toggle window",0.8,0.8,0.8)
        GameTooltip:AddLine("Right-click: Add planter",  0.8,0.8,0.8)
        GameTooltip:AddLine("Drag:        Move icon",    0.8,0.8,0.8)
        local n = table.getn(GardenBuddyDB.planters)
        if n>0 then GameTooltip:AddLine(n.." planter(s) tracked",0.4,1.0,0.4) end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    GB_UpdateMinimapPos()
    return btn
end

-------------------------------------------------------------------------------
-- SOUND BUTTON / CYCLING
-------------------------------------------------------------------------------
function GB_UpdateSoundBtn()
    local f = GardenBuddyMainFrame
    if not f then return end
    local snd = GB_SOUNDS[GardenBuddyDB.soundIndex]
    if GardenBuddyDB.soundEnabled and snd and snd.file then
        f.soundBtn:SetText("|cff55ff55"..snd.label.."|r")
    else
        f.soundBtn:SetText("|cffff5555Off|r")
    end
end

function GB_CycleSound()
    local db=GardenBuddyDB
    db.soundIndex = math.mod(db.soundIndex,table.getn(GB_SOUNDS))+1
    local s=GB_SOUNDS[db.soundIndex]
    if s and s.file then db.soundEnabled=true ; PlaySoundFile(s.file)
    else db.soundEnabled=false end
    GB_UpdateSoundBtn() ; GB_UpdateSettingsPanel()
end

-------------------------------------------------------------------------------
-- MINIMIZE / RESTORE
-------------------------------------------------------------------------------
function GB_ToggleMinimize()
    local db=GardenBuddyDB ; local f=GardenBuddyMainFrame
    if not f then return end
    db.minimized = not db.minimized
    if db.minimized then
        f.hdrFrame:Hide() ; f.content:Hide() ; f.noPlText:Hide()
        f.upArrow:Hide()  ; f.downArrow:Hide()
        GardenBuddyAddBtn:Hide() ; GardenBuddySettBtn:Hide() ; GardenBuddySoundBtn:Hide()
        f:SetHeight(GB_PAD+24+GB_PAD)
    else
        f.hdrFrame:Show() ; f.content:Show()
        f.upArrow:Show()  ; f.downArrow:Show()
        GardenBuddyAddBtn:Show() ; GardenBuddySettBtn:Show() ; GardenBuddySoundBtn:Show()
        f:SetHeight(GB_CalcFrameHeight()) ; GB_RefreshDisplay()
    end
end

-------------------------------------------------------------------------------
-- DISPLAY REFRESH
-------------------------------------------------------------------------------
function GB_RefreshDisplay()
    local f = GardenBuddyMainFrame
    if not f then return end
    local planters = GardenBuddyDB.planters
    local total    = table.getn(planters)

    if total==0 then f.noPlText:Show() else f.noPlText:Hide() end
    if total>GB_MAX_VISIBLE_ROWS then
        f.upArrow:Show() ; f.downArrow:Show()
    else
        f.upArrow:Hide() ; f.downArrow:Hide() ; GB.scrollOfs=0
    end

    for i=1,GB_MAX_VISIBLE_ROWS do
        local row  = GB.rows[i]
        local pIdx = i+GB.scrollOfs
        local p    = planters[pIdx]
        if p then
            GB_MigratePlanter(p)
            row:Show() ; row.planterIdx=pIdx

            local phase,timeRem,phasesLeft = GB_GetStatus(p)
            local isDone  = (phase>=GB_TOTAL_PHASES and p.phaseReady)
            local isReady = (p.phaseReady and not isDone)
            local isWarn  = (not p.phaseReady and timeRem<120)

            row.nameFs:SetText("|cffddffdd"..p.name.."|r")

            local pName = GB_PHASE_NAMES[phase] or ("Phase "..phase)
            if isDone then   row.phaseFs:SetText("|cff00ff44"..pName.."|r")
            elseif isReady then row.phaseFs:SetText("|cffffbb00"..pName.."|r")
            elseif isWarn then  row.phaseFs:SetText("|cffffbb00"..pName.."|r")
            else             row.phaseFs:SetText("|cffaaddaa"..pName.."|r") end

            if isDone then
                row.timeFs:SetText("|cff00ff44HARVEST!|r")
            elseif isReady then
                row.timeFs:SetText("|cffffaa00CLICK!|r")
            elseif isWarn then
                row.timeFs:SetText("|cffffbb00"..GB_FormatTime(timeRem).."|r")
            else
                row.timeFs:SetText("|cffffffff"..GB_FormatTime(timeRem).."|r")
            end

            if isDone then
                row.leftFs:SetText("|cff00ff44Done!|r")
            else
                local ls = phasesLeft.." / "..(GB_TOTAL_PHASES-1)
                if phasesLeft<=1 then row.leftFs:SetText("|cffffbb00"..ls.."|r")
                else row.leftFs:SetText("|cffaaffaa"..ls.."|r") end
            end
        else
            row:Hide() ; row.planterIdx=nil
        end
    end
    GB_UpdateSoundBtn()
end

-------------------------------------------------------------------------------
-- ADD PLANTER DIALOG
-------------------------------------------------------------------------------
local function GB_CreateAddDialog()
    local d = CreateFrame("Frame","GardenBuddyAddDialog",UIParent)
    d:SetWidth(255) ; d:SetHeight(112)
    d:SetPoint("CENTER",UIParent,"CENTER")
    d:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile=true, tileSize=32, edgeSize=32,
        insets={left=11,right=12,top=12,bottom=11},
    })
    d:SetBackdropColor(0.04,0.12,0.04,0.98)
    d:SetFrameStrata("DIALOG")
    d:EnableMouse(true) ; d:SetMovable(true)
    d:RegisterForDrag("LeftButton")
    d:SetScript("OnDragStart", function() this:StartMoving() end)
    d:SetScript("OnDragStop",  function() this:StopMovingOrSizing() end)

    local titleFs = d:CreateFontString(nil,"OVERLAY","GameFontNormal")
    titleFs:SetPoint("TOP",d,"TOP",0,-16)
    titleFs:SetText("|cff55ff55Add Garden Planter|r")

    local labelFs = d:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    labelFs:SetPoint("TOPLEFT",d,"TOPLEFT",18,-38)
    labelFs:SetText("|cffddffddPlanter Name (blank = auto-number):|r")

    local editBox = CreateFrame("EditBox","GardenBuddyDialogEdit",d,"InputBoxTemplate")
    editBox:SetWidth(205) ; editBox:SetHeight(20)
    editBox:SetPoint("TOPLEFT",d,"TOPLEFT",18,-54)
    editBox:SetMaxLetters(40) ; editBox:SetAutoFocus(true)
    editBox:SetScript("OnEnterPressed", function()
        local txt = GB_Trim(this:GetText())
        if strlen(txt)==0 then
            -- auto-number
            local db=GardenBuddyDB
            db.planterCount=(db.planterCount or 0)+1
            txt = "Planter "..db.planterCount
        end
        GB_AddPlanter(txt) ; GardenBuddyAddDialog:Hide()
    end)
    editBox:SetScript("OnEscapePressed", function() GardenBuddyAddDialog:Hide() end)

    local okBtn = CreateFrame("Button",nil,d,"GameMenuButtonTemplate")
    okBtn:SetWidth(80) ; okBtn:SetHeight(22)
    okBtn:SetPoint("BOTTOMLEFT",d,"BOTTOMLEFT",18,12)
    okBtn:SetText("|cff55ff55Plant!|r")
    okBtn:SetScript("OnClick", function()
        local txt = GB_Trim(GardenBuddyDialogEdit:GetText())
        if strlen(txt)==0 then
            local db=GardenBuddyDB
            db.planterCount=(db.planterCount or 0)+1
            txt = "Planter "..db.planterCount
        end
        GB_AddPlanter(txt) ; GardenBuddyAddDialog:Hide()
    end)

    local cancelBtn = CreateFrame("Button",nil,d,"GameMenuButtonTemplate")
    cancelBtn:SetWidth(80) ; cancelBtn:SetHeight(22)
    cancelBtn:SetPoint("BOTTOMRIGHT",d,"BOTTOMRIGHT",-18,12)
    cancelBtn:SetText("Cancel")
    cancelBtn:SetScript("OnClick", function() GardenBuddyAddDialog:Hide() end)

    d:Hide()
end

function GB_ShowAddDialog()
    if not GardenBuddyAddDialog then GB_CreateAddDialog() end
    GardenBuddyDialogEdit:SetText("")
    GardenBuddyDialogEdit:SetFocus()
    GardenBuddyAddDialog:Show()
end

-------------------------------------------------------------------------------
-- EVENT HANDLER
-------------------------------------------------------------------------------
local evFrame = CreateFrame("Frame","GardenBuddyEventFrame")
evFrame:RegisterEvent("ADDON_LOADED")
evFrame:RegisterEvent("PLAYER_LOGOUT")
evFrame:RegisterEvent("SPELLCAST_START")
evFrame:RegisterEvent("SPELLCAST_STOP")
evFrame:RegisterEvent("SPELLCAST_FAILED")
evFrame:RegisterEvent("SPELLCAST_INTERRUPTED")

evFrame:SetScript("OnEvent", function()

    if event=="ADDON_LOADED" and arg1=="GardenBuddy" then
        if not GardenBuddyDB then
            GardenBuddyDB = GB_GetDefaults()
        else
            local def=GB_GetDefaults()
            for k,v in pairs(def) do
                if GardenBuddyDB[k]==nil then GardenBuddyDB[k]=v end
            end
        end
        for _,p in ipairs(GardenBuddyDB.planters) do GB_MigratePlanter(p) end

        GardenBuddyMainFrame = GB_CreateMainFrame()
        GardenBuddyMainFrame:Hide()
        GB_CreateMinimapButton()

        if GardenBuddyDB.minimized then
            GardenBuddyDB.minimized=false ; GB_ToggleMinimize()
        end
        GB_RefreshDisplay()
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff55ff55[GardenBuddy]|r v"..GARDENBUDDY_VERSION..
            " loaded - click the |cff33dd33herb minimap icon|r or type |cffddffdd/gb|r.")
        GB.initialized   = true
        GB.lastPlantTime = 0
        GB.pendingSpell  = nil

    elseif event=="PLAYER_LOGOUT" then
        if GardenBuddyMainFrame then
            local _,_,_,x,y = GardenBuddyMainFrame:GetPoint()
            GardenBuddyDB.posX=x ; GardenBuddyDB.posY=y
        end

    elseif event=="SPELLCAST_START" and GB.initialized then
        -- Store spell name (or true for instant casts that may skip START)
        GB.pendingSpell = arg1 or true

    elseif event=="SPELLCAST_STOP" and GB.initialized then
        local spell = GB.pendingSpell
        GB.pendingSpell = nil
        if not spell then return end

        -- Priority 1: advance lowest-numbered phase-ready planter
        local readyIdx = GB_FirstReadyIndex()
        if readyIdx then
            GB_AdvancePlanter(readyIdx)
            return
        end

        -- Priority 2: no planter was ready - maybe it's a new planting
        local now = GetTime()
        if (now - GB.lastPlantTime) >= GB_DETECT_COOLDOWN then
            local sn = (type(spell)=="string") and spell or ""
            if GB_SpellMatchesWords(sn, GB_PLANT_WORDS) then
                GB.lastPlantTime = now
                local db = GardenBuddyDB
                db.planterCount = (db.planterCount or 0) + 1
                GB_AddPlanter("Planter "..db.planterCount)
                DEFAULT_CHAT_FRAME:AddMessage(
                    "|cff55ff55[GardenBuddy]|r Auto-detected planting!")
            end
        end

    elseif (event=="SPELLCAST_FAILED" or event=="SPELLCAST_INTERRUPTED")
           and GB.initialized then
        GB.pendingSpell = nil
    end
end)

-------------------------------------------------------------------------------
-- DEBUG HELPER
-------------------------------------------------------------------------------
local GB_debugActive   = false
local GB_debugDeadline = 0
local GB_debugFrame    = CreateFrame("Frame","GardenBuddyDebugFrame")
local GB_DEBUG_EVENTS  = {
    "SPELLCAST_START","SPELLCAST_STOP","SPELLCAST_FAILED","SPELLCAST_INTERRUPTED",
    "CHAT_MSG_SYSTEM","CHAT_MSG_SPELL_SELF_BUFF","CHAT_MSG_LOOT",
}
for _,ev in ipairs(GB_DEBUG_EVENTS) do GB_debugFrame:RegisterEvent(ev) end
GB_debugFrame:SetScript("OnEvent", function()
    if not GB_debugActive then return end
    if GetTime() > GB_debugDeadline then
        GB_debugActive=false
        DEFAULT_CHAT_FRAME:AddMessage("|cff55ff55[GardenBuddy Debug]|r 30s window closed.")
        return
    end
    local a1 = arg1 and strsub(tostring(arg1),1,60) or ""
    local a2 = arg2 and strsub(tostring(arg2),1,30) or ""
    DEFAULT_CHAT_FRAME:AddMessage(
        "|cff55ff55[GB]|r |cffffaa00"..event.."|r"..
        (strlen(a1)>0 and (" |cffddffdd"..a1.."|r") or "")..
        (strlen(a2)>0 and (" / "..a2) or ""))
end)

-------------------------------------------------------------------------------
-- SLASH COMMANDS
-------------------------------------------------------------------------------
SLASH_GARDENBUDDY1="/gb" ; SLASH_GARDENBUDDY2="/gardenbuddy" ; SLASH_GARDENBUDDY3="/garden"

SlashCmdList["GARDENBUDDY"] = function(msg)
    if not msg then msg="" end
    msg=GB_Trim(msg)
    local spacePos=strfind(msg," ")
    local cmd,rest
    if spacePos then
        cmd=strlower(strsub(msg,1,spacePos-1)) ; rest=GB_Trim(strsub(msg,spacePos+1))
    else cmd=strlower(msg) ; rest="" end

    if cmd=="add" then
        if strlen(rest)>0 then GB_AddPlanter(rest) else GB_ShowAddDialog() end

    elseif cmd=="remove" or cmd=="rem" or cmd=="del" then
        local idx=tonumber(rest)
        if idx then GB_RemovePlanter(idx)
        else DEFAULT_CHAT_FRAME:AddMessage("|cff55ff55[GardenBuddy]|r Usage: /gb remove <number>") end

    elseif cmd=="rename" then
        local sp2=strfind(rest," ")
        if sp2 then
            local idx=tonumber(strsub(rest,1,sp2-1))
            local name=GB_Trim(strsub(rest,sp2+1))
            if idx and GardenBuddyDB.planters[idx] then
                GardenBuddyDB.planters[idx].name=name ; GB_RefreshDisplay()
                DEFAULT_CHAT_FRAME:AddMessage(
                    "|cff55ff55[GardenBuddy]|r Renamed: |cffddffdd"..name.."|r")
            end
        else DEFAULT_CHAT_FRAME:AddMessage("|cff55ff55[GardenBuddy]|r Usage: /gb rename <#> <n>") end

    elseif cmd=="advance" or cmd=="adv" then
        local idx=tonumber(rest)
        if idx then GB_AdvancePlanter(idx)
        else DEFAULT_CHAT_FRAME:AddMessage("|cff55ff55[GardenBuddy]|r Usage: /gb advance <number>") end

    elseif cmd=="clear" then
        GardenBuddyDB.planters={} ; GB.scrollOfs=0 ; GB_RefreshDisplay()
        DEFAULT_CHAT_FRAME:AddMessage("|cff55ff55[GardenBuddy]|r All planters cleared.")

    elseif cmd=="show"   then GardenBuddyMainFrame:Show() ; GB_RefreshDisplay()
    elseif cmd=="hide"   then GardenBuddyMainFrame:Hide()
    elseif cmd=="toggle" then
        if GardenBuddyMainFrame:IsShown() then GardenBuddyMainFrame:Hide()
        else GardenBuddyMainFrame:Show() ; GB_RefreshDisplay() end

    elseif cmd=="sound"    then GB_CycleSound()
    elseif cmd=="settings" then GB_ToggleSettings()

    elseif cmd=="list" then
        local ps=GardenBuddyDB.planters
        if table.getn(ps)==0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cff55ff55[GardenBuddy]|r No active planters.")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cff55ff55[GardenBuddy]|r Active planters:")
            for i,p in ipairs(ps) do
                GB_MigratePlanter(p)
                local ph,tr,pl=GB_GetStatus(p)
                local pname=GB_PHASE_NAMES[ph] or ("Phase "..ph)
                local tstr=p.phaseReady and
                    (ph>=GB_TOTAL_PHASES and "HARVEST!" or "CLICK!") or GB_FormatTime(tr)
                DEFAULT_CHAT_FRAME:AddMessage(string.format(
                    "  |cffddffdd#%d|r %s  |cffaaffaa%s|r  %s  |cffaaffaa%d left|r",
                    i,p.name,pname,tstr,pl))
            end
        end

    elseif cmd=="debug" then
        GB_debugActive=true ; GB_debugDeadline=GetTime()+30
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff55ff55[GardenBuddy]|r Debug active 30s - interact with planter now!")

    elseif cmd=="reset" then
        local kept=GardenBuddyDB.planters ; local cnt=GardenBuddyDB.planterCount
        GardenBuddyDB=GB_GetDefaults()
        GardenBuddyDB.planters=kept ; GardenBuddyDB.planterCount=cnt
        GB_UpdateSoundBtn()
        DEFAULT_CHAT_FRAME:AddMessage("|cff55ff55[GardenBuddy]|r Settings reset (planters kept).")

    elseif cmd=="resetall" then
        GardenBuddyDB=GB_GetDefaults() ; GB.scrollOfs=0 ; GB_RefreshDisplay()
        DEFAULT_CHAT_FRAME:AddMessage("|cff55ff55[GardenBuddy]|r Full reset.")

    else
        DEFAULT_CHAT_FRAME:AddMessage("|cff55ff55=== Garden Buddy v"..GARDENBUDDY_VERSION.." ===|r")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffddffdd/gb add [name]|r        - Track a planter (blank = auto-number)")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffddffdd/gb advance <#>|r       - Manually advance planter phase")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffddffdd/gb remove <#>|r        - Remove planter")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffddffdd/gb rename <#> <n>|r    - Rename a planter")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffddffdd/gb clear|r              - Remove all planters")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffddffdd/gb list|r               - Print all planters")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffddffdd/gb show|r / |cffddffdd/gb hide|r / |cffddffdd/gb toggle|r")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffddffdd/gb sound|r              - Quick-cycle alert sound")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffddffdd/gb settings|r           - Open settings panel")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffddffdd/gb debug|r              - Watch events for 30s")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffddffdd/gb reset|r / |cffddffdd/gb resetall|r")
        DEFAULT_CHAT_FRAME:AddMessage("  |cff668866Right-click any row to advance that planter's phase.|r")
        DEFAULT_CHAT_FRAME:AddMessage("  |cff668866Phase click always updates the lowest-numbered ready planter.|r")
    end
end
