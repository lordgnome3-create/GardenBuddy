-------------------------------------------------------------------------------
-- GardenBuddy.lua
-- Turtle WoW Garden Planter Tracker
-- A FishingBuddy-style window for tracking your garden planters
-- Tracks phase timers, phases remaining, and sounds a chime on phase change
-------------------------------------------------------------------------------

GARDENBUDDY_VERSION = "1.1"

-------------------------------------------------------------------------------
-- CONSTANTS
-------------------------------------------------------------------------------

-- Planter phase names (Turtle WoW gardening phases)
local GB_PHASE_NAMES = {
    [1] = "Seedling",
    [2] = "Sprouting",
    [3] = "Growing",
    [4] = "Maturing",
    [5] = "Harvest Ready",
}
local GB_TOTAL_PHASES = 5

-- Selectable phase durations in seconds (10 / 15 / 20 / 30 / 40 / 60 min)
local GB_PHASE_DURATIONS    = { 600, 900, 1200, 1800, 2400, 3600 }
local GB_DEFAULT_PHASE_DUR  = 1800   -- 30 minutes default

-- Maximum planters we track
local GB_MAX_PLANTERS        = 20

-- UI sizing
local GB_FRAME_W             = 320
local GB_ROW_H               = 22
local GB_MAX_VISIBLE_ROWS    = 8
local GB_PAD                 = 12

-- Column widths (must sum to ~ GB_FRAME_W - 2*GB_PAD - 20 for the delete btn)
local GB_COL_DEL   = 14
local GB_COL_NAME  = 78
local GB_COL_PHASE = 82
local GB_COL_TIME  = 70
local GB_COL_LEFT  = 50

-- Sound menu options { display label, PlaySound id }
local GB_SOUNDS = {
    { label = "Chime",      id = "igQuestComplete"   },
    { label = "Level Up",   id = "LevelUp"           },
    { label = "Raid Ping",  id = "RaidWarning"       },
    { label = "Loot Click", id = "igItemPickup"      },
    { label = "Coin Drop",  id = "igAbilityIconDrop" },
    { label = "None",       id = nil                 },
}

-- Chat keywords that suggest the player just placed a planter (auto-detect)
local GB_PLANT_KEYWORDS = {
    "place the planter",
    "planter placed",
    "you plant",
    "plant the seed",
    "begin planting",
    "you set down",
    "planting complete",
}

-------------------------------------------------------------------------------
-- RUNTIME STATE  (not saved)
-------------------------------------------------------------------------------

local GB = {}
GB.rows         = {}      -- array of row frame objects
GB.scrollOfs    = 0       -- scroll offset into planters list
GB.updateTimer  = 0       -- accumulator for OnUpdate throttle
GB.initialized  = false

-------------------------------------------------------------------------------
-- SAVED-VARIABLE DEFAULTS
-------------------------------------------------------------------------------

local function GB_GetDefaults()
    return {
        soundEnabled  = true,
        soundIndex    = 1,                    -- index into GB_SOUNDS
        phaseDuration = GB_DEFAULT_PHASE_DUR, -- seconds per phase
        planters      = {},                   -- array of planter records
        nextId        = 1,                    -- auto-increment id
        posX          = 100,
        posY          = -200,
        visible       = true,
        minimized     = false,
    }
end

-------------------------------------------------------------------------------
-- UTILITIES
-------------------------------------------------------------------------------

local function GB_FormatTime(secs)
    if secs <= 0 then return "00:00" end
    local m = math.floor(secs / 60)
    local s = math.floor(math.mod(secs, 60))
    return string.format("%02d:%02d", m, s)
end

-- Returns currentPhase (1-5), phaseTimeRemaining (secs), phasesLeft (after current)
local function GB_GetStatus(planter)
    local phaseDur  = GardenBuddyDB.phaseDuration
    local elapsed   = GetTime() - planter.plantedAt
    local totalTime = GB_TOTAL_PHASES * phaseDur

    if elapsed >= totalTime then
        return GB_TOTAL_PHASES, 0, 0
    end

    local phase      = math.floor(elapsed / phaseDur) + 1
    if phase > GB_TOTAL_PHASES then phase = GB_TOTAL_PHASES end

    local phaseElap  = elapsed - ((phase - 1) * phaseDur)
    local phaseRem   = phaseDur - phaseElap
    local phasesLeft = GB_TOTAL_PHASES - phase

    return phase, phaseRem, phasesLeft
end

