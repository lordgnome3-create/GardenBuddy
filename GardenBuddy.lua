-------------------------------------------------------------------------------
-- GardenBuddy.lua  v1.8
-- Turtle WoW Garden Planter Tracker
-- FishingBuddy-style window - Minimap herb icon - Phase chime alerts
--
-- Lua 5.0 (WoW 1.12) compatibility notes:
--   - string.match does not exist; use string.find with captures instead
--   - strtrim does not exist; use local GB_Trim() instead
--   - UNIT_SPELLCAST_SUCCEEDED does not exist
--   - SPELLCAST_START / SPELLCAST_STOP DO exist and are used for detection
-------------------------------------------------------------------------------

GARDENBUDDY_VERSION = "1.8"

local GB_PHASE_NAMES = {
    [1] = "Seedling",
    [2] = "Sprouting",
    [3] = "Growing",
    [4] = "Maturing",
    [5] = "Harvest Ready",
}
local GB_TOTAL_PHASES = 5
local GB_PHASE_DUR    = 540   -- 9 minutes per phase, fixed for Turtle WoW

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
-- SOUNDS  (PlaySoundFile with real .wav paths - works in all 1.12 builds)
-------------------------------------------------------------------------------
local GB_SOUNDS = {
    { label = "Bell",       file = "Sound\\Interface\\UI_BellTollAlliance.wav" },
    { label = "Level Up",   file = "Sound\\Interface\\LevelUp.wav"             },
    { label = "Quest Done", file = "Sound\\Interface\\iQuestComplete.wav"      },
    { label = "Loot",       file = "Sound\\Interface\\iPickUpItem.wav"         },
    { label = "Whisper",    file = "Sound\\Interface\\iTellMessage.wav"        },
    { label = "None",       file = nil                                         },
}

-------------------------------------------------------------------------------
-- PLANTING DETECTION
-- SPELLCAST_START fires with arg1 = spell name when the player begins a cast.
-- SPELLCAST_STOP  fires when the cast finishes (whether successful or not).
-- We save the spell name on START and fire the add on STOP if it matched.
-- This gives a precise timer start right at the moment the seed goes in.
-------------------------------------------------------------------------------

-- Lowercase fragments matched against the spell name on SPELLCAST_START.
local GB_PLANT_SPELL_WORDS = {
    "plant",
    "seed",
    "sow",
    "garden",
    "planter",
    "cultivat",
}

-- Cooldown (seconds) to prevent a double-add if the event fires twice.
local GB_DETECT_COOLDOWN = 3

-- Runtime state
local GB = {}
GB.rows          = {}
GB.scrollOfs     = 0
GB.updateTimer   = 0
GB.initialized   = false
GB.lastPlantTime = 0      -- timestamp of last auto-add
GB.pendingSpell  = nil    -- spell name saved from SPELLCAST_START

-------------------------------------------------------------------------------
-- SAVED-VARIABLE DEFAULTS
-------------------------------------------------------------------------------

local function GB_GetDefaults()
    return {
        soundEnabled = true,
        soundIndex   = 1,
        planters     = {},
        nextId       = 1,
        posX         = 200,
        posY         = -200,
        minimized    = false,
        minimapAngle = 195,
    }
end

-------------------------------------------------------------------------------
-- UTILITIES
-------------------------------------------------------------------------------

-- Lua 5.0 safe trim (strtrim does not exist in 1.12)
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

local function GB_GetStatus(planter)
    local elapsed = GetTime() - planter.plantedAt
    local totalT  = GB_TOTAL_PHASES * GB_PHASE_DUR
    if elapsed >= totalT then return GB_TOTAL_PHASES, 0, 0 end
    local phase = math.floor(elapsed / GB_PHASE_DUR) + 1
    if phase > GB_TOTAL_PHASES then phase = GB_TOTAL_PHASES end
    local phaseRem = GB_PHASE_DUR - (elapsed - ((phase - 1) * GB_PHASE_DUR))
    local left     = GB_TOTAL_PHASES - phase
    return phase, phaseRem, left
end

