-- =========================
-- PetHealthWatch v1.14.0 - Wow Forever port (from Turtle WoW v1.3.1)
-- Secret-value aware: when the game hides pet health from addons, the
-- alert is driven by a color curve instead of Lua comparisons.
-- =========================

-- Hunter only. Exit before creating any frames, events or slash commands, so
-- nothing runs on other classes (PHW_Config is account-wide, so a bare
-- "is PHW_Config set" check is not enough to keep other classes out).
local _, PHW_PlayerClass = UnitClass("player")
if PHW_PlayerClass ~= "HUNTER" then return end

-- 1. Setup Defaults
PHW_Defaults = {
    threshPct = 50,
    threshVal = 500,
    isPercent = true,
    posX = 0,
    posY = -100,
    manaCost = 480,
    deadMemory = false,
    flashMax = 0.2,  -- peak opacity of the screen flash (0 = off, 1 = solid)
    clickMod = "none", -- key held to click the button while pet is alive: none/shift/ctrl/alt
    deathSoundOn = true,     -- play a sound when the pet dies
    deathSound = 8648        -- sound kit ID (8648 = Battleguard Sartura death)
}

local ADDON_NAME = "PetHealthWatch"

local isTriggered = false
local isChanneling = false
local channelStart = 0
local channelDuration = 5
local mendCastIntent = 0
local macroPending = false

local alertCurve, flashCurve = nil, nil   -- built by BuildCurves()
local curveAccum = 0
local wasCurveDriven = false

-- Mend Pet ranks 1-7: spell IDs and mana costs
local PHW_MendIDs  = { 136, 3111, 3661, 3662, 13542, 13543, 13544 }
local PHW_ManaTable = { 50, 90, 155, 225, 300, 385, 480 }

-- ---------------------------------------------------------------
-- Compatibility helpers
-- ---------------------------------------------------------------
local function IsSecret(v)
    if issecretvalue then return issecretvalue(v) and true or false end
    return false
end

local function SpellNameByID(id, fallback)
    local name
    if C_Spell and C_Spell.GetSpellName then
        name = C_Spell.GetSpellName(id)
    elseif GetSpellInfo then
        name = GetSpellInfo(id)
    end
    return name or fallback
end

local function SpellKnown(id)
    if IsSpellKnown and IsSpellKnown(id) then return true end
    if IsPlayerSpell and IsPlayerSpell(id) then return true end
    return false
end

local mendName   = "Mend Pet"
local reviveName = "Revive Pet"

local function ResolveSpellNames()
    mendName   = SpellNameByID(136, "Mend Pet")
    reviveName = SpellNameByID(982, "Revive Pet")
end

-- 2. Create the Flash Frame
local flash = CreateFrame("Frame", "PHW_FlashFrame", UIParent)
flash:SetAllPoints(UIParent)
flash:SetFrameStrata("BACKGROUND")
flash:EnableMouse(false)
flash.tex = flash:CreateTexture(nil, "BACKGROUND")
flash.tex:SetAllPoints(flash)
flash.tex:SetColorTexture(0.95, 0.75, 0.3, 1)
flash:SetAlpha(0.3)
flash.curAlpha = 0.3   -- we track alpha ourselves; never read it back with GetAlpha()
flash:Hide()

-- Pulse via an animation on the texture. Animation alpha multiplies with the
-- frame's alpha, so this pulses even when the frame alpha is curve-driven.
flash.pulse = flash.tex:CreateAnimationGroup()
do
    local a = flash.pulse:CreateAnimation("Alpha")
    a:SetFromAlpha(1)
    a:SetToAlpha(0.25)
    a:SetDuration(0.6)
    flash.pulse:SetLooping("BOUNCE")
end

local function SetFlashColor(r, g, b)
    flash.tex:SetColorTexture(r, g, b, 1)
end

-- 3. Create the Mend Button (secure button inside a non-secure container)
local container = CreateFrame("Frame", "PHW_Container", UIParent)
container:SetWidth(60); container:SetHeight(60)
container:SetFrameStrata("MEDIUM")
container:SetMovable(true)
container:SetPoint("CENTER", UIParent, "CENTER", 0, -100)
container:Hide()

local frame = CreateFrame("Button", "PHW_MendButton", container, "SecureActionButtonTemplate")
frame:SetAllPoints(container)
frame:EnableMouse(true)
-- Left button only. Register both directions: with the "cast on key press"
-- setting enabled, secure buttons only fire on the down-click.
frame:RegisterForClicks("LeftButtonUp", "LeftButtonDown")
-- Let right-clicks pass through to the game world (mouselook, movement)
if frame.SetPassThroughButtons then
    frame:SetPassThroughButtons("RightButton")
end
frame:RegisterForDrag("LeftButton")

-- Visuals are on the container, NOT the button. The secure button is just an
-- invisible click layer on top, so it can be hidden (and lose its hit area)
-- without hiding the icon and text.
frame.icon = container:CreateTexture(nil, "ARTWORK")
frame.icon:SetAllPoints(container)

local timerText = container:CreateFontString(nil, "OVERLAY")
timerText:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
timerText:SetPoint("BOTTOM", container, "BOTTOM", 0, -18)

local CLICK_PREFIX = { none = "", shift = "shift-", ctrl = "ctrl-", alt = "alt-" }
local macroText = ""
local chordBlocked = false

local function ClearClickAttributes()
    for _, pre in pairs(CLICK_PREFIX) do
        frame:SetAttribute(pre .. "type1", nil)
        frame:SetAttribute(pre .. "macrotext1", nil)
    end
end