-- Check if planter has advanced to a new phase since last check
local function GB_DetectPhaseAdvance(planter)
    local phase, _, _ = GB_GetStatus(planter)
    if planter.lastKnownPhase == nil then
        planter.lastKnownPhase = phase
        return false
    end
    if phase > planter.lastKnownPhase then
        planter.lastKnownPhase = phase
        return true  -- phase just advanced
    end
    return false
end

-------------------------------------------------------------------------------
-- SOUND
-------------------------------------------------------------------------------

local function GB_PlayChime()
    if not GardenBuddyDB.soundEnabled then return end
    local s = GB_SOUNDS[GardenBuddyDB.soundIndex]
    if s and s.id then
        PlaySound(s.id)
    end
end

-- Runs every second; sounds chime on phase change
local function GB_CheckAlerts()
    if not GardenBuddyDB or not GardenBuddyDB.planters then return end
    for _, planter in ipairs(GardenBuddyDB.planters) do
        if GB_DetectPhaseAdvance(planter) then
            GB_PlayChime()
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff55ff55[GardenBuddy]|r |cffddffdd" .. planter.name ..
                "|r has entered a new phase: |cff55ff55" ..
                (GB_PHASE_NAMES[planter.lastKnownPhase] or "Phase " .. planter.lastKnownPhase) .. "|r")
        end
    end
end

-------------------------------------------------------------------------------
-- PLANTER MANAGEMENT
-------------------------------------------------------------------------------

function GB_AddPlanter(name)
    local db = GardenBuddyDB
    if not name or strlen(name) == 0 then
        name = "Planter " .. db.nextId
    end

    if table.getn(db.planters) >= GB_MAX_PLANTERS then
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff55ff55[GardenBuddy]|r Max planters reached (" .. GB_MAX_PLANTERS .. ")")
        return
    end

    local phase1, _, _ = GB_GetStatus({ plantedAt = GetTime() })

    local p = {
        name           = name,
        plantedAt      = GetTime(),
        id             = db.nextId,
        lastKnownPhase = 1,
    }
    db.nextId = db.nextId + 1
    table.insert(db.planters, p)

    DEFAULT_CHAT_FRAME:AddMessage(
        "|cff55ff55[GardenBuddy]|r Tracking: |cffddffdd" .. name .. "|r  (phase timer started)")

    if GardenBuddyMainFrame then
        GardenBuddyDB.visible = true
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

-------------------------------------------------------------------------------
-- ROW CREATION
-------------------------------------------------------------------------------

local function GB_CreateRow(parent, rowIdx)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(GB_ROW_H)
    row:SetPoint("TOPLEFT",  parent, "TOPLEFT",  0, -((rowIdx - 1) * GB_ROW_H))
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -((rowIdx - 1) * GB_ROW_H))

    -- Alternating row background
    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(row)
    if math.mod(rowIdx, 2) == 0 then
        bg:SetTexture(0, 0, 0, 0.25)
    else
        bg:SetTexture(0.07, 0.18, 0.07, 0.25)
    end

    -- Delete button  [ x ]
    local del = CreateFrame("Button", nil, row)
    del:SetWidth(GB_COL_DEL)
    del:SetHeight(GB_ROW_H - 4)
    del:SetPoint("LEFT", row, "LEFT", 2, 0)
    del:SetNormalFontObject("GameFontNormalSmall")
    del:SetText("|cffff4444x|r")
    del:SetScript("OnClick", function()
        if row.planterIdx then
            GB_RemovePlanter(row.planterIdx)
        end
    end)
    del:SetScript("OnEnter", function() GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText("Remove this planter", 1, 1, 1) GameTooltip:Show() end)
    del:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local xOfs = GB_COL_DEL + 4

    -- Name column
    local nameFs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameFs:SetWidth(GB_COL_NAME)
    nameFs:SetPoint("LEFT", row, "LEFT", xOfs, 0)
    nameFs:SetJustifyH("LEFT")
    xOfs = xOfs + GB_COL_NAME + 4

    -- Phase name column
    local phaseFs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    phaseFs:SetWidth(GB_COL_PHASE)
    phaseFs:SetPoint("LEFT", row, "LEFT", xOfs, 0)
    phaseFs:SetJustifyH("LEFT")
    xOfs = xOfs + GB_COL_PHASE + 4

    -- Time remaining column
    local timeFs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    timeFs:SetWidth(GB_COL_TIME)
    timeFs:SetPoint("LEFT", row, "LEFT", xOfs, 0)
    timeFs:SetJustifyH("CENTER")
    xOfs = xOfs + GB_COL_TIME + 4

    -- Phases left column
    local leftFs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    leftFs:SetWidth(GB_COL_LEFT)
    leftFs:SetPoint("LEFT", row, "LEFT", xOfs, 0)
    leftFs:SetJustifyH("CENTER")

    row.nameFs  = nameFs
    row.phaseFs = phaseFs
    row.timeFs  = timeFs
    row.leftFs  = leftFs
    row.delBtn  = del
    row:Hide()
    return row