local function GB_DetectPhaseAdvance(planter)
    local phase = GB_GetStatus(planter)
    if planter.lastKnownPhase == nil then
        planter.lastKnownPhase = phase
        return false
    end
    if phase > planter.lastKnownPhase then
        planter.lastKnownPhase = phase
        return true
    end
    return false
end

-------------------------------------------------------------------------------
-- SOUND
-------------------------------------------------------------------------------

local function GB_PlayChime()
    if not GardenBuddyDB.soundEnabled then return end
    local s = GB_SOUNDS[GardenBuddyDB.soundIndex]
    if s and s.file then PlaySoundFile(s.file) end
end

local function GB_CheckAlerts()
    if not GardenBuddyDB or not GardenBuddyDB.planters then return end
    for _, planter in ipairs(GardenBuddyDB.planters) do
        if GB_DetectPhaseAdvance(planter) then
            GB_PlayChime()
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff55ff55[GardenBuddy]|r |cffddffdd" .. planter.name ..
                "|r advanced to: |cff55ff55" ..
                (GB_PHASE_NAMES[planter.lastKnownPhase] or
                 "Phase " .. planter.lastKnownPhase) .. "|r")
        end
    end
end

-------------------------------------------------------------------------------
-- PLANTER MANAGEMENT
-------------------------------------------------------------------------------

function GB_AddPlanter(name)
    local db = GardenBuddyDB
    if not name or strlen(name) == 0 then name = "Planter " .. db.nextId end
    if table.getn(db.planters) >= GB_MAX_PLANTERS then
        DEFAULT_CHAT_FRAME:AddMessage("|cff55ff55[GardenBuddy]|r Max planters reached.")
        return
    end
    local p = {
        name           = name,
        plantedAt      = GetTime(),
        id             = db.nextId,
        lastKnownPhase = 1,
    }
    db.nextId = db.nextId + 1
    table.insert(db.planters, p)
    DEFAULT_CHAT_FRAME:AddMessage(
        "|cff55ff55[GardenBuddy]|r Now tracking: |cffddffdd" .. name .. "|r")
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

-------------------------------------------------------------------------------
-- PLANTING DETECTION HELPERS
-------------------------------------------------------------------------------

-- Returns true if spellName contains any planting keyword.
local function GB_IsPlantingSpell(spellName)
    if not spellName then return false end
    local lower = strlower(spellName)
    for _, word in ipairs(GB_PLANT_SPELL_WORDS) do
        if strfind(lower, word, 1, true) then
            return true
        end
    end
    return false
end

-- Strip common cast-verb prefixes to produce a clean seed label.
-- "Plant Stranglekelp Seed" -> "Stranglekelp Seed"
local function GB_SeedNameFromSpell(spellName)
    if not spellName then return nil end
    local prefixes = { "plant ", "sow ", "cultivate ", "use ", "place " }
    local lower = strlower(spellName)
    for _, prefix in ipairs(prefixes) do
        if strfind(lower, prefix, 1, true) == 1 then
            local stripped = strsub(spellName, strlen(prefix) + 1)
            if strlen(stripped) > 0 then return stripped end
        end
    end
    return spellName
end

-- Called from SPELLCAST_STOP when a planting spell just completed.
local function GB_OnSpellPlantingComplete(spellName)
    local now = GetTime()
    if (now - GB.lastPlantTime) < GB_DETECT_COOLDOWN then return end
    GB.lastPlantTime = now

    local seedName = GB_SeedNameFromSpell(spellName)
    if not seedName or strlen(seedName) == 0 then
        seedName = "Planter " .. (table.getn(GardenBuddyDB.planters) + 1)
    end
    GB_AddPlanter(seedName)
    DEFAULT_CHAT_FRAME:AddMessage(
        "|cff55ff55[GardenBuddy]|r Auto-detected planting! " ..
        "Use |cffddffdd/gb rename <#> <n>|r to rename if needed.")
end

-------------------------------------------------------------------------------
-- ROW CREATION
-------------------------------------------------------------------------------