local function ApplyMacro()
    if InCombatLockdown() then
        macroPending = true
        return
    end
    macroPending = false
    macroText = "/cast [@pet,exists,nodead] " .. mendName .. "; " .. reviveName

    local mod = (PHW_Config and PHW_Config.clickMod) or "none"
    if not CLICK_PREFIX[mod] then mod = "none" end
    local pre = CLICK_PREFIX[mod]

    -- Only the chosen click combination has an action; every other click
    -- (right-click, or left-click without the required modifier) does nothing.
    -- The "1" suffix = left mouse button.
    ClearClickAttributes()
    frame:SetAttribute("type1", "macro")
    frame:SetAttribute("macrotext1", macroText)
    if pre ~= "" then
        frame:SetAttribute(pre .. "type1", "macro")
        frame:SetAttribute(pre .. "macrotext1", macroText)
    end

    -- Hit-area control. In modifier mode the game (not our code) keeps the
    -- click layer hidden unless the modifier is held, or the pet is dead / gone
    -- (the alert is then fully visible and we know it's needed). A hidden frame
    -- has no hit area, so left+right clicks fall through to the world.
    if mod == "none" then
        UnregisterStateDriver(frame, "visibility")
        frame:Show()
    else
        RegisterStateDriver(frame, "visibility",
            "[@pet,dead] show; [nopet] show; [mod:" .. mod .. "] show; hide")
    end

    -- Act on button release, not press, even if "cast on key press" is enabled.
    -- A left+right press then no longer fires the instant the left button lands.
    frame:SetAttribute("useOnKeyDown", false)
end

-- Out of combat only (protected attributes can't change in combat): if the
-- right button is held or the mouse is in mouselook when a click arrives, it is
-- a left+right "move forward" chord, not a deliberate click. Blank the action
-- for this one click and restore it right after.
frame:HookScript("PreClick", function()
    if InCombatLockdown() then return end
    local rightDown = IsMouseButtonDown and IsMouseButtonDown("RightButton")
    local looking = IsMouselooking and IsMouselooking()
    if rightDown or looking then
        ClearClickAttributes()
        chordBlocked = true
    end
end)

frame:HookScript("PostClick", function()
    if chordBlocked and not InCombatLockdown() then
        chordBlocked = false
        ApplyMacro()
    end
    if not (PHW_Config and PHW_Config.deadMemory) then
        mendCastIntent = GetTime()
    end
end)

-- 4. Helper Functions
local function PHW_PrintStatus()
    if not PHW_Config then return end
    local mode = PHW_Config.isPercent and "%" or " HP"
    local currentVal = PHW_Config.isPercent and PHW_Config.threshPct or PHW_Config.threshVal
    DEFAULT_CHAT_FRAME:AddMessage("|cffffff00Pet Health Watch V1.14.0 loaded.  /PHW for help")
    DEFAULT_CHAT_FRAME:AddMessage("|cffffff00PHW Alert at:|r |cff00ff00" .. currentVal .. mode .. "|r")
end

local function PHW_ScanMana()
    local highestRank = 0
    for rank, id in ipairs(PHW_MendIDs) do
        if SpellKnown(id) then highestRank = rank end
    end
    if PHW_Config then
        PHW_Config.manaCost = (highestRank > 0) and (PHW_ManaTable[highestRank] or 480) or 480
    end
end

-- Returns true/false, or nil if we can't tell (unknown or secret)
local function PetInMendRange()
    local r
    if C_Spell and C_Spell.IsSpellInRange then
        r = C_Spell.IsSpellInRange(mendName, "pet")
    elseif IsSpellInRange then
        r = IsSpellInRange(mendName, "pet")
    end
    if r ~= nil and not IsSecret(r) then
        return (r == true or r == 1)
    end
    if r == nil then
        local ok, res = pcall(CheckInteractDistance, "pet", 4)
        if ok and not IsSecret(res) then return res and true or false end
    end
    return nil
end

-- Returns a number, or nil if hidden from addons
local function PlayerMana()
    local m
    if UnitPower then m = UnitPower("player", 0) else m = UnitMana("player") end
    if IsSecret(m) then return nil end
    return m
end

-- ---------------------------------------------------------------
-- Alert helpers
-- ---------------------------------------------------------------
-- Alert sound. Only fires where health is readable by the addon; the game does
-- not let us detect the threshold crossing while pet health is hidden.

-- Sounds the user can choose from: built-in game sound kit IDs
-- (see wowhead.com/classic/sounds). Any other ID can be entered as a custom number.
PHW_SoundLibrary = {
    { name = "Sartura - I Serve To The Last",   kind = "kit",  value = 8648 },
    { name = "Sea Turtle Death",                kind = "kit",  value = 1462 },
    { name = "Human Male Death",                kind = "kit",  value = 2944 },
    { name = "Wolf Death",                      kind = "kit",  value = 394 },
    { name = "Dragon Whelp Death",              kind = "kit",  value = 432 },
    { name = "Hydra Death",                     kind = "kit",  value = 449 },
    { name = "Swarm Guard Death",               kind = "kit",  value = 8520 },
}

-- Lowercase and strip spaces/punctuation so "wolf death" matches "Wolf Death"
local function NormName(str)
    return (string.lower(str or ""):gsub("[^%w]", ""))
end

-- Find a library entry by name. Returns the entry, or nil plus a list of
-- matches when the text is ambiguous.
local function FindSound(query)
    local q = NormName(query)
    if q == "" then return nil end
    for _, e in ipairs(PHW_SoundLibrary) do
        if NormName(e.name) == q then return e end
    end
    local matches = {}
    for _, e in ipairs(PHW_SoundLibrary) do
        if string.find(NormName(e.name), q, 1, true) then table.insert(matches, e) end
    end
    if #matches == 1 then return matches[1] end
    return nil, matches
end

-- Friendly name for a stored selection (library name, or the raw number)
local function SoundLabel(sel)
    for _, e in ipairs(PHW_SoundLibrary) do
        if e.value == sel or (tonumber(sel) and e.value == tonumber(sel)) then
            return e.name .. " (" .. tostring(e.value) .. ")"
        end
    end
    return "custom " .. tostring(sel)
end

-- Play a sound kit ID. Returns false if the value isn't a number.
local function PlaySelection(sel)
    local id = tonumber(sel)
    if not id then return false end
    return (pcall(PlaySound, id, "Master"))
end

local function PlayDeathSound()
    if PHW_Config and PHW_Config.deathSoundOn == false then return end
    PlaySelection(PHW_Config and PHW_Config.deathSound or 8648)
end

-- Start/stop the main flash's pulse animation (steady dim glow when stopped)
local function SetFlashPulse(on)
    if on then
        if flash.animOn ~= true then
            flash.tex:SetAlpha(1)
            flash.pulse:Play()
            flash.animOn = true
        end
    else
        if flash.animOn ~= false then
            flash.pulse:Stop()
            flash.tex:SetAlpha(0.6)
            flash.animOn = false
        end
    end
end

-- Builds the curves that turn pet health % into an alpha value without us
-- ever reading the health number. Alpha is full at/below the threshold and
-- zero above it (with a 1% ramp so it works however the curve interpolates).
local function BuildCurves()
    alertCurve, flashCurve = nil, nil
    if not PHW_Config then return end
    if not (C_CurveUtil and C_CurveUtil.CreateColorCurve and CreateColor and UnitHealthPercent) then return end

    local frac = (PHW_Config.threshPct or 50) / 100
    if not PHW_Config.isPercent then
        local max = UnitHealthMax("pet")
        if max and not IsSecret(max) and max > 0 then
            frac = (PHW_Config.threshVal or 500) / max
        end
    end
    if frac < 0.01 then frac = 0.01 end
    if frac > 0.98 then frac = 0.98 end

    local function make(maxAlpha)
        local c = C_CurveUtil.CreateColorCurve()
        if Enum and Enum.LuaCurveType and c.SetType then
            c:SetType(Enum.LuaCurveType.Linear)
        end
        c:AddPoint(0, CreateColor(1, 1, 1, maxAlpha))
        c:AddPoint(frac, CreateColor(1, 1, 1, maxAlpha))
        c:AddPoint(frac + 0.01, CreateColor(1, 1, 1, 0))
        c:AddPoint(1, CreateColor(1, 1, 1, 0))
        return c
    end
    alertCurve = make(1)
    flashCurve = make(PHW_Config.flashMax or 0.2)

end

-- Sets icon/text/flash color for the "heal pet" state (all secret-safe)
local function UpdateHealUI(exists)
    frame.icon:SetTexture("Interface\\Icons\\Ability_Hunter_MendPet")
    local curMana = PlayerMana()
    local inRange = PetInMendRange()
    if curMana and curMana < PHW_Config.manaCost then
        timerText:SetText(curMana .. " / " .. PHW_Config.manaCost)
        timerText:SetTextColor(0.5, 0.5, 1)
        SetFlashColor(0.25, 0.35, 0.8)
    elseif (not exists) or inRange == false then
        timerText:SetText("OUT OF RANGE")
        timerText:SetTextColor(1, 0.3, 0.3)
        SetFlashColor(0.75, 0.2, 0.2)
    else
        local mod = PHW_Config.clickMod or "none"
        if mod == "none" then
            timerText:SetText("HEAL PET")
        else
            timerText:SetText("HEAL PET [" .. string.upper(mod) .. "]")
        end
        timerText:SetTextColor(1, 1, 0)
        SetFlashColor(0.95, 0.75, 0.3)
    end
end

-- 5. Unified Logic Frame
local logicFrame = CreateFrame("Frame", "PHW_LogicFrame", UIParent)
logicFrame:SetScript("OnUpdate", function(self, elapsed)
    if not PHW_Config or not PHW_Config.manaCost then return end
    elapsed = elapsed or 0

    local exists = UnitExists("pet")
    local isDead = UnitIsDead("pet")
    local hp = exists and UnitHealth("pet") or 0
    local hpSecret = IsSecret(hp)

    -- Dead-state sync. Only trust the game's explicit "dead" flag; this
    -- ignores the "0 HP" glitch when the pet is out of range.
    if exists then
        if isDead then
            if not PHW_Config.deadMemory then PlayDeathSound() end
            PHW_Config.deadMemory = true
        elseif hpSecret or hp > 0 then
            if PHW_Config.deadMemory then PHW_Config.deadMemory = false end
        end
    end

    -- When health is hidden from us, the alert is driven by the curves.
    local curveDriven = (not PHW_Config.deadMemory) and (not isTriggered)
        and (not isChanneling) and exists and (not isDead)
        and hpSecret and alertCurve ~= nil

    -- DYNAMIC UI
    if PHW_Config.deadMemory then
        -- Revive Pet works from anywhere, so no "call pet" step is needed
        frame.icon:SetTexture("Interface\\Icons\\Ability_Hunter_BeastSoothe")
        timerText:SetText("REVIVE PET")
        timerText:SetTextColor(1, 0, 0)
        SetFlashColor(0.75, 0.2, 0.2)
    elseif isTriggered or curveDriven then
        UpdateHealUI(exists)
    end

    -- Channeling
    if isChanneling then
        local timeLeft = channelDuration - (GetTime() - channelStart)
        if timeLeft > 0 then
            timerText:SetTextColor(1, 1, 1)
            timerText:SetText("MENDING: " .. string.format("%.1f", timeLeft))
        else
            isChanneling = false
        end
    end

    -- CURVE-DRIVEN MODE (health is secret): visibility is an alpha value
    -- computed by the game; we just hand it to the frames.
    if curveDriven then
        if not wasCurveDriven then
            wasCurveDriven = true
            container:SetAlpha(0)
            flash:SetAlpha(0)
            curveAccum = 1  -- force an immediate evaluation
        end
        if not container:IsShown() then container:Show() end
        flash:Show()
        SetFlashPulse(true)       -- keep pulsing until healed

        curveAccum = curveAccum + elapsed
        if curveAccum >= 0.1 then
            curveAccum = 0
            local c1 = UnitHealthPercent("pet", false, alertCurve)
            local c2 = UnitHealthPercent("pet", false, flashCurve)
            if c1 and c1.GetRGBA then
                local _, _, _, a = c1:GetRGBA()
                container:SetAlpha(a)
            end
            if c2 and c2.GetRGBA then
                local _, _, _, a = c2:GetRGBA()
                flash:SetAlpha(a)
            end
        end
        return
    end

    -- Leaving curve mode: restore normal (non-secret) alpha values
    if wasCurveDriven then
        wasCurveDriven = false
        container:SetAlpha(1)
        flash.curAlpha = (PHW_Config.flashMax or 0.2) * 0.6
        flash:SetAlpha(flash.curAlpha)
        flash.alphaDir = 1
        flash.pulse:Stop()
        flash.tex:SetAlpha(1)
        flash.animOn = nil
    end

    -- Visibility Controller (normal mode)
    if (PHW_Config.deadMemory or isTriggered or isChanneling) then
        if not container:IsShown() then container:Show() end
        if (PHW_Config.deadMemory or isTriggered) and not isChanneling then
            flash:Show()
            local fmax = PHW_Config.flashMax or 0.2
            local curAlpha = flash.curAlpha or 0.3
            local dir = flash.alphaDir or 1
            curAlpha = curAlpha + (elapsed * 2.0 * dir)
            local fmin = fmax * 0.25
            if curAlpha < fmin then curAlpha = fmin; flash.alphaDir = 1 end
            if curAlpha > fmax then curAlpha = fmax; flash.alphaDir = -1 end
            flash.curAlpha = curAlpha
            flash:SetAlpha(curAlpha)
        else
            flash:Hide()
        end
    else
        if container:IsShown() then container:Hide() end
        flash:Hide()
    end
end)

-- 6. Dragging (moves the container; not allowed in combat)
frame:SetScript("OnDragStart", function()
    if InCombatLockdown() then return end
    container:StartMoving()
end)
frame:SetScript("OnDragStop", function()
    container:StopMovingOrSizing()
    if not PHW_Config then return end
    local x, y = container:GetCenter()
    local ux, uy = UIParent:GetCenter()
    if x and ux then
        PHW_Config.posX = x - ux
        PHW_Config.posY = y - uy
    end
end)

-- 7. Event Handling
local function CheckPetHealth()
    if not PHW_Config then return end

    if not UnitExists("pet") or UnitIsDead("pet") then
        isTriggered = false
        return
    end

    local cur, max = UnitHealth("pet"), UnitHealthMax("pet")
    -- Health hidden from addons: can't compare. The curve handles the visual.
    if IsSecret(cur) or IsSecret(max) then
        isTriggered = false
        return
    end
    if max == 0 then return end

    local val = PHW_Config.isPercent and (cur / max) * 100 or cur
    local thresh = PHW_Config.isPercent and PHW_Config.threshPct or PHW_Config.threshVal

    if val <= thresh and not isTriggered and cur > 0 then
        isTriggered = true
    elseif isTriggered and val > (thresh + (PHW_Config.isPercent and 5 or 100)) then
        isTriggered = false
    end
end

local function OnChannelStart()
    if UnitChannelInfo then
        local name, _, _, startMS, endMS = UnitChannelInfo("player")
        if name and not IsSecret(name) and name == mendName then
            isChanneling = true
            if startMS and endMS and not IsSecret(startMS) and not IsSecret(endMS) then
                channelStart = startMS / 1000
                channelDuration = (endMS - startMS) / 1000
            else
                channelStart = GetTime()
                channelDuration = 5
            end
            return
        end
    end
    if (GetTime() - mendCastIntent) < 0.5 then
        isChanneling = true
        channelStart = GetTime()
        channelDuration = 5
    end
end

local eventFrame = CreateFrame("Frame", "PHW_EventFrame", UIParent)
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("UNIT_HEALTH")
eventFrame:RegisterEvent("UNIT_MAXHEALTH")
eventFrame:RegisterEvent("UNIT_PET")
eventFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
eventFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        if not PHW_Config then PHW_Config = {} end
        for k, v in pairs(PHW_Defaults) do
            if PHW_Config[k] == nil then PHW_Config[k] = v end
        end
        container:ClearAllPoints()
        container:SetPoint("CENTER", UIParent, "CENTER", PHW_Config.posX, PHW_Config.posY)

        ResolveSpellNames()
        ApplyMacro()
        BuildCurves()
        if PHW_RegisterOptionsPanel then PHW_RegisterOptionsPanel() end
        PHW_PrintStatus()
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        ResolveSpellNames()
        PHW_ScanMana()
        ApplyMacro()
        BuildCurves()
    elseif event == "PLAYER_REGEN_ENABLED" then
        if macroPending then ApplyMacro() end
    elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
        if arg1 == "player" then OnChannelStart() end
    elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        if arg1 == "player" then isChanneling = false end
    elseif event == "UNIT_HEALTH" then
        if arg1 ~= "pet" then return end
    elseif event == "UNIT_MAXHEALTH" then
        if arg1 ~= "pet" then return end
        BuildCurves()   -- raw-HP threshold depends on max health
    elseif event == "UNIT_PET" then
        if arg1 ~= "player" then return end
        BuildCurves()
    end

    CheckPetHealth()
end)

-- ---------------------------------------------------------------
-- Settings window  (/phw or /phw config)
-- Plain frames + standard templates. None of this touches the secure button,
-- so it is safe to open in combat.
-- ---------------------------------------------------------------
local UI = {}
local settings = nil
local WOWHEAD_URL = "https://www.wowhead.com/classic/sounds"
local MOD_ORDER  = { "none", "shift", "ctrl", "alt" }
local MOD_LABELS = { none = "None", shift = "Shift", ctrl = "Ctrl", alt = "Alt" }

local function say(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffff00PHW:|r " .. text)
end

local function Clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

local function AddEdge(f, p1, p2, w, h)
    local t = f:CreateTexture(nil, "BORDER")
    t:SetColorTexture(0.55, 0.45, 0.2, 1)
    t:SetPoint(p1, f, p1, 0, 0)
    t:SetPoint(p2, f, p2, 0, 0)
    if w then t:SetWidth(w) end
    if h then t:SetHeight(h) end
end

local function AddBorder(f)
    AddEdge(f, "TOPLEFT", "TOPRIGHT", nil, 1)
    AddEdge(f, "BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
    AddEdge(f, "TOPLEFT", "BOTTOMLEFT", 1, nil)
    AddEdge(f, "TOPRIGHT", "BOTTOMRIGHT", 1, nil)
end

local function MakeLabel(parent, text, x, y, font)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    fs:SetText(text)
    return fs
end

local function MakeButton(parent, text, w, h)
    local ok, b = pcall(CreateFrame, "Button", nil, parent, "UIPanelButtonTemplate")
    if not ok or not b then
        b = CreateFrame("Button", nil, parent)
        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetAllPoints(b)
        b.bg:SetColorTexture(0.25, 0.25, 0.3, 1)
        b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        b.label:SetPoint("CENTER", b, "CENTER", 0, 0)
        b.SetText = function(self, t) self.label:SetText(t) end
    end
    b:SetWidth(w); b:SetHeight(h)
    b:SetText(text)
    return b
end

local function MakeCheck(parent, text, x, y, onClick)
    local ok, c = pcall(CreateFrame, "CheckButton", nil, parent, "UICheckButtonTemplate")
    if not ok or not c then
        c = CreateFrame("CheckButton", nil, parent)
        c:SetWidth(24); c:SetHeight(24)
        c:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
        c:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
        c:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
        c:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
    end
    c:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    c.phwLabel = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    c.phwLabel:SetPoint("LEFT", c, "RIGHT", 2, 1)
    c.phwLabel:SetText(text)
    c:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
    return c
end

-- Edit box that applies its value when you press Enter or click away,
-- and reverts if you press Escape.
local function MakeEdit(parent, w, x, y, applyFn)
    local e = CreateFrame("EditBox", nil, parent)
    e:SetWidth(w); e:SetHeight(22)
    e:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    e.cancel = false
    e:SetAutoFocus(false)
    e:SetFont("Fonts\\FRIZQT__.TTF", 12, "")
    e:SetTextInsets(6, 6, 0, 0)
    local bg = e:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(e)
    bg:SetColorTexture(0, 0, 0, 0.6)
    AddBorder(e)
    e:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    e:SetScript("OnEscapePressed", function(self) self.cancel = true; self:ClearFocus() end)
    e:SetScript("OnEditFocusLost", function(self)
        if self.cancel then
            self.cancel = false
        elseif applyFn then
            applyFn(self)
        end
        PHW_RefreshUI()
    end)
    return e
end

-- ---------------------------------------------------------------
-- Settings window. Built the same way as RangeHelper's window (the game's own
-- frame template, radio buttons, arrow steppers, bottom button bar) so the two
-- addons look and behave alike. Each control registers a "refresher" that
-- redraws it from the saved settings.
-- ---------------------------------------------------------------
local refreshers = {}
local editCounter = 0

-- Try several templates; use the first one this client knows about.
local function TryCreate(frameType, name, parent, templates)
    for _, tpl in ipairs(templates) do
        local ok, obj = pcall(CreateFrame, frameType, name, parent, tpl)
        if ok and obj then return obj, tpl end
    end
    return CreateFrame(frameType, name, parent)
end

-- Text label. y is negative (distance down from the top of the parent).
local function WLabel(parent, fontObject, text, x, y, width)
    local fs = parent:CreateFontString(nil, "OVERLAY", fontObject)
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    fs:SetJustifyH("LEFT")
    if width then fs:SetWidth(width) end
    fs:SetText(text)
    return fs
end

local function WHeader(parent, text, x, y)
    return WLabel(parent, "GameFontHighlightLarge", text, x, y)
end

local function HasAtlas(name)
    return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end

local function TextHeight(fs)
    local h = fs.GetStringHeight and fs:GetStringHeight()
    if type(h) ~= "number" or h <= 0 then h = 12 end
    return h
end

-- A group of radio buttons that all edit one setting. Row height follows the
-- real height of the description text, so wrapped descriptions never collide
-- with the next row.
-- items = { { value, label, description }, ... }; returns next free y, entries
local DESC_WIDTH = 290
local function WRadioGroup(parent, x, y, items, getFn, setFn)
    local entries = {}
    for _, item in ipairs(items) do
        local value, label, desc = item[1], item[2], item[3]
        local b = TryCreate("CheckButton", nil, parent, { "UIRadioButtonTemplate", "UICheckButtonTemplate" })
        b:SetSize(22, 22)
        b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
        b:SetHitRectInsets(0, -(item.hit or 230), 0, 0)   -- clicking the label works too
        local labelFS = WLabel(parent, "GameFontNormal", label, x + 26, y - 4)
        local rowH = 26
        if desc then
            local d = WLabel(parent, "GameFontDisableSmall", desc, x + 26, y - 20, DESC_WIDTH)
            rowH = math.max(30, 20 + TextHeight(d) + 8)
        end
        b:SetScript("OnClick", function()
            setFn(value)
            PHW_RefreshUI()
        end)
        entries[#entries + 1] = { button = b, value = value, y = y, label = labelFS }
        y = y - rowH
    end
    refreshers[#refreshers + 1] = function()
        local cur = getFn()
        for _, e in ipairs(entries) do e.button:SetChecked(cur == e.value) end
    end
    return y, entries
end

-- Arrow art: the same atlas the game's option sliders use when available,
-- otherwise a plain - / + button.
local function ArrowButton(parent, direction)
    local base = "Minimal_SliderBar_Button_" .. direction
    if HasAtlas(base) then
        local b = CreateFrame("Button", nil, parent)
        b:SetSize(14, 20)
        pcall(function()
            b:SetNormalAtlas(base)
            if HasAtlas(base .. "_Pressed") then b:SetPushedAtlas(base .. "_Pressed") end
            if HasAtlas(base .. "_Disabled") then b:SetDisabledAtlas(base .. "_Disabled") end
            if HasAtlas(base .. "_Highlight") then b:SetHighlightAtlas(base .. "_Highlight") end
        end)
        return b
    end
    local b = TryCreate("Button", nil, parent, { "UIPanelButtonTemplate" })
    b:SetSize(22, 22)
    b:SetText(direction == "Left" and "-" or "+")
    return b
end

-- [<] value [>]. Click = one step, Shift+click = a big step.
-- rangeFn returns: min, max, step, bigStep.  Returns a table with the next y.
local function WStepper(parent, x, y, text, rangeFn, getFn, setFn, tip)
    local st = {}
    st.label = WLabel(parent, "GameFontNormal", text, x, y - 4)
    local minus = ArrowButton(parent, "Left")
    minus:SetPoint("TOPLEFT", parent, "TOPLEFT", x + 185, y - 1)

    local valueFS = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    valueFS:SetPoint("LEFT", minus, "RIGHT", 0, 0)
    valueFS:SetWidth(40)
    valueFS:SetJustifyH("CENTER")

    local plus = ArrowButton(parent, "Right")
    plus:SetPoint("LEFT", minus, "RIGHT", 40, 0)

    local function change(dir)
        local lo, hi, step, big = rangeFn()
        local amount = ((IsShiftKeyDown and IsShiftKeyDown()) and big or step) * dir
        setFn(Clamp((getFn() or lo) + amount, lo, hi))
        PHW_RefreshUI()
    end
    minus:SetScript("OnClick", function() change(-1) end)
    plus:SetScript("OnClick", function() change(1) end)

    if tip then
        for _, w in ipairs({ minus, plus }) do
            w:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(tip, 1, 1, 1, 1, true)
            end)
            w:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
    end

    refreshers[#refreshers + 1] = function() valueFS:SetText(tostring(getFn() or "")) end
    st.left, st.right, st.value, st.y = minus, plus, valueFS, y - 28
    return st
end

local function WButton(parent, text, width, point, rel, relPoint, x, y, onClick)
    local b = TryCreate("Button", nil, parent, { "UIPanelButtonTemplate" })
    b:SetSize(width, 22)
    b:SetText(text)
    b:SetPoint(point, rel, relPoint, x, y)
    b:SetScript("OnClick", onClick)
    return b
end

local function WCheck(parent, x, y, text, onClick)
    local c = TryCreate("CheckButton", nil, parent, { "UICheckButtonTemplate" })
    c:SetSize(26, 26)
    c:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    c:SetHitRectInsets(0, -220, 0, 0)
    WLabel(parent, "GameFontNormal", text, x + 30, y - 6)
    c:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
    return c
end

-- Standard game text box (falls back to a plain dark box)
local function WEdit(parent, w, x, y)
    editCounter = editCounter + 1
    local e, tpl = TryCreate("EditBox", "PHW_Edit" .. editCounter, parent, { "InputBoxTemplate" })
    if tpl ~= "InputBoxTemplate" then
        e:SetFont("Fonts\\FRIZQT__.TTF", 12, "")
        e:SetTextInsets(6, 6, 0, 0)
        local bg = e:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(e)
        bg:SetColorTexture(0, 0, 0, 0.6)
        AddBorder(e)
    end
    e:SetAutoFocus(false)
    e:SetSize(w, 22)
    e:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    e:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    e:SetScript("OnEditFocusLost", function() PHW_RefreshUI() end)
    return e
end

-- Redraw every control from the saved settings
function PHW_RefreshUI()
    if not settings or not settings:IsShown() or not PHW_Config then return end
    for _, fn in ipairs(refreshers) do fn() end
end

local function BuildSettings()
    -- Same frame the game's own Options window uses (marble background, gold
    -- border, title bar, bottom button bar), with fallbacks for older clients.
    local win, tpl = TryCreate("Frame", "PHW_SettingsFrame", UIParent,
        { "ButtonFrameTemplateNoPortrait", "ButtonFrameTemplate", "BasicFrameTemplateWithInset", "BackdropTemplate" })
    settings = win
    win:SetSize(700, 540)
    win:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
    win:SetFrameStrata("DIALOG")
    win:SetMovable(true)
    win:SetClampedToScreen(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", function(self) self:StartMoving() end)
    win:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    local isButtonFrame = (tpl == "ButtonFrameTemplateNoPortrait" or tpl == "ButtonFrameTemplate")
    if tpl == "ButtonFrameTemplate" then
        pcall(function()
            if ButtonFrameTemplate_HidePortrait then ButtonFrameTemplate_HidePortrait(win) end
        end)
    end
    if isButtonFrame and win.Inset then
        win.Inset:ClearAllPoints()
        win.Inset:SetPoint("TOPLEFT", win, "TOPLEFT", 4, -26)
        win.Inset:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -6, 28)
    end
    if not isButtonFrame and tpl ~= "BasicFrameTemplateWithInset" then
        -- plain fallback look
        if win.SetBackdrop then
            win:SetBackdrop({
                bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                tile = true, tileSize = 32, edgeSize = 32,
                insets = { left = 8, right = 8, top = 8, bottom = 8 },
            })
        end
        local closeBtn = TryCreate("Button", nil, win, { "UIPanelCloseButton" })
        closeBtn:SetPoint("TOPRIGHT", win, "TOPRIGHT", -4, -4)
    end

    if isButtonFrame and win.SetTitle then
        win:SetTitle("PetHealthWatch Settings")
    else
        local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOP", win, "TOP", 0, -6)
        title:SetText("PetHealthWatch Settings")
    end

    table.insert(UISpecialFrames, "PHW_SettingsFrame")   -- Escape closes it

    -- ===== LEFT COLUMN: the alert =====
    local lx = 20
    local y = -38
    WHeader(win, "How is the alert measured?", lx, y); y = y - 28
    y, UI.measureEntries = WRadioGroup(win, lx, y, {
        { true,  "Percent of max health", "Alerts when health falls to this percent of its maximum." },
        { false, "Raw HP",                "A fixed amount of health instead of a percent." },
    }, function() return PHW_Config.isPercent and true or false end,
       function(v)
           PHW_Config.isPercent = v
           BuildCurves()
       end)

    y = y - 4
    UI.threshStep = WStepper(win, lx, y, "Alert at",
        function()
            if PHW_Config.isPercent then return 1, 100, 1, 10 end
            return 1, 100000, 10, 100
        end,
        function() return PHW_Config.isPercent and PHW_Config.threshPct or PHW_Config.threshVal end,
        function(v)
            if PHW_Config.isPercent then PHW_Config.threshPct = v else PHW_Config.threshVal = v end
            BuildCurves()
        end,
        "Click an arrow for one step; hold Shift for a bigger step.")
    refreshers[#refreshers + 1] = function()
        UI.threshStep.label:SetText(PHW_Config.isPercent and "Alert at (% of health)" or "Alert at (HP)")
    end
    y = UI.threshStep.y - 10

    WHeader(win, "How it looks", lx, y); y = y - 28
    UI.flashStep = WStepper(win, lx, y, "Flash intensity",
        function() return 0, 100, 5, 25 end,
        function() return math.floor((PHW_Config.flashMax or 0.2) * 100 + 0.5) end,
        function(v)
            PHW_Config.flashMax = v / 100
            BuildCurves()
        end,
        "0 turns the screen flash off. Hold Shift for a bigger step.")
    y = UI.flashStep.y
    WLabel(win, "GameFontDisableSmall", "0 turns the screen flash off.", lx + 26, y + 6)
    y = y - 22

    WHeader(win, "Click to cast with", lx, y); y = y - 28
    y, UI.modEntries = WRadioGroup(win, lx, y, {
        { "none",  "No key", "Plain left-click. The invisible button can catch stray clicks." },
        { "shift", "Shift",  "Hold the key while clicking. Removes the invisible click area." },
        { "ctrl",  "Ctrl" },
        { "alt",   "Alt" },
    }, function() return PHW_Config.clickMod or "none" end,
       function(v)
           PHW_Config.clickMod = v
           ApplyMacro()
           if macroPending then say("Click setting will apply when you leave combat.") end
       end)

    -- ===== RIGHT COLUMN: pet death sound =====
    local rx = 350
    local ry = -38
    WHeader(win, "Pet death sound", rx, ry); ry = ry - 28
    UI.deathCheck = WCheck(win, rx - 2, ry, "Play a sound when my pet dies", function(checked)
        PHW_Config.deathSoundOn = checked
    end)
    ry = ry - 28
    UI.nowUsing = WLabel(win, "GameFontHighlightSmall", "", rx + 4, ry)
    ry = ry - 20
    refreshers[#refreshers + 1] = function()
        UI.deathCheck:SetChecked(PHW_Config.deathSoundOn ~= false)
        UI.nowUsing:SetText("Now using: |cff00ff00" .. SoundLabel(tonumber(PHW_Config.deathSound) or 8648) .. "|r")
    end

    local soundItems = {}
    for i, entry in ipairs(PHW_SoundLibrary) do
        soundItems[i] = { entry.value, entry.name .. "   |cff888888" .. tostring(entry.value) .. "|r", hit = 200 }
    end
    local soundEntries
    ry, soundEntries = WRadioGroup(win, rx, ry, soundItems,
        function() return tonumber(PHW_Config.deathSound) end,
        function(v)
            PHW_Config.deathSound = v
            UI.customDirty = false
            PlaySelection(v)
        end)
    UI.rows = {}
    for i, e in ipairs(soundEntries) do
        e.button.value = e.value
        e.button.play = WButton(win, "Play", 54, "TOPLEFT", win, "TOPLEFT", rx + 266, e.y,
            function() PlaySelection(e.value) end)
        UI.rows[i] = e.button
    end

    -- custom sound: radio + ID box + Play. Choosing it = selecting the radio,
    -- or pressing Enter in the box.
    local function ApplyCustom()
        local id = tonumber(UI.customEdit:GetText())
        if id and id > 0 then
            PHW_Config.deathSound = math.floor(id)
            UI.customDirty = false
            PlaySelection(id)
        else
            say("Type a sound ID number in the box first.")
        end
        PHW_RefreshUI()
    end
    UI.customRadio = TryCreate("CheckButton", nil, win, { "UIRadioButtonTemplate", "UICheckButtonTemplate" })
    UI.customRadio:SetSize(22, 22)
    UI.customRadio:SetPoint("TOPLEFT", win, "TOPLEFT", rx, ry)
    UI.customRadio:SetHitRectInsets(0, -76, 0, 0)
    WLabel(win, "GameFontNormal", "Custom ID", rx + 26, ry - 4)
    UI.customRadio:SetScript("OnClick", ApplyCustom)

    UI.customEdit = WEdit(win, 130, rx + 112, ry)
    UI.customEdit:SetScript("OnTextChanged", function(self, user)
        if user then UI.customDirty = true end
    end)
    UI.customEdit:SetScript("OnEnterPressed", function(self)
        ApplyCustom()
        self:ClearFocus()
    end)
    UI.customPlay = WButton(win, "Play", 54, "TOPLEFT", win, "TOPLEFT", rx + 266, ry, function()
        local id = tonumber(UI.customEdit:GetText())
        if id then PlaySelection(id) else say("Type a sound ID number first.") end
    end)
    refreshers[#refreshers + 1] = function()
        local cur = tonumber(PHW_Config.deathSound)
        local inLibrary = false
        for _, row in ipairs(UI.rows) do
            if row.value == cur then inLibrary = true end
        end
        local customActive = (cur ~= nil) and not inLibrary
        UI.customRadio:SetChecked(customActive)
        -- Don't touch the box while the user is typing in it, or after they typed
        -- something (clicking Play takes focus away first, and a redraw here would
        -- wipe their number before the click is processed).
        if not UI.customEdit:HasFocus() and not UI.customDirty then
            UI.customEdit:SetText(customActive and tostring(cur) or "")
        end
    end
    ry = ry - 30

    WLabel(win, "GameFontDisableSmall",
        "Type an ID and press Play to hear it. Select Custom ID (or press Enter) to use it.",
        rx + 4, ry, 320)
    ry = ry - 34

    WLabel(win, "GameFontHighlightSmall", "Find more sound IDs (select and copy the link):", rx + 4, ry)
    ry = ry - 18
    local url = WEdit(win, 320, rx + 2, ry)
    url:SetText(WOWHEAD_URL)
    url:SetCursorPosition(0)
    url:SetScript("OnTextChanged", function(self, user)
        if user then self:SetText(WOWHEAD_URL) end
    end)
    url:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    url:SetScript("OnEditFocusLost", function(self) self:HighlightText(0, 0) end)

    -- ===== BOTTOM =====
    WLabel(win, "GameFontDisableSmall",
        "Tip: click an arrow to change a value, or hold Shift while clicking for a bigger step. Drag the alert button itself to move it.",
        20, -478, 640)

    -- these sit in the frame's bottom bar, like the Close button in the game's Options window
    WButton(win, "Test alert", 100, "BOTTOMLEFT", win, "BOTTOMLEFT", 12, 4, function()
        isTriggered = not isTriggered
    end)
    WButton(win, "Reset button position", 150, "BOTTOMLEFT", win, "BOTTOMLEFT", 118, 4, function()
        if InCombatLockdown() then say("Can't move the button in combat."); return end
        container:ClearAllPoints()
        container:SetPoint("CENTER", UIParent, "CENTER", 0, -100)
        PHW_Config.posX = 0; PHW_Config.posY = -100
    end)
    WButton(win, "Clear dead-pet memory", 160, "BOTTOMLEFT", win, "BOTTOMLEFT", 274, 4, function()
        PHW_Config.deadMemory = false
    end)
    WButton(win, "Reset defaults", 110, "BOTTOMLEFT", win, "BOTTOMLEFT", 440, 4, function()
        -- Settings only: the button position and dead-pet memory are left alone
        for k, v in pairs(PHW_Defaults) do
            if k ~= "posX" and k ~= "posY" and k ~= "deadMemory" then PHW_Config[k] = v end
        end
        UI.customDirty = false
        BuildCurves()
        ApplyMacro()
        PHW_RefreshUI()
    end)
    WButton(win, "Close", 90, "BOTTOMRIGHT", win, "BOTTOMRIGHT", -10, 4, function() win:Hide() end)

    win:SetScript("OnShow", function() PHW_RefreshUI() end)
    win:Hide()
end

function PHW_ToggleSettings()
    if not PHW_Config then
        say("Settings aren't loaded yet; try again in a moment.")
        return
    end
    if not settings then BuildSettings() end
    if settings:IsShown() then
        settings:Hide()
    else
        settings:Show()
    end
end

-- Open the settings window (never closes it)
function PHW_OpenSettings()
    if not PHW_Config then
        say("Settings aren't loaded yet; try again in a moment.")
        return
    end
    if not settings then BuildSettings() end
    if not settings:IsShown() then settings:Show() end
end

-- ---------------------------------------------------------------
-- Entry in the game's Options > AddOns tab. A small info page with a button
-- that opens the settings window. Registration is wrapped in pcall so a
-- different or missing Settings API can never break the addon.
-- ---------------------------------------------------------------
local panelRegistered = false

function PHW_RegisterOptionsPanel()
    if panelRegistered then return end
    panelRegistered = true

    local panel = CreateFrame("Frame", "PHW_OptionsPanel")
    panel.name = "PetHealthWatch"

    local version = ""
    pcall(function()
        local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
        version = getMeta and getMeta(ADDON_NAME, "Version") or ""
    end)

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
    title:SetText("PetHealthWatch " .. version)

    local function paragraph(text, y)
        local fs = MakeLabel(panel, text, 16, y, "GameFontHighlight")
        fs:SetWidth(560)
        fs:SetJustifyH("LEFT")
        return fs
    end

    paragraph("A hunter pet health monitor. When your pet's health drops to your threshold, " ..
        "the screen flashes and a Mend Pet button appears. If your pet dies, the button " ..
        "becomes Revive Pet and a sound of your choice plays.", 52)

    local open = MakeButton(panel, "Open settings", 160, 26)
    open:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -120)
    open:SetScript("OnClick", function()
        -- Close the game's options window first so ours isn't hidden behind it
        pcall(function()
            if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end
        end)
        PHW_OpenSettings()
    end)

    MakeLabel(panel, "Good to know", 16, 166, "GameFontNormal")
    paragraph("Wow Forever hides a pet's current health from addons, so the low-health alert " ..
        "is drawn by the game from a rule. The addon can't see the moment health crosses " ..
        "your threshold, which is why it can't play a sound or flash once at that moment. " ..
        "The sound is for your pet dying.", 190)

    paragraph("Type /phw to open the settings window at any time, or /phw help for the " ..
        "list of commands.", 266)

    pcall(function()
        if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
            local category = Settings.RegisterCanvasLayoutCategory(panel, "PetHealthWatch")
            Settings.RegisterAddOnCategory(category)
        elseif InterfaceOptions_AddCategory then
            InterfaceOptions_AddCategory(panel)
        end
    end)
end

-- 8. Slash Commands
SLASH_PHW1 = "/phw"
local function PHW_Slash(msg)
    if not PHW_Config then return end
    local _, _, cmd, arg = string.find(msg or "", "(%a+)%s*(.*)")
    if cmd == nil or cmd == "config" or cmd == "options" or cmd == "settings" then
        PHW_ToggleSettings()
    elseif cmd == "set" and tonumber(arg) then
        if PHW_Config.isPercent then PHW_Config.threshPct = tonumber(arg) else PHW_Config.threshVal = tonumber(arg) end
        BuildCurves()
        PHW_PrintStatus()
    elseif cmd == "toggle" then
        PHW_Config.isPercent = not PHW_Config.isPercent
        BuildCurves()
        PHW_PrintStatus()
    elseif cmd == "flash" and tonumber(arg) then
        local pct = math.max(0, math.min(100, tonumber(arg)))
        PHW_Config.flashMax = pct / 100
        BuildCurves()
        DEFAULT_CHAT_FRAME:AddMessage("|cffffff00PHW:|r Flash intensity set to " .. pct .. "%")
    elseif cmd == "clickmod" then
        local m = string.lower(arg or "")
        if CLICK_PREFIX[m] then
            PHW_Config.clickMod = m
            ApplyMacro()
            local how = (m == "none") and "plain left-click" or (m .. " + left-click")
            if macroPending then
                DEFAULT_CHAT_FRAME:AddMessage("|cffffff00PHW:|r Button will use " .. how .. " once you leave combat.")
            else
                DEFAULT_CHAT_FRAME:AddMessage("|cffffff00PHW:|r Button now uses " .. how .. ".")
            end
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffffff00PHW:|r Usage: /phw clickmod none|shift|ctrl|alt")
        end
    elseif cmd == "sounds" then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffff00PHW sounds:|r (use a name or any ID with /phw death pick)")
        for _, e in ipairs(PHW_SoundLibrary) do
            DEFAULT_CHAT_FRAME:AddMessage("   " .. e.name .. "  |cff00ff00" .. tostring(e.value) .. "|r")
        end
        DEFAULT_CHAT_FRAME:AddMessage("   Look up more IDs at wowhead.com/classic/sounds")
    elseif cmd == "death" then
        local sub, val = string.match(arg or "", "^(%a+)%s*(.*)$")
        sub = sub and string.lower(sub) or ""
        if sub == "on" then
            PHW_Config.deathSoundOn = true
        elseif sub == "off" then
            PHW_Config.deathSoundOn = false
        elseif sub == "test" then
            PlaySelection(PHW_Config.deathSound)
            return
        elseif sub == "pick" and val ~= "" then
            local chosen
            if tonumber(val) then
                chosen = tonumber(val)
            else
                local e, multi = FindSound(val)
                if e then
                    chosen = e.value
                elseif multi and #multi > 1 then
                    DEFAULT_CHAT_FRAME:AddMessage("|cffffff00PHW:|r More than one sound matches '" .. val .. "':")
                    for _, m in ipairs(multi) do
                        DEFAULT_CHAT_FRAME:AddMessage("   " .. m.name)
                    end
                    return
                else
                    DEFAULT_CHAT_FRAME:AddMessage("|cffffff00PHW:|r No sound named '" .. val .. "'. Use /phw sounds to see the list, or enter a sound ID number.")
                    return
                end
            end
            PHW_Config.deathSound = chosen
            PlaySelection(chosen)
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffffff00PHW:|r Usage: /phw death on|off|test|pick <name|id>")
            return
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cffffff00PHW:|r Death sound is " ..
            (PHW_Config.deathSoundOn and "ON" or "OFF") .. ", playing: " .. SoundLabel(PHW_Config.deathSound))
    elseif cmd == "test" then
        isTriggered = not isTriggered
    elseif cmd == "clear" then
        PHW_Config.deadMemory = false
    elseif cmd == "reset" then
        if InCombatLockdown() then
            DEFAULT_CHAT_FRAME:AddMessage("|cffffff00PHW:|r Can't reset position in combat.")
            return
        end
        container:ClearAllPoints()
        container:SetPoint("CENTER", UIParent, "CENTER", 0, -100)
        PHW_Config.posX = 0; PHW_Config.posY = -100
    elseif cmd == "debug" then
        local hp, max = UnitHealth("pet"), UnitHealthMax("pet")
        DEFAULT_CHAT_FRAME:AddMessage("|cffffff00PHW debug:|r pet health secret = " .. tostring(IsSecret(hp)) ..
            ", max secret = " .. tostring(IsSecret(max)) ..
            ", curves ready = " .. tostring(alertCurve ~= nil) ..
            ", lockdown = " .. tostring(InCombatLockdown() and true or false) ..
            ", affecting combat = " .. tostring(UnitAffectingCombat("player") and true or false))
        local secretNow = "n/a"
        if C_Secrets and C_Secrets.ShouldUnitHealthBeSecret then
            local ok, res = pcall(C_Secrets.ShouldUnitHealthBeSecret, "pet")
            if ok then secretNow = tostring(res) end
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cffffff00PHW debug:|r should pet health be secret = " .. secretNow ..
            ", click mod = " .. tostring(PHW_Config.clickMod) .. ", useOnKeyDown = " .. tostring(frame:GetAttribute("useOnKeyDown")) .. ", click layer shown = " .. tostring(frame:IsShown() and true or false))
        DEFAULT_CHAT_FRAME:AddMessage("|cffffff00PHW macro:|r " .. tostring(frame:GetAttribute((CLICK_PREFIX[PHW_Config.clickMod or "none"] or "") .. "macrotext1")))

    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffffff00PetHealthWatch Commands:|r")
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/phw|r or |cff00ff00/phw config|r - Open the settings window")
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/phw set #|r - Set alert threshold (e.g. 40)")
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/phw toggle|r - Switch between % and raw HP")
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/phw flash #|r - Screen flash intensity 0-100 (default 20, 0 = off)")
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/phw clickmod <none|shift|ctrl|alt>|r - Key to hold while clicking the button")
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/phw sounds|r - List the built-in sound choices")
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/phw death on|off|test|pick <name|id>|r - Sound when the pet dies")
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/phw test|r - Toggle the alert display for testing")
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/phw clear|r - Force clear death memory")
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/phw reset|r - Reset button to center screen")
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/phw debug|r - Show whether pet health is hidden from addons")
        PHW_PrintStatus()
    end
end

SlashCmdList["PHW"] = function(msg)
    PHW_Slash(msg)
    PHW_RefreshUI()
end