end

-------------------------------------------------------------------------------
-- MAIN FRAME CREATION
-------------------------------------------------------------------------------

local function GB_CalcFrameHeight()
    return GB_PAD + 24 + 6 + 18 + 4 + (GB_MAX_VISIBLE_ROWS * GB_ROW_H) + 8 + 26 + 22 + GB_PAD
end

local function GB_CreateMainFrame()
    local fh = GB_CalcFrameHeight()
    local f  = CreateFrame("Frame", "GardenBuddyMainFrame", UIParent)
    f:SetWidth(GB_FRAME_W)
    f:SetHeight(fh)
    f:SetPoint("TOPLEFT", UIParent, "TOPLEFT",
               GardenBuddyDB.posX, GardenBuddyDB.posY)
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 32,
        insets   = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    f:SetBackdropColor(0.04, 0.12, 0.04, 0.95)
    f:SetFrameStrata("MEDIUM")
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() this:StartMoving() end)
    f:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        local _, _, _, x, y = this:GetPoint()
        GardenBuddyDB.posX = x
        GardenBuddyDB.posY = y
    end)

    -- ===== Title Bar =====
    local titleBar = CreateFrame("Frame", nil, f)
    titleBar:SetHeight(24)
    titleBar:SetPoint("TOPLEFT",  f, "TOPLEFT",  GB_PAD,     -GB_PAD)
    titleBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -(GB_PAD + 36), -GB_PAD)
    local titleBg = titleBar:CreateTexture(nil, "BACKGROUND")
    titleBg:SetAllPoints(titleBar)
    titleBg:SetTexture(0.05, 0.30, 0.05, 0.85)

    local leafL = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    leafL:SetPoint("LEFT", titleBar, "LEFT", 6, 0)
    leafL:SetText("|cff33dd33>|r")

    local titleFs = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleFs:SetPoint("CENTER", titleBar, "CENTER", 0, 0)
    titleFs:SetText("|cffddffdd Garden Buddy |r")

    local verFs = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    verFs:SetPoint("RIGHT", titleBar, "RIGHT", -6, 0)
    verFs:SetText("|cff668866v" .. GARDENBUDDY_VERSION .. "|r")

    -- ===== Close Button =====
    local closeBtn = CreateFrame("Button", "GardenBuddyCloseBtn", f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function()
        GardenBuddyDB.visible = false
        GardenBuddyMainFrame:Hide()
    end)

    -- ===== Minimize Button =====
    local minBtn = CreateFrame("Button", "GardenBuddyMinBtn", f)
    minBtn:SetWidth(16)
    minBtn:SetHeight(16)
    minBtn:SetPoint("TOPRIGHT", closeBtn, "TOPLEFT", -2, 0)
    local minNorm = minBtn:CreateTexture(nil, "BACKGROUND")
    minNorm:SetAllPoints(minBtn)
    minNorm:SetTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
    minBtn:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
    minBtn:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
    minBtn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
    minBtn:SetScript("OnClick", function() GB_ToggleMinimize() end)
    minBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText("Minimize / Restore", 1, 1, 1)
        GameTooltip:Show()
    end)
    minBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- ===== Column Headers =====
    local hdrY = -(GB_PAD + 24 + 6)
    local hdrFrame = CreateFrame("Frame", nil, f)
    hdrFrame:SetHeight(18)
    hdrFrame:SetPoint("TOPLEFT",  f, "TOPLEFT",  GB_PAD,     hdrY)
    hdrFrame:SetPoint("TOPRIGHT", f, "TOPRIGHT", -GB_PAD,    hdrY)
    local hdrBg = hdrFrame:CreateTexture(nil, "BACKGROUND")
    hdrBg:SetAllPoints(hdrFrame)
    hdrBg:SetTexture(0.08, 0.28, 0.08, 0.80)

    local function MakeHeader(parent, label, width, xOfs)
        local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetWidth(width)
        fs:SetPoint("LEFT", parent, "LEFT", xOfs, 0)
        fs:SetText("|cffaaffaa" .. label .. "|r")
        fs:SetJustifyH("LEFT")
        return fs
    end

    local hx = GB_COL_DEL + 6
    MakeHeader(hdrFrame, "Planter",   GB_COL_NAME,  hx)
    hx = hx + GB_COL_NAME + 4
    MakeHeader(hdrFrame, "Phase",     GB_COL_PHASE, hx)
    hx = hx + GB_COL_PHASE + 4
    local hTimeFs = MakeHeader(hdrFrame, "Remaining", GB_COL_TIME, hx)
    hTimeFs:SetJustifyH("CENTER")
    hx = hx + GB_COL_TIME + 4
    local hLeftFs = MakeHeader(hdrFrame, "Left", GB_COL_LEFT, hx)
    hLeftFs:SetJustifyH("CENTER")

    f.hdrFrame = hdrFrame

    -- ===== Content / Row Area =====
    local contentY = hdrY - 18 - 4
    local contentH = GB_MAX_VISIBLE_ROWS * GB_ROW_H

    local content = CreateFrame("Frame", nil, f)
    content:SetHeight(contentH)
    content:SetPoint("TOPLEFT",  f, "TOPLEFT",  GB_PAD,  contentY)
    content:SetPoint("TOPRIGHT", f, "TOPRIGHT", -GB_PAD, contentY)
    f.content = content

    -- "No planters" placeholder
    local noPs = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    noPs:SetPoint("CENTER", content, "CENTER", 0, 0)
    noPs:SetText("|cff668866No active planters.\n" ..
                 "Use |r|cffddffdd/gb add|r|cff668866 or click |r|cffddffdd'Add Planter'|r|cff668866 below.|r")
    noPs:Hide()
    f.noPlText = noPs

    -- Scroll Up / Down arrows (shown when > GB_MAX_VISIBLE_ROWS planters)
    local upArrow = CreateFrame("Button", nil, f)
    upArrow:SetWidth(14) upArrow:SetHeight(14)
    upArrow:SetPoint("TOPRIGHT", content, "TOPRIGHT", 16, 0)
    upArrow:SetNormalTexture("Interface\\Buttons\\Arrow-Up-Up")
    upArrow:SetPushedTexture("Interface\\Buttons\\Arrow-Up-Down")
    upArrow:SetScript("OnClick", function()
        if GB.scrollOfs > 0 then
            GB.scrollOfs = GB.scrollOfs - 1
            GB_RefreshDisplay()
        end
    end)

    local downArrow = CreateFrame("Button", nil, f)
    downArrow:SetWidth(14) downArrow:SetHeight(14)
    downArrow:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 16, 0)
    downArrow:SetNormalTexture("Interface\\Buttons\\Arrow-Down-Up")
    downArrow:SetPushedTexture("Interface\\Buttons\\Arrow-Down-Down")
    downArrow:SetScript("OnClick", function()
        local total = table.getn(GardenBuddyDB.planters)
        if GB.scrollOfs + GB_MAX_VISIBLE_ROWS < total then
            GB.scrollOfs = GB.scrollOfs + 1
            GB_RefreshDisplay()
        end
    end)

    f.upArrow   = upArrow
    f.downArrow = downArrow

    -- Create row frames
    for i = 1, GB_MAX_VISIBLE_ROWS do
        GB.rows[i] = GB_CreateRow(content, i)
    end

    -- ===== Separator line =====
    local sepY = contentY - contentH - 4
    local sep = f:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(2)
    sep:SetPoint("TOPLEFT",  f, "TOPLEFT",  GB_PAD + 4, sepY)
    sep:SetPoint("TOPRIGHT", f, "TOPRIGHT", -GB_PAD - 4, sepY)
    sep:SetTexture(0.15, 0.45, 0.15, 0.8)

    -- ===== Bottom Controls Row 1 — Add button + Sound button =====
    local ctrl1Y = -(fh - GB_PAD - 26 - 22 - 4)

    local addBtn = CreateFrame("Button", "GardenBuddyAddBtn", f, "GameMenuButtonTemplate")
    addBtn:SetWidth(105)
    addBtn:SetHeight(22)
    addBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", GB_PAD, GB_PAD + 26)
    addBtn:SetText("|cff55ff55+ Add Planter|r")
    addBtn:SetScript("OnClick", function() GB_ShowAddDialog() end)

    local soundBtn = CreateFrame("Button", "GardenBuddySoundBtn", f, "GameMenuButtonTemplate")
    soundBtn:SetWidth(120)
    soundBtn:SetHeight(22)
    soundBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -GB_PAD, GB_PAD + 26)
    soundBtn:SetScript("OnClick", function() GB_CycleSound() end)
    soundBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_TOP")
        GameTooltip:SetText("Click to cycle sound options.\nA preview will play for each.", 1,1,1)
        GameTooltip:Show()
    end)
    soundBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.soundBtn = soundBtn

    -- ===== Bottom Controls Row 2 — Duration + status hint =====
    local durBtn = CreateFrame("Button", "GardenBuddyDurBtn", f, "GameMenuButtonTemplate")
    durBtn:SetWidth(150)
    durBtn:SetHeight(22)
    durBtn:SetPoint("BOTTOM", f, "BOTTOM", 0, GB_PAD + 2)
    durBtn:SetScript("OnClick", function() GB_CycleDuration() end)
    durBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_TOP")
        GameTooltip:SetText("Click to cycle phase duration.\nMust match your server's gardening timer!", 1,1,1)
        GameTooltip:Show()
    end)
    durBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.durBtn = durBtn

    -- ===== OnUpdate — refresh once per second =====
    f:SetScript("OnUpdate", function()
        GB.updateTimer = GB.updateTimer + arg1
        if GB.updateTimer >= 1.0 then
            GB.updateTimer = 0
            GB_CheckAlerts()
            GB_RefreshDisplay()
        end
    end)

    GB_UpdateBottomButtons()

    return f