local function GB_CreateRow(parent, rowIdx)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(GB_ROW_H)
    row:SetPoint("TOPLEFT",  parent, "TOPLEFT",  0, -((rowIdx - 1) * GB_ROW_H))
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -((rowIdx - 1) * GB_ROW_H))

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(row)
    if math.mod(rowIdx, 2) == 0 then
        bg:SetTexture(0, 0, 0, 0.22)
    else
        bg:SetTexture(0.06, 0.16, 0.06, 0.22)
    end

    -- Delete widget as plain Frame (avoids Button-only API issues in 1.12)
    local del = CreateFrame("Frame", nil, row)
    del:SetWidth(GB_COL_DEL)
    del:SetHeight(GB_ROW_H - 2)
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
        GameTooltip:SetText("Remove planter", 1, 1, 1)
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
-- MAIN FRAME
-------------------------------------------------------------------------------

local function GB_CalcFrameHeight()
    return GB_PAD + 24 + 6 + 18 + 4 + (GB_MAX_VISIBLE_ROWS * GB_ROW_H) + 6 + 24 + GB_PAD
end

local function GB_CreateMainFrame()
    local fh = GB_CalcFrameHeight()
    local f  = CreateFrame("Frame", "GardenBuddyMainFrame", UIParent)
    f:SetWidth(GB_FRAME_W)
    f:SetHeight(fh)
    f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", GardenBuddyDB.posX, GardenBuddyDB.posY)
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

    -- Title bar
    local titleBar = CreateFrame("Frame", nil, f)
    titleBar:SetHeight(24)
    titleBar:SetPoint("TOPLEFT",  f, "TOPLEFT",  GB_PAD,         -GB_PAD)
    titleBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -(GB_PAD + 38), -GB_PAD)
    local titleBg = titleBar:CreateTexture(nil, "BACKGROUND")
    titleBg:SetAllPoints(titleBar)
    titleBg:SetTexture(0.05, 0.28, 0.05, 0.88)
    local titleFs = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleFs:SetPoint("CENTER", titleBar, "CENTER", 0, 0)
    titleFs:SetText("|cff33dd33* |r|cffddffddGarden Buddy|r|cff33dd33 *|r")
    local verFs = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    verFs:SetPoint("RIGHT", titleBar, "RIGHT", -6, 0)
    verFs:SetText("|cff668866v" .. GARDENBUDDY_VERSION .. "|r")

    -- Close button
    local closeBtn = CreateFrame("Button", "GardenBuddyCloseBtn", f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() GardenBuddyMainFrame:Hide() end)

    -- Minimize button
    local minBtn = CreateFrame("Button", "GardenBuddyMinBtn", f)
    minBtn:SetWidth(16) ; minBtn:SetHeight(16)
    minBtn:SetPoint("TOPRIGHT", closeBtn, "TOPLEFT", -2, 0)
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

    -- Column headers
    local hdrY     = -(GB_PAD + 24 + 6)
    local hdrFrame = CreateFrame("Frame", nil, f)
    hdrFrame:SetHeight(18)
    hdrFrame:SetPoint("TOPLEFT",  f, "TOPLEFT",  GB_PAD,  hdrY)
    hdrFrame:SetPoint("TOPRIGHT", f, "TOPRIGHT", -GB_PAD, hdrY)
    local hdrBg = hdrFrame:CreateTexture(nil, "BACKGROUND")
    hdrBg:SetAllPoints(hdrFrame)
    hdrBg:SetTexture(0.08, 0.26, 0.08, 0.82)

    local function MakeHdr(lbl, width, xOfs, justify)
        local fs = hdrFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetWidth(width)
        fs:SetPoint("LEFT", hdrFrame, "LEFT", xOfs, 0)
        fs:SetText("|cffaaffaa" .. lbl .. "|r")
        fs:SetJustifyH(justify or "LEFT")
    end
    local hx = GB_COL_DEL + 6
    MakeHdr("Planter",   GB_COL_NAME,  hx)           ; hx = hx + GB_COL_NAME  + 4
    MakeHdr("Phase",     GB_COL_PHASE, hx)           ; hx = hx + GB_COL_PHASE + 4
    MakeHdr("Remaining", GB_COL_TIME,  hx, "CENTER") ; hx = hx + GB_COL_TIME  + 4
    MakeHdr("Left",      GB_COL_LEFT,  hx, "CENTER")
    f.hdrFrame = hdrFrame

    -- Row content area
    local contentY = hdrY - 18 - 4
    local contentH = GB_MAX_VISIBLE_ROWS * GB_ROW_H
    local content  = CreateFrame("Frame", nil, f)
    content:SetHeight(contentH)
    content:SetPoint("TOPLEFT",  f, "TOPLEFT",  GB_PAD,  contentY)
    content:SetPoint("TOPRIGHT", f, "TOPRIGHT", -GB_PAD, contentY)
    f.content = content

    local noPlFs = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    noPlFs:SetPoint("CENTER", content, "CENTER", 0, 0)
    noPlFs:SetText("|cff668866No active planters.\nClick the minimap icon or type |r|cffddffdd/gb add|r")
    noPlFs:Hide()
    f.noPlText = noPlFs

    -- Scroll arrows
    local upArrow = CreateFrame("Button", nil, f)
    upArrow:SetWidth(14) ; upArrow:SetHeight(14)
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
    downArrow:SetWidth(14) ; downArrow:SetHeight(14)
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

    for i = 1, GB_MAX_VISIBLE_ROWS do
        GB.rows[i] = GB_CreateRow(content, i)
    end

    -- Separator
    local sepY = contentY - contentH - 3
    local sep  = f:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(2)
    sep:SetPoint("TOPLEFT",  f, "TOPLEFT",  GB_PAD + 4,  sepY)
    sep:SetPoint("TOPRIGHT", f, "TOPRIGHT", -GB_PAD - 4, sepY)
    sep:SetTexture(0.15, 0.45, 0.15, 0.8)

    -- Bottom buttons
    local addBtn = CreateFrame("Button", "GardenBuddyAddBtn", f, "GameMenuButtonTemplate")
    addBtn:SetWidth(110) ; addBtn:SetHeight(22)
    addBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", GB_PAD, GB_PAD + 2)
    addBtn:SetText("|cff55ff55+ Add Planter|r")
    addBtn:SetScript("OnClick", function() GB_ShowAddDialog() end)

    local soundBtn = CreateFrame("Button", "GardenBuddySoundBtn", f, "GameMenuButtonTemplate")
    soundBtn:SetWidth(125) ; soundBtn:SetHeight(22)
    soundBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -GB_PAD, GB_PAD + 2)
    soundBtn:SetScript("OnClick", function() GB_CycleSound() end)
    soundBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_TOP")
        GameTooltip:SetText("Click to cycle alert sound.\nPlays a preview each time.", 1, 1, 1)
        GameTooltip:Show()
    end)
    soundBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.soundBtn = soundBtn

    -- OnUpdate throttled to ~1 second
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

    GB_UpdateBottomButtons()
    return f