end

-------------------------------------------------------------------------------
-- UPDATE BOTTOM BUTTONS TEXT
-------------------------------------------------------------------------------

function GB_UpdateBottomButtons()
    local f = GardenBuddyMainFrame
    if not f then return end
    local db = GardenBuddyDB

    -- Sound button
    local sndData = GB_SOUNDS[db.soundIndex]
    local sndName = sndData and sndData.label or "None"
    if db.soundEnabled and sndData and sndData.id then
        f.soundBtn:SetText("|cff55ff55Snd: " .. sndName .. "|r")
    else
        f.soundBtn:SetText("|cffff5555Sound: Off|r")
    end

    -- Duration button
    local mins = math.floor(db.phaseDuration / 60)
    f.durBtn:SetText("|cffaaffaaPhase Duration: " .. mins .. " min|r")
end

-------------------------------------------------------------------------------
-- SOUND CYCLING
-------------------------------------------------------------------------------

function GB_CycleSound()
    local db = GardenBuddyDB
    db.soundIndex = math.mod(db.soundIndex, table.getn(GB_SOUNDS)) + 1
    local sndData = GB_SOUNDS[db.soundIndex]
    if sndData and sndData.id then
        db.soundEnabled = true
        PlaySound(sndData.id)   -- preview
    else
        db.soundEnabled = false
    end
    GB_UpdateBottomButtons()
end

-------------------------------------------------------------------------------
-- DURATION CYCLING
-------------------------------------------------------------------------------

function GB_CycleDuration()
    local db = GardenBuddyDB
    local cur = db.phaseDuration
    local next = GB_PHASE_DURATIONS[1]
    for i, dur in ipairs(GB_PHASE_DURATIONS) do
        if dur == cur then
            next = GB_PHASE_DURATIONS[math.mod(i, table.getn(GB_PHASE_DURATIONS)) + 1]
            break
        end
    end
    db.phaseDuration = next
    GB_UpdateBottomButtons()
    DEFAULT_CHAT_FRAME:AddMessage(
        "|cff55ff55[GardenBuddy]|r Phase duration set to |cffddffdd" ..
        math.floor(next / 60) .. " minutes|r per phase.")
end

-------------------------------------------------------------------------------
-- MINIMIZE / RESTORE
-------------------------------------------------------------------------------

function GB_ToggleMinimize()
    local db = GardenBuddyDB
    local f  = GardenBuddyMainFrame
    if not f then return end

    db.minimized = not db.minimized

    if db.minimized then
        f.hdrFrame:Hide()
        f.content:Hide()
        f.noPlText:Hide()
        f.upArrow:Hide()
        f.downArrow:Hide()
        GardenBuddyAddBtn:Hide()
        GardenBuddySoundBtn:Hide()
        GardenBuddyDurBtn:Hide()
        f:SetHeight(GB_PAD + 24 + GB_PAD)
    else
        f.hdrFrame:Show()
        f.content:Show()
        f.upArrow:Show()
        f.downArrow:Show()
        GardenBuddyAddBtn:Show()
        GardenBuddySoundBtn:Show()
        GardenBuddyDurBtn:Show()
        f:SetHeight(GB_CalcFrameHeight())
        GB_RefreshDisplay()
    end
end

-------------------------------------------------------------------------------
-- DISPLAY REFRESH
-------------------------------------------------------------------------------