end

-------------------------------------------------------------------------------
-- MINIMAP BUTTON
-------------------------------------------------------------------------------

local function GB_UpdateMinimapPos()
    local btn = GardenBuddyMinimapBtn
    if not btn then return end
    local angle = math.rad(GardenBuddyDB.minimapAngle or 195)
    btn:SetPoint("CENTER", Minimap, "CENTER",
        math.cos(angle) * GB_MINIMAP_RADIUS,
        math.sin(angle) * GB_MINIMAP_RADIUS)
end

local function GB_CreateMinimapButton()
    local btn = CreateFrame("Button", "GardenBuddyMinimapBtn", Minimap)
    btn:SetWidth(31)
    btn:SetHeight(31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:SetClampedToScreen(true)

    -- Herb icon: swap texture name to change herb
    --   Firebloom:   INV_Misc_Herb_Firebloom
    --   Plaguebloom: INV_Misc_Herb_PlagueFlower
    --   Icecap:      INV_Misc_Herb_Icecap
    btn:SetNormalTexture("Interface\\Icons\\INV_Misc_Herb_Firebloom")
    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    btn:SetPushedTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetWidth(54)
    border:SetHeight(54)
    border:SetPoint("TOPLEFT", btn, "TOPLEFT", -11.5, 11.5)

    local isDragging = false

    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    btn:SetScript("OnMouseDown", function()
        if arg1 == "LeftButton" then isDragging = false end
    end)

    btn:SetScript("OnUpdate", function()
        if not IsMouseButtonDown("LeftButton") then return end
        local mx, my = Minimap:GetCenter()
        local cx, cy = GetCursorPosition()
        local s      = UIParent:GetScale()
        cx = cx / s ; cy = cy / s
        local newAngle = math.deg(math.atan2(cy - my, cx - mx))
        if not isDragging then
            local diff = math.abs(newAngle - (GardenBuddyDB.minimapAngle or 195))
            if diff > 180 then diff = 360 - diff end
            if diff > 5 then isDragging = true end
        end
        if isDragging then
            GardenBuddyDB.minimapAngle = newAngle
            GB_UpdateMinimapPos()
        end
    end)

    btn:SetScript("OnClick", function()
        if isDragging then isDragging = false ; return end
        if arg1 == "RightButton" then
            GB_ShowAddDialog()
        else
            if GardenBuddyMainFrame:IsShown() then
                GardenBuddyMainFrame:Hide()
            else
                GardenBuddyMainFrame:Show()
                GB_RefreshDisplay()
            end
        end
    end)

    btn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:AddLine("|cff55ff55Garden Buddy|r", 1, 1, 1)
        GameTooltip:AddLine("Left-click:  Toggle window", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Right-click: Add planter",  0.8, 0.8, 0.8)
        GameTooltip:AddLine("Drag:        Move icon",    0.8, 0.8, 0.8)
        local n = table.getn(GardenBuddyDB.planters)
        if n > 0 then
            GameTooltip:AddLine(n .. " planter(s) tracked", 0.4, 1.0, 0.4)
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    GB_UpdateMinimapPos()
    return btn
end

-------------------------------------------------------------------------------
-- BOTTOM BUTTONS / SOUND
-------------------------------------------------------------------------------

function GB_UpdateBottomButtons()
    local f = GardenBuddyMainFrame
    if not f then return end
    local snd = GB_SOUNDS[GardenBuddyDB.soundIndex]
    if GardenBuddyDB.soundEnabled and snd and snd.file then
        f.soundBtn:SetText("|cff55ff55Alert: " .. snd.label .. "|r")
    else
        f.soundBtn:SetText("|cffff5555Alert: Off|r")
    end
end

function GB_CycleSound()
    local db = GardenBuddyDB
    db.soundIndex = math.mod(db.soundIndex, table.getn(GB_SOUNDS)) + 1
    local s = GB_SOUNDS[db.soundIndex]
    if s and s.file then
        db.soundEnabled = true
        PlaySoundFile(s.file)
    else
        db.soundEnabled = false
    end
    GB_UpdateBottomButtons()
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
        f:SetHeight(GB_PAD + 24 + GB_PAD)
    else
        f.hdrFrame:Show()
        f.content:Show()
        f.upArrow:Show()
        f.downArrow:Show()
        GardenBuddyAddBtn:Show()
        GardenBuddySoundBtn:Show()
        f:SetHeight(GB_CalcFrameHeight())
        GB_RefreshDisplay()
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

    if total == 0 then f.noPlText:Show() else f.noPlText:Hide() end

    if total > GB_MAX_VISIBLE_ROWS then
        f.upArrow:Show() ; f.downArrow:Show()
    else
        f.upArrow:Hide() ; f.downArrow:Hide()
        GB.scrollOfs = 0
    end

    for i = 1, GB_MAX_VISIBLE_ROWS do
        local row  = GB.rows[i]
        local pIdx = i + GB.scrollOfs
        local p    = planters[pIdx]
        if p then
            row:Show()
            row.planterIdx = pIdx
            local phase, timeRem, phasesLeft = GB_GetStatus(p)
            local isReady = (phasesLeft == 0 and timeRem <= 0)
            local isWarn  = (not isReady and timeRem < 120)

            row.nameFs:SetText("|cffddffdd" .. p.name .. "|r")

            local pName = GB_PHASE_NAMES[phase] or ("Phase " .. phase)
            if isReady then
                row.phaseFs:SetText("|cff00ff44" .. pName .. "|r")
            elseif isWarn then
                row.phaseFs:SetText("|cffffbb00" .. pName .. "|r")
            else
                row.phaseFs:SetText("|cffaaddaa" .. pName .. "|r")
            end

            if isReady then
                row.timeFs:SetText("|cff00ff44HARVEST!|r")
            elseif isWarn then
                row.timeFs:SetText("|cffffbb00" .. GB_FormatTime(timeRem) .. "|r")
            else
                row.timeFs:SetText("|cffffffff" .. GB_FormatTime(timeRem) .. "|r")
            end

            if isReady then
                row.leftFs:SetText("|cff00ff44Done!|r")
            else
                local ls = phasesLeft .. " / " .. (GB_TOTAL_PHASES - 1)
                if phasesLeft <= 1 then
                    row.leftFs:SetText("|cffffbb00" .. ls .. "|r")
                else
                    row.leftFs:SetText("|cffaaffaa" .. ls .. "|r")
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
    d:SetWidth(255) ; d:SetHeight(112)
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
    labelFs:SetPoint("TOPLEFT", d, "TOPLEFT", 18, -38)
    labelFs:SetText("|cffddffddPlanter Name:|r")

    local editBox = CreateFrame("EditBox", "GardenBuddyDialogEdit", d, "InputBoxTemplate")
    editBox:SetWidth(205) ; editBox:SetHeight(20)
    editBox:SetPoint("TOPLEFT", d, "TOPLEFT", 18, -54)
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
    okBtn:SetWidth(80) ; okBtn:SetHeight(22)
    okBtn:SetPoint("BOTTOMLEFT", d, "BOTTOMLEFT", 18, 12)
    okBtn:SetText("|cff55ff55Plant!|r")
    okBtn:SetScript("OnClick", function()
        GB_AddPlanter(GardenBuddyDialogEdit:GetText())
        GardenBuddyAddDialog:Hide()
    end)

    local cancelBtn = CreateFrame("Button", nil, d, "GameMenuButtonTemplate")
    cancelBtn:SetWidth(80) ; cancelBtn:SetHeight(22)
    cancelBtn:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", -18, 12)
    cancelBtn:SetText("Cancel")
    cancelBtn:SetScript("OnClick", function() GardenBuddyAddDialog:Hide() end)

    d:Hide()
end

function GB_ShowAddDialog()
    if not GardenBuddyAddDialog then GB_CreateAddDialog() end
    local suggestName = "Planter " .. (table.getn(GardenBuddyDB.planters) + 1)
    GardenBuddyDialogEdit:SetText(suggestName)
    GardenBuddyDialogEdit:HighlightText()
    GardenBuddyDialogEdit:SetFocus()
    GardenBuddyAddDialog:Show()
end

-------------------------------------------------------------------------------
-- EVENT HANDLER
-- SPELLCAST_START: arg1 = spell name. Save it if it looks like a planting cast.
-- SPELLCAST_STOP:  no args. If we have a pending planting spell, fire the add.
-- SPELLCAST_FAILED / SPELLCAST_INTERRUPTED: clear pendingSpell without adding.
-------------------------------------------------------------------------------

local evFrame = CreateFrame("Frame", "GardenBuddyEventFrame")
evFrame:RegisterEvent("ADDON_LOADED")
evFrame:RegisterEvent("PLAYER_LOGOUT")
evFrame:RegisterEvent("SPELLCAST_START")
evFrame:RegisterEvent("SPELLCAST_STOP")
evFrame:RegisterEvent("SPELLCAST_FAILED")
evFrame:RegisterEvent("SPELLCAST_INTERRUPTED")

evFrame:SetScript("OnEvent", function()

    if event == "ADDON_LOADED" and arg1 == "GardenBuddy" then
        if not GardenBuddyDB then
            GardenBuddyDB = GB_GetDefaults()
        else
            local def = GB_GetDefaults()
            for k, v in pairs(def) do
                if GardenBuddyDB[k] == nil then GardenBuddyDB[k] = v end
            end
        end

        GardenBuddyMainFrame = GB_CreateMainFrame()
        GardenBuddyMainFrame:Hide()
        GB_CreateMinimapButton()

        if GardenBuddyDB.minimized then
            GardenBuddyDB.minimized = false
            GB_ToggleMinimize()
        end

        GB_RefreshDisplay()
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff55ff55[GardenBuddy]|r v" .. GARDENBUDDY_VERSION ..
            " loaded - click the |cff33dd33herb minimap icon|r or type |cffddffdd/gb|r.")
        GB.initialized   = true
        GB.lastPlantTime = 0
        GB.pendingSpell  = nil

    elseif event == "PLAYER_LOGOUT" then
        if GardenBuddyMainFrame then
            local _, _, _, x, y = GardenBuddyMainFrame:GetPoint()
            GardenBuddyDB.posX = x
            GardenBuddyDB.posY = y
        end

    elseif event == "SPELLCAST_START" and GB.initialized then
        -- arg1 = spell name, arg2 = rank, arg3 = cast time in ms
        if GB_IsPlantingSpell(arg1) then
            GB.pendingSpell = arg1
        else
            GB.pendingSpell = nil
        end

    elseif event == "SPELLCAST_STOP" and GB.initialized then
        -- Cast completed successfully - check if it was a planting cast
        if GB.pendingSpell then
            local spellName = GB.pendingSpell
            GB.pendingSpell = nil
            GB_OnSpellPlantingComplete(spellName)
        end

    elseif (event == "SPELLCAST_FAILED" or event == "SPELLCAST_INTERRUPTED")
           and GB.initialized then
        -- Cast failed or was interrupted - discard pending spell
        GB.pendingSpell = nil
    end
end)

-------------------------------------------------------------------------------
-- DEBUG HELPER
-- /gb debug: prints SPELLCAST events to chat for 30 seconds so you can
-- see exactly what spell name fires when you plant a seed.
-------------------------------------------------------------------------------

local GB_debugActive   = false
local GB_debugDeadline = 0
local GB_debugFrame    = CreateFrame("Frame", "GardenBuddyDebugFrame")
GB_debugFrame:RegisterEvent("SPELLCAST_START")
GB_debugFrame:RegisterEvent("SPELLCAST_STOP")
GB_debugFrame:RegisterEvent("SPELLCAST_FAILED")
GB_debugFrame:RegisterEvent("SPELLCAST_INTERRUPTED")
GB_debugFrame:RegisterEvent("CHAT_MSG_SYSTEM")
GB_debugFrame:RegisterEvent("CHAT_MSG_SPELL_SELF_BUFF")

GB_debugFrame:SetScript("OnEvent", function()
    if not GB_debugActive then return end
    if GetTime() > GB_debugDeadline then
        GB_debugActive = false
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff55ff55[GardenBuddy Debug]|r 30s window closed.")
        return
    end
    local a1 = arg1 and strsub(tostring(arg1), 1, 60) or ""
    local a2 = arg2 and strsub(tostring(arg2), 1, 30) or ""
    DEFAULT_CHAT_FRAME:AddMessage(
        "|cff55ff55[GB Debug]|r |cffffaa00" .. event .. "|r" ..
        (strlen(a1) > 0 and (" |cffddffdd" .. a1 .. "|r") or "") ..
        (strlen(a2) > 0 and (" / " .. a2) or ""))
end)

-------------------------------------------------------------------------------
-- SLASH COMMANDS
-------------------------------------------------------------------------------

SLASH_GARDENBUDDY1 = "/gb"
SLASH_GARDENBUDDY2 = "/gardenbuddy"
SLASH_GARDENBUDDY3 = "/garden"

SlashCmdList["GARDENBUDDY"] = function(msg)
    if not msg then msg = "" end
    msg = GB_Trim(msg)

    local spacePos = strfind(msg, " ")
    local cmd, rest
    if spacePos then
        cmd  = strlower(strsub(msg, 1, spacePos - 1))
        rest = GB_Trim(strsub(msg, spacePos + 1))
    else
        cmd  = strlower(msg)
        rest = ""
    end

    if cmd == "add" then
        if strlen(rest) > 0 then GB_AddPlanter(rest) else GB_ShowAddDialog() end

    elseif cmd == "remove" or cmd == "rem" or cmd == "del" then
        local idx = tonumber(rest)
        if idx then
            GB_RemovePlanter(idx)
        else
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff55ff55[GardenBuddy]|r Usage: /gb remove <number>")
        end

    elseif cmd == "rename" then
        local sp2 = strfind(rest, " ")
        if sp2 then
            local idx  = tonumber(strsub(rest, 1, sp2 - 1))
            local name = GB_Trim(strsub(rest, sp2 + 1))
            if idx and GardenBuddyDB.planters[idx] then
                GardenBuddyDB.planters[idx].name = name
                GB_RefreshDisplay()
                DEFAULT_CHAT_FRAME:AddMessage(
                    "|cff55ff55[GardenBuddy]|r Renamed to: |cffddffdd" .. name .. "|r")
            end
        else
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff55ff55[GardenBuddy]|r Usage: /gb rename <#> <new name>")
        end

    elseif cmd == "clear" then
        GardenBuddyDB.planters = {}
        GB.scrollOfs = 0
        GB_RefreshDisplay()
        DEFAULT_CHAT_FRAME:AddMessage("|cff55ff55[GardenBuddy]|r All planters cleared.")

    elseif cmd == "show" then
        GardenBuddyMainFrame:Show()
        GB_RefreshDisplay()

    elseif cmd == "hide" then
        GardenBuddyMainFrame:Hide()

    elseif cmd == "toggle" then
        if GardenBuddyMainFrame:IsShown() then
            GardenBuddyMainFrame:Hide()
        else
            GardenBuddyMainFrame:Show()
            GB_RefreshDisplay()
        end

    elseif cmd == "sound" then
        GB_CycleSound()

    elseif cmd == "list" then
        local ps = GardenBuddyDB.planters
        if table.getn(ps) == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cff55ff55[GardenBuddy]|r No active planters.")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cff55ff55[GardenBuddy]|r Active planters:")
            for i, p in ipairs(ps) do
                local ph, tr, pl = GB_GetStatus(p)
                local pname = GB_PHASE_NAMES[ph] or ("Phase " .. ph)
                DEFAULT_CHAT_FRAME:AddMessage(string.format(
                    "  |cffddffdd#%d|r %s  |cffaaffaa%s|r  %s remaining  |cffaaffaa%d left|r",
                    i, p.name, pname, GB_FormatTime(tr), pl))
            end
        end

    elseif cmd == "debug" then
        GB_debugActive   = true
        GB_debugDeadline = GetTime() + 30
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff55ff55[GardenBuddy]|r Debug active for 30s - plant a seed now!")
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff55ff55[GardenBuddy]|r Watching: SPELLCAST_START/STOP, CHAT_MSG_SYSTEM, CHAT_MSG_SPELL_SELF_BUFF")

    elseif cmd == "reset" then
        local kept = GardenBuddyDB.planters
        GardenBuddyDB = GB_GetDefaults()
        GardenBuddyDB.planters = kept
        GB_UpdateBottomButtons()
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff55ff55[GardenBuddy]|r Settings reset (planters kept).")

    elseif cmd == "resetall" then
        GardenBuddyDB = GB_GetDefaults()
        GB.scrollOfs = 0
        GB_RefreshDisplay()
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff55ff55[GardenBuddy]|r Full reset - all data cleared.")

    else
        DEFAULT_CHAT_FRAME:AddMessage("|cff55ff55=== Garden Buddy v" .. GARDENBUDDY_VERSION .. " ===|r")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffddffdd/gb add [name]|r      - Manually track a planter")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffddffdd/gb remove <#>|r      - Remove planter by number")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffddffdd/gb rename <#> <n>|r  - Rename a planter")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffddffdd/gb clear|r            - Remove all planters")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffddffdd/gb list|r             - Print planters to chat")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffddffdd/gb show|r / |cffddffdd/gb hide|r    - Show / hide window")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffddffdd/gb toggle|r           - Toggle window")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffddffdd/gb sound|r            - Cycle alert sound")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffddffdd/gb debug|r            - Watch spell/chat events for 30s")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffddffdd/gb reset|r            - Reset settings (keep planters)")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffddffdd/gb resetall|r         - Full wipe")
        DEFAULT_CHAT_FRAME:AddMessage("  |cff668866Phase: 9 min fixed. Minimap: L-click=toggle, R-click=add, drag=move|r")
    end
end