function GB_RefreshDisplay()
    local f = GardenBuddyMainFrame
    if not f or not f:IsShown() then return end

    local db      = GardenBuddyDB
    local planters = db.planters
    local total   = table.getn(planters)

    -- Placeholder text
    if total == 0 then
        f.noPlText:Show()
    else
        f.noPlText:Hide()
    end

    -- Scroll arrows
    if total > GB_MAX_VISIBLE_ROWS then
        f.upArrow:Show()
        f.downArrow:Show()
    else
        f.upArrow:Hide()
        f.downArrow:Hide()
        GB.scrollOfs = 0
    end

    -- Populate rows
    for i = 1, GB_MAX_VISIBLE_ROWS do
        local row = GB.rows[i]
        local pIdx = i + GB.scrollOfs
        local p    = planters[pIdx]

        if p then
            row:Show()
            row.planterIdx = pIdx

            local phase, timeRem, phasesLeft = GB_GetStatus(p)
            local isReady = (phasesLeft == 0 and timeRem <= 0)
            local isWarn  = (not isReady and timeRem < 300)   -- < 5 min warning

            -- Name
            row.nameFs:SetText("|cffddffdd" .. p.name .. "|r")

            -- Phase name
            local phaseName = GB_PHASE_NAMES[phase] or ("Phase " .. phase)
            if isReady then
                row.phaseFs:SetText("|cff00ff44" .. phaseName .. "|r")
            elseif isWarn then
                row.phaseFs:SetText("|cffffaa00" .. phaseName .. "|r")
            else
                row.phaseFs:SetText("|cffaaddaa" .. phaseName .. "|r")
            end

            -- Time remaining
            if isReady then
                row.timeFs:SetText("|cff00ff44HARVEST!|r")
            else
                local ts = GB_FormatTime(timeRem)
                if isWarn then
                    row.timeFs:SetText("|cffffaa00" .. ts .. "|r")
                else
                    row.timeFs:SetText("|cffffffff" .. ts .. "|r")
                end
            end

            -- Phases left
            if isReady then
                row.leftFs:SetText("|cff00ff44Done!|r")
            else
                local leftStr = phasesLeft .. " / " .. (GB_TOTAL_PHASES - 1)
                if phasesLeft <= 1 then
                    row.leftFs:SetText("|cffffaa00" .. leftStr .. "|r")
                else
                    row.leftFs:SetText("|cffaaffaa" .. leftStr .. "|r")
                end
            end

        else
            row:Hide()
            row.planterIdx = nil
        end
    end

    GB_UpdateBottomButtons()
end

-------------------------------------------------------------------------------
-- ADD PLANTER DIALOG
-------------------------------------------------------------------------------

local function GB_CreateAddDialog()
    local d = CreateFrame("Frame", "GardenBuddyAddDialog", UIParent)
    d:SetWidth(250)
    d:SetHeight(110)
    d:SetPoint("CENTER", UIParent, "CENTER")
    d:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 32,
        insets   = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    d:SetBackdropColor(0.04, 0.12, 0.04, 0.98)
    d:SetFrameStrata("DIALOG")
    d:EnableMouse(true)
    d:SetMovable(true)
    d:RegisterForDrag("LeftButton")
    d:SetScript("OnDragStart", function() this:StartMoving() end)
    d:SetScript("OnDragStop",  function() this:StopMovingOrSizing() end)

    local titleFs = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleFs:SetPoint("TOP", d, "TOP", 0, -16)
    titleFs:SetText("|cff55ff55Add Garden Planter|r")

    local labelFs = d:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    labelFs:SetPoint("TOPLEFT", d, "TOPLEFT", 16, -38)
    labelFs:SetText("|cffddffddPlanter Name:|r")

    local editBox = CreateFrame("EditBox", "GardenBuddyDialogEdit", d, "InputBoxTemplate")
    editBox:SetWidth(200)
    editBox:SetHeight(20)
    editBox:SetPoint("TOPLEFT", d, "TOPLEFT", 16, -54)
    editBox:SetMaxLetters(40)
    editBox:SetAutoFocus(true)
    editBox:SetScript("OnEnterPressed", function()
        GB_AddPlanter(this:GetText())
        GardenBuddyAddDialog:Hide()
    end)
    editBox:SetScript("OnEscapePressed", function()
        GardenBuddyAddDialog:Hide()
    end)

    local okBtn = CreateFrame("Button", nil, d, "GameMenuButtonTemplate")
    okBtn:SetWidth(80) okBtn:SetHeight(22)
    okBtn:SetPoint("BOTTOMLEFT", d, "BOTTOMLEFT", 16, 12)
    okBtn:SetText("|cff55ff55Plant!|r")
    okBtn:SetScript("OnClick", function()
        GB_AddPlanter(GardenBuddyDialogEdit:GetText())
        GardenBuddyAddDialog:Hide()
    end)

    local cancelBtn = CreateFrame("Button", nil, d, "GameMenuButtonTemplate")
    cancelBtn:SetWidth(80) cancelBtn:SetHeight(22)
    cancelBtn:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", -16, 12)
    cancelBtn:SetText("Cancel")
    cancelBtn:SetScript("OnClick", function()
        GardenBuddyAddDialog:Hide()
    end)

    d:Hide()
end

function GB_ShowAddDialog()
    if not GardenBuddyAddDialog then
        GB_CreateAddDialog()
    end
    local suggestName = "Planter " .. (table.getn(GardenBuddyDB.planters) + 1)
    GardenBuddyDialogEdit:SetText(suggestName)
    GardenBuddyDialogEdit:HighlightText()
    GardenBuddyDialogEdit:SetFocus()
    GardenBuddyAddDialog:Show()
end

-------------------------------------------------------------------------------
-- AUTO DETECT PLANTING FROM CHAT
-------------------------------------------------------------------------------

local function GB_CheckChatForPlanting(msg)
    if not msg then return false end
    local lower = strlower(msg)
    for _, kw in ipairs(GB_PLANT_KEYWORDS) do
        if strfind(lower, kw, 1, true) then
            return true
        end
    end
    return false
end

-------------------------------------------------------------------------------
-- EVENT HANDLING
-------------------------------------------------------------------------------

local evFrame = CreateFrame("Frame", "GardenBuddyEventFrame")
evFrame:RegisterEvent("ADDON_LOADED")
evFrame:RegisterEvent("PLAYER_LOGOUT")
evFrame:RegisterEvent("CHAT_MSG_SYSTEM")
evFrame:RegisterEvent("CHAT_MSG_SPELL_SELF_BUFF")

evFrame:SetScript("OnEvent", function()
    -- ---- Addon loaded ----
    if event == "ADDON_LOADED" and arg1 == "GardenBuddy" then
        -- Init / merge saved variables
        if not GardenBuddyDB then
            GardenBuddyDB = GB_GetDefaults()
        else
            local def = GB_GetDefaults()
            for k, v in pairs(def) do
                if GardenBuddyDB[k] == nil then
                    GardenBuddyDB[k] = v
                end
            end
        end

        -- Build UI
        GardenBuddyMainFrame = GB_CreateMainFrame()

        if GardenBuddyDB.visible then
            GardenBuddyMainFrame:Show()
        else
            GardenBuddyMainFrame:Hide()
        end

        if GardenBuddyDB.minimized then
            -- Silently apply minimized state
            GardenBuddyDB.minimized = false  -- flip so toggle works
            GB_ToggleMinimize()
        end

        GB_RefreshDisplay()

        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff55ff55[GardenBuddy]|r v" .. GARDENBUDDY_VERSION ..
            " loaded. Type |cffddffdd/gb help|r for commands.")

        GB.initialized = true

    -- ---- Save position on logout ----
    elseif event == "PLAYER_LOGOUT" then
        if GardenBuddyMainFrame then
            local _, _, _, x, y = GardenBuddyMainFrame:GetPoint()
            GardenBuddyDB.posX = x
            GardenBuddyDB.posY = y
        end

    -- ---- Auto detect planting ----
    elseif event == "CHAT_MSG_SYSTEM" or event == "CHAT_MSG_SPELL_SELF_BUFF" then
        if GB.initialized and GB_CheckChatForPlanting(arg1) then
            local newName = "Planter " .. (table.getn(GardenBuddyDB.planters) + 1)
            GB_AddPlanter(newName)
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff55ff55[GardenBuddy]|r Auto-detected planting action!")
        end
    end
end)

-------------------------------------------------------------------------------
-- SLASH COMMANDS
-------------------------------------------------------------------------------

SLASH_GARDENBUDDY1 = "/gb"
SLASH_GARDENBUDDY2 = "/gardenbuddy"
SLASH_GARDENBUDDY3 = "/garden"

SlashCmdList["GARDENBUDDY"] = function(msg)
    if not msg then msg = "" end
    msg = strtrim(msg)

    -- Split into cmd + rest
    local spacePos = strfind(msg, " ")
    local cmd, rest
    if spacePos then
        cmd  = strlower(strsub(msg, 1, spacePos - 1))
        rest = strtrim(strsub(msg, spacePos + 1))
    else
        cmd  = strlower(msg)
        rest = ""
    end

    if cmd == "add" then
        if strlen(rest) > 0 then
            GB_AddPlanter(rest)
        else
            GB_ShowAddDialog()
        end

    elseif cmd == "remove" or cmd == "rem" or cmd == "del" then
        local idx = tonumber(rest)
        if idx then
            GB_RemovePlanter(idx)
        else
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff55ff55[GardenBuddy]|r Usage: |cffddffdd/gb remove <number>|r")
        end

    elseif cmd == "clear" then
        GardenBuddyDB.planters = {}
        GB.scrollOfs = 0
        GB_RefreshDisplay()
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff55ff55[GardenBuddy]|r All planters cleared.")

    elseif cmd == "show" then
        GardenBuddyDB.visible = true
        GardenBuddyMainFrame:Show()
        GB_RefreshDisplay()

    elseif cmd == "hide" then
        GardenBuddyDB.visible = false
        GardenBuddyMainFrame:Hide()

    elseif cmd == "toggle" then
        if GardenBuddyMainFrame:IsShown() then
            GardenBuddyDB.visible = false
            GardenBuddyMainFrame:Hide()
        else
            GardenBuddyDB.visible = true
            GardenBuddyMainFrame:Show()
            GB_RefreshDisplay()
        end

    elseif cmd == "sound" then
        GB_CycleSound()

    elseif cmd == "list" then
        local ps = GardenBuddyDB.planters
        if table.getn(ps) == 0 then
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff55ff55[GardenBuddy]|r No active planters.")
        else
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff55ff55[GardenBuddy]|r Active planters:")
            for i, p in ipairs(ps) do
                local ph, tr, pl = GB_GetStatus(p)
                local pname = GB_PHASE_NAMES[ph] or ("Phase " .. ph)
                DEFAULT_CHAT_FRAME:AddMessage(string.format(
                    "  |cffddffdd#%d|r %s  |cffaaffaa%s|r  %s remaining  |cffaaffaa%d phases left|r",
                    i, p.name, pname, GB_FormatTime(tr), pl))
            end
        end

    elseif cmd == "duration" or cmd == "dur" then
        local mins = tonumber(rest)
        if mins and mins > 0 then
            GardenBuddyDB.phaseDuration = mins * 60
            GB_UpdateBottomButtons()
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff55ff55[GardenBuddy]|r Phase duration set to |cffddffdd" .. mins .. " min|r.")
        else
            GB_CycleDuration()
        end

    elseif cmd == "reset" then
        local oldPlanters = GardenBuddyDB.planters
        GardenBuddyDB = GB_GetDefaults()
        GardenBuddyDB.planters = oldPlanters   -- keep planters, reset settings only
        GB_UpdateBottomButtons()
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff55ff55[GardenBuddy]|r Settings reset to defaults (planters kept).")

    elseif cmd == "resetall" then
        GardenBuddyDB = GB_GetDefaults()
        GB.scrollOfs = 0
        GB_RefreshDisplay()
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff55ff55[GardenBuddy]|r Full reset — all planters and settings cleared.")

    else
        -- Help
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff55ff55====[ Garden Buddy v" .. GARDENBUDDY_VERSION .. " ]====|r")
        DEFAULT_CHAT_FRAME:AddMessage(
            "  |cffddffdd/gb add [name]|r     - Track a new planter (opens dialog if no name)")
        DEFAULT_CHAT_FRAME:AddMessage(
            "  |cffddffdd/gb remove <#>|r     - Remove planter by list number")
        DEFAULT_CHAT_FRAME:AddMessage(
            "  |cffddffdd/gb clear|r          - Remove all planters")
        DEFAULT_CHAT_FRAME:AddMessage(
            "  |cffddffdd/gb list|r           - Print all planters to chat")
        DEFAULT_CHAT_FRAME:AddMessage(
            "  |cffddffdd/gb show|r / |cffddffdd/gb hide|r  - Show or hide the window")
        DEFAULT_CHAT_FRAME:AddMessage(
            "  |cffddffdd/gb toggle|r         - Toggle window visibility")
        DEFAULT_CHAT_FRAME:AddMessage(
            "  |cffddffdd/gb sound|r          - Cycle through sound options")
        DEFAULT_CHAT_FRAME:AddMessage(
            "  |cffddffdd/gb duration [m]|r   - Set phase duration in minutes")
        DEFAULT_CHAT_FRAME:AddMessage(
            "  |cffddffdd/gb reset|r          - Reset settings (keeps planters)")
        DEFAULT_CHAT_FRAME:AddMessage(
            "  |cffddffdd/gb resetall|r       - Full reset (clears everything)")
    end
end
