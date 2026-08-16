local addon = Arkana

-- ── Konstanten ────────────────────────────────────────────────────────────────

local BOARD_W, BOARD_H = 1000, 720
local MINION_W, MINION_H = 88, 122   -- Verhältnis passt zu 256×388 Originalformat
local HAND_W,   HAND_H   = 88, 122
-- TGA-Originalformat 256×388, transparent, kein Padding-Crop nötig
local FALLBACK  = "Interface\\AddOns\\Arkana\\Textures\\fallback.tga"
local CARDBACK  = "Interface\\AddOns\\Arkana\\Textures\\card_back.tga"
local TEXTURES  = "Interface\\AddOns\\Arkana\\Textures\\"
local CARD_TEX_V = 388 / 512  -- Kartenrender 256x388, in 256x512 gepaddet

-- Neue Hero-Portraits (Textures\HeroFrames): 330x429 oben links in 512x512 gepaddet
local HEROFRAME_U, HEROFRAME_V = 330 / 512, 429 / 512
local HEROFRAME_IDS = {
    HERO_01 = true, HERO_02 = true, HERO_03 = true, HERO_04 = true, HERO_05 = true,
    HERO_06 = true, HERO_07 = true, HERO_08 = true, HERO_09 = true,
}
-- Hero-Portrait setzen: Helden-Skin (falls gewählt) > HeroFrames-TGA > altes Cards-TGA
local function SetHeroPortrait(tex, heroId, skinPath)
    if skinPath then
        tex:SetTexture(skinPath)
        tex:SetTexCoord(0, HEROFRAME_U, 0, HEROFRAME_V)
    elseif HEROFRAME_IDS[heroId] then
        tex:SetTexture(TEXTURES .. "HeroFrames\\" .. heroId .. ".tga")
        tex:SetTexCoord(0, HEROFRAME_U, 0, HEROFRAME_V)
    else
        tex:SetTexture(TEXTURES .. "Cards\\" .. heroId .. ".tga")
        tex:SetTexCoord(0, 1, 0, CARD_TEX_V)
    end
end

local GB = nil          -- Haupt-Frame
local selected = nil    -- { type="hand"|"minion"|"heropower", idx=..., eid=... }
local turnSecondsLeft = 0
local turnTicker = nil
local entityFrameMap = {}   -- entityId → UI-Frame, nach jedem Board_Update aktuell
local pendingFloats  = {}   -- { eid, text, r, g, b } — vom Engine-Callback gesammelt
local logBuffer      = {}   -- alle Spiellog-Einträge, persistiert auch wenn Fenster geschlossen

-- Animation states
local pendingPlayAnimation = nil
local animatingEntities = {}
local pendingSummonPops = {}  -- entityIds von Secret-Beschwörungen, die beim nächsten Board_Update einen Pop-Puls bekommen sollen
local animatingControlEntities = {}
local spellAnimating = false
local attackAnimating = false
local delayedFloats = {}

local activeTooltipType = nil   -- "minion"|"playerhero"|"enemyhero"|"heropower"
local activeTooltipFrame = nil
local activeTooltipData = nil
local playerDisplayBoard = {}
local enemyDisplayBoard = {}
local prevHandEntityIds = nil   -- nil = nicht initialisiert (erste Anzeige nicht animieren)
local prevEnemyHandEntityIds = nil
local prevManaState = nil       -- nil = nicht initialisiert (erste Anzeige nicht animieren)

-- Führt das Engine-Brett ins Anzeige-Brett; sterbende Diener bleiben 1 s auf ihrem Platz.
local function UpdateDisplayBoard(display, engineBoard)
    local alive = {}
    for _, m in ipairs(engineBoard) do alive[m.entityId] = true end

    local engineMap = {}
    for i, m in ipairs(engineBoard) do
        engineMap[m.entityId] = { m = m, index = i }
    end

    -- Verwandlung/Hex: der neue Diener trägt transformedFrom = alte entityId →
    -- Display-Item IN PLACE ersetzen (kein Sterbe-/Beschwör-Ablauf, direkter Tausch)
    local transformMap = {}
    for _, m in ipairs(engineBoard) do
        if m.transformedFrom then transformMap[m.transformedFrom] = m end
    end

    local newDisplay = {}
    local matchedAlive = {}

    -- Process previous display board items to keep their layout order intact
    for _, item in ipairs(display) do
        local eid = item.m.entityId
        local engineItem = engineMap[eid]

        local tm = transformMap[eid]
        if not engineItem and tm and not matchedAlive[tm.entityId] then
            item.m = tm
            item.isDying = false
            item.removeNext = nil
            item.deathAnimStarted = nil
            table.insert(newDisplay, item)
            matchedAlive[tm.entityId] = true
        elseif engineItem then
            -- Still alive: update state data, reset dying flags
            item.m = engineItem.m
            item.isDying = false
            item.removeNext = nil
            item.deathAnimStarted = nil
            table.insert(newDisplay, item)
            matchedAlive[eid] = true
        else
            -- Not alive in engine: dying or just died
            if item.isDying then
                if not item.removeNext then
                    table.insert(newDisplay, item)
                end
            else
                -- Just died: start 1s grace period, keep in place
                item.isDying = true
                item.removeNext = nil
                table.insert(newDisplay, item)
                local ref = item
                local function graceRemove()
                    -- Solange eine Zauber-Kette läuft (z.B. Arkane Geschosse), Item
                    -- behalten — Folge-Geschosse brauchen den Frame noch als Ziel
                    if spellAnimating then
                        C_Timer.After(0.5, graceRemove)
                        return
                    end
                    ref.removeNext = true
                    addon:Board_Update()
                end
                C_Timer.After(1.0, graceRemove)
            end
        end
    end

    -- Insert new/summoned minions that were not in display previously
    for i, m in ipairs(engineBoard) do
        if not matchedAlive[m.entityId] then
            local insertIndex = nil
            for j = i + 1, #engineBoard do
                local nextEid = engineBoard[j].entityId
                for k, ndItem in ipairs(newDisplay) do
                    if ndItem.m.entityId == nextEid then
                        insertIndex = k
                        break
                    end
                end
                if insertIndex then break end
            end

            local newItem = { m = m, isDying = false }
            if insertIndex then
                table.insert(newDisplay, insertIndex, newItem)
            else
                table.insert(newDisplay, newItem)
            end
        end
    end

    return newDisplay
end

local function StopTurnTicker()
    if turnTicker then
        turnTicker:Cancel()
        turnTicker = nil
    end
end

local function StartTurnTicker()
    StopTurnTicker()
    if addon.GE_IsSandbox and addon:GE_IsSandbox() then
        if GB and GB.timerText then
            GB.timerText:SetText("Sandbox")
            GB.timerText:SetTextColor(0.72, 0.42, 1)
        end
        return
    end
    turnSecondsLeft = 90
    if GB and GB.timerText then
        GB.timerText:SetText("" ..  turnSecondsLeft .. "s")
        GB.timerText:SetTextColor(1, 0.8, 0.2)
    end
    turnTicker = C_Timer.NewTicker(1, function()
        if turnSecondsLeft > 0 then
            turnSecondsLeft = turnSecondsLeft - 1
            if GB and GB.timerText then
                GB.timerText:SetText("" ..  turnSecondsLeft .. "s")
                if turnSecondsLeft <= 15 then
                    GB.timerText:SetTextColor(1, 0.2, 0.2)
                else
                    GB.timerText:SetTextColor(1, 0.8, 0.2)
                end
            end
        else
            StopTurnTicker()
        end
    end)
end

local function CD(id)
    if id == "NEW1_031a" then id = "NEW1_034"
    elseif id == "NEW1_031b" then id = "NEW1_032"
    elseif id == "NEW1_031c" then id = "NEW1_033"
    end
    return ARKANA_CardData and ARKANA_CardData[id] or nil
end

-- ── Farb-Helfer ───────────────────────────────────────────────────────────────

local function SetBG(tex, r, g, b, a) tex:SetColorTexture(r, g, b, a or 1) end

-- ── Mini-Karten-Frame (Hand + Brett) ─────────────────────────────────────────

local function MakeCardFrame(parent, w, h)
    local f = CreateFrame("Button", nil, parent)
    f:SetSize(w, h)

    -- Kartenrahmen als OVERLAY (über dem Portrait), damit kein Ghost-Doppelrahmen entsteht
    local frame = f:CreateTexture(nil, "OVERLAY")
    frame:SetAllPoints()
    f.frame = frame

    -- Karten-Textur füllt den gesamten Frame (der Render enthält alle Infos)
    local art = f:CreateTexture(nil, "ARTWORK")
    art:SetAllPoints()
    f.art = art

    -- Dummy-Felder für Kompatibilität mit FillMinionSlot / FillHandSlot
    -- Mana-Kristall hinter der Kostenziffer
    local manaGem = CreateFrame("Frame", nil, f)
    manaGem:SetSize(38, 38)          -- Größe hier anpassen
    manaGem:SetPoint("TOPLEFT", 3, -8.5)  -- Position hier anpassen
    manaGem:SetFrameLevel(f:GetFrameLevel() + 2)
    manaGem:EnableMouse(false)
    local manaBg = manaGem:CreateTexture(nil, "BACKGROUND")
    manaBg:SetAllPoints()
    manaBg:SetTexture("Interface\\AddOns\\Arkana\\Textures\\Frames\\cost-mana.tga")
    f.manaGem = manaGem

    f.costText  = manaGem:CreateFontString(nil, "OVERLAY")
    f.costText:SetFont("Fonts\\FRIZQT__.TTF", 16, "THICKOUTLINE")
    f.costText:SetPoint("TOPLEFT", manaGem, "TOPLEFT", 3.5, -2.5)
    f.nameText  = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.statsText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")

    -- ATK: TGA-Hintergrund + Zahl
    local atkGem = CreateFrame("Frame", nil, f)
    atkGem:SetSize(38, 38)
    atkGem:SetPoint("BOTTOMLEFT", 2, -0.5)
    atkGem:SetFrameLevel(f:GetFrameLevel() + 6)
    atkGem:EnableMouse(false)
    local atkBg = atkGem:CreateTexture(nil, "BACKGROUND")
    atkBg:SetAllPoints()
    atkBg:SetTexture("Interface\\AddOns\\Arkana\\Textures\\Frames\\attack-minion.tga")
    atkBg:SetTexCoord(0, 1, 0, 1)
    atkGem:Hide()
    f.atkGem = atkGem

    local atk = atkGem:CreateFontString(nil, "OVERLAY")
    atk:SetPoint("CENTER", atkGem, "CENTER", -6, 2)
    atk:SetFont("Fonts\\FRIZQT__.TTF", 14, "THICKOUTLINE")
    atk:SetTextColor(1, 1, 1)
    f.atkText = atk

    -- HP: TGA-Hintergrund + Zahl
    local hpGem = CreateFrame("Frame", nil, f)
    hpGem:SetSize(20, 34)
    hpGem:SetPoint("BOTTOMRIGHT", -4, 0)
    hpGem:SetFrameLevel(f:GetFrameLevel() + 6)
    hpGem:EnableMouse(false)
    local hpBg = hpGem:CreateTexture(nil, "BACKGROUND")
    hpBg:SetAllPoints()
    hpBg:SetTexture("Interface\\AddOns\\Arkana\\Textures\\Frames\\health.tga")
    hpBg:SetTexCoord(0, 1, 0, 1)
    hpGem:Hide()
    f.hpGem = hpGem

    local hp = hpGem:CreateFontString(nil, "OVERLAY")
    hp:SetPoint("CENTER", hpGem, "CENTER", -0.5, 3.5)
    hp:SetFont("Fonts\\FRIZQT__.TTF", 14, "THICKOUTLINE")
    hp:SetTextColor(1, 1, 1)
    f.hpText = hp

    -- "Verstummt"-Label für stille Diener
    local silenced = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    silenced:SetPoint("TOP", 0, -4)
    silenced:SetText("|cffaaaaaaVerstummt|r")
    silenced:Hide()
    f.silencedText = silenced

    -- Highlight-Overlay (selektiert / angreifbar)
    local hl = f:CreateTexture(nil, "OVERLAY")
    hl:SetAllPoints(); hl:SetColorTexture(1, 1, 0, 0.35); hl:Hide()
    f.highlight = hl

    -- Schlaf-Overlay
    local sleep = f:CreateTexture(nil, "OVERLAY")
    sleep:SetAllPoints(); sleep:SetColorTexture(0.1, 0.1, 0.1, 0.55); sleep:Hide()
    f.sleepOverlay = sleep

    -- Frozen-Overlay (Eis-Tint + eisblauer Rahmen + Text)
    local frozen = CreateFrame("Frame", nil, f)
    frozen:SetAllPoints()
    frozen:SetFrameLevel(f:GetFrameLevel() + 5)
    frozen:EnableMouse(false)
    frozen:Hide()
    f.frozenOverlay = frozen

    local frozenBg = frozen:CreateTexture(nil, "ARTWORK")
    frozenBg:SetAllPoints()
    frozenBg:SetTexture("Interface\\AddOns\\Arkana\\Textures\\frozen_frame.tga")
    frozenBg:SetTexCoord(0, 1, 0, CARD_TEX_V)

    local frozenText = frozen:CreateFontString(nil, "OVERLAY", "GameFontNormalOutline")
    frozenText:SetPoint("CENTER", f, "CENTER", 0, 0)
    frozenText:SetText("|cff66ccffEingefroren|r")
    frozenText:Hide()
    f.frozenText = frozenText

    -- Spott-Overlay (leicht lila hinterlegt)
    local taunt = f:CreateTexture(nil, "OVERLAY")
    taunt:SetAllPoints(); taunt:SetColorTexture(0.45, 0.1, 0.75, 0.43); taunt:Hide()
    f.tauntOverlay = taunt

    local tauntText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalOutline")
    tauntText:SetPoint("CENTER", f, "CENTER", 0, 0)
    tauntText:SetText("|cffd070ffSpott|r")
    tauntText:Hide()
    f.tauntText = tauntText

    -- Divine Shield-Overlay Frame (Erstellt einen separaten Frame ganz oben, um alle Elemente/Zahlen zu überlagern)
    local dsFrame = CreateFrame("Frame", nil, f)
    dsFrame:SetAllPoints(f)
    dsFrame:SetFrameLevel(f:GetFrameLevel() + 10)
    dsFrame:Hide()
    f.divineShieldOverlay = dsFrame

    local ds = dsFrame:CreateTexture(nil, "OVERLAY")
    ds:SetTexture("Interface\\AddOns\\Arkana\\Textures\\divine_shield.tga")
    ds:SetPoint("TOPLEFT", dsFrame, "TOPLEFT", -6, 6)
    ds:SetPoint("BOTTOMRIGHT", dsFrame, "BOTTOMRIGHT", 6, -6)

    -- Pulsierungs-Animationen auf der GPU (absolut lagg-frei)
    local dsGroup = ds:CreateAnimationGroup()
    dsGroup:SetLooping("REPEAT")
    
    local dsAlpha1 = dsGroup:CreateAnimation("Alpha")
    dsAlpha1:SetFromAlpha(0.60)
    dsAlpha1:SetToAlpha(0.95)
    dsAlpha1:SetDuration(1.8)
    dsAlpha1:SetSmoothing("IN_OUT")
    dsAlpha1:SetOrder(1)
    
    local dsAlpha2 = dsGroup:CreateAnimation("Alpha")
    dsAlpha2:SetFromAlpha(0.95)
    dsAlpha2:SetToAlpha(0.60)
    dsAlpha2:SetDuration(1.8)
    dsAlpha2:SetSmoothing("IN_OUT")
    dsAlpha2:SetOrder(2)
    
    dsGroup:Play()
    f.divineShieldAnim = dsGroup

    local dsText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalOutline")
    dsText:SetPoint("CENTER", f, "CENTER", 0, 0)
    dsText:SetText("|cff88ddffGottesschild|r")
    dsText:Hide()
    f.divineShieldText = dsText

    -- Windfury-Overlay (türkiser Rahmen + Text)
    local wf = CreateFrame("Frame", nil, f)
    wf:SetAllPoints()
    wf:SetFrameLevel(f:GetFrameLevel() + 4)
    wf:EnableMouse(false)
    wf:Hide()
    f.windfuryOverlay = wf

    local wft = wf:CreateTexture(nil, "OVERLAY")
    wft:SetHeight(2); wft:SetPoint("TOPLEFT"); wft:SetPoint("TOPRIGHT"); wft:SetColorTexture(0, 0.9, 0.9, 0.8)
    local wfb = wf:CreateTexture(nil, "OVERLAY")
    wfb:SetHeight(2); wfb:SetPoint("BOTTOMLEFT"); wfb:SetPoint("BOTTOMRIGHT"); wfb:SetColorTexture(0, 0.9, 0.9, 0.8)
    local wfl = wf:CreateTexture(nil, "OVERLAY")
    wfl:SetWidth(2); wfl:SetPoint("TOPLEFT"); wfl:SetPoint("BOTTOMLEFT"); wfl:SetColorTexture(0, 0.9, 0.9, 0.8)
    local wfr = wf:CreateTexture(nil, "OVERLAY")
    wfr:SetWidth(2); wfr:SetPoint("TOPRIGHT"); wfr:SetPoint("BOTTOMRIGHT"); wfr:SetColorTexture(0, 0.9, 0.9, 0.8)

    local wfText = wf:CreateFontString(nil, "OVERLAY", "GameFontNormalOutline")
    wfText:SetPoint("CENTER", f, "CENTER", 0, 0)
    wfText:SetText("|cff00e6e6Windzorn|r")
    wfText:Hide()
    f.windfuryText = wfText

    -- Stealth-Overlay (dunkelgrauer Rahmen + Text)
    local stealth = CreateFrame("Frame", nil, f)
    stealth:SetAllPoints()
    stealth:SetFrameLevel(f:GetFrameLevel() + 5)
    stealth:EnableMouse(false)
    stealth:Hide()
    f.stealthOverlay = stealth

    local stt = stealth:CreateTexture(nil, "OVERLAY")
    stt:SetHeight(2); stt:SetPoint("TOPLEFT"); stt:SetPoint("TOPRIGHT"); stt:SetColorTexture(0.1, 0.1, 0.1, 0.85)
    local stb = stealth:CreateTexture(nil, "OVERLAY")
    stb:SetHeight(2); stb:SetPoint("BOTTOMLEFT"); stb:SetPoint("BOTTOMRIGHT"); stb:SetColorTexture(0.1, 0.1, 0.1, 0.85)
    local stl = stealth:CreateTexture(nil, "OVERLAY")
    stl:SetWidth(2); stl:SetPoint("TOPLEFT"); stl:SetPoint("BOTTOMLEFT"); stl:SetColorTexture(0.1, 0.1, 0.1, 0.85)
    local str = stealth:CreateTexture(nil, "OVERLAY")
    str:SetWidth(2); str:SetPoint("TOPRIGHT"); str:SetPoint("BOTTOMRIGHT"); str:SetColorTexture(0.1, 0.1, 0.1, 0.85)

    local stealthText = stealth:CreateFontString(nil, "OVERLAY", "GameFontNormalOutline")
    stealthText:SetPoint("CENTER", f, "CENTER", 0, 0)
    stealthText:SetText("|cff888888Verstohlenheit|r")
    stealthText:Hide()
    f.stealthText = stealthText

    -- Todesröcheln-Text
    local drText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalOutline")
    drText:SetPoint("CENTER", f, "CENTER", 0, 0)
    drText:SetText("|cffaa8800Todesröcheln|r")
    drText:Hide()
    f.drText = drText

    -- Immunität-Overlay (weißer Rahmen + Text)
    local imm = CreateFrame("Frame", nil, f)
    imm:SetAllPoints()
    imm:SetFrameLevel(f:GetFrameLevel() + 5)
    imm:EnableMouse(false)
    imm:Hide()
    f.immuneOverlay = imm
    local imt = imm:CreateTexture(nil, "OVERLAY")
    imt:SetHeight(2); imt:SetPoint("TOPLEFT"); imt:SetPoint("TOPRIGHT"); imt:SetColorTexture(1, 1, 1, 0.9)
    local imb = imm:CreateTexture(nil, "OVERLAY")
    imb:SetHeight(2); imb:SetPoint("BOTTOMLEFT"); imb:SetPoint("BOTTOMRIGHT"); imb:SetColorTexture(1, 1, 1, 0.9)
    local iml = imm:CreateTexture(nil, "OVERLAY")
    iml:SetWidth(2); iml:SetPoint("TOPLEFT"); iml:SetPoint("BOTTOMLEFT"); iml:SetColorTexture(1, 1, 1, 0.9)
    local imr = imm:CreateTexture(nil, "OVERLAY")
    imr:SetWidth(2); imr:SetPoint("TOPRIGHT"); imr:SetPoint("BOTTOMRIGHT"); imr:SetColorTexture(1, 1, 1, 0.9)
    local immText = imm:CreateFontString(nil, "OVERLAY", "GameFontNormalOutline")
    immText:SetPoint("CENTER", f, "CENTER", 0, 0)
    immText:SetText("|cffffffffImmunität|r")
    immText:Hide()
    f.immuneText = immText

    -- Border-System erstellen (4 feine Linientexturen an den Kanten)
    local border = {}
    local thickness = 2
    
    local bt = f:CreateTexture(nil, "OVERLAY")
    bt:SetHeight(thickness)
    bt:SetBlendMode("ADD")
    bt:SetPoint("TOPLEFT"); bt:SetPoint("TOPRIGHT")
    border.top = bt
    
    local bb = f:CreateTexture(nil, "OVERLAY")
    bb:SetHeight(thickness)
    bb:SetBlendMode("ADD")
    bb:SetPoint("BOTTOMLEFT"); bb:SetPoint("BOTTOMRIGHT")
    border.bottom = bb
    
    local bl = f:CreateTexture(nil, "OVERLAY")
    bl:SetWidth(thickness)
    bl:SetBlendMode("ADD")
    bl:SetPoint("TOPLEFT"); bl:SetPoint("BOTTOMLEFT")
    border.left = bl
    
    local br = f:CreateTexture(nil, "OVERLAY")
    br:SetWidth(thickness)
    br:SetBlendMode("ADD")
    br:SetPoint("TOPRIGHT"); br:SetPoint("BOTTOMRIGHT")
    border.right = br
    
    function border:SetColor(r, g, b, a)
        self.top:SetColorTexture(r, g, b, a or 1)
        self.bottom:SetColorTexture(r, g, b, a or 1)
        self.left:SetColorTexture(r, g, b, a or 1)
        self.right:SetColorTexture(r, g, b, a or 1)
    end
    
    function border:Show()
        self.top:Show(); self.bottom:Show(); self.left:Show(); self.right:Show()
    end
    
    function border:Hide()
        self.top:Hide(); self.bottom:Hide(); self.left:Hide(); self.right:Hide()
    end
    
    f.cardBorder = border
    border:Hide()

    -- Attack Glow (Schwert-Symbol) — eigener Frame bei +5, über windfuryOverlay (+4)
    local glowFrame = CreateFrame("Frame", nil, f)
    glowFrame:SetAllPoints(f)
    glowFrame:SetFrameLevel(f:GetFrameLevel() + 5)
    local attackGlow = glowFrame:CreateTexture(nil, "ARTWORK")
    attackGlow:SetTexture("Interface\\AddOns\\Arkana\\Textures\\Frames\\attack-weapon-premium.tga")
    attackGlow:SetSize(32, 32)
    attackGlow:SetPoint("TOPLEFT", f, "TOPLEFT", -6, 6)
    attackGlow:Hide()
    f.attackGlow = attackGlow

    f:Hide()
    return f
end

-- ── Hero-Frame ────────────────────────────────────────────────────────────────

local FRAMES = "Interface\\AddOns\\Arkana\\Textures\\Frames\\"

local function MakeHeroFrame(parent, isEnemy)
    local f = CreateFrame("Button", nil, parent)
    f.isHero = true
    -- 132×200 = 20% schmaler, Seitenverhältnis 132:200 ≈ 256:388 (CARD_TEX_V-Bereich) → kein Quetschen
    f:SetSize(140.4, 174.6)

    -- Portrait füllt den gesamten Rahmen ohne Quetschen
    local portrait = f:CreateTexture(nil, "ARTWORK")
    portrait:SetAllPoints()
    portrait:SetTexture(FALLBACK)
    portrait:SetTexCoord(0, 1, 0, CARD_TEX_V)
    f.portrait = portrait

    -- HP-Gem: health-premium.tga (128x256, Tropfen belegt Zeilen 0–164)
    local hpGem = CreateFrame("Frame", nil, f)
    hpGem:SetSize(33, 43)  -- 38 × 164/128 ≈ 48 → Ausschnitt bleibt proportional
    hpGem:SetPoint("CENTER", f, "BOTTOM", 50, 65)
    hpGem:SetFrameLevel(f:GetFrameLevel() + 3)
    hpGem:EnableMouse(false)
    local hpBg = hpGem:CreateTexture(nil, "BACKGROUND")
    hpBg:SetAllPoints()
    hpBg:SetTexture(FRAMES .. "health-premium.tga")
    hpBg:SetTexCoord(0, 1, 0, 164/256)  -- ganzer Tropfen (vorher 0.5 → Spitze abgeschnitten)
    f.hpGem = hpGem

    local hp = hpGem:CreateFontString(nil, "OVERLAY")
    hp:SetPoint("CENTER", hpGem, "CENTER", -2, -8)
    hp:SetJustifyH("CENTER")
    hp:SetFont("Fonts\\FRIZQT__.TTF", 20, "THICKOUTLINE")
    hp:SetTextColor(1, 1, 1, 1)
    f.hpText = hp

    -- Armor-Gem: armor.tga (128x256 → obere Hälfte = 128x128 = Schild)
    local armorGem = CreateFrame("Frame", nil, f)
    armorGem:SetSize(44, 44)
    armorGem:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    armorGem:SetFrameLevel(f:GetFrameLevel() + 3)
    armorGem:EnableMouse(false)
    local armorBg = armorGem:CreateTexture(nil, "BACKGROUND")
    armorBg:SetAllPoints()
    armorBg:SetTexture(FRAMES .. "armor.tga")
    armorBg:SetTexCoord(0, 1, 0, 0.5)
    armorGem:Hide()
    f.armorGem = armorGem

    local armor = armorGem:CreateFontString(nil, "OVERLAY")
    armor:SetPoint("CENTER", armorGem, "CENTER", 0, 0)
    armor:SetJustifyH("CENTER")
    armor:SetFont("Fonts\\FRIZQT__.TTF", 20, "THICKOUTLINE")
    armor:SetTextColor(1, 1, 1, 1)
    armor:Hide()
    f.armorText = armor

    -- Waffen-ATK Gem (attack-weapon-premium.tga, 256x256)
    local weaponAtkGem = CreateFrame("Frame", nil, f)
    weaponAtkGem:SetSize(70, 70)
    if isEnemy then
        weaponAtkGem:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10.5, 74)
    else
        weaponAtkGem:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10.5, 74)
    end
    weaponAtkGem:SetFrameLevel(f:GetFrameLevel() + 2)
    weaponAtkGem:EnableMouse(false)
    local weaponAtkBg = weaponAtkGem:CreateTexture(nil, "BACKGROUND")
    weaponAtkBg:SetAllPoints()
    weaponAtkBg:SetTexture(FRAMES .. "attack-weapon-premium.tga")
    weaponAtkGem:Hide()
    f.weaponAtkGem = weaponAtkGem
    local atkNum = weaponAtkGem:CreateFontString(nil, "OVERLAY")
    atkNum:SetPoint("CENTER", weaponAtkGem, "CENTER", -14, 14)
    atkNum:SetFont("Fonts\\FRIZQT__.TTF", 24, "THICKOUTLINE")
    atkNum:SetTextColor(1, 1, 1)
    f.atkText = atkNum

    -- Waffen-Haltbarkeit Gem (durability-premium.tga, 128x256 → obere Hälfte)
    local weaponDurGem = CreateFrame("Frame", nil, f)
    weaponDurGem:SetSize(32, 32)
    if isEnemy then
        weaponDurGem:SetPoint("CENTER", weaponAtkGem, "CENTER", -14, -20)
    else
        weaponDurGem:SetPoint("CENTER", weaponAtkGem, "CENTER", -14, -20)
    end
    weaponDurGem:SetFrameLevel(f:GetFrameLevel() + 2)
    weaponDurGem:EnableMouse(false)
    local weaponDurBg = weaponDurGem:CreateTexture(nil, "BACKGROUND")
    weaponDurBg:SetAllPoints()
    weaponDurBg:SetTexture(FRAMES .. "durability-premium.tga")
    weaponDurBg:SetTexCoord(0, 1, 0, 0.5)
    weaponDurGem:Hide()
    f.weaponDurGem = weaponDurGem
    local durNum = weaponDurGem:CreateFontString(nil, "OVERLAY")
    durNum:SetPoint("CENTER", weaponDurGem, "CENTER", 0, 0)
    durNum:SetFont("Fonts\\FRIZQT__.TTF", 24, "THICKOUTLINE")
    durNum:SetTextColor(1, 1, 1)
    f.weaponText = durNum

    -- Highlight-Overlay (Zielauswahl)
    local hl = f:CreateTexture(nil, "OVERLAY")
    hl:SetAllPoints(); hl:SetColorTexture(1, 0.3, 0, 0.35); hl:Hide()
    f.highlight = hl

    -- Frozen-Overlay für Helden (Portrait-Tint)
    local frozen = f:CreateTexture(nil, "OVERLAY")
    frozen:SetAllPoints(portrait)
    frozen:SetTexture("Interface\\AddOns\\Arkana\\Textures\\HeroIcedFrame.tga")
    frozen:SetTexCoord(0, HEROFRAME_U, 0, HEROFRAME_V)
    frozen:Hide()
    f.frozenOverlay = frozen

    -- Ice Block Overlay für Helden (Eisblock-Frame) — eigener Träger-Frame mit
    -- hohem FrameLevel, damit er auch beim Gegner über Handkarten/Icons liegt
    local frozenInsetX = 10
    local frozenInsetY = 10
    local frozenOffsetY = 5
    local ibf = CreateFrame("Frame", nil, f)
    ibf:SetPoint("TOPLEFT", portrait, "TOPLEFT", frozenInsetX, -frozenInsetY - frozenOffsetY)
    ibf:SetPoint("BOTTOMRIGHT", portrait, "BOTTOMRIGHT", -frozenInsetX, frozenInsetY - frozenOffsetY)
    ibf:SetFrameLevel(f:GetFrameLevel() + 15)
    ibf:EnableMouse(false)
    ibf:Hide()
    local iceBlock = ibf:CreateTexture(nil, "OVERLAY")
    iceBlock:SetAllPoints()
    iceBlock:SetTexture("Interface\\AddOns\\Arkana\\Textures\\ice_block.tga")
    -- Bildinhalt liegt oben links (ca. 330x429 im Hero-Frame-Layout) — volle
    -- Breite (0..1) würde das Eis nach links verschieben und quetschen
    iceBlock:SetTexCoord(0, HEROFRAME_U, 0, HEROFRAME_V)
    f.iceBlockOverlay = ibf

    -- Gelber Schein: Held kann noch angreifen — Silhouette des Portraits selbst,
    -- gelb eingefärbt und leicht vergrößert hinter dem Portrait (BORDER < ARTWORK).
    -- Textur wird in Board_Update via SetHeroPortrait gesetzt (gleiche wie Portrait).
    local GLOW_GROW = 10                                    -- px über den Portrait-Rand hinaus
    local canAtkGlow = f:CreateTexture(nil, "BORDER")
    canAtkGlow:SetPoint("TOPLEFT", portrait, "TOPLEFT", -GLOW_GROW, GLOW_GROW)
    canAtkGlow:SetPoint("BOTTOMRIGHT", portrait, "BOTTOMRIGHT", GLOW_GROW, -GLOW_GROW)
    canAtkGlow:SetDesaturated(true)
    canAtkGlow:SetVertexColor(1, 0.7, 0, 1)            -- Farbe + Alpha
    canAtkGlow:Hide()
    f.canAttackGlow = canAtkGlow

    -- Gleicher Schein hinter dem HP-Gem (Tropfen-Silhouette, unter hpBg)
    local GEM_GROW = 3                                     -- Überstand oben/unten
    local GEM_GROW_RIGHT = 7                               -- Überstand rechts (kräftiger)
    local gemGlow = hpGem:CreateTexture(nil, "BACKGROUND", nil, -1)
    gemGlow:SetPoint("TOPLEFT", hpGem, "TOPLEFT", 0, GEM_GROW)          -- links bündig
    gemGlow:SetPoint("BOTTOMRIGHT", hpGem, "BOTTOMRIGHT", GEM_GROW_RIGHT, -GEM_GROW)
    gemGlow:SetTexture(FRAMES .. "health-premium.tga")
    gemGlow:SetTexCoord(0, 1, 0, 164/256)
    gemGlow:SetDesaturated(true)
    gemGlow:SetVertexColor(1, 0.7, 0, 1)                -- wie canAtkGlow
    gemGlow:Hide()
    f.canAttackGlowGem = gemGlow

    f:Hide()
    return f
end

-- ── Deck-Stapel-Funktionen ───────────────────────────────────────────────────

local function MakeDeckStack(parent, xOffset, yOffset, flip)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(60, 82)
    container:SetPoint("RIGHT", parent, "RIGHT", xOffset, yOffset)

    -- 4 gestapelte Karten (von hinten nach vorne)
    local dir = flip and -1 or 1
    local cards = {}
    for i = 4, 1, -1 do
        local c = CreateFrame("Frame", nil, container)
        c:SetSize(50, 72)
        c:SetPoint("CENTER", container, "CENTER", dir*(i-2.5)*3, -(i-2.5)*2)  -- leicht versetzt
        local bg = c:CreateTexture(nil, "ARTWORK")
        bg:SetAllPoints()
        bg:SetTexture(CARDBACK)
        bg:SetTexCoord(0, 1, 0, CARD_TEX_V)
        c.back = bg   -- für Kartenrücken-Skins nachträglich umskinbar (Board_Update)
        cards[i] = c
    end
    container.cards = cards

    -- Overlay-Frame mit höherem FrameLevel, damit Texte über den Karten-Frames liegen
    local overlayF = CreateFrame("Frame", nil, container)
    overlayF:SetAllPoints()
    overlayF:SetFrameLevel(container:GetFrameLevel() + 10)

    -- Zahl (Anzahl Karten) auf vorderer Karte
    local countTxt = overlayF:CreateFontString(nil, "OVERLAY")
    countTxt:SetPoint("CENTER", overlayF, "CENTER", 4, -3)
    countTxt:SetFont("Fonts\\FRIZQT__.TTF", 18, "OUTLINE")
    countTxt:SetTextColor(1, 1, 1)
    container.countTxt = countTxt

    -- Totenkopf-Overlay (bei 0 Karten)
    local skull = overlayF:CreateFontString(nil, "OVERLAY")
    skull:SetPoint("CENTER", overlayF, "CENTER", 0, 0)
    skull:SetFont("Fonts\\FRIZQT__.TTF", 28, "OUTLINE")
    skull:SetText("|cffaaaaaa☠|r")
    skull:Hide()
    container.skull = skull

    return container
end

local function UpdateDeckStack(widget, count)
    if not widget then return end
    local cards = widget.cards
    if count == 0 then
        for i = 1, 4 do if cards[i] then cards[i]:Hide() end end
        widget.countTxt:SetText("")
        widget.skull:Show()
    else
        widget.skull:Hide()
        widget.countTxt:SetText(count)
        local visible = math.min(count, 4)
        for i = 1, 4 do
            if cards[i] then
                cards[i]:SetShown(i <= visible)
            end
        end
    end
end

-- ── Board erstellen ───────────────────────────────────────────────────────────
-- Forward-Declaration: ClearHighlights wird erst nach BuildBoard definiert,
-- muss aber im Cancel-Button-Callback als Upvalue sichtbar sein.
local ClearHighlights
-- ShowHeroPowerTooltip wird erst nach BuildBoard definiert, aber der Gegner-
-- Heldenfähigkeit-Button (in BuildBoard) referenziert sie im OnEnter → als Upvalue
-- forward-deklarieren, sonst sieht der Closure die (nicht existente) globale Funktion.
local ShowHeroPowerTooltip

local function BuildBoard()
    if ARKANA_CardData then
        if not ARKANA_CardData["ROGUE_DAGGER"] then
            ARKANA_CardData["ROGUE_DAGGER"] = {
                id = "ROGUE_DAGGER", name = "Dolch", cost = 1, type = "WEAPON",
                class = "ROGUE", attack = 1, health = 2, rarity = "COMMON",
                targetType = "NONE", targetCondition = "NONE", collectible = false
            }
        end
        if not ARKANA_CardData["EX1_323w"] then
            ARKANA_CardData["EX1_323w"] = {
                id = "EX1_323w", name = "Blutswut", cost = 3, type = "WEAPON",
                class = "WARLOCK", attack = 3, health = 8, rarity = "COMMON",
                targetType = "NONE", targetCondition = "NONE", collectible = false
            }
        end
    end

    local f = CreateFrame("Frame", "ARKANA_GameBoard", UIParent)
    f:SetSize(BOARD_W, BOARD_H)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    -- Basis-Level 40: Karten/Diener/Chrome liegen ab hier aufwärts. Der
    -- Hintergrund wandert auf einen Level-2-Träger (unten) — das Band 3..39
    -- dazwischen gehört der Szenerie-Deko des M2-Editors (über dem Brett-
    -- Hintergrund, unter allem Spielgeschehen). Alle Kind-Level sind relativ
    -- zu f, verschieben sich also einfach mit.
    f:SetFrameLevel(40)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    -- Brett-Skalierung (z.B. für 4K-Monitore): SetScale auf dem Board-Frame
    -- skaliert alle Kinder (Diener, Hand, Helden, Buttons) automatisch mit.
    -- Einstellbar über Rechtsklick auf den Minimap-Button → "Skalierung".
    f:SetScale(ARKANA_Settings and ARKANA_Settings.boardScale or 1.0)

    -- Hintergrund — auf eigenem Level-2-Träger, damit die Szenerie-Deko
    -- (Level 3..39) ZWISCHEN Hintergrund und Spielgeschehen passt
    local bgHolder = CreateFrame("Frame", nil, f)
    bgHolder:SetAllPoints()
    bgHolder:SetFrameLevel(2)
    local bg = bgHolder:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(); SetBG(bg, 0.04, 0.06, 0.10, 0.97)

    -- Horizontale Trennlinie (Mitte)
    local div = f:CreateTexture(nil, "ARTWORK")
    div:SetPoint("LEFT"); div:SetPoint("RIGHT")
    div:SetHeight(2)
    div:SetPoint("CENTER", 0, 0)
    div:SetColorTexture(0.3, 0.3, 0.5, 1)

    -- ── Spielernamen (oben links = Gegner, unten links = Spieler) ──
    local enemyNameText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    enemyNameText:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -8)
    enemyNameText:SetTextColor(1, 0.82, 0)
    f.enemyNameText = enemyNameText
    -- Rang-Medaillon unter dem Gegner-Namen (in Board_Update gesetzt, wenn Rang bekannt)
    f.enemyRankIcon = f:CreateTexture(nil, "OVERLAY")
    f.enemyRankIcon:SetSize(40, 40)
    f.enemyRankIcon:SetPoint("TOPLEFT", enemyNameText, "BOTTOMLEFT", 0, -2)
    f.enemyRankIcon:Hide()

    -- Geheimnis-Icons: bis zu 10 Fragezeichen-Symbole, Farbe je nach Klasse des Geheimnisses.
    -- Reihe startet an der linken unteren/oberen Ecke des Diener-Spielfelds (siehe LayoutRow) und läuft
    -- außerhalb davon (unterhalb bzw. oberhalb der Diener-Reihe) nach rechts.
    local function MakeSecretIcons(point, x, y, interactive)
        local icons = {}
        for i = 1, 10 do
            local icon = CreateFrame("Frame", nil, f)
            icon:SetSize(20, 20)
            icon:SetPoint(point, f, "CENTER", x + (i - 1) * 22, y)
            local tex = icon:CreateTexture(nil, "BACKGROUND")
            tex:SetAllPoints()
            tex:SetTexture("Interface\\Buttons\\WHITE8X8")
            icon.tex = tex
            local mark = icon:CreateFontString(nil, "OVERLAY", "GameFontNormalOutline")
            mark:SetPoint("CENTER")
            mark:SetText("?")
            if interactive then icon:EnableMouse(true) end
            icon:Hide()
            icons[i] = icon
        end
        return icons
    end
    -- linke Kante der 7-Slot-Diener-Reihe (identisch zu LayoutRow-Berechnung)
    local BOARD_ROW_LEFT_X = -(7 * MINION_W + 6 * 8) / 2
    local BOARD_ROW_BOTTOM_Y = -65 - MINION_H / 2  -- untere Kante eigener Diener-Reihe
    local BOARD_ROW_TOP_Y    =  65 + MINION_H / 2  -- obere Kante gegnerischer Diener-Reihe
    f.enemySecretIcons = MakeSecretIcons("BOTTOMLEFT", BOARD_ROW_LEFT_X, BOARD_ROW_TOP_Y + 8, false)

    local playerNameText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    playerNameText:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 8, 58)
    playerNameText:SetTextColor(0.4, 1, 0.4)
    f.playerNameText = playerNameText
    -- Rang-Medaillon ÜBER dem eigenen Namen (aktueller Rang) — unter dem Namen würde es
    -- mit dem Aufgeben-Button unten links überlappen.
    f.playerRankIcon = f:CreateTexture(nil, "OVERLAY")
    f.playerRankIcon:SetSize(40, 40)
    f.playerRankIcon:SetPoint("BOTTOMLEFT", playerNameText, "TOPLEFT", 0, 2)
    f.playerRankIcon:Hide()

    -- eigene Geheimnisse: interaktiv (Tooltip zeigt, welche Karte es war — nur für den, der sie gelegt hat)
    f.playerSecretIcons = MakeSecretIcons("TOPLEFT", BOARD_ROW_LEFT_X, BOARD_ROW_BOTTOM_Y - 8, true)

    -- ── Gegner-Bereich (oben) ──
    f.enemyHero = MakeHeroFrame(f, true)
    f.enemyHero:SetPoint("LEFT", 5, 75)

    -- Gegner-Heldenpower-Icon (nur Anzeige + Tooltip, nicht klickbar)
    local ehp = CreateFrame("Button", nil, f)
    ehp:SetSize(95, 75)
    ehp:SetPoint("LEFT", 27.5, 260)
    f.enemyHeroPowerBtn = ehp
    local ehpBg = ehp:CreateTexture(nil, "BACKGROUND")
    ehpBg:SetAllPoints(); ehpBg:SetColorTexture(0.05, 0.05, 0.05, 0)
    local ehpArt = ehp:CreateTexture(nil, "ARTWORK")
    ehpArt:SetAllPoints()
    ehpArt:SetTexCoord(0, 1, 0, 0.35)
    f.enemyHeroPowerArt = ehpArt
    local ehpHl = ehp:CreateTexture(nil, "OVERLAY")
    ehpHl:SetAllPoints(); ehpHl:SetColorTexture(1, 1, 1, 0)
    ehp:SetScript("OnEnter", function() ehpHl:SetColorTexture(1, 1, 1, 0.15)
        if ShowHeroPowerTooltip then ShowHeroPowerTooltip(ehp, true) end
    end)
    ehp:SetScript("OnLeave", function() ehpHl:SetColorTexture(1, 1, 1, 0)
        if HideMinionTooltip then HideMinionTooltip() end
    end)

    f.enemyManaText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.enemyManaText:SetPoint("CENTER", 0, 160)
    f.enemyManaText:SetTextColor(0.4, 0.6, 1)

    f.enemyBoard = {}
    for i = 1, 7 do
        local s = MakeCardFrame(f, MINION_W, MINION_H)
        f.enemyBoard[i] = s
    end

    -- ── Spieler-Bereich (unten) ──
    f.playerHero = MakeHeroFrame(f)
    f.playerHero:SetPoint("LEFT", 5, -90)

    -- Heldenpower-Button (kein Template – GameMenuButtonTemplate quetscht die transparente Art)
    local hp = CreateFrame("Button", nil, f)
    hp:SetSize(95, 75)
    hp:SetPoint("LEFT", 27.5, -215)
    hp:SetScript("OnClick", function() addon:Board_UseHeroPower() end)
    f.heroPowerBtn = hp
    -- Dunkler Hintergrund damit transparente TGA sichtbar ist
    local hpBg = hp:CreateTexture(nil, "BACKGROUND")
    hpBg:SetAllPoints(); hpBg:SetColorTexture(0.05, 0.05, 0.05, 0)
    
    -- Artwork füllt den Button, zeigt obere ~66% (quadratischer Ausschnitt aus 256×388)
    local hpArt = hp:CreateTexture(nil, "ARTWORK")
    hpArt:SetAllPoints()
    hpArt:SetTexCoord(0, 1, 0, 0.35)  -- 256px von 512px Höhe (quadratischer Ausschnitt)
    f.heroPowerArt = hpArt
    -- Hover-Highlight
    local hpHl = hp:CreateTexture(nil, "OVERLAY")
    hpHl:SetAllPoints(); hpHl:SetColorTexture(1, 1, 1, 0)
    hp:SetScript("OnEnter", function() hpHl:SetColorTexture(1, 1, 1, 0.15)
        if ShowHeroPowerTooltip then ShowHeroPowerTooltip(hp) end
    end)
    hp:SetScript("OnLeave", function() hpHl:SetColorTexture(1, 1, 1, 0)
        if HideMinionTooltip then HideMinionTooltip() end
    end)

    -- Mana-Anzeige
    f.manaText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    f.manaText:SetPoint("CENTER", 0, -160)
    f.manaText:SetTextColor(0.4, 0.6, 1)

    -- Mana-Kristalle (10 Stück, links ausgerichtet unter dem Mana-Text)
    local CRYSTAL_SIZE = 45
    local CRYSTAL_GAP  = -15
    local manaCrystals = {}
    for i = 1, 10 do
        local c = CreateFrame("Frame", nil, f)
        c:SetSize(CRYSTAL_SIZE, CRYSTAL_SIZE)
        c:SetPoint("LEFT", f.manaText, "LEFT", (i-1) * (CRYSTAL_SIZE + CRYSTAL_GAP) -100, -30)
        c:SetFrameLevel(f:GetFrameLevel() + 2)
        local tex = c:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints()
        tex:SetTexture("Interface\\AddOns\\Arkana\\Textures\\Frames\\cost-mana.tga")
        c.tex = tex
        manaCrystals[i] = c
    end
    f.manaCrystals = manaCrystals

    f.playerBoard = {}
    for i = 1, 7 do
        local s = MakeCardFrame(f, MINION_W, MINION_H)
        f.playerBoard[i] = s
    end

    -- ── End-Turn-Button ──
    local et = CreateFrame("Button", nil, f, "GameMenuButtonTemplate")
    et:SetSize(120, 50)
    et:SetPoint("RIGHT", -20, 0)
    et:SetText("Zug beenden")
    et:SetScript("OnClick", function() addon:Net_EndTurn() end)
    f.endTurnBtn = et

    -- ── Eigene Hand ──
    f.hand = {}
    for i = 1, 10 do
        local s = MakeCardFrame(f, HAND_W, HAND_H)
        f.hand[i] = s
    end

    -- ── Gegner-Hand (Kartenrücken, oben) ──
    f.enemyHand = {}
    for i = 1, 10 do
        local s = MakeCardFrame(f, HAND_W, HAND_H)
        f.enemyHand[i] = s
    end

    -- ── Eigener Deck-Kartenstapel (unter dem "Zug beenden"-Button) ──
    f.playerDeckWidget = MakeDeckStack(f, -22, -145)

    -- ── Gegnerischer Deck-Kartenstapel (über dem "Zug beenden"-Button) ──
    f.enemyDeckWidget = MakeDeckStack(f, -22, 145)


    -- ── Brett-Zonen: Hintergrund + leere Felder ──────────────────────────────
    local ZONE_W  = 7 * MINION_W + 6 * 8 + 16   -- Gesamtbreite 7 Slots + Padding
    local ZONE_H  = MINION_H + 16
    local SLOT_GAP = 8
    local SLOT7_W  = 7 * MINION_W + 6 * SLOT_GAP
    local SLOT7_X0 = -SLOT7_W / 2 + MINION_W / 2  -- x-Offset des ersten Slots

    -- Gegner-Zone Hintergrund
    local ezBg = f:CreateTexture(nil, "BACKGROUND")
    ezBg:SetPoint("CENTER", f, "CENTER", 0, 65)
    ezBg:SetSize(ZONE_W, ZONE_H)
    ezBg:SetColorTexture(0.5, 0.1, 0.1, 0.18)
    f.enemyZoneBg = ezBg

    local ezLabel = f:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    ezLabel:SetPoint("CENTER", f, "CENTER", 0, 140)
    ezLabel:SetText("|cff886666Gegner-Brett|r")

    -- Spieler-Zone Hintergrund
    local pzBg = f:CreateTexture(nil, "BACKGROUND")
    pzBg:SetPoint("CENTER", f, "CENTER", 0, -65)
    pzBg:SetSize(ZONE_W, ZONE_H)
    pzBg:SetColorTexture(0.1, 0.35, 0.1, 0.18)
    f.playerZoneBg = pzBg

    local pzLabel = f:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    pzLabel:SetPoint("CENTER", f, "CENTER", 0, -140)
    pzLabel:SetText("|cff668866Dein Brett|r")

    -- Leere Slot-Felder (7 pro Seite, immer sichtbar)
    f.emptyEnemySlots  = {}
    f.emptyPlayerSlots = {}
    for i = 1, 7 do
        local x = SLOT7_X0 + (i - 1) * (MINION_W + SLOT_GAP)

        -- Gegner-Slot (Rand)
        local eb = f:CreateTexture(nil, "BORDER")
        eb:SetSize(MINION_W, MINION_H)
        eb:SetPoint("CENTER", f, "CENTER", x, 65)
        eb:SetColorTexture(0.55, 0.2, 0.2, 0.35)
        -- Gegner-Slot (Füllung)
        local ef = f:CreateTexture(nil, "BACKGROUND")
        ef:SetSize(MINION_W - 2, MINION_H - 2)
        ef:SetPoint("CENTER", f, "CENTER", x, 65)
        ef:SetColorTexture(0.08, 0.04, 0.04, 0.5)
        f.emptyEnemySlots[i] = ef

        -- Spieler-Slot (Rand)
        local pb = f:CreateTexture(nil, "BORDER")
        pb:SetSize(MINION_W, MINION_H)
        pb:SetPoint("CENTER", f, "CENTER", x, -65)
        pb:SetColorTexture(0.2, 0.5, 0.2, 0.35)
        -- Spieler-Slot (Füllung)
        local pf = f:CreateTexture(nil, "BACKGROUND")
        pf:SetSize(MINION_W - 2, MINION_H - 2)
        pf:SetPoint("CENTER", f, "CENTER", x, -65)
        pf:SetColorTexture(0.04, 0.08, 0.04, 0.5)
        f.emptyPlayerSlots[i] = pf
    end

    -- ── Status-Text & Timer ──
    f.statusText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    f.statusText:SetPoint("BOTTOM", et, "TOP", 0, 8)

    f.timerText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    f.timerText:SetPoint("BOTTOM", et, "TOP", 0, 32)
    f.timerText:SetTextColor(1, 0.8, 0.2)

    -- ── StateHash-Anzeige (Debug) ──
    f.hashText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.hashText:SetPoint("BOTTOMRIGHT", -10, 10)
    f.hashText:SetTextColor(0.5, 0.5, 0.5)

    -- ── Aufgeben-Button ──
    local concede = CreateFrame("Button", nil, f, "GameMenuButtonTemplate")
    concede:SetSize(140, 35)
    concede:SetPoint("BOTTOMLEFT", 10, 10)
    concede:SetText("Aufgeben")
    local concedeConfirm = false
    local concedeTimer   = nil
    local function ConcedeLabel()
        return addon.GE_IsSandbox and addon:GE_IsSandbox() and "Sandbox beenden" or "Aufgeben"
    end
    concede:SetScript("OnClick", function()
        if not concedeConfirm then
            concedeConfirm = true
            concede:SetText("Sicher?")
            if concedeTimer then concedeTimer:Cancel() end
            concedeTimer = C_Timer.NewTimer(3, function()
                concedeConfirm = false
                concede:SetText(ConcedeLabel())
            end)
        else
            if concedeTimer then concedeTimer:Cancel(); concedeTimer = nil end
            concedeConfirm = false
            concede:SetText(ConcedeLabel())
            local st = addon:GE_State()
            if st then
                if addon.GE_IsSandbox and addon:GE_IsSandbox() then
                    addon:Sandbox_End()
                else
                    local winner = st.myRole == "first" and "second" or "first"
                    addon:GE_EndGame(winner)
                end
            end
        end
    end)
    f.concedeBtn = concede
    f.RefreshConcedeLabel = function()
        if not concedeConfirm then concede:SetText(ConcedeLabel()) end
    end

    -- Log-Toggle-Button (neben Aufgeben)
    local logBtn = CreateFrame("Button", nil, f, "GameMenuButtonTemplate")
    logBtn:SetSize(60, 35)
    logBtn:SetPoint("BOTTOMLEFT", concede, "BOTTOMRIGHT", 8, 0)
    logBtn:SetText("Log")
    f.logBtn = logBtn

    -- Log-Fenster: außerhalb des Boards, frei verschiebbar (UIParent)
    local logFrame = CreateFrame("Frame", "ARKANA_LogFrame", UIParent)
    logFrame:SetSize(264, 385)
    logFrame:SetPoint("TOPRIGHT", f, "TOPLEFT", -10, 0)
    logFrame:SetMovable(true)
    logFrame:EnableMouse(true)
    logFrame:RegisterForDrag("LeftButton")
    logFrame:SetScript("OnDragStart", logFrame.StartMoving)
    logFrame:SetScript("OnDragStop", logFrame.StopMovingOrSizing)
    logFrame:SetFrameStrata("HIGH")
    local logBg = logFrame:CreateTexture(nil, "BACKGROUND")
    logBg:SetAllPoints(); logBg:SetColorTexture(0, 0, 0, 0.88)
    local logTitle = logFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    logTitle:SetPoint("TOPLEFT", 8, -7); logTitle:SetText("Spiellog")  -- links, damit rechts Platz für "Kopieren" ist
    local logScroll = CreateFrame("ScrollingMessageFrame", nil, logFrame)
    logScroll:SetPoint("TOPLEFT", 4, -28)   -- unter dem Kopfband (Titel + Kopieren)
    logScroll:SetPoint("BOTTOMRIGHT", -4, 4)
    logScroll:SetMaxLines(1000)   -- lange Partien liefen sonst oben aus dem Puffer
    logScroll:SetFading(false)
    logScroll:SetFontObject(GameFontHighlightSmall)
    logScroll:SetJustifyH("LEFT")
    logScroll:EnableMouseWheel(true)
    logScroll:SetScript("OnMouseWheel", function(self, delta)
        if delta > 0 then self:ScrollUp() else self:ScrollDown() end
    end)

    -- Tester-Wunsch: Kartennamen im Log hovern → Karten-Tooltip zum Nachlesen.
    -- GameLog markiert die Namen als |Harkanacard:<id>|h-Links (zentral, statt an
    -- jedem GE_Log-Callsite); hier nur die Hover-Handler. DB_ShowCardTip statt
    -- der lokalen Tooltip-Funktionen (die sind hier noch nil, S37-Falle).
    logScroll:SetHyperlinksEnabled(true)
    logScroll:SetScript("OnHyperlinkEnter", function(self, link)
        local id = link:match("^arkanacard:(.+)$")
        local cd = id and ARKANA_CardData and ARKANA_CardData[id]
        if cd and addon.DB_ShowCardTip then
            addon:DB_ShowCardTip(cd, self)
        end
    end)
    logScroll:SetScript("OnHyperlinkLeave", function()
        if addon.DB_HideCardTip then addon:DB_HideCardTip() end
    end)

    -- Copy button in top right
    local copyBtn = CreateFrame("Button", nil, logFrame, "GameMenuButtonTemplate")
    copyBtn:SetSize(70, 18)
    copyBtn:SetPoint("TOPRIGHT", logFrame, "TOPRIGHT", -6, -4)
    copyBtn:SetText("Kopieren")
    if copyBtn:GetFontString() then copyBtn:GetFontString():SetFontObject(GameFontNormalSmall) end

    -- Overlay Frame for Copying
    local copyOverlay = CreateFrame("Frame", nil, logFrame)
    copyOverlay:SetPoint("TOPLEFT", 4, -28)
    copyOverlay:SetPoint("BOTTOMRIGHT", -4, 4)
    copyOverlay:Hide()

    local overlayBg = copyOverlay:CreateTexture(nil, "BACKGROUND")
    overlayBg:SetAllPoints()
    overlayBg:SetColorTexture(0.05, 0.05, 0.05, 0.98)

    local sf = CreateFrame("ScrollFrame", "ARKANA_LogCopyScroll", copyOverlay, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 6, -6)
    sf:SetPoint("BOTTOMRIGHT", -26, 26)

    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true)
    eb:SetMaxLetters(99999)
    eb:SetFontObject(GameFontHighlightSmall)
    eb:SetWidth(210)
    eb:SetHeight(320)
    eb:SetAutoFocus(false)
    eb:SetScript("OnEscapePressed", function(self) copyOverlay:Hide() end)
    eb:SetScript("OnChar", function(self, text)
        -- Read-only
    end)
    sf:SetScrollChild(eb)

    local closeCopyBtn = CreateFrame("Button", nil, copyOverlay, "GameMenuButtonTemplate")
    closeCopyBtn:SetSize(80, 20)
    closeCopyBtn:SetPoint("BOTTOM", copyOverlay, "BOTTOM", 0, 4)
    closeCopyBtn:SetText("Fertig")
    if closeCopyBtn:GetFontString() then closeCopyBtn:GetFontString():SetFontObject(GameFontNormalSmall) end
    closeCopyBtn:SetScript("OnClick", function() copyOverlay:Hide() end)

    copyBtn:SetScript("OnClick", function()
        if copyOverlay:IsShown() then
            copyOverlay:Hide()
        else
            local text = ""
            for _, msg in ipairs(logBuffer) do
                local cleanMsg = msg:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
                text = text .. cleanMsg .. "\n"
            end
            eb:SetText(text)
            copyOverlay:Show()
            C_Timer.After(0.05, function()
                eb:SetFocus()
                eb:HighlightText()
            end)
        end
    end)

    logFrame:Hide()
    -- Der Log hängt an UIParent (verschiebbar) → er würde beim Schließen des Bretts
    -- offen stehen bleiben. Ein Hook deckt ALLE Schließ-Wege ab (Zuschauer-Ende,
    -- Verlassen-Button, Endscreen) statt jeden Aufrufer einzeln zu flicken.
    f:HookScript("OnHide", function() logFrame:Hide() end)
    f.logFrame  = logFrame
    f.logScroll = logScroll

    logBtn:SetScript("OnClick", function()
        if logFrame:IsShown() then
            logFrame:Hide()
        else
            -- Buffer beim Öffnen einspielen
            logScroll:Clear()
            for _, msg in ipairs(logBuffer) do
                logScroll:AddMessage(msg)
            end
            logFrame:Show()
        end
    end)

    -- ── Karten-Sandbox ──
    -- Angedockte, scrollbarfreie Testfläche. Sie verändert
    -- weder Sammlung noch Deck und wird außerhalb einer Sandbox ausgeblendet.
    local sandboxPanel = CreateFrame("Frame", "ARKANA_SandboxPanel", f)
    sandboxPanel:SetSize(310, 600)
    sandboxPanel:SetPoint("TOPLEFT", f, "TOPRIGHT", 10, 0)
    sandboxPanel:SetFrameLevel(f:GetFrameLevel() + 20)
    sandboxPanel:EnableMouse(true)
    sandboxPanel:EnableMouseWheel(true)
    local spColors = addon.UI_RegisterThemePalette and addon:UI_RegisterThemePalette({}) or {
        panel={0.03,0.024,0.05,0.98}, panelBorder={0.3,0.22,0.43,1},
        inner={0.055,0.045,0.08,0.97}, row={0.055,0.045,0.08,0.96},
        button={0.105,0.088,0.145,1}, purple={0.58,0.3,0.92,1},
        purpleSoft={0.34,0.24,0.48,1}, title={0.82,0.68,1,1},
    }
    if addon.UI_RegisterThemeFrame then addon:UI_RegisterThemeFrame(sandboxPanel) end

    local spBg = sandboxPanel:CreateTexture(nil, "BACKGROUND")
    spBg:SetAllPoints(); spBg:SetColorTexture(unpack(spColors.panel))
    local function AddBorder(frame, r, g, b, a)
        local top = frame:CreateTexture(nil, "BORDER")
        top:SetPoint("TOPLEFT"); top:SetPoint("TOPRIGHT"); top:SetHeight(1)
        top:SetColorTexture(r, g, b, a)
        local bottom = frame:CreateTexture(nil, "BORDER")
        bottom:SetPoint("BOTTOMLEFT"); bottom:SetPoint("BOTTOMRIGHT"); bottom:SetHeight(1)
        bottom:SetColorTexture(r, g, b, a)
        local left = frame:CreateTexture(nil, "BORDER")
        left:SetPoint("TOPLEFT"); left:SetPoint("BOTTOMLEFT"); left:SetWidth(1)
        left:SetColorTexture(r, g, b, a)
        local right = frame:CreateTexture(nil, "BORDER")
        right:SetPoint("TOPRIGHT"); right:SetPoint("BOTTOMRIGHT"); right:SetWidth(1)
        right:SetColorTexture(r, g, b, a)
    end
    AddBorder(sandboxPanel, unpack(spColors.panelBorder))

    local spTitle = sandboxPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    spTitle:SetPoint("TOPLEFT", 14, -13)
    spTitle:SetText("Karten-Sandbox")
    spTitle:SetTextColor(unpack(spColors.title))
    local spHint = sandboxPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    spHint:SetPoint("TOPLEFT", spTitle, "BOTTOMLEFT", 0, -5)
    spHint:SetText("Karte suchen und auf die Hand legen")
    spHint:SetTextColor(0.58, 0.58, 0.65)

    local search = CreateFrame("EditBox", nil, sandboxPanel)
    search:SetSize(282, 30)
    search:SetPoint("TOPLEFT", 14, -58)
    search:SetAutoFocus(false)
    search:SetFontObject(GameFontHighlight)
    search:SetTextInsets(9, 9, 0, 0)
    local searchBg = search:CreateTexture(nil, "BACKGROUND")
    searchBg:SetAllPoints(); searchBg:SetColorTexture(unpack(spColors.inner))
    AddBorder(search, unpack(spColors.purpleSoft))
    search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local spCount = sandboxPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    spCount:SetPoint("TOPLEFT", 15, -96)
    spCount:SetTextColor(0.6, 0.6, 0.68)

    local catalog = {}
    for cardId, card in pairs(ARKANA_CardData or {}) do
        if cardId ~= "ARKANA_SANDBOX_DUMMY"
            and (card.type == "MINION" or card.type == "SPELL" or card.type == "WEAPON") then
            catalog[#catalog + 1] = {
                id = cardId,
                card = card,
                name = tostring(card.name or cardId),
                cost = tonumber(card.cost) or 0,
            }
        end
    end
    table.sort(catalog, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        if a.cost ~= b.cost then return a.cost < b.cost end
        return a.id < b.id
    end)

    local rarityColor = {
        FREE="|cffaaaaaa", COMMON="|cffffffff", RARE="|cff3399ff",
        EPIC="|cffa335ee", LEGENDARY="|cffff8000",
    }
    local typeName = { MINION="Diener", SPELL="Zauber", WEAPON="Waffe" }
    local rows, filtered, resultOffset = {}, {}, 0
    local function SetSandboxStatus(message, success)
        sandboxPanel.status:SetText((success and "|cff66ff88" or "|cffff7777") .. tostring(message or "") .. "|r")
    end
    local function RunSandboxTool(callback)
        local ok, message = callback()
        SetSandboxStatus(message, ok)
    end

    for i = 1, 9 do
        local row = CreateFrame("Button", nil, sandboxPanel)
        row:SetSize(282, 36)
        row:SetPoint("TOPLEFT", 14, -112 - (i - 1) * 38)
        local rowBg = row:CreateTexture(nil, "BACKGROUND")
        rowBg:SetAllPoints(); rowBg:SetColorTexture(unpack(spColors.row))
        AddBorder(row, unpack(spColors.purpleSoft))
        local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        name:SetPoint("TOPLEFT", 8, -5); name:SetPoint("RIGHT", -28, 0)
        name:SetJustifyH("LEFT")
        local meta = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        meta:SetPoint("BOTTOMLEFT", 8, 4); meta:SetPoint("RIGHT", -28, 0)
        meta:SetJustifyH("LEFT")
        local plus = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
        plus:SetPoint("RIGHT", -8, 0); plus:SetText("+"); plus:SetTextColor(unpack(spColors.purple))
        row.name, row.meta, row.bg = name, meta, rowBg
        row:SetScript("OnEnter", function(self)
            self.bg:SetColorTexture(unpack(spColors.button))
            local card = self.cardId and ARKANA_CardData and ARKANA_CardData[self.cardId]
            if card and addon.DB_ShowCardTip then addon:DB_ShowCardTip(card, self) end
        end)
        row:SetScript("OnLeave", function(self)
            self.bg:SetColorTexture(unpack(spColors.row))
            if addon.DB_HideCardTip then addon:DB_HideCardTip() end
        end)
        row:SetScript("OnClick", function(self)
            if not self.cardId then return end
            local ok, message = addon:GE_SandboxGiveCard(self.cardId)
            SetSandboxStatus(message, ok)
        end)
        rows[i] = row
    end

    local function RefreshSandboxResults()
        filtered = {}
        local query = string.lower((search:GetText() or ""):match("^%s*(.-)%s*$"))
        for _, item in ipairs(catalog) do
            if query == ""
                or string.find(string.lower(item.name), query, 1, true)
                or string.find(string.lower(item.id), query, 1, true) then
                filtered[#filtered + 1] = item
            end
        end
        local maxOffset = math.max(0, #filtered - #rows)
        resultOffset = math.max(0, math.min(resultOffset, maxOffset))
        spCount:SetText(string.format("%d Karten · Mausrad zum Blättern", #filtered))
        for i, row in ipairs(rows) do
            local item = filtered[resultOffset + i]
            if item then
                row.cardId = item.id
                row.name:SetText((rarityColor[item.card.rarity] or "|cffdddddd") .. item.name .. "|r")
                row.meta:SetText(string.format("%d Mana · %s · %s", item.cost, typeName[item.card.type] or item.card.type, item.id))
                row:Show()
            else
                row.cardId = nil
                row:Hide()
            end
        end
    end
    search:SetScript("OnTextChanged", function()
        resultOffset = 0
        RefreshSandboxResults()
    end)
    sandboxPanel:SetScript("OnMouseWheel", function(_, delta)
        local maxOffset = math.max(0, #filtered - #rows)
        resultOffset = math.max(0, math.min(maxOffset, resultOffset - delta * 3))
        RefreshSandboxResults()
    end)

    local function MakeSandboxButton(text, x, y, callback, width)
        local button = CreateFrame("Button", nil, sandboxPanel)
        button:SetSize(width or 136, 30)
        button:SetPoint("BOTTOMLEFT", x, y)
        local bg = button:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(); bg:SetColorTexture(unpack(spColors.button))
        AddBorder(button, unpack(spColors.purple))
        local label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("CENTER"); label:SetText(text)
        button:SetScript("OnEnter", function() bg:SetColorTexture(unpack(spColors.purpleSoft)) end)
        button:SetScript("OnLeave", function() bg:SetColorTexture(unpack(spColors.button)) end)
        button:SetScript("OnClick", function() RunSandboxTool(callback) end)
        return button
    end
    MakeSandboxButton("Mana", 14, 76, function() return addon:GE_SandboxFillMana() end, 88)
    MakeSandboxButton("Hand leeren", 111, 76, function() return addon:GE_SandboxClearHand() end, 88)
    MakeSandboxButton("Felder leeren", 208, 76, function() return addon:GE_SandboxClearBoards() end, 88)

    local function MakeSandboxNumberBox(labelText, x, defaultValue)
        local label = sandboxPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("BOTTOMLEFT", x, 65)
        label:SetWidth(60); label:SetJustifyH("CENTER")
        label:SetText(labelText); label:SetTextColor(0.68, 0.68, 0.76)

        local box = CreateFrame("EditBox", nil, sandboxPanel)
        box:SetSize(60, 30)
        box:SetPoint("BOTTOMLEFT", x, 34)
        box:SetAutoFocus(false)
        box:SetFontObject(GameFontHighlight)
        box:SetJustifyH("CENTER")
        box:SetNumeric(true)
        box:SetMaxLetters(3)
        box:SetText(tostring(defaultValue))
        local bg = box:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(); bg:SetColorTexture(unpack(spColors.inner))
        AddBorder(box, unpack(spColors.purpleSoft))
        box:SetScript("OnEditFocusGained", function(self)
            self:HighlightText()
            bg:SetColorTexture(unpack(spColors.button))
        end)
        box:SetScript("OnEditFocusLost", function()
            bg:SetColorTexture(unpack(spColors.inner))
        end)
        box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        return box
    end

    local dummyAttack = MakeSandboxNumberBox("Angriff", 14, 30)
    local dummyHealth = MakeSandboxNumberBox("Leben", 82, 30)
    local function ReadSandboxStat(box, fallback, minimum)
        local value = math.floor(tonumber(box:GetText()) or fallback)
        return math.max(minimum, math.min(999, value))
    end
    MakeSandboxButton("Gegner-Dummy", 150, 34, function()
        local attack = ReadSandboxStat(dummyAttack, 30, 0)
        local health = ReadSandboxStat(dummyHealth, 30, 1)
        dummyAttack:SetText(tostring(attack))
        dummyHealth:SetText(tostring(health))
        dummyAttack:ClearFocus(); dummyHealth:ClearFocus()
        return addon:GE_SandboxAddDummy(true, attack, health)
    end, 146)

    local spStatus = sandboxPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    spStatus:SetPoint("BOTTOMLEFT", 15, 12); spStatus:SetPoint("RIGHT", -15, 0)
    spStatus:SetJustifyH("LEFT"); spStatus:SetText("Bereit für einen Kartentest.")
    sandboxPanel.status = spStatus
    sandboxPanel.Refresh = RefreshSandboxResults
    RefreshSandboxResults()
    sandboxPanel:Hide()
    f.sandboxPanel = sandboxPanel

    -- ── End-of-Game-Overlay ──
    local eo = CreateFrame("Frame", nil, f)
    eo:SetAllPoints()
    eo:SetFrameStrata("DIALOG")
    local eoBg = eo:CreateTexture(nil, "BACKGROUND")
    eoBg:SetAllPoints(); eoBg:SetColorTexture(0, 0, 0, 0.82)
    -- Eigener Frame nur für den Text, damit er per SetScale animiert werden kann
    -- (bare FontStrings unterstützen SetScale nicht zuverlässig auf diesem Client)
    local eoTextFrame = CreateFrame("Frame", nil, eo)
    eoTextFrame:SetSize(700, 90)
    eoTextFrame:SetPoint("CENTER", 0, 55)
    local eoText = eoTextFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightHuge")
    eoText:SetPoint("CENTER")
    local eoCountdown = eo:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    eoCountdown:SetPoint("CENTER", 0, 25)
    eoCountdown:SetTextColor(0.75, 0.75, 0.75)
    -- Ranked-Zeile über dem SIEG/NIEDERLAGE-Text (Stern-/Rang-Änderung)
    local eoRank = eo:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    eoRank:SetPoint("CENTER", 0, 112)
    local eoBtn = CreateFrame("Button", nil, eo, "GameMenuButtonTemplate")
    eoBtn:SetSize(210, 45)
    eoBtn:SetPoint("CENTER", 0, -20)
    eoBtn:SetText("Zurück zum Hauptmenü")
    eoBtn:SetScript("OnClick", function()
        eo:Hide()
        if GB.logFrame then GB.logFrame:Hide() end
        GB:Hide()
        if addon.IsSpectating and addon:IsSpectating() and addon.Spec_Leave then
            addon:Spec_Leave()   -- Zuschauer: Watch-Session sauber beenden
        end
        addon:OpenMainMenu()
    end)
    eo:Hide()
    f.endGameOverlay    = eo
    f.endGameText       = eoText
    f.endGameTextFrame  = eoTextFrame
    f.endGameCountdown  = eoCountdown
    f.endGameRankText   = eoRank

    -- Zielauswahl-Banner (eigener Frame über dem Board, damit es immer sichtbar ist;
    -- ans BRETT geankert, damit er beim Verschieben mitwandert — Tester-Wunsch)
    local tbFrame = CreateFrame("Frame", nil, UIParent)
    tbFrame:SetSize(600, 30)
    tbFrame:SetPoint("CENTER", f, "CENTER", 0, 20)
    tbFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    local tb = tbFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    tb:SetAllPoints()
    tb:SetTextColor(1, 0.9, 0.1)
    tbFrame:Hide()
    f.targetBanner = tbFrame
    f.targetBannerText = tb

    local prepBadge = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    prepBadge:SetPoint("BOTTOM", f.manaText, "TOP", 0, 4)
    prepBadge:Hide()
    f.prepBadge = prepBadge



    -- Cancel-Button als UIParent-Kind → garantiert über allem klickbar
    local cancelBtn = CreateFrame("Button", "ARKANA_CancelBtn", UIParent, "UIPanelButtonTemplate")
    cancelBtn:SetSize(100, 28)
    cancelBtn:SetFrameStrata("FULLSCREEN_DIALOG")
    cancelBtn:SetText("Abbrechen")
    cancelBtn:SetScript("OnClick", function() ClearHighlights(); addon:Board_Update() end)
    cancelBtn:Hide()
    f.targetCancelBtn = cancelBtn

    -- "Kein Ziel"-Button als UIParent-Kind
    local noTargetBtn = CreateFrame("Button", "ARKANA_NoTargetBtn", UIParent, "UIPanelButtonTemplate")
    noTargetBtn:SetSize(100, 28)
    noTargetBtn:SetFrameStrata("FULLSCREEN_DIALOG")
    noTargetBtn:SetText("Kein Ziel")
    noTargetBtn:SetScript("OnClick", function()
        if not selected or not selected.isMinion then return end
        local state = addon:GE_State()
        if not state then return end
        selected.chosenTarget = nil
        local sel = selected
        ClearHighlights()
        selected = sel
        addon:Board_ShowSlotButtons(#state.players[state.myPlayerIdx].board)
    end)
    noTargetBtn:Hide()
    f.targetNoTargetBtn = noTargetBtn

    -- Handkarten-Counter (Spieler und Gegner)
    local pHandCount = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pHandCount:SetPoint("BOTTOM", f, "BOTTOM", 0, HAND_H + 14)
    pHandCount:SetTextColor(0.8, 0.8, 0.8)
    f.playerHandCount = pHandCount

    local eHandCount = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    eHandCount:SetPoint("TOP", f, "TOP", 0, -(HAND_H + 14))
    f.enemyHandCount = eHandCount

    f:Hide()
    return f
end

local function GetSlotCoords(isMine, index)
    local gbx, gby = GB:GetCenter()
    if not gbx or not gby then return nil, nil end
    local SLOT_GAP = 8
    local SLOT7_W  = 7 * MINION_W + 6 * SLOT_GAP
    local SLOT7_X0 = -SLOT7_W / 2 + MINION_W / 2
    local x = SLOT7_X0 + (index - 1) * (MINION_W + SLOT_GAP)
    local centerY = isMine and -65 or 65
    return gbx + x, gby + centerY
end

-- ── Positions-Helfer ──────────────────────────────────────────────────────────

local function LayoutRow(slots, centerY, count, parent)
    local SLOT_GAP = 8
    local SLOT7_W  = 7 * MINION_W + 6 * SLOT_GAP
    local SLOT7_X0 = -SLOT7_W / 2 + MINION_W / 2
    for i = 1, 7 do
        local s = slots[i]
        -- (vaporized-Flag entfernt: wurde nie zurückgesetzt → ein einmal betroffener
        -- Slot wäre für immer vom Layout ausgeschlossen gewesen. Der neue Zerstäuben-
        -- Ablauf nutzt animatingEntities statt Frame-Flags.)
        if i <= count then
            local x = SLOT7_X0 + (i - 1) * (MINION_W + SLOT_GAP)
            s:ClearAllPoints()
            s:SetPoint("CENTER", parent, "CENTER", x, centerY)
            s:Show()
        else
            s:Hide()
        end
    end
end

local function LayoutHand(slots, cards)
    local n   = #cards
    if n == 0 then
        for _, s in ipairs(slots) do s:Hide() end
        return
    end
    local leftLimit  = -BOARD_W / 2 + 185
    local rightLimit = BOARD_W / 2 - 15
    local maxWidth   = rightLimit - leftLimit
    local gap  = math.max(-20, math.min(10, (maxWidth - n * HAND_W) / math.max(n - 1, 1)))
    local total = n * HAND_W + (n - 1) * gap
    local center = (leftLimit + rightLimit) / 2
    local startX = center - total / 2 + HAND_W / 2
    for i = 1, #slots do
        local s = slots[i]
        if i <= n then
            s:ClearAllPoints()
            s:SetPoint("CENTER", GB, "CENTER", startX + (i - 1) * (HAND_W + gap), -BOARD_H / 2 + HAND_H / 2 + 8)
            s:Show()
        else
            s:Hide()
        end
    end
end

-- ── Highlight-Helfer ──────────────────────────────────────────────────────────

ClearHighlights = function()
    -- Brett evtl. nie gebaut (z.B. /reload mitten im Match, dann trifft das
    -- ENDGAME-Signal ein → GE_OnGameEnd ruft uns VOR seinem eigenen GB-Guard)
    if not GB then return end
    for _, s in ipairs(GB.hand)        do s.highlight:Hide() end
    for _, s in ipairs(GB.playerBoard) do s.highlight:Hide() end
    for _, s in ipairs(GB.enemyBoard)  do s.highlight:Hide() end
    GB.playerHero.highlight:Hide()
    GB.enemyHero.highlight:Hide()
    selected = nil
    if addon.Board_HideSlotButtons then addon:Board_HideSlotButtons() end
    if GB and GB.targetBanner then GB.targetBanner:Hide() end
    if GB and GB.targetCancelBtn then GB.targetCancelBtn:Hide() end
    if GB and GB.targetNoTargetBtn then GB.targetNoTargetBtn:Hide() end
    activeTooltipType = nil
    activeTooltipFrame = nil
    activeTooltipData = nil
end

-- ── Schwebende Schaden/Heilungs-Zahlen ───────────────────────────────────────

local floatPool = {}

local function GetFloatFrame()
    for _, f in ipairs(floatPool) do
        if not f:IsShown() then return f end
    end
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(120, 50)
    f:SetFrameStrata("TOOLTIP")
    local txt = f:CreateFontString(nil, "OVERLAY")
    txt:SetAllPoints(); txt:SetJustifyH("CENTER")
    txt:SetFont("Fonts\\FRIZQT__.TTF", 32, "THICKOUTLINE")
    f.txt = txt
    f:Hide()
    table.insert(floatPool, f)
    return f
end

local function ShowFloatText(srcFrame, text, r, g, b)
    if not srcFrame or not srcFrame:IsShown() then return end
    local cx, cy = srcFrame:GetCenter()
    if not cx then return end
    local scale = srcFrame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    cx = cx * scale; cy = cy * scale
    local pf = GetFloatFrame()
    pf:SetScale(1.0)   -- Sicherheitsnetz: Pool-Frame nie mit verirrtem Scale anzeigen
    pf.txt:SetText(text)
    pf.txt:SetTextColor(r, g, b, 1)
    local startY = cy + 10
    pf.elapsed = 0
    pf:ClearAllPoints()
    pf:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx, startY)
    pf:Show()
    -- Verhalten wie im Original: Zahl bleibt an Ort und Stelle stehen und fadet aus.
    -- (Vorher stieg sie 1.5s lang auf — der Diener verschwindet aber schon nach
    -- ~0.7s, dadurch "flog" eine einsame Zahl über den leeren Slot davon.)
    pf:SetScript("OnUpdate", function(self, dt)
        self.elapsed = self.elapsed + dt
        local pct = self.elapsed / 1.0
        if pct >= 1 then self:Hide(); self:SetScript("OnUpdate", nil); return end
        self.txt:SetTextColor(r, g, b, 1 - pct * pct)   -- erst voll sichtbar, dann zügig weg
    end)
end

-- ── Diener-Hover-Tooltip ──────────────────────────────────────────────────────

local minionTooltip = nil

local function MakeMinionTooltip()
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(460, 340)
    f:SetFrameStrata("TOOLTIP")
    -- Endgröße = Gesamt-Skalierung × Tooltip-Extra (siehe ApplyScales in Main.lua)
    f:SetScale(ARKANA_Settings and (ARKANA_Settings.boardScale or 1.0) * (ARKANA_Settings.tooltipScale or 1.0) or 1.0)
    addon.minionTooltip = f
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(); bg:SetColorTexture(0, 0.0, 0, 0.0)
    f.bg = bg
    local border = f:CreateTexture(nil, "BORDER")
    border:SetPoint("TOPLEFT", 235, -20); border:SetPoint("BOTTOMRIGHT", 10, 12)
    border:SetColorTexture(0.2, 0.2, 0.2, 0.85)
    f.border = border

    local art = f:CreateTexture(nil, "ARTWORK")
    art:SetPoint("TOPLEFT", -60, 60)
    art:SetSize(320, 430)
    f.art = art

    local info = f:CreateFontString(nil, "OVERLAY")
    info:SetFont("Fonts\\FRIZQT__.TTF", 20, "")
    info:SetPoint("TOPLEFT", art, "TOPRIGHT", 4, -100)
    info:SetWidth(224)
    info:SetJustifyH("LEFT"); info:SetJustifyV("TOP"); info:SetWordWrap(true)
    f.info = info
    f:Hide()
    return f
end

local TAG_LABELS = {
    TAUNT="Spott", DIVINE_SHIELD="Gottesschild", CHARGE="Ansturm",
    WINDFURY="Windzorn", STEALTH="Tarnung", ELUSIVE="Ungreifbar",
}

local HERO_POWER_DESC = {
    WARRIOR      = "Rüstung aufbauen!: Erhaltet 2 Rüstung.",
    SHAMAN       = "Totembeschwörung: Beschwört ein zufälliges Totem.",
    ROGUE        = "Dolchfächer: Legt eine Waffe (1/2) an.",
    PALADIN      = "Reinigung: Beschwört einen Rekruten der Silbernen Hand (1/1).",
    HUNTER       = "Zuverlässiger Schuss: Fügt dem gegnerischen Helden 2 Schaden zu.",
    DRUID        = "Gestaltwandeln: +1 Angriff diese Runde. +1 Rüstung.",
    WARLOCK      = "Aderlass: Zieht eine Karte und erleidet 2 Schaden.",
    MAGE         = "Feuerschlag: Fügt einem Charakter 1 Schaden zu.",
    PRIEST       = "Geringe Heilung: Stellt bei einem Charakter 2 Leben wieder her.",
    SHADOW_PRIEST = "Dunkle Pulse: Fügt einem Charakter 2 Schaden zu.",
    SHADOW_PRIEST_UPGRADED = "Gedankenschinden: Fügt einem Charakter 3 Schaden zu.",
    CLASSLESS    = "Neugier: Zieht 1 Karte. (Testklasse — kann alle Karten nutzen)",
    JARAXXUS     = "INFERNO!: Beschwört einen Infernalen (6/6)."
}
addon.HERO_POWER_DESC = HERO_POWER_DESC  -- vom DeckBuilder-Klassen-Dropdown mitgenutzt

local CLASS_DE = {
    DRUID="Druide", HUNTER="Jäger", MAGE="Magier", PALADIN="Paladin",
    PRIEST="Priester", ROGUE="Schurke", SHAMAN="Schamane", WARLOCK="Hexenmeister", WARRIOR="Krieger",
    CLASSLESS="Classless", JARAXXUS="Lord Jaraxxus",
}

-- Klassenfarben für Geheimnis-Icons (WoW-Klassenfarben)
local CLASS_COLOR = {
    MAGE = {0.41, 0.8, 0.94}, HUNTER = {0.67, 0.83, 0.45}, PALADIN = {0.96, 0.55, 0.73},
}

-- Besitzer eines Tooltip-Ziels ermitteln (für Karten-Skins): Brett-Diener über die
-- Entity-ID im Spielzustand suchen; alles ohne Entity-ID (Handkarten, Geheimnis-Icons)
-- gehört dem Betrachter selbst.
local function TooltipIsMine(m)
    if not m.entityId then return true end
    local st = addon:GE_State()
    if st then
        local opIdx = 3 - (st.myPlayerIdx or 1)
        for _, bm in ipairs(st.players[opIdx].board) do
            if bm.entityId == m.entityId then return false end
        end
    end
    return true
end

local function ShowMinionTooltip(srcFrame, m)
    if selected then return end  -- keine Tooltips während Auswahl aktiv
    -- Zauber-Karten (wie CS2_009) zeigen ausschließlich ihren statischen card.text ohne Neuberechnung
    if not minionTooltip then minionTooltip = MakeMinionTooltip() end
    local cardId = m.id
    local artId = m.displayId or m.id
    local data = CD(cardId)
    if not data then return end

    local artData = CD(artId) or data
    minionTooltip.art:SetVertexColor(1, 1, 1)
    if artData.artTexture then
        local skinArt = addon.CS_ArtFor and addon:CS_ArtFor(artId, TooltipIsMine(m), m and m.entityId)
        minionTooltip.art:SetTexture(skinArt or artData.artTexture)
        minionTooltip.art:SetTexCoord(0, 1, 0, CARD_TEX_V)
        -- Eigene Größe/Position:
        minionTooltip.art:ClearAllPoints()
        minionTooltip.art:SetPoint("TOPLEFT", -80, 45)
        minionTooltip.art:SetSize(320, 430)

    else
        minionTooltip.art:SetTexture(FALLBACK)
        minionTooltip.art:SetTexCoord(0, 1, 0, 1)
    end
    
    activeTooltipType = "minion"
    activeTooltipFrame = srcFrame
    activeTooltipData = m

    local name = data.name or cardId
    local cost = data.cost or 0
    local costStr = tostring(cost)
    local state = addon:GE_State()
    if state and data.type == "SPELL" and not m.baseAttack then
        -- Hand card spell
        local myIdx = state.myPlayerIdx
        local red = state.players[myIdx].spellCostReduction or 0
        if red > 0 then
            costStr = "|cff00ff00" .. math.max(0, cost - red) .. "|r"
        end
    end
    local typeStr = data.type == "MINION" and "Diener" or data.type == "SPELL" and "Zauber" or "Waffe"
    
    local lines = { "|cffd4af37" .. name .. "  [" .. costStr .. "]|r", "|cffaaaaaa" .. typeStr .. "|r" }
    
    if m.entityId and m.baseAttack then
        -- Brett-Diener (dynamische Werte)
        local atk = addon:GE_MinionAtk(m)
        local maxHp = (m.baseHealth or 1) + (m.auraHealth or 0)
        for _, e in ipairs(m.enchantments or {}) do maxHp = maxHp + (e.health or 0) end
        local curHp = maxHp - (m.damageTaken or 0)
        
        lines[#lines+1] = string.format("|cffffd700%d|r ATK  |cff%s%d/%d|r HP",
            atk, curHp < maxHp and "ff4444" or "44ff44", curHp, maxHp)
            
        local active = {}
        for _, t in ipairs(m.tags or {}) do
            if TAG_LABELS[t.type] then active[#active+1] = TAG_LABELS[t.type] end
        end
        if m.divineShield then active[#active+1] = "Gottesschild" end
        if m.frozen       then active[#active+1] = "|cff88ccffEingefroren|r" end
        if m.stealthed    then active[#active+1] = "|cff888888Verstohlenheit|r" end
        if m.silenced     then active[#active+1] = "|cffaaaaaa[Verstummt]|r" end
        if #active > 0 then lines[#lines+1] = table.concat(active, ", ") end
        
        local totalEnchAtk, totalEnchHp = 0, 0
        for _, e in ipairs(m.enchantments or {}) do
            totalEnchAtk = totalEnchAtk + (e.attack or 0)
            totalEnchHp  = totalEnchHp  + (e.health  or 0)
        end
        local enchParts = {}
        if totalEnchAtk ~= 0 then enchParts[#enchParts+1] = (totalEnchAtk > 0 and "+" or "") .. totalEnchAtk .. " ATK" end
        if totalEnchHp  ~= 0 then enchParts[#enchParts+1] = (totalEnchHp  > 0 and "+" or "") .. totalEnchHp  .. " HP"  end
        if #enchParts > 0 then lines[#lines+1] = "|cff88ff88" .. table.concat(enchParts, " / ") .. "|r" end
    else
        -- Handkarte (statische Werte)
        if data.type == "MINION" then
            lines[#lines+1] = string.format("|cffffd700%d|r ATK  |cff44ff44%d|r HP", data.attack or 0, data.health or 0)
        elseif data.type == "WEAPON" then
            lines[#lines+1] = string.format("|cffffd700%d|r ATK  |cffaaaaaa%d|r Haltbarkeit", data.attack or 0, data.health or 0)
        elseif data.type == "SPELL" then
            local isSecret = false
            for _, t in ipairs(data.tags or {}) do if t.type == "SECRET" then isSecret = true; break end end
            if not isSecret then
                local state = addon:GE_State()
                local bonus = state and addon:GE_SpellDmgBonus(state.myPlayerIdx) or 0
                if bonus > 0 then lines[#lines+1] = "|cff8888ffZauberschaden: +" .. bonus .. "|r" end
            end
        end
    end
    
    local descText = data.text
    if descText and descText ~= "" then
        -- für Brett-Diener mit Tag-Labels den Card-Text unterdrücken wenn er nur Keywords enthält (vermeidet Duplikate wie Al'Akir)
        local showDesc = true
        if m.baseAttack then
            local KNOWN_KW = {["ansturm"]=true,["gottesschild"]=true,["spott"]=true,["windzorn"]=true,
                              ["tarnung"]=true,["ungreifbar"]=true,["windfury"]=true,["angriff"]=true,
                              ["charge"]=true,["divine shield"]=true,["taunt"]=true,["stealth"]=true,["elusive"]=true}
            local allKw = true
            for part in descText:lower():gmatch("[^,]+") do
                if not KNOWN_KW[part:match("^%s*(.-)%s*$")] then allKw = false; break end
            end
            if allKw then showDesc = false end
        end
        if showDesc then
            lines[#lines+1] = ""
            lines[#lines+1] = descText
        end
    end
    
    minionTooltip.info:SetText(table.concat(lines, "\n"))

    local textHeight = minionTooltip.info:GetStringHeight()
    minionTooltip:SetWidth(460)
    minionTooltip:SetHeight(math.max(340, textHeight + 16))
    -- Neues Border:
    minionTooltip.border:ClearAllPoints()
    minionTooltip.border:SetPoint("TOPLEFT", 199, -12); minionTooltip.border:SetPoint("BOTTOMRIGHT", 15, 15)
    minionTooltip.border:SetColorTexture(0.2, 0.2, 0.2, 0.85)
    -- Text
    minionTooltip.info:ClearAllPoints()
    minionTooltip.info:SetPoint("TOPLEFT", 225, -30); minionTooltip.info:SetPoint("BOTTOMRIGHT", 0, 0)

    local scale = UIParent:GetEffectiveScale()
    local tScale = ARKANA_Settings and (ARKANA_Settings.boardScale or 1.0) * (ARKANA_Settings.tooltipScale or 1.0) or 1.0
    local mx, my = GetCursorPosition()
    minionTooltip:ClearAllPoints()
    local screenW = GetScreenWidth() * scale
    if mx + (460 * scale * tScale) < screenW then
        minionTooltip:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", (mx / scale + 15) / tScale, (my / scale + 15) / tScale)
    else
        minionTooltip:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMLEFT", (mx / scale - 15) / tScale, (my / scale + 15) / tScale)
    end
    minionTooltip:Show()
end

local function ShowHeroTooltip(srcFrame, isMine)
    if selected then return end  -- keine Tooltips während Auswahl aktiv
    activeTooltipType = isMine and "playerhero" or "enemyhero"
    activeTooltipFrame = srcFrame
    activeTooltipData = isMine

    if not minionTooltip then minionTooltip = MakeMinionTooltip() end
    local state = addon:GE_State()
    if not state then return end
    
    local pIdx = isMine and state.myPlayerIdx or (state.myPlayerIdx == 1 and 2 or 1)
    local player = state.players[pIdx]
    local hero = player.hero
    
       
    minionTooltip.art:ClearAllPoints()
    minionTooltip.art:SetPoint("TOPLEFT", -50, 0)
    minionTooltip.art:SetSize(320, 430)
    minionTooltip.art:SetTexture(FALLBACK)
    minionTooltip.art:SetTexCoord(0, 1, 0, 1)

    local classToHero = {
        WARRIOR = "HERO_01", SHAMAN = "HERO_02", ROGUE = "HERO_03", PALADIN = "HERO_04",
        HUNTER = "HERO_05", DRUID = "HERO_06", WARLOCK = "HERO_07", MAGE = "HERO_08", PRIEST = "HERO_09",
        JARAXXUS = "EX1_323"
    }
    local myHeroTex = classToHero[hero.class or ""]
    if hero.heroPowerOverride == "SHADOW_PRIEST" or hero.heroPowerOverride == "SHADOW_PRIEST_UPGRADED" then
        myHeroTex = "EX1_625"
    end
    if myHeroTex then
        -- Tooltip zeigt den Helden-Skin der jeweiligen Seite (eigener/Gegner/Zuschauer)
        local hsTex = addon.HS_ArtFor and addon:HS_ArtFor(myHeroTex, isMine) or nil
        SetHeroPortrait(minionTooltip.art, myHeroTex, hsTex)
    end
    
    local name = isMine and "Dein Held" or "Gegnerischer Held"
    -- Zeilen ANHÄNGEN statt Tabellen-Literal mit nil-Löchern: ohne Rüstung stand an
    -- Index 5 ein nil, und ipairs bricht dort ab — die Waffen-Zeilen dahinter wurden
    -- nie ausgegeben (Tester: "Waffe wird nicht angezeigt").
    local lines = {}
    local function put(l) if l then lines[#lines + 1] = l end end
    put("|cffd4af37" .. name .. "|r")
    put("Klasse: " .. (CLASS_DE[hero.class] or hero.class or "Unbekannt"))
    put("")
    put(string.format("Leben: |cffff4444%d/30|r", hero.health or 30))
    if (hero.armor or 0) > 0 then put(string.format("Rüstung: |cff888888+%d|r", hero.armor)) end
    if player.weapon then
        local wepData = CD(player.weapon.id)
        put(string.format("Waffe: |cffffd700%s|r (%d/%d)", wepData and wepData.name or "Waffe",
            addon:GE_WeaponEffAtk(pIdx), player.weapon.durability))
        if wepData and wepData.text and wepData.text ~= "" then
            put("|cffcccccc" .. wepData.text .. "|r")
        end
    end

    minionTooltip.info:SetText(table.concat(lines, "\n"))

    local textHeight = minionTooltip.info:GetStringHeight()
    minionTooltip:SetWidth(460)
    minionTooltip:SetHeight(math.max(340, textHeight + 16))
    
    minionTooltip.bg:ClearAllPoints()
    minionTooltip.bg:SetPoint("TOPLEFT",     minionTooltip.art, "TOPRIGHT", 4, 8)
    minionTooltip.bg:SetPoint("BOTTOMRIGHT", minionTooltip,     "BOTTOMRIGHT", -1, 1)
    minionTooltip.border:SetPoint("TOPLEFT", 235, -20); minionTooltip.border:SetPoint("BOTTOMRIGHT", 10, 12)
    -- Text Edit
    minionTooltip.info:ClearAllPoints()
    minionTooltip.info:SetPoint("TOPLEFT", 255, -35); minionTooltip.info:SetPoint("BOTTOMRIGHT", 0, 0)

    local scale = UIParent:GetEffectiveScale()
    local tScale = ARKANA_Settings and (ARKANA_Settings.boardScale or 1.0) * (ARKANA_Settings.tooltipScale or 1.0) or 1.0
    local mx, my = GetCursorPosition()
    minionTooltip:ClearAllPoints()
    local screenW = GetScreenWidth() * scale
    if mx + (460 * scale * tScale) < screenW then
        minionTooltip:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", (mx / scale + 15) / tScale, (my / scale + 15) / tScale)
    else
        minionTooltip:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMLEFT", (mx / scale - 15) / tScale, (my / scale + 15) / tScale)
    end
    minionTooltip:Show()
end

ShowHeroPowerTooltip = function(srcFrame, isEnemy)
    if selected then return end  -- keine Tooltips während Auswahl aktiv
    activeTooltipType = isEnemy and "enemyheropower" or "heropower"
    activeTooltipFrame = srcFrame
    activeTooltipData = nil

    if not minionTooltip then minionTooltip = MakeMinionTooltip() end
    local state = addon:GE_State()
    if not state then return end

    local pIdx = isEnemy and (state.myPlayerIdx == 1 and 2 or 1) or state.myPlayerIdx
    local player = state.players[pIdx]
    local heroClass = player.hero.heroPowerOverride or player.hero.class or ""
    
    minionTooltip.art:SetTexture(FALLBACK)
    minionTooltip.art:SetTexCoord(0, 1, 0, 1)
    
    local classToHero = {
        WARRIOR = "HERO_01", SHAMAN = "HERO_02", ROGUE = "HERO_03", PALADIN = "HERO_04",
        HUNTER = "HERO_05", DRUID = "HERO_06", WARLOCK = "HERO_07", MAGE = "HERO_08", PRIEST = "HERO_09",
        JARAXXUS = "EX1_323"
    }
    local myHeroTex
    if heroClass == "JARAXXUS" then
        minionTooltip.art:SetTexture(TEXTURES .. "Cards\\EX1_tk33.tga")
        myHeroTex = "EX1_tk33"
    elseif heroClass == "SHADOW_PRIEST" then
        minionTooltip.art:SetTexture(TEXTURES .. "Cards\\EX1_625t.tga")
        myHeroTex = "EX1_625t"
    elseif heroClass == "SHADOW_PRIEST_UPGRADED" then
        minionTooltip.art:SetTexture(TEXTURES .. "Cards\\EX1_625t2.tga")
        myHeroTex = "EX1_625t2"
    else
        myHeroTex = classToHero[heroClass or ""]
        if myHeroTex then
            minionTooltip.art:SetTexture(TEXTURES .. "Cards\\" .. myHeroTex .. "bp.tga")
        end
    end
    if myHeroTex then
        minionTooltip.art:SetTexCoord(0, 1, 0, 0.65)
        -- Eigene Größe/Position nur für HeroPower TGA:
        minionTooltip.art:ClearAllPoints()
        minionTooltip.art:SetPoint("TOPLEFT", -95, 70)
        minionTooltip.art:SetSize(320, 430)
    
    end
    
    local desc = HERO_POWER_DESC[heroClass] or "Nutze die Heldenfähigkeit."
    local name = "Heldenfähigkeit"
    if heroClass == "PRIEST" then name = "Geringe Heilung"
    elseif heroClass == "SHADOW_PRIEST" then name = "Gedankenstachel"
    elseif heroClass == "SHADOW_PRIEST_UPGRADED" then name = "Gedankenschinden"
    elseif heroClass == "MAGE" then name = "Feuerschlag"
    elseif heroClass == "WARRIOR" then name = "Rüstung aufbauen!"
    elseif heroClass == "SHAMAN" then name = "Totembeschwörung"
    elseif heroClass == "ROGUE" then name = "Dolchfächer"
    elseif heroClass == "PALADIN" then name = "Reinigung"
    elseif heroClass == "HUNTER" then name = "Zuverlässiger Schuss"
    elseif heroClass == "DRUID" then name = "Gestaltwandeln"
    elseif heroClass == "WARLOCK" then name = "Aderlass"
    elseif heroClass == "CLASSLESS" then name = "Neugier"
    elseif heroClass == "JARAXXUS" then name = "INFERNO!"
    end
    
    local lines = {
        "|cffd4af37" .. name .. "  [2]|r",
        "Heldenfähigkeit",
        "",
        desc,
        player.hero.heroPowerUsedThisTurn and "|cffff4444In diesem Zug bereits genutzt.|r" or nil
    }
    
    local cleanLines = {}
    for _, l in ipairs(lines) do if l then cleanLines[#cleanLines+1] = l end end
    
    minionTooltip.info:SetText(table.concat(cleanLines, "\n"))

    local textHeight = minionTooltip.info:GetStringHeight()
    minionTooltip:SetWidth(460)
    minionTooltip:SetHeight(math.max(340, textHeight + 16))
    minionTooltip.bg:ClearAllPoints()
    minionTooltip.bg:SetPoint("TOPLEFT",     minionTooltip.art, "TOPRIGHT", 4, 8)
    minionTooltip.bg:SetPoint("BOTTOMRIGHT", minionTooltip,     "BOTTOMRIGHT", -1, 1)
    minionTooltip.border:SetPoint("TOPLEFT", 200, -12); minionTooltip.border:SetPoint("BOTTOMRIGHT", 10, 19)
        -- Text Edit
    minionTooltip.info:ClearAllPoints()
    minionTooltip.info:SetPoint("TOPLEFT", 225, -35); minionTooltip.info:SetPoint("BOTTOMRIGHT", 0, 0)

    local scale = UIParent:GetEffectiveScale()
    local tScale = ARKANA_Settings and (ARKANA_Settings.boardScale or 1.0) * (ARKANA_Settings.tooltipScale or 1.0) or 1.0
    local mx, my = GetCursorPosition()
    minionTooltip:ClearAllPoints()
    local screenW = GetScreenWidth() * scale
    if mx + (460 * scale * tScale) < screenW then
        minionTooltip:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", (mx / scale + 15) / tScale, (my / scale + 15) / tScale)
    else
        minionTooltip:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMLEFT", (mx / scale - 15) / tScale, (my / scale + 15) / tScale)
    end
    minionTooltip:Show()
end

local function HideMinionTooltip()
    activeTooltipType = nil
    activeTooltipFrame = nil
    activeTooltipData = nil

    if minionTooltip then 
        minionTooltip:Hide()
        -- bg immer zurücksetzen beim Verstecken
        minionTooltip.bg:ClearAllPoints()
        minionTooltip.bg:SetPoint("TOPLEFT",     minionTooltip, "TOPLEFT",  0,  0)
        minionTooltip.bg:SetPoint("BOTTOMRIGHT", minionTooltip, "BOTTOMRIGHT", 0, 0)
    end
end

-- ── Karte in Slot befüllen ────────────────────────────────────────────────────

local tokenColors = {
    -- Alle Tokens haben inzwischen TGA-Grafiken in Textures/Cards/
}
addon.tokenColors = tokenColors

local function FillMinionSlot(slot, m, isMine, isMyTurn)
    if not slot then return end  -- mehr Display-Einträge als Slots (z.B. sterbende Diener) → überspringen
    -- Gems hart auf Normalgröße/-scale normalisieren (außer der Puls läuft gerade):
    -- Sicherheitsnetz gegen Drift aus unterbrochenen Animationen, egal woher
    if slot.atkGem and not slot.atkGem.popRunning then
        slot.atkGem:SetScale(1.0)
        if slot.atkGem.popBaseW then slot.atkGem:SetSize(slot.atkGem.popBaseW, slot.atkGem.popBaseH) end
    end
    if slot.hpGem and not slot.hpGem.popRunning then
        slot.hpGem:SetScale(1.0)
        if slot.hpGem.popBaseW then slot.hpGem:SetSize(slot.hpGem.popBaseW, slot.hpGem.popBaseH) end
    end
    if slot.atkGem  then slot.atkGem:Show()  end
    if slot.hpGem   then slot.hpGem:Show()   end
    local id = m.displayId or m.id
    local data = CD(id)
    local color = tokenColors[id]
    if data and data.artTexture then
        local skinArt = addon.CS_ArtFor and addon:CS_ArtFor(id, isMine, m.entityId)
        slot.art:SetTexture(skinArt or data.artTexture)
        slot.art:SetVertexColor(1, 1, 1)
        slot.art:SetTexCoord(0, 1, 0, CARD_TEX_V)
        slot.art:Show()
        slot.frame:Hide()
    elseif color then
        slot.art:SetTexture("Interface\\Buttons\\WHITE8X8")
        slot.art:SetVertexColor(color[1], color[2], color[3])
        slot.art:SetTexCoord(0, 1, 0, 1)
        slot.art:Show()
        slot.frame:Hide()
    else
        slot.art:SetTexture(FALLBACK)
        slot.art:SetVertexColor(1, 1, 1)
        slot.art:SetTexCoord(0, 1, 0, 1)
        slot.art:Show()
        slot.frame:Hide()
    end

    slot.nameText:SetText("")
    slot.statsText:SetText("")
    -- Kosten auch auf dem Brett anzeigen (Tester: auf der Hand da, auf dem Brett
    -- nicht). Gedruckter Preis der Karte — Rabatte/Aufschläge gelten nur auf der Hand.
    slot.costText:SetText(tostring((data and data.cost) or 0))
    slot.costText:Show()
    if slot.manaGem then slot.manaGem:Show() end
    -- ATK aus Basiswert + Aura + Enchantments + Enrage (Engine rechnet, klemmt bei 0)
    local atk = addon:GE_MinionAtk(m)
    -- HP: GE hat kein currentHealth-Feld → maxHp - damageTaken berechnen
    local maxHp = (m.baseHealth or 1) + (m.auraHealth or 0)
    for _, e in ipairs(m.enchantments or {}) do maxHp = maxHp + (e.health or 0) end
    local curHp = maxHp - (m.damageTaken or 0)

    -- Stat-Pop: kurzer Skalierungspuls, wenn sich ATK/HP desselben Diener geändert hat
    local track = slot.statTrack
    if track and track.entityId == m.entityId then
        if track.atk ~= atk and slot.atkGem and addon.AnimateStatPop then
            addon:AnimateStatPop(slot.atkGem)
        end
        if track.hp ~= curHp and slot.hpGem and addon.AnimateStatPop then
            addon:AnimateStatPop(slot.hpGem)
        end
    end
    slot.statTrack = { entityId = m.entityId, atk = atk, hp = curHp }

    local baseAtk = m.baseAttack or 0
    if atk > baseAtk then
        slot.atkText:SetTextColor(1, 0.9, 0)      -- gelb = gebufft
    else
        slot.atkText:SetTextColor(1, 1, 1)         -- weiß = normal
    end
    slot.atkText:SetText(atk)

    local baseHp = m.baseHealth or 1
    if curHp < maxHp then
        slot.hpText:SetTextColor(1, 0.2, 0.2)     -- rot = beschädigt
    elseif maxHp > baseHp then
        slot.hpText:SetTextColor(0.2, 1, 0.2)     -- grün = gebufft über max
    else
        slot.hpText:SetTextColor(1, 1, 1)          -- weiß = normal
    end
    slot.hpText:SetText(curHp)
    slot.silencedText:SetShown(m.silenced or false)
    
    local canAttack = isMine and isMyTurn and m.canAttackThisTurn
    
    -- Getarnter Diener projiziert keinen Spott (gleiche Regel wie TauntActive in
    -- der Engine) — sonst zeigt das Brett einen Zwang an, den es gar nicht gibt.
    local hasTaunt = false
    for _, t in ipairs(m.tags or {}) do if t.type == "TAUNT" then hasTaunt = true; break end end
    if m.stealthed then hasTaunt = false end

    if slot.cardBorder then
        if canAttack then
            slot.cardBorder:SetColor(1, 0.85, 0, 0.7)
            slot.cardBorder:Show()
        elseif hasTaunt then
            slot.cardBorder:SetColor(0.55, 0.15, 0.8, 0.45)
            slot.cardBorder:Show()
        else
            slot.cardBorder:Hide()
        end
    end
    
    local hasWindfury = false
    for _, t in ipairs(m.tags or {}) do if t.type == "WINDFURY" then hasWindfury = true; break end end

    slot.tauntOverlay:SetShown(hasTaunt)
    if slot.tauntText then slot.tauntText:SetShown(hasTaunt) end
    
    slot.divineShieldOverlay:SetShown(m.divineShield or false)
    if slot.divineShieldText then slot.divineShieldText:SetShown(m.divineShield or false) end

    if slot.windfuryOverlay then slot.windfuryOverlay:SetShown(hasWindfury) end
    if slot.windfuryText then slot.windfuryText:SetShown(hasWindfury) end

    if slot.stealthOverlay then slot.stealthOverlay:SetShown(m.stealthed or false) end
    if slot.stealthText then slot.stealthText:SetShown(m.stealthed or false) end

    if slot.immuneOverlay then slot.immuneOverlay:SetShown(m.immuneThisTurn or false) end
    if slot.immuneText then slot.immuneText:SetShown(m.immuneThisTurn or false) end

    local hasDR = m.extraDeathrattle ~= nil
    if not hasDR then
        local mcd = ARKANA_CardData and ARKANA_CardData[m.id]
        if mcd then for _, t in ipairs(mcd.tags or {}) do if t.type == "DEATHRATTLE" then hasDR = true; break end end end
    end
    if slot.drText then slot.drText:SetShown(hasDR and not m.silenced) end

    slot.frozenOverlay:SetShown(m.frozen or false)
    if slot.frozenText then slot.frozenText:SetShown(m.frozen or false) end
    
    slot.sleepOverlay:SetShown(isMine and (m.summonedThisTurn and not m.canAttackThisTurn))

    -- Dynamische Text-Positionierung zur Vermeidung von Überlagerungen
    local activeTexts = {}
    if hasTaunt and slot.tauntText then table.insert(activeTexts, slot.tauntText) end
    if m.divineShield and slot.divineShieldText then table.insert(activeTexts, slot.divineShieldText) end
    if hasWindfury and slot.windfuryText then table.insert(activeTexts, slot.windfuryText) end
    if m.stealthed and slot.stealthText then table.insert(activeTexts, slot.stealthText) end
    if m.frozen and slot.frozenText then table.insert(activeTexts, slot.frozenText) end
    if m.immuneThisTurn and slot.immuneText then table.insert(activeTexts, slot.immuneText) end
    if hasDR and slot.drText then table.insert(activeTexts, slot.drText) end

    local numActive = #activeTexts
    if numActive > 0 then
        local startY = (numActive - 1) * 8
        for idx, text in ipairs(activeTexts) do
            text:ClearAllPoints()
            text:SetPoint("CENTER", slot, "CENTER", 0, startY - (idx - 1) * 16)
        end
    end
    slot.entityId = m.entityId

    if slot.attackGlow then
        slot.attackGlow:SetShown(canAttack)
    end

    -- Inaktive Minions ausgrauen
    if isMine then
        if canAttack then
            slot:SetAlpha(1.0)
        else
            slot:SetAlpha(0.55)
        end
    else
        slot:SetAlpha(1.0)
    end
end

local COMBO_CARDS = {
    ["CS2_073"] = true,  -- Kaltblütigkeit
    ["EX1_124"] = true,  -- Ausweiden
    ["EX1_134"] = true,  -- SI:7-Agent
    ["EX1_613"] = true,  -- Edwin VanCleef
    ["EX1_137"] = true,  -- Schädelbruch
    ["EX1_133"] = true,  -- Klinge des Verderbens
    ["EX1_131"] = true,  -- Rädelsführer der Defias
    ["NEW1_005"] = true, -- Entführer
}

local function FillHandSlot(slot, card, handIdx, isMyTurn)
    if slot.atkGem then slot.atkGem:Hide() end
    if slot.hpGem  then slot.hpGem:Hide()  end
    local id = card.id
    local data = CD(id)
    local color = tokenColors[id]
    if data and data.artTexture then
        local skinArt = addon.CS_ArtFor and addon:CS_ArtFor(id, true)   -- eigene Hand
        slot.art:SetTexture(skinArt or data.artTexture)
        slot.art:SetTexCoord(0, 1, 0, CARD_TEX_V)
        slot.frame:Hide()  -- artTexture ist Vollrender inkl. Rahmen
    elseif color then
        slot.art:SetColorTexture(color[1], color[2], color[3])
        slot.art:SetTexCoord(0, 1, 0, 1)
        slot.art:Show()
        if data and data.frameTexture then
            slot.frame:SetTexture(data.frameTexture)
            slot.frame:Show()
        else
            slot.frame:Hide()
        end
    else
        slot.art:SetTexture((addon.CB_MyBackTexture and addon:CB_MyBackTexture()) or CARDBACK)
        slot.art:SetTexCoord(0, 1, 0, CARD_TEX_V)
        slot.frame:Hide()
    end
    local state = addon:GE_State()
    local red = 0
    local allFree = false
    if state and data and data.type == "SPELL" then
        local myIdx = state.myPlayerIdx
        local mp = state.players[myIdx]
        red = mp.spellCostReduction or 0
        if mp.allCostZeroThisTurn then allFree = true end
        if mp.nextSecretFree and data.tags then
            for _, t in ipairs(data.tags) do
                if t.type == "SECRET" then allFree = true; break end
            end
        end
    end
    local base = (data and data.cost) or 0  -- Basispreis aus ClassicCardData für Farbvergleich
    local slotExtra = (card.cost or 0) - base  -- +2 durch Eiskältefalle, -2 durch Schattenschritt
    local effCost = allFree and 0 or (state and addon:GE_EffCost(state.myPlayerIdx, card.id, slotExtra) or (card.cost or 0))
    if effCost > base then
        slot.costText:SetText("|cffff4444" .. effCost .. "|r")  -- rot = teurer
    elseif effCost < base then
        slot.costText:SetText("|cff00ff00" .. effCost .. "|r")  -- grün = günstiger
    else
        slot.costText:SetText("|cffffffff" .. effCost .. "|r")  -- weiß = normal
    end
    slot.costText:Show()
    if slot.manaGem then slot.manaGem:Show() end
    
    slot.nameText:SetText("")
    slot.statsText:SetText("")
    slot.atkText:SetText("")
    slot.hpText:SetText("")
    slot.sleepOverlay:Hide()
    slot.frozenOverlay:Hide()
    if slot.divineShieldOverlay then slot.divineShieldOverlay:Hide() end
    if slot.divineShieldText then slot.divineShieldText:Hide() end

    if slot.immuneOverlay then slot.immuneOverlay:Hide() end
    if slot.immuneText then slot.immuneText:Hide() end
    if slot.tauntOverlay then slot.tauntOverlay:Hide() end
    if slot.tauntText then slot.tauntText:Hide() end
    if slot.silencedText then slot.silencedText:Hide() end
    if slot.cardBorder then
        local state = addon:GE_State()
        if state and state.activePlayer == state.myPlayerIdx and COMBO_CARDS[card.id] and state.players[state.myPlayerIdx].cardPlayedThisTurn then
            slot.cardBorder:SetColor(1, 0.1, 0.1, 0.7)
            slot.cardBorder:Show()
        else
            slot.cardBorder:Hide()
        end
    end
    if slot.attackGlow then slot.attackGlow:Hide() end
    slot.handIdx = handIdx
    slot.cardId  = card.id
end

-- ── Board-Update ──────────────────────────────────────────────────────────────

local function HasTaunt(board)
    for _, m in ipairs(board) do
        for _, t in ipairs(m.tags or {}) do
            if t.type == "TAUNT" then return true end
        end
    end
    return false
end

function addon:Board_Update()
    if not GB or not GB:IsShown() then return end
    local state = addon:GE_State()
    if not state then return end

    local myIdx    = state.myPlayerIdx
    local peerIdx  = myIdx == 1 and 2 or 1
    local me       = state.players[myIdx]
    local peer     = state.players[peerIdx]
    local isMyTurn = state.activePlayer == myIdx and state.phase == "play"
    local spectating = addon.IsSpectating and addon:IsSpectating()
    local sandbox = addon.GE_IsSandbox and addon:GE_IsSandbox()

    if GB.sandboxPanel then
        GB.sandboxPanel:SetShown(sandbox and not spectating)
        if sandbox and GB.sandboxPanel.Refresh then GB.sandboxPanel.Refresh() end
    end
    if GB.RefreshConcedeLabel then GB.RefreshConcedeLabel() end

    local classToHero = {
        WARRIOR = "HERO_01",
        SHAMAN  = "HERO_02",
        ROGUE   = "HERO_03",
        PALADIN = "HERO_04",
        HUNTER  = "HERO_05",
        DRUID   = "HERO_06",
        WARLOCK = "HERO_07",
        MAGE    = "HERO_08",
        PRIEST  = "HERO_09",
        DEATHKNIGHT = "HERO_11",
        DEMONHUNTER = "HERO_10",
        JARAXXUS = "EX1_323"
    }

    -- Status-Text — Position signalisiert die Seite: unterer Spieler (ich/P1) am Zug
    -- → Text UNTER dem "Zug beenden"-Button; oberer Spieler (Gegner/P2) am Zug → DARÜBER.
    local bottomActive = (state.activePlayer == myIdx)
    GB.statusText:ClearAllPoints()
    if bottomActive then
        GB.statusText:SetPoint("TOP", GB.endTurnBtn, "BOTTOM", 0, -8)
    else
        GB.statusText:SetPoint("BOTTOM", GB.endTurnBtn, "TOP", 0, 8)
    end
    if state.phase == "mulligan" then
        GB.statusText:SetText("|cffffd700Mulligan…|r")
    elseif spectating then
        -- Zuschauer: kein "du" — Name des aktiven Spielers (P1 unten/Host, P2 oben)
        local p1, p2 = "?", "?"
        if addon.Spec_PlayerNames then p1, p2 = addon:Spec_PlayerNames() end
        local activeName = (state.activePlayer == 1) and p1 or p2
        activeName = activeName and (activeName:sub(1,1):upper() .. activeName:sub(2)) or "?"
        GB.statusText:SetText("|cffffd700" .. activeName .. " ist am Zug|r")
    elseif isMyTurn then
        GB.statusText:SetText("|cff00ff00Dein Zug|r")
    elseif addon.Sandbox_IsActive and addon:Sandbox_IsActive() then
        GB.statusText:SetText("|cffaaaaaa" .. (addon:Sandbox_Name() or "Trainingsziel") .. " ist dran|r")
    else
        GB.statusText:SetText("|cffaaaaaaGegner ist dran|r")
    end
    GB.hashText:SetText("Hash: " .. addon:GE_StateHash())

    -- End-Turn-Button
    GB.endTurnBtn:SetEnabled(isMyTurn)

    -- Hero-Power: deaktivieren + visuell verblassen wenn benutzt oder nicht dran
    local hpActive = isMyTurn and not me.hero.heroPowerUsedThisTurn
        and (me.mana.currentPermanent + me.mana.temporary) >= 2
    GB.heroPowerBtn:SetEnabled(hpActive)
    GB.heroPowerBtn:SetAlpha(hpActive and 1.0 or 0.4)
    if GB.heroPowerArt then GB.heroPowerArt:SetAlpha(hpActive and 1.0 or 0.4) end

    -- ── Mana ──
    local mana = me.mana
    GB.manaText:SetText(string.format("|cff6699ffMana: %d/%d|r", mana.currentPermanent + mana.temporary, mana.maxPermanent))
    GB.enemyManaText:SetText(string.format("|cff6699ffMana: %d/%d|r", peer.mana.currentPermanent, peer.mana.maxPermanent))

    -- Mana-Kristalle aktualisieren
    local curMana = mana.currentPermanent + mana.temporary
    local maxMana = mana.maxPermanent
    local locked  = mana.locked or 0
    if GB.manaCrystals then
        local prev = prevManaState
        local prevVisible = prev and math.max(prev.curMana, prev.maxMana) or math.huge
        local curVisible  = math.max(curMana, maxMana)
        for i = 1, 10 do
            local c = GB.manaCrystals[i]
            if i <= curVisible then
                c:Show()
                -- überladen: wird nächste Runde von currentPermanent abgezogen (gesperrt)
                if locked > 0 and i > mana.currentPermanent - locked and i <= mana.currentPermanent then
                    c.tex:SetTexture("Interface\\AddOns\\Arkana\\Textures\\Frames\\cost-mana-locked.tga")
                    c.tex:SetVertexColor(1.0, 1.0, 1.0)
                else
                    c.tex:SetTexture("Interface\\AddOns\\Arkana\\Textures\\Frames\\cost-mana.tga")
                    if i <= mana.currentPermanent then
                        c.tex:SetVertexColor(0.4, 0.6, 1.0)    -- verfügbar: blau
                    elseif i <= curMana then
                        c.tex:SetVertexColor(1.0, 0.85, 0.0)   -- temporär (Coin/Innervate): gold
                    else
                        c.tex:SetVertexColor(0.15, 0.2, 0.35)  -- verbraucht: dunkelblau
                    end
                end

                if prev and addon.AnimateStatPop then
                    if i > prevVisible then
                        -- neuer Kristall (Zugbeginn) oder neuer temporärer Kristall (Münze/Innervate)
                        addon:AnimateStatPop(c)
                    elseif i > curMana and i <= prev.curMana then
                        -- gerade verbraucht: kurzes Aufblitzen beim Ausgeben
                        addon:AnimateStatPop(c)
                    end
                end
            else
                c:Hide()
            end
        end

        -- neu überladene Kristalle hervorheben, sobald ein Overload-Zauber gespielt wurde
        if prev and locked > prev.locked and addon.AnimateStatPop then
            for i = mana.currentPermanent - locked + 1, mana.currentPermanent do
                local c = GB.manaCrystals[i]
                if c then addon:AnimateStatPop(c) end
            end
        end

        prevManaState = { maxMana = maxMana, curMana = curMana, locked = locked }
    end

    -- ── Spielernamen + Geheimnisse ──
    local myLower = ((UnitName("player") or ""):match("^[^-]+") or ""):lower()
    local p1Lower, p2Lower
    if spectating and addon.Spec_PlayerNames then
        -- Zuschauer: echte Namen aus der Lobby (unten P1/Host, oben P2/Gegner) statt
        -- UnitName (=Zuschauer selbst) und Net_GetPeerName (=nil)
        local p1, p2 = addon:Spec_PlayerNames()
        local function Cap(n) n = n or "?"; return n:sub(1,1):upper() .. n:sub(2) end
        GB.playerNameText:SetText(Cap(p1))
        GB.enemyNameText:SetText(Cap(p2))
        p1Lower, p2Lower = (p1 or ""):lower(), (p2 or ""):lower()
    else
        GB.playerNameText:SetText(UnitName("player") or "Spieler")
        local peerName = addon:Net_GetPeerName() or "Gegner"
        GB.enemyNameText:SetText((peerName:sub(1,1):upper() .. peerName:sub(2)))
        p1Lower, p2Lower = myLower, (peerName or ""):lower()
    end

    -- Rang-Medaillon unter den Namen: eigener Rang direkt, fremde aus RKINFO-Ansagen
    local function RankTex(nameLower)
        if not nameLower or nameLower == "" or not addon.RK_Icon then return nil end
        if nameLower == myLower then return addon:RK_Icon() end   -- eigener aktueller Rang
        local k = addon.RK_Known and addon.RK_Known[nameLower]
        return k and addon:RK_Icon(k) or nil
    end
    local function ApplyRankIcon(icon, nameLower)
        local tex = RankTex(nameLower)
        if tex then icon:SetTexture(tex); icon:Show() else icon:Hide() end
    end
    ApplyRankIcon(GB.playerRankIcon, p1Lower)
    ApplyRankIcon(GB.enemyRankIcon, p2Lower)

    local function UpdateSecretIcons(icons, secretIds)
        for i, icon in ipairs(icons) do
            local cardId = secretIds and secretIds[i]
            if cardId then
                local sdata = CD(cardId)
                local color = sdata and CLASS_COLOR[sdata.class] or {0.5, 0.5, 1}
                icon.tex:SetVertexColor(color[1], color[2], color[3])
                icon.cardId = cardId
                icon:Show()
            else
                icon.cardId = nil
                icon:Hide()
            end
        end
    end
    UpdateSecretIcons(GB.playerSecretIcons, me.secrets)
    UpdateSecretIcons(GB.enemySecretIcons, peer.secrets)

    -- ── Eigener Held ──
    local mh = me.hero
    GB.playerHero:Show()
    GB.playerHero.hpText:SetText(mh.health)
    
    local myHeroTex = classToHero[mh.class or ""]
    if mh.heroPowerOverride == "SHADOW_PRIEST" or mh.heroPowerOverride == "SHADOW_PRIEST_UPGRADED" then
        myHeroTex = "EX1_625"
    end
    if myHeroTex then
        local hsTex = addon.HS_ArtFor and addon:HS_ArtFor(myHeroTex, true)
        SetHeroPortrait(GB.playerHero.portrait, myHeroTex, hsTex)
        SetHeroPortrait(GB.playerHero.canAttackGlow, myHeroTex, hsTex)  -- Glow = gleiche Silhouette
    else
        GB.playerHero.portrait:SetTexture(FALLBACK)
        GB.playerHero.portrait:SetTexCoord(0, 1, 0, 1)
    end
    
    GB.playerHero.armorGem:SetShown(mh.armor > 0)
    GB.playerHero.armorText:SetShown(mh.armor > 0)
    if mh.armor > 0 then GB.playerHero.armorText:SetText(mh.armor) end
    if GB.playerHero.frozenOverlay then GB.playerHero.frozenOverlay:SetShown(mh.frozen or false) end
    if GB.playerHero.iceBlockOverlay then GB.playerHero.iceBlockOverlay:SetShown(mh.immuneThisTurn or false) end
    local myWep = me.weapon
    local heroCanAttack = isMyTurn and (mh.attacksThisTurn or 0) == 0 and ((myWep and myWep.attack > 0) or (mh.attack or 0) > 0)
    GB.playerHero.canAttackGlow:SetShown(heroCanAttack)
    GB.playerHero.canAttackGlowGem:SetShown(heroCanAttack)
    if myWep then
        GB.playerHero.weaponAtkGem:Show()
        GB.playerHero.weaponDurGem:Show()
        GB.playerHero.atkText:SetText(addon:GE_WeaponEffAtk(myIdx) + (mh.attack or 0))
        GB.playerHero.weaponText:SetText(myWep.durability)
    elseif (mh.attack or 0) > 0 then
        GB.playerHero.weaponAtkGem:Show()
        GB.playerHero.weaponDurGem:Hide()
        GB.playerHero.atkText:SetText(mh.attack)
    else
        GB.playerHero.weaponAtkGem:Hide()
        GB.playerHero.weaponDurGem:Hide()
    end

    -- ── Gegner-Held ──
    local ph = peer.hero
    GB.enemyHero:Show()
    GB.enemyHero.hpText:SetFont("Fonts\\FRIZQT__.TTF", ph.health >= 1000 and 14 or 20, "THICKOUTLINE")
    GB.enemyHero.hpText:SetText(ph.health)
    
    local enemyHeroTex = classToHero[ph.class or ""]
    if ph.heroPowerOverride == "SHADOW_PRIEST" or ph.heroPowerOverride == "SHADOW_PRIEST_UPGRADED" then
        enemyHeroTex = "EX1_625"
    end
    if enemyHeroTex then
        SetHeroPortrait(GB.enemyHero.portrait, enemyHeroTex, addon.HS_ArtFor and addon:HS_ArtFor(enemyHeroTex, false))
    else
        GB.enemyHero.portrait:SetTexture(FALLBACK)
        GB.enemyHero.portrait:SetTexCoord(0, 1, 0, 1)
    end
    GB.enemyHero.armorGem:SetShown(ph.armor > 0)
    GB.enemyHero.armorText:SetShown(ph.armor > 0)
    if ph.armor > 0 then GB.enemyHero.armorText:SetText(ph.armor) end
    if GB.enemyHero.frozenOverlay then GB.enemyHero.frozenOverlay:SetShown(ph.frozen or false) end
    if GB.enemyHero.iceBlockOverlay then GB.enemyHero.iceBlockOverlay:SetShown(ph.immuneThisTurn or false) end
    local pWep = peer.weapon
    if pWep then
        GB.enemyHero.weaponAtkGem:Show()
        GB.enemyHero.weaponDurGem:Show()
        GB.enemyHero.atkText:SetText(addon:GE_WeaponEffAtk(peerIdx) + (ph.attack or 0))
        GB.enemyHero.weaponText:SetText(pWep.durability)
    elseif (ph.attack or 0) > 0 then
        GB.enemyHero.weaponAtkGem:Show()
        GB.enemyHero.weaponDurGem:Hide()
        GB.enemyHero.atkText:SetText(ph.attack)
    else
        GB.enemyHero.weaponAtkGem:Hide()
        GB.enemyHero.weaponDurGem:Hide()
    end

    -- ── Hero-Power-Artwork (klassenspezifisch) ──
    if GB.heroPowerArt then
        if mh.class == "JARAXXUS" then
            GB.heroPowerArt:SetTexture(TEXTURES .. "Cards\\EX1_tk33.tga")
        elseif mh.heroPowerOverride == "SHADOW_PRIEST" then
            GB.heroPowerArt:SetTexture(TEXTURES .. "Cards\\EX1_625t.tga")
        elseif mh.heroPowerOverride == "SHADOW_PRIEST_UPGRADED" then
            GB.heroPowerArt:SetTexture(TEXTURES .. "Cards\\EX1_625t2.tga")
        else
            local hpTex = classToHero[mh.class or ""]
            if hpTex then
                GB.heroPowerArt:SetTexture(TEXTURES .. "Cards\\" .. hpTex .. "bp.tga")
            end
        end
    end
    if GB.enemyHeroPowerArt then
        if ph.class == "JARAXXUS" then
            GB.enemyHeroPowerArt:SetTexture(TEXTURES .. "Cards\\EX1_tk33.tga")
        elseif ph.heroPowerOverride == "SHADOW_PRIEST" then
            GB.enemyHeroPowerArt:SetTexture(TEXTURES .. "Cards\\EX1_625t.tga")
        elseif ph.heroPowerOverride == "SHADOW_PRIEST_UPGRADED" then
            GB.enemyHeroPowerArt:SetTexture(TEXTURES .. "Cards\\EX1_625t2.tga")
        else
            local hpTex = classToHero[ph.class or ""]
            if hpTex then
                GB.enemyHeroPowerArt:SetTexture(TEXTURES .. "Cards\\" .. hpTex .. "bp.tga")
            end
        end
    end
    -- Zonen-Hintergründe bleiben einfarbig: Portraits sind transparent → kein Mehrwert

    -- ── Deck-Anzahlen ──
    UpdateDeckStack(GB.playerDeckWidget, #me.deck)
    UpdateDeckStack(GB.enemyDeckWidget, #peer.deck)

    -- ── Handkarten-Counter ──
    if GB.playerHandCount then
        GB.playerHandCount:SetText(string.format("Hand: %d/10", #me.hand))
    end
    if GB.enemyHandCount then
        GB.enemyHandCount:SetText(string.format("Hand: %d/10", #peer.hand))
    end

    -- ── Gegner-Hand (Kartenrücken, oben) ──
    -- neu gezogene gegnerische Karten per entityId erkennen (nicht bei der ersten Anzeige animieren)
    local newlyDrawnEnemyIdx = {}
    if prevEnemyHandEntityIds then
        for i, card in ipairs(peer.hand) do
            if card.entityId and not prevEnemyHandEntityIds[card.entityId] then
                newlyDrawnEnemyIdx[i] = true
            end
        end
    end
    local curEnemyHandEntityIds = {}
    for _, card in ipairs(peer.hand) do
        if card.entityId then curEnemyHandEntityIds[card.entityId] = true end
    end
    prevEnemyHandEntityIds = curEnemyHandEntityIds

    -- Gleicher Rand-Abstand wie LayoutHand() (Spieler-Hand), sonst überlappen 10 Karten das
    -- Heldenfähigkeit-Icon des Gegners links oben.
    -- Kartenrücken-Skins: eigener Rücken am eigenen Deck, verifizierter Gegner-Rücken
    -- an dessen Deck + Handkarten (CardBacks.lua; Fallback = Standard-Rücken)
    local myBack   = (addon.CB_MyBackTexture   and addon:CB_MyBackTexture())   or CARDBACK
    local peerBack = (addon.CB_PeerBackTexture and addon:CB_PeerBackTexture()) or CARDBACK
    if GB.playerDeckWidget and GB.playerDeckWidget.cards then
        for _, c in ipairs(GB.playerDeckWidget.cards) do c.back:SetTexture(myBack) end
    end
    if GB.enemyDeckWidget and GB.enemyDeckWidget.cards then
        for _, c in ipairs(GB.enemyDeckWidget.cards) do c.back:SetTexture(peerBack) end
    end

    local ehN     = #peer.hand
    local ehLeftLimit  = -BOARD_W / 2 + 185
    local ehRightLimit = BOARD_W / 2 - 15
    local ehMaxWidth   = ehRightLimit - ehLeftLimit
    local ehGap   = math.max(-20, math.min(10, (ehMaxWidth - ehN * HAND_W) / math.max(ehN - 1, 1)))
    local ehTotal = ehN * HAND_W + math.max(0, ehN - 1) * ehGap
    local ehCenter = (ehLeftLimit + ehRightLimit) / 2
    local ehStartX = ehCenter - ehTotal / 2 + HAND_W / 2
    for i = 1, 10 do
        local s = GB.enemyHand[i]
        if i <= ehN then
            s:ClearAllPoints()
            s:SetPoint("CENTER", GB, "CENTER", ehStartX + (i - 1) * (HAND_W + ehGap), BOARD_H / 2 - HAND_H / 2 - 8)
            s.art:SetTexture(peerBack)
            s.art:SetTexCoord(0, 1, 0, CARD_TEX_V)
            s.frame:Hide()
            if s.manaGem then s.manaGem:Hide() end
            if s.costText then s.costText:Hide() end
            s:Show()
            s:SetAlpha(1)
        else
            s:Hide()
        end
    end

    for i in pairs(newlyDrawnEnemyIdx) do
        local s = GB.enemyHand[i]
        if s and addon.AnimateCardDraw then
            local tx, ty = s:GetCenter()
            local dx, dy
            if GB.enemyDeckWidget then dx, dy = GB.enemyDeckWidget:GetCenter() end
            if not dx or not dy then dx, dy = tx, (ty or 0) - 150 end
            if tx and ty then
                s:SetAlpha(0)
                addon:AnimateCardDraw(nil, dx, dy, tx, ty, function()
                    s:SetAlpha(1)
                end, true)
            end
        end
    end

    -- Gather previous positions of board entities before update (skipping dying ones)
    local prevEntityPositions = {}
    if playerDisplayBoard and enemyDisplayBoard then
        for i, item in ipairs(playerDisplayBoard) do
            if not item.isDying then
                local frame = GB.playerBoard[i]
                if frame then
                    local x, y = frame:GetCenter()
                    if x and y then
                        prevEntityPositions[item.m.entityId] = { x = x, y = y, owner = "player" }
                    end
                end
            end
        end
        for i, item in ipairs(enemyDisplayBoard) do
            if not item.isDying then
                local frame = GB.enemyBoard[i]
                if frame then
                    local x, y = frame:GetCenter()
                    if x and y then
                        prevEntityPositions[item.m.entityId] = { x = x, y = y, owner = "enemy" }
                    end
                end
            end
        end
    end

    playerDisplayBoard = UpdateDisplayBoard(playerDisplayBoard, me.board)
    enemyDisplayBoard = UpdateDisplayBoard(enemyDisplayBoard, peer.board)

    -- Process pending card play animation first so the slot frame is hidden (alpha = 0) during flight
    if pendingPlayAnimation then
        local pIdx = pendingPlayAnimation.pIdx
        local boardPos = pendingPlayAnimation.boardPos
        local displayBoard = (pIdx == myIdx) and playerDisplayBoard or enemyDisplayBoard
        local boardFrames = (pIdx == myIdx) and GB.playerBoard or GB.enemyBoard
        local item = displayBoard[boardPos + 1]
        if item and item.m then
            local entityId = item.m.entityId
            animatingEntities[entityId] = true
            
            local targetFrame = boardFrames[boardPos + 1]
            local targetX, targetY
            
            local gbx, gby = GB:GetCenter()
            if gbx and gby then
                local SLOT_GAP = 8
                local SLOT7_W  = 7 * MINION_W + 6 * SLOT_GAP
                local SLOT7_X0 = -SLOT7_W / 2 + MINION_W / 2
                local idx = boardPos + 1
                local x = SLOT7_X0 + (idx - 1) * (MINION_W + SLOT_GAP)
                local centerY = (pIdx == myIdx) and -65 or 65
                targetX = gbx + x
                targetY = gby + centerY
            else
                targetX, targetY = targetFrame:GetCenter()
            end
            
            if targetX and targetY then
                local cardData = CD(pendingPlayAnimation.cardId)
                local hasBattlecry = false
                if cardData and cardData.tags then
                    for _, tag in ipairs(cardData.tags) do
                        if tag.type == "BATTLECRY" then
                            hasBattlecry = true
                            break
                        end
                    end
                end
                local override = addon.CARD_VISUAL_OVERRIDES and addon.CARD_VISUAL_OVERRIDES[pendingPlayAnimation.cardId]
                if addon.mirrorEntityTriggered then
                    addon:AnimatePlayCopiedCard(pendingPlayAnimation.cardId, pendingPlayAnimation.startX, pendingPlayAnimation.startY, targetX, targetY, function()
                        animatingEntities[entityId] = nil
                        addon:Board_Update()
                    end)
                elseif hasBattlecry or (override and override.isBattlecry) then
                    addon:AnimatePlayBattlecryCard(pendingPlayAnimation.cardId, pendingPlayAnimation.startX, pendingPlayAnimation.startY, targetX, targetY, function()
                        animatingEntities[entityId] = nil
                        addon:Board_Update()
                    end)
                else
                    addon:AnimatePlayCard(pendingPlayAnimation.cardId, pendingPlayAnimation.startX, pendingPlayAnimation.startY, targetX, targetY, function()
                        animatingEntities[entityId] = nil
                        addon:Board_Update()
                    end)
                end
            else
                animatingEntities[entityId] = nil
            end
        end
        pendingPlayAnimation = nil
    end

    -- ── Boards ──
    LayoutRow(GB.playerBoard, -65, #playerDisplayBoard, GB)
    LayoutRow(GB.enemyBoard, 65, #enemyDisplayBoard, GB)

    -- Detect ownership changes and trigger control change animations
    for i, item in ipairs(playerDisplayBoard) do
        if not item.isDying then
            local eid = item.m.entityId
            local prev = prevEntityPositions[eid]
            
            local animInfo = animatingControlEntities[eid]
            if animInfo and type(animInfo) == "table" and animInfo.state == "queued" then
                if not spellAnimating and not attackAnimating then
                    animInfo.state = "animating"
                    animInfo.slotIdx = i
                    -- Mark the source ghost in enemyDisplayBoard for removal
                    for _, enemyItem in ipairs(enemyDisplayBoard) do
                        if enemyItem.m.entityId == eid then
                            enemyItem.removeNext = true
                        end
                    end
                    local targetX, targetY = GetSlotCoords(true, i)
                    if targetX and targetY then
                        addon:AnimateControlChange(item.m.id, animInfo.startX, animInfo.startY, targetX, targetY, function()
                            animatingControlEntities[eid] = nil
                            addon:Board_Update()
                        end)
                    else
                        animatingControlEntities[eid] = nil
                    end
                end
            elseif prev and prev.owner == "enemy" and not animInfo then
                if spellAnimating or attackAnimating then
                    animatingControlEntities[eid] = {
                        state = "queued",
                        id = item.m.id,
                        startX = prev.x,
                        startY = prev.y,
                        isMine = true,
                        slotIdx = i
                    }
                else
                    animatingControlEntities[eid] = "animating"
                    local targetX, targetY = GetSlotCoords(true, i)
                    if targetX and targetY then
                        addon:AnimateControlChange(item.m.id, prev.x, prev.y, targetX, targetY, function()
                            animatingControlEntities[eid] = nil
                            addon:Board_Update()
                        end)
                    else
                        animatingControlEntities[eid] = nil
                    end
                end
            end
        end
    end

    for i, item in ipairs(enemyDisplayBoard) do
        if not item.isDying then
            local eid = item.m.entityId
            local prev = prevEntityPositions[eid]
            
            local animInfo = animatingControlEntities[eid]
            if animInfo and type(animInfo) == "table" and animInfo.state == "queued" then
                if not spellAnimating and not attackAnimating then
                    animInfo.state = "animating"
                    animInfo.slotIdx = i
                    -- Mark the source ghost in playerDisplayBoard for removal
                    for _, playerItem in ipairs(playerDisplayBoard) do
                        if playerItem.m.entityId == eid then
                            playerItem.removeNext = true
                        end
                    end
                    local targetX, targetY = GetSlotCoords(false, i)
                    if targetX and targetY then
                        addon:AnimateControlChange(item.m.id, animInfo.startX, animInfo.startY, targetX, targetY, function()
                            animatingControlEntities[eid] = nil
                            addon:Board_Update()
                        end)
                    else
                        animatingControlEntities[eid] = nil
                    end
                end
            elseif prev and prev.owner == "player" and not animInfo then
                if spellAnimating or attackAnimating then
                    animatingControlEntities[eid] = {
                        state = "queued",
                        id = item.m.id,
                        startX = prev.x,
                        startY = prev.y,
                        isMine = false,
                        slotIdx = i
                    }
                else
                    animatingControlEntities[eid] = "animating"
                    local targetX, targetY = GetSlotCoords(false, i)
                    if targetX and targetY then
                        addon:AnimateControlChange(item.m.id, prev.x, prev.y, targetX, targetY, function()
                            animatingControlEntities[eid] = nil
                            addon:Board_Update()
                        end)
                    else
                        animatingControlEntities[eid] = nil
                    end
                end
            end
        end
    end

    for i, item in ipairs(playerDisplayBoard) do
      local slot = GB.playerBoard[i]
      if slot then
        FillMinionSlot(slot, item.m, true, isMyTurn)

        local animInfo = animatingControlEntities[item.m.entityId]

        if item.isDying and not animInfo then
            -- Echter Tod (kein Kontrollwechsel): einmalige Schrumpf+Fade-Animation
            -- auslösen, danach Alpha/Scale der Animation überlassen statt sie
            -- jeden Board_Update-Durchlauf mit einem flachen Wert zu überschreiben.
            -- Läuft noch ein Projektil/Angriff, wartet der Tod bis zum Impact
            -- (TriggerDelayedFloats ruft dann Board_Update → Anim startet hier).
            if not item.deathAnimStarted then
                if animatingEntities[item.m.entityId] then
                    -- Sonder-Animation (Zerstäuben etc.) steuert diesen Diener — kein Schrumpfen
                elseif spellAnimating or attackAnimating then
                    GB.playerBoard[i]:SetAlpha(1)
                else
                    item.deathAnimStarted = true
                    local ref = item
                    addon:AnimateMinionDeath(GB.playerBoard[i], function()
                        -- Item exakt am Animations-Ende entfernen (kein Pop-back,
                        -- kein verwaistes Alpha auf dem gepoolten Slot-Frame)
                        ref.removeNext = true
                        addon:Board_Update()
                    end)
                end
            end
            if animatingEntities[item.m.entityId] then
                GB.playerBoard[i]:SetAlpha(0)
            end
        else
            GB.playerBoard[i]:SetScale(1.0)
            addon:ResetAttackLift(GB.playerBoard[i])
            local alpha = item.isDying and 0.3 or 1.0
            if item.isDying then
                if animInfo and type(animInfo) == "table" and animInfo.state == "queued" then
                    alpha = 1.0  -- Keep source ghost fully visible while queued
                end
            else
                -- On destination board (alive), hide while queued or animating
                if animInfo and (animInfo == "animating" or (type(animInfo) == "table" and animInfo.isMine)) then
                    alpha = 0
                end
            end
            if animatingEntities[item.m.entityId] then alpha = 0 end
            GB.playerBoard[i]:SetAlpha(alpha)
        end
      end
    end

    for i, item in ipairs(enemyDisplayBoard) do
      local slot = GB.enemyBoard[i]
      if slot then
        FillMinionSlot(slot, item.m, false, isMyTurn)

        local animInfo = animatingControlEntities[item.m.entityId]

        if item.isDying and not animInfo then
            if not item.deathAnimStarted then
                if animatingEntities[item.m.entityId] then
                    -- Sonder-Animation (Zerstäuben etc.) steuert diesen Diener — kein Schrumpfen
                elseif spellAnimating or attackAnimating then
                    GB.enemyBoard[i]:SetAlpha(1)   -- Tod wartet bis zum Impact (s. oben)
                else
                    item.deathAnimStarted = true
                    local ref = item
                    addon:AnimateMinionDeath(GB.enemyBoard[i], function()
                        ref.removeNext = true
                        addon:Board_Update()
                    end)
                end
            end
            if animatingEntities[item.m.entityId] then
                GB.enemyBoard[i]:SetAlpha(0)
            end
        else
            GB.enemyBoard[i]:SetScale(1.0)
            addon:ResetAttackLift(GB.enemyBoard[i])
            local alpha = item.isDying and 0.3 or 1.0
            if item.isDying then
                if animInfo and type(animInfo) == "table" and animInfo.state == "queued" then
                    alpha = 1.0  -- Keep source ghost fully visible while queued
                end
            else
                -- On destination board (alive), hide while queued or animating
                if animInfo and (animInfo == "animating" or (type(animInfo) == "table" and not animInfo.isMine)) then
                    alpha = 0
                end
            end
            if animatingEntities[item.m.entityId] then alpha = 0 end
            GB.enemyBoard[i]:SetAlpha(alpha)
        end
      end
    end

    -- ── Eigene Hand ──
    -- neu gezogene Karten per entityId erkennen (nicht bei der ersten Anzeige animieren)
    local newlyDrawnIdx = {}
    if prevHandEntityIds then
        for i, card in ipairs(me.hand) do
            if card.entityId and not prevHandEntityIds[card.entityId] then
                newlyDrawnIdx[i] = true
            end
        end
    end
    local curHandEntityIds = {}
    for _, card in ipairs(me.hand) do
        if card.entityId then curHandEntityIds[card.entityId] = true end
    end
    prevHandEntityIds = curHandEntityIds

    LayoutHand(GB.hand, me.hand)
    if spectating then
        -- Zuschauer sieht auch die "eigene" (P1-)Hand nur als Kartenrücken — wie ein
        -- echter Zuschauer ohne Deck-Tracker (Engine kennt die Karten, UI versteckt sie)
        for i = 1, #me.hand do
            local s = GB.hand[i]
            s.art:SetTexture(myBack)   -- Zuschauer: Rücken des P1-Spielers (via CB_MyBackTexture)
            s.art:SetVertexColor(1, 1, 1)
            s.art:SetTexCoord(0, 1, 0, CARD_TEX_V)
            s.art:Show()
            if s.frame    then s.frame:Hide()    end
            if s.manaGem  then s.manaGem:Hide()  end
            if s.costText then s.costText:SetText(""); s.costText:Hide() end
            if s.nameText then s.nameText:SetText("") end
            if s.statsText then s.statsText:SetText("") end
            if s.atkGem   then s.atkGem:Hide()   end
            if s.hpGem    then s.hpGem:Hide()    end
        end
    else
    for i, card in ipairs(me.hand) do FillHandSlot(GB.hand[i], card, i - 1, isMyTurn) end

    for i in pairs(newlyDrawnIdx) do
        local s = GB.hand[i]
        local card = me.hand[i]
        if s and card and addon.AnimateCardDraw then
            local tx, ty = s:GetCenter()
            local dx, dy
            if GB.playerDeckWidget then dx, dy = GB.playerDeckWidget:GetCenter() end
            if not dx or not dy then dx, dy = tx, (ty or 0) + 150 end
            if tx and ty then
                s:SetAlpha(0)
                addon:AnimateCardDraw(card.id, dx, dy, tx, ty, function()
                    s:SetAlpha(1)
                end)
            end
        end
    end
    end  -- if spectating else

    -- ── Klick-Handler (nur mein Zug) ──
    for i, card in ipairs(me.hand) do
        local s = GB.hand[i]
        if isMyTurn then
            s:SetScript("OnClick", function(self) addon:Board_ClickHand(self.handIdx, self.cardId) end)
        else
            s:SetScript("OnClick", nil)
        end
    end
    for i = 1, 7 do
        local s = GB.playerBoard[i]
        if i <= #playerDisplayBoard then
            local item = playerDisplayBoard[i]
            if not item.isDying then
                if isMyTurn then
                    s:SetScript("OnClick", function(self) addon:Board_ClickMyMinion(self.entityId) end)
                else
                    s:SetScript("OnClick", nil)
                end
            else
                s:SetScript("OnClick", nil)
            end
        else
            s:SetScript("OnClick", nil)
        end
    end
    for i = 1, 7 do
        local s = GB.enemyBoard[i]
        if i <= #enemyDisplayBoard then
            local item = enemyDisplayBoard[i]
            if not item.isDying then
                s:SetScript("OnClick", function(self) addon:Board_ClickEnemyMinion(self.entityId) end)
            else
                s:SetScript("OnClick", nil)
            end
        else
            s:SetScript("OnClick", nil)
        end
    end
    GB.playerHero:SetScript("OnClick", function() addon:Board_ClickMyHero() end)
    GB.playerHero:SetScript("OnEnter", function() ShowHeroTooltip(GB.playerHero, true) end)
    GB.playerHero:SetScript("OnLeave", HideMinionTooltip)
    
    GB.enemyHero:SetScript("OnClick", function() addon:Board_ClickEnemyHero() end)
    GB.enemyHero:SetScript("OnEnter", function() ShowHeroTooltip(GB.enemyHero, false) end)
    GB.enemyHero:SetScript("OnLeave", HideMinionTooltip)
    
    GB.heroPowerBtn:SetScript("OnEnter", function() ShowHeroPowerTooltip(GB.heroPowerBtn) end)
    GB.heroPowerBtn:SetScript("OnLeave", HideMinionTooltip)

    -- Gegner-Heldenpower: OnLeave hier neu setzen, damit HideMinionTooltip im Scope ist
    -- (die BuildBoard-Closure referenzierte es als noch nil → Tooltip blieb hängen).
    GB.enemyHeroPowerBtn:SetScript("OnEnter", function() ShowHeroPowerTooltip(GB.enemyHeroPowerBtn, true) end)
    GB.enemyHeroPowerBtn:SetScript("OnLeave", HideMinionTooltip)

    -- ── Hover-Tooltips für Handkarten ──
    for i, card in ipairs(me.hand) do
        local s = GB.hand[i]
        s:SetScript("OnEnter", function() ShowMinionTooltip(s, card) end)
        s:SetScript("OnLeave", HideMinionTooltip)
    end
    for i = #me.hand + 1, 10 do
        local s = GB.hand[i]
        s:SetScript("OnEnter", nil); s:SetScript("OnLeave", nil)
    end

    -- ── Hover-Tooltips für eigene Geheimnisse (nur eigene, Gegner-Geheimnisse bleiben verdeckt) ──
    -- Zuschauer sehen KEINE Geheimnis-Inhalte (beide Seiten verdeckt, wie im echten HS).
    for _, icon in ipairs(GB.playerSecretIcons) do
        if spectating then
            icon:SetScript("OnEnter", nil)
            icon:SetScript("OnLeave", nil)
        else
            icon:SetScript("OnEnter", function() if icon.cardId then ShowMinionTooltip(icon, { id = icon.cardId }) end end)
            icon:SetScript("OnLeave", HideMinionTooltip)
        end
    end

    -- ── Hover-Tooltips für Brett-Diener ──
    for i = 1, 7 do
        local s = GB.playerBoard[i]
        if i <= #playerDisplayBoard then
            local item = playerDisplayBoard[i]
            if not item.isDying then
                s:SetScript("OnEnter", function() ShowMinionTooltip(s, item.m) end)
                s:SetScript("OnLeave", HideMinionTooltip)
            else
                s:SetScript("OnEnter", nil); s:SetScript("OnLeave", nil)
            end
        else
            s:SetScript("OnEnter", nil); s:SetScript("OnLeave", nil)
        end
    end
    for i = 1, 7 do
        local s = GB.enemyBoard[i]
        if i <= #enemyDisplayBoard then
            local item = enemyDisplayBoard[i]
            if not item.isDying then
                s:SetScript("OnEnter", function() ShowMinionTooltip(s, item.m) end)
                s:SetScript("OnLeave", HideMinionTooltip)
            else
                s:SetScript("OnEnter", nil); s:SetScript("OnLeave", nil)
            end
        else
            s:SetScript("OnEnter", nil); s:SetScript("OnLeave", nil)
        end
    end

    -- ── Entity→Frame-Map aktualisieren ──
    entityFrameMap = {}
    for i, item in ipairs(playerDisplayBoard) do
        entityFrameMap[item.m.entityId] = GB.playerBoard[i]
    end
    for i, item in ipairs(enemyDisplayBoard) do
        entityFrameMap[item.m.entityId] = GB.enemyBoard[i]
    end
    entityFrameMap[me.hero.entityId]   = GB.playerHero
    entityFrameMap[peer.hero.entityId] = GB.enemyHero
    addon.entityFrameMap = entityFrameMap

    -- ── Ausstehende Secret-Beschwörungen: Pop-Puls sobald der Frame existiert ──
    if #pendingSummonPops > 0 and addon.AnimateStatPop then
        for _, eid in ipairs(pendingSummonPops) do
            local frame = entityFrameMap[eid]
            if frame then addon:AnimateStatPop(frame) end
        end
        pendingSummonPops = {}
    end

    -- ── Ausstehende Pop-ups anzeigen ──
    for _, ev in ipairs(pendingFloats) do
        ShowFloatText(entityFrameMap[ev.eid], ev.text, ev.r, ev.g, ev.b)
    end
    pendingFloats = {}

    if not selected and addon.Board_HideSlotButtons then
        addon:Board_HideSlotButtons()
    end

    local sr = me.spellCostReduction or 0
    if sr > 0 then
        GB.prepBadge:SetText("|cffffff00Vorbereitung: -" .. sr .. "|r")
        GB.prepBadge:Show()
    else
        GB.prepBadge:Hide()
    end

    if minionTooltip and minionTooltip:IsShown() and activeTooltipFrame then
        if not activeTooltipFrame:IsShown() then
            HideMinionTooltip()
        elseif activeTooltipType == "minion" then
            if activeTooltipData and activeTooltipData.entityId then
                local found = nil
                for pIdx = 1, 2 do
                    for _, m in ipairs(state.players[pIdx].board) do
                        if m.entityId == activeTooltipData.entityId then
                            found = m
                            break
                        end
                    end
                end
                if found then
                    ShowMinionTooltip(activeTooltipFrame, found)
                else
                    HideMinionTooltip()
                end
            else
                ShowMinionTooltip(activeTooltipFrame, activeTooltipData)
            end
        elseif activeTooltipType == "playerhero" then
            ShowHeroTooltip(activeTooltipFrame, true)
        elseif activeTooltipType == "enemyhero" then
            ShowHeroTooltip(activeTooltipFrame, false)
        elseif activeTooltipType == "heropower" then
            ShowHeroPowerTooltip(activeTooltipFrame)
        elseif activeTooltipType == "enemyheropower" then
            ShowHeroPowerTooltip(activeTooltipFrame, true)
        end
    end

    -- Zuschauer: alle Interaktionen zentral abschalten (überschreibt oben gesetzte
    -- Klick-Handler), damit ein Klick nicht lokal eine Aktion auslöst und desynct.
    -- Sonst: Buttons/Overlay wieder in den normalen Spielzustand versetzen (falls
    -- zuvor zugeschaut wurde und dieselben GB-Frames wiederverwendet werden).
    if spectating then
        addon:Spec_LockBoard()
    else
        if GB.endTurnBtn then GB.endTurnBtn:Show() end
        if GB.concedeBtn then GB.concedeBtn:Show() end
        if GB.specBanner then GB.specBanner:Hide() end
        if GB.specLeaveBtn then GB.specLeaveBtn:Hide() end
    end
    if addon.Spec_RefreshWatcherDisplay then addon:Spec_RefreshWatcherDisplay() end
end

-- ── Interaktion ───────────────────────────────────────────────────────────────

-- Karten deren targetType in ClassicCardData nicht korrekt gesetzt ist
local CARD_TARGET_OVERRIDE = {
    ["CS2_203"] = "ANY_MINION",       -- Eisenschnabeleule Battlecry: beliebigen Diener schweigen
    ["EX1_014t"] = "FRIENDLY_MINION",  -- Banane: eigenen Diener buffen
    ["EX1_011"] = "ANY",  -- Voodoo Doctor: heilt beliebigen Charakter
    ["CS2_004"] = "ANY",  -- Voodoo Doctor Variante
    ["CS2_009"] = "FRIENDLY_MINION",  -- Mal der Wildnis: eigenen Diener als Ziel
    ["CS2_087"] = "FRIENDLY_MINION",  -- Segen der Macht: eigenen Diener
    ["EX1_623"] = "FRIENDLY_MINION",  -- Vollstrecker des Tempels: eigenen Diener
    ["CS2_092"] = "ANY_MINION",  -- Segen der Könige: beliebigen Diener
    ["CS2_108"] = "ENEMY_MINION",     -- Hinrichten: verletzten feindl. Diener
    ["CS2_234"] = "ANY_MINION",       -- Schattenwort: Schmerz: beliebigen Diener ≤3 ATK
    ["EX1_622"] = "ANY_MINION",       -- Schattenwort: Tod: beliebigen Diener ≥5 ATK
    ["EX1_561"] = "ANY",              -- Alexstrasza: beliebigen Helden
    ["DS1_070"] = "FRIENDLY_MINION",  -- Hundemeister: eigenes Wildtier
    ["EX1_046"] = "ANY_MINION",       -- Dunkeleisenzwerg: beliebigen DIENER (Held war wählbar → Kampfschrei verpuffte still)
    ["CS2_150"] = "ANY",              -- Sturmlanzenkommando: 2 Schaden
    ["EX1_002"] = "ENEMY_MINION",    -- Schwarzer Ritter: Spott-Diener wählen
    ["NEW1_017"] = "ANY_MINION",     -- Hungrige Krabbe: beliebigen Murloc
    -- Battlecry-Overrides
    ["EX1_048"] = "ANY_MINION",      -- Zauberbrecher: beliebigen Diener schweigen
    ["EX1_382"] = "ENEMY_MINION",    -- Friedensbewahrer: feindl. Diener ATK auf 1
    ["EX1_587"] = "FRIENDLY_MINION", -- Windsprecher: eigenen Diener Windzorn
    ["NEW1_014"] = "FRIENDLY_MINION",-- Meisterin der Tarnung: eigenen Diener stealthen
    -- Spell-Overrides
    ["CS2_005"] = "NONE",            -- Klaue: kein Ziel, eigener Held
    ["CS2_039"] = "FRIENDLY_MINION", -- Windzorn: eigenen Diener
    ["CS2_046"] = "NONE",            -- Kampfrausch: kein Ziel (alle eigenen Diener)
    ["CS2_076"] = "ENEMY_MINION",    -- Attentat: feindl. Diener
    ["CS2_103"] = "FRIENDLY_MINION", -- Sturmangriff: eigenen Diener
    ["CS2_105"] = "NONE",            -- Heldenhafter Stoß: kein Ziel, eigener Held
    ["CS2_011"] = "NONE",            -- Wildes Brüllen: kein Ziel (AoE)
    ["EX1_246"] = "ANY_MINION",      -- Verhexung: beliebigen Diener → Frosch
    ["CS2_022"] = "ANY_MINION",      -- Verwandlung: beliebigen Diener → Schaf
    ["EX1_355"] = "ANY_MINION",      -- Gesegneter Champion: beliebigen Diener ATK ×2
    ["EX1_360"] = "ANY_MINION",      -- Demut: beliebigen Diener ATK auf 1
    ["EX1_371"] = "FRIENDLY_MINION", -- Hand des Schutzes: eigenen Diener Gottesschild
    ["EX1_538"] = "NONE",            -- Lasst die Hunde los!: kein Ziel (AoE)
    ["EX1_617"] = "NONE",            -- Tödlicher Schuss: kein Ziel (zufällig)
    -- CHOOSE_ONE (alle targetlos, Auswahl passiert im Overlay)
    ["EX1_154"] = "NONE",
    ["EX1_155"] = "NONE",
    ["EX1_158"] = "NONE",
    ["EX1_160"] = "NONE",
    ["EX1_164"] = "NONE",
    ["NEW1_007"] = "NONE",
    ["EX1_410"] = "ANY_MINION",     -- Schildschlag: nur Diener
    ["EX1_392"] = "NONE",           -- Kampfeswut: kein Ziel (zählt verletzte eigene Charaktere)
    ["NEW1_036"] = "NONE",          -- Befehlsruf: kein Ziel
    -- Neue Battlecry-Overrides
    ["EX1_091"] = "ENEMY_MINION",   -- Kabaleschattenpriesterin: feindl. Diener ≤2 ATK
    ["EX1_564"] = "ANY_MINION",     -- Gesichtsloser Manipulator: Kopie eines Ziels
    -- Neue Spell-Overrides
    ["CS2_026"] = "NONE",           -- Frostnova: alle feindl. Diener einfrieren (AoE)
    ["CS2_027"] = "NONE",           -- Spiegelbild: 2× Spiegelbild (AoE)
    ["CS2_032"] = "NONE",           -- Flammensto: 4 Schaden alle feindl. Diener (AoE)
    ["CS2_093"] = "NONE",           -- Weihe: 2 Schaden alle Feinde (AoE)
    ["CS2_104"] = "FRIENDLY_MINION",-- Toben: verletzten eigenen Diener
    ["EX1_248"] = "NONE",           -- Wildgeist: 2× Geisterwolf (AoE)
    ["EX1_316"] = "FRIENDLY_MINION",-- Überwältigende Macht: eigenen Diener
    ["EX1_349"] = "NONE",           -- Göttliche Gunst: kein Ziel
    ["EX1_400"] = "NONE",           -- Wirbelwind: 1 Schaden alle eigenen Diener (AoE)
    ["EX1_407"] = "NONE",           -- Scharmützel: alle außer 1 (AoE)
    ["EX1_570"] = "NONE",           -- Biss: kein Ziel, eigener Held
    ["EX1_626"] = "NONE",           -- Massenbannung: alle feindl. Diener schweigen (AoE)
    ["EX1_128"] = "NONE",           -- Verhüllen: alle freundl. Diener (AoE)
    -- Task 50 Overrides
    ["EX1_043"] = "NONE",           -- Zwielichtdrache (Selbst-Buff)
    ["EX1_590"] = "NONE",           -- Blutritter (kein Ziel)
    ["EX1_583"] = "NONE",           -- Priesterin von Elune (Helden-Heilung)
    ["NEW1_041"] = "NONE",          -- Panischer Kodo (zufällig)
    ["EX1_089"] = "NONE",           -- Arkangolem (kein Ziel)
    ["EX1_312"] = "NONE",           -- Wirbelnder Nether (kein Ziel)
    ["EX1_619"] = "NONE",           -- Gleichheit (kein Ziel)
    ["EX1_571"] = "NONE",           -- Naturgewalt (kein Ziel)
    -- Task 55 Overrides
    ["EX1_083"] = "NONE",           -- Tüftlermeister Oberfunks: KEIN Ziel (zufälliger Diener)
    ["CS2_038"] = "FRIENDLY_MINION", -- Geist der Ahnen: eigener Diener
    -- Task 57 Overrides
    ["CS2_045"] = "FRIENDLY_ANY",     -- Waffe des Felsbeißers: eigenen Charakter (Held + Diener)
    ["CS2_236"] = "ANY_MINION",       -- Göttlicher Wille: beliebigen Diener
    ["EX1_303"] = "FRIENDLY_MINION",  -- Schattenflamme: eigenen Diener opfern
    ["EX1_334"] = "ENEMY_MINION",     -- Dunkler Wahnsinn: feindl. Diener ≤3 ATK
    ["EX1_365"] = "ANY",              -- Heiliger Zorn: beliebigen Charakter
    ["NEW1_005"] = "ANY_MINION",      -- Entführer: Combo holt einen DIENER zurück (Held war wählbar → Combo verpuffte)
    -- Nachgezogen (S45): Karten, deren Text nur Diener zulässt, standen in den generierten
    -- Kartendaten auf targetType="ANY" → beide Helden wurden hervorgehoben und der Effekt
    -- verpuffte am Helden still. Reihenfolge: Diener beliebig / nur eigene / nur feindliche.
    ["CS1_129"] = "ANY_MINION",       -- Inneres Feuer
    ["CS2_057"] = "ANY_MINION",       -- Schattenblitz
    ["CS2_073"] = "ANY_MINION",       -- Kaltblütigkeit
    ["CS2_084"] = "ANY_MINION",       -- Mal des Jägers
    ["CS2_188"] = "ANY_MINION",       -- Ruchloser Unteroffizier (Kampfschrei)
    ["EX1_005"] = "ANY_MINION",       -- Großwildjäger (Kampfschrei; ≥7 Angriff zusätzlich in Highlight + beiden Klick-Pfaden)
    ["EX1_059"] = "ANY_MINION",       -- Verrückter Alchemist (Kampfschrei)
    ["EX1_161"] = "ANY_MINION",       -- Kreislauf der Natur
    ["EX1_245"] = "ANY_MINION",       -- Erdschock
    ["EX1_275"] = "ANY_MINION",       -- Kältekegel
    ["EX1_302"] = "ANY_MINION",       -- Weltliche Ängste
    ["EX1_309"] = "ANY_MINION",       -- Seele entziehen
    ["EX1_332"] = "ANY_MINION",       -- Stille
    ["EX1_363"] = "ANY_MINION",       -- Segen der Weisheit
    ["EX1_391"] = "ANY_MINION",       -- Zerschmettern
    ["EX1_537"] = "ANY_MINION",       -- Explosivschuss
    ["EX1_578"] = "ANY_MINION",       -- Unbändigkeit
    ["EX1_596"] = "ANY_MINION",       -- Dämonenfeuer
    ["EX1_603"] = "ANY_MINION",       -- Fieser Zuchtmeister (Kampfschrei)
    ["EX1_607"] = "ANY_MINION",       -- Innere Wut
    ["EX1_019"] = "FRIENDLY_MINION",  -- Blutelfenklerikerin: befreundeter Diener
    ["EX1_057"] = "FRIENDLY_MINION",  -- Uralter Braumeister: befreundeter Diener
    ["EX1_144"] = "FRIENDLY_MINION",  -- Schattenschritt: befreundeter Diener
    ["EX1_126"] = "ENEMY_MINION",     -- Verrat: feindlicher Diener
    ["EX1_581"] = "ENEMY_MINION",     -- Kopfnuss: feindlicher Diener
}

local CHOOSE_ONE_OPTIONS = {
    ["EX1_154"] = {"EX1_154a", "EX1_154b"},
    ["EX1_155"] = {"EX1_155a", "EX1_155b"},
    ["EX1_160"] = {"EX1_160a", "EX1_160b"},
    ["EX1_164"] = {"EX1_164a", "EX1_164b"},
    ["NEW1_007"] = {"NEW1_007a", "NEW1_007b"},
    ["EX1_165"] = {"EX1_165a", "EX1_165b"},
    ["EX1_178"] = {"EX1_178a", "EX1_178b"},
    ["NEW1_008"] = {"NEW1_008a", "NEW1_008b"},
    ["EX1_573"] = {"EX1_573a", "EX1_573b"},
    ["EX1_166"] = {"EX1_166a", "EX1_166b"},
}

-- Welches Ziel braucht die gewählte Sub-Karte? (ClassicCardData nicht immer korrekt)
local CHOOSE_ONE_TARGET = {
    ["EX1_154a"] = "ANY_MINION", ["EX1_154b"] = "ANY_MINION",
    ["EX1_155a"] = "FRIENDLY_MINION", ["EX1_155b"] = "FRIENDLY_MINION",
    ["EX1_160a"] = "NONE", ["EX1_160b"] = "NONE",
    ["EX1_164a"] = "NONE", ["EX1_164b"] = "NONE",
    ["NEW1_007a"] = "NONE", ["NEW1_007b"] = "ANY_MINION",
    ["EX1_166a"] = "ANY", ["EX1_166b"] = "ANY_MINION",
}

-- Flüchtig (Feendrache): kein Ziel für Zauber & Heldenfähigkeiten.
-- Die Engine lehnt es ohnehin ab (ValidatePlay/ValidateHeroPower) — hier nur Optik + Klicksperre.
local function IsElusive(bm)
    for _, t in ipairs(bm.tags or {}) do if t.type == "ELUSIVE" then return true end end
    return false
end

-- Verdeckt die Markierung flüchtiger Diener auf beiden Brettseiten.
local function HideElusiveHighlights(st)
    local myIdx = st.myPlayerIdx
    local peerIdx = myIdx == 1 and 2 or 1
    for i, bm in ipairs(st.players[myIdx].board) do
        if IsElusive(bm) and GB.playerBoard[i] then GB.playerBoard[i].highlight:Hide() end
    end
    for i, bm in ipairs(st.players[peerIdx].board) do
        if IsElusive(bm) and GB.enemyBoard[i] then GB.enemyBoard[i].highlight:Hide() end
    end
end

-- Ist die aktuelle Auswahl ein Zauber/eine Heldenfähigkeit (also flüchtig-relevant)?
local function SelIsSpellLike(sel)
    return sel and (sel.type == "heropower" or (sel.type == "hand" and not sel.isMinion))
end

local function ShowChoiceTargeting(handIdx, cardId, choiceId)
    local subTT = CHOOSE_ONE_TARGET[choiceId] or "NONE"
    local stt = addon:GE_State()
    if not stt then return end
    local myIdx = stt.myPlayerIdx
    local peerIdx = myIdx == 1 and 2 or 1
    local cd = CD(cardId)
    selected = { type = "hand", idx = handIdx, cardId = cardId, isMinion = (cd and cd.type == "MINION") or false, pendingChoice = choiceId }
    GB.hand[handIdx + 1].highlight:Show()
    if GB and GB.targetBanner then
        local subCd = ARKANA_CardData and ARKANA_CardData[choiceId]
        GB.targetBannerText:SetText("Wähle Ziel für: " .. (subCd and subCd.name or choiceId))
        GB.targetBanner:Show()
        GB.targetCancelBtn:ClearAllPoints()
        GB.targetCancelBtn:SetPoint("CENTER", GB, "CENTER", 0, -180)
        if GB.targetNoTargetBtn then GB.targetNoTargetBtn:Hide() end
        GB.targetCancelBtn:Show()
    end
    if subTT == "ANY" or subTT == "ANY_MINION" then
        for i = 1, #stt.players[myIdx].board do GB.playerBoard[i].highlight:Show() end
        for i = 1, #stt.players[peerIdx].board do GB.enemyBoard[i].highlight:Show() end
    end
    if subTT == "ANY" then
        GB.playerHero.highlight:Show(); GB.enemyHero.highlight:Show()
    end
    if subTT == "FRIENDLY_MINION" then
        for i = 1, #stt.players[myIdx].board do GB.playerBoard[i].highlight:Show() end
    end
    if not selected.isMinion then HideElusiveHighlights(stt) end
end

function addon:Board_ClickHand(handIdx, cardId)
    if selected and selected.type == "hand" and selected.idx == handIdx then
        ClearHighlights(); return
    end
    ClearHighlights()
    local data = CD(cardId)
    if not data then return end
    -- Mana-Prüfung: effektive Kosten berücksichtigen (nextSecretFree, spellCostReduction)
    local st = addon:GE_State()
    if st then
        local mana  = st.players[st.myPlayerIdx].mana
        local mp    = st.players[st.myPlayerIdx]
        local avail = mana.currentPermanent + mana.temporary
        local handSlot = st.players[st.myPlayerIdx].hand[handIdx + 1]
        local baseC = (data and data.cost) or 0
        local slotExtra = handSlot and ((handSlot.cost or 0) - baseC) or 0
        local effC  = addon:GE_EffCost(st.myPlayerIdx, cardId, slotExtra)
        if avail < effC then
            addon:GameLog("|cffff8800[HS]|r Nicht genug Mana (" .. avail .. "/" .. effC .. ")")
            return
        end
    end
    -- CHOOSE_ONE: Overlay vor Zielauswahl zeigen
    local coOpts = CHOOSE_ONE_OPTIONS[cardId]
    if coOpts then
        addon:ChooseOne_Show(coOpts[1], coOpts[2], function(choiceId)
            local subTT = CHOOSE_ONE_TARGET[choiceId] or "NONE"
            if subTT == "NONE" then
                if data.type == "MINION" then
                    selected = { type = "hand", idx = handIdx, cardId = cardId, isMinion = true, pendingChoice = choiceId }
                    GB.hand[handIdx + 1].highlight:Show()
                    addon:Board_ShowSlotButtons(#st.players[st.myPlayerIdx].board)
                else
                    addon:Net_PlayCard(handIdx, nil, 0, choiceId)
                    addon:Board_Update()
                end
            else
                ShowChoiceTargeting(handIdx, cardId, choiceId)
            end
        end)
        return
    end
    -- Karten ohne Ziel direkt spielen
    local effectiveTargetType = CARD_TARGET_OVERRIDE[cardId] or data.targetType
    if effectiveTargetType == "NONE" or effectiveTargetType == nil then
        if data.type == "MINION" then
            selected = { type = "hand", idx = handIdx, cardId = cardId, isMinion = true }
            GB.hand[handIdx + 1].highlight:Show()
            addon:Board_ShowSlotButtons(#st.players[st.myPlayerIdx].board)
            return
        else
            addon:Net_PlayCard(handIdx, nil, 0)
            addon:Board_Update()
            return
        end
    end
    -- Sonst: Ziel wählen
    selected = { type = "hand", idx = handIdx, cardId = cardId, isMinion = (data.type == "MINION") }
    GB.hand[handIdx + 1].highlight:Show()
    if GB and GB.targetBanner then
        GB.targetBannerText:SetText("Wähle Ziel für: " .. (data.name or selected.cardId))
        GB.targetBanner:Show()
        GB.targetCancelBtn:ClearAllPoints()
        if selected.isMinion then
            GB.targetCancelBtn:SetPoint("CENTER", GB, "CENTER", -60, -180)
            if GB.targetNoTargetBtn then
                GB.targetNoTargetBtn:ClearAllPoints()
                GB.targetNoTargetBtn:SetPoint("CENTER", GB, "CENTER", 60, -180)
                GB.targetNoTargetBtn:Show()
            end
        else
            GB.targetCancelBtn:SetPoint("CENTER", GB, "CENTER", 0, -180)
            if GB.targetNoTargetBtn then GB.targetNoTargetBtn:Hide() end
        end
        GB.targetCancelBtn:Show()
    end

    local tt = CARD_TARGET_OVERRIDE[cardId] or data.targetType or "NONE"
    local myIdx = st.myPlayerIdx
    local peerIdx = myIdx == 1 and 2 or 1
    if tt == "FRIENDLY" or tt == "FRIENDLY_ANY" then
        GB.playerHero.highlight:Show()
        for i = 1, #st.players[myIdx].board do
            GB.playerBoard[i].highlight:Show()
        end
    elseif tt == "FRIENDLY_MINION" then
        for i = 1, #st.players[myIdx].board do
            GB.playerBoard[i].highlight:Show()
        end
    elseif tt == "ENEMY_MINION" then
        for i, bm in ipairs(st.players[peerIdx].board) do
            local show = true
            if cardId == "CS2_108" then
                show = bm.damageTaken > 0
            elseif cardId == "CS2_072" then   -- Meucheln: nur unverletzte Diener
                show = bm.damageTaken == 0
            elseif cardId == "CS2_234" then
                local a = bm.baseAttack + (bm.auraAttack or 0)
                for _, e in ipairs(bm.enchantments or {}) do a = a + (e.attack or 0) end
                show = a <= 3
            elseif cardId == "EX1_622" then
                local a = bm.baseAttack + (bm.auraAttack or 0)
                for _, e in ipairs(bm.enchantments or {}) do a = a + (e.attack or 0) end
                show = a >= 5
            elseif cardId == "EX1_002" then
                show = false
                if bm.tags then for _, t in ipairs(bm.tags) do if t.type == "TAUNT" then show = true; break end end end
            elseif cardId == "EX1_091" then
                local a = bm.baseAttack + (bm.auraAttack or 0)
                for _, e in ipairs(bm.enchantments or {}) do a = a + (e.attack or 0) end
                show = a <= 2
            elseif cardId == "EX1_334" then
                local a = bm.baseAttack + (bm.auraAttack or 0)
                for _, e in ipairs(bm.enchantments or {}) do a = a + (e.attack or 0) end
                show = a <= 3
            end
            if show and not bm.stealthed then GB.enemyBoard[i].highlight:Show() end
        end
    elseif tt == "ENEMY" then
        GB.enemyHero.highlight:Show()
        for i, bm in ipairs(st.players[peerIdx].board) do
            if not bm.stealthed then GB.enemyBoard[i].highlight:Show() end
        end
    elseif tt == "ANY" then
        GB.playerHero.highlight:Show()
        GB.enemyHero.highlight:Show()
        for i = 1, #st.players[myIdx].board do
            GB.playerBoard[i].highlight:Show()
        end
        for i, bm in ipairs(st.players[peerIdx].board) do
            if not bm.stealthed then GB.enemyBoard[i].highlight:Show() end
        end
    elseif tt == "ANY_MINION" then
        local function atkOf(bm)
            local a = bm.baseAttack + (bm.auraAttack or 0)
            for _, e in ipairs(bm.enchantments or {}) do a = a + (e.attack or 0) end
            return a
        end
        local function minionOk(bm)
            if cardId == "CS2_234" then return atkOf(bm) <= 3
            elseif cardId == "EX1_622" then return atkOf(bm) >= 5
            elseif cardId == "EX1_005" then return atkOf(bm) >= 7   -- Großwildjäger
            elseif cardId == "NEW1_017" then
                local d = ARKANA_CardData and ARKANA_CardData[bm.id]
                return d and d.race == "MURLOC"
            end
            return true
        end
        for i, bm in ipairs(st.players[myIdx].board) do
            if minionOk(bm) then GB.playerBoard[i].highlight:Show() end
        end
        for i, bm in ipairs(st.players[peerIdx].board) do
            if minionOk(bm) and not bm.stealthed then GB.enemyBoard[i].highlight:Show() end
        end
    end
    if data.type == "SPELL" then HideElusiveHighlights(st) end
end

local HERO_POWER_TARGET = {
    PRIEST                 = "ANY",
    MAGE                   = "ANY",
    SHADOW_PRIEST          = "ANY",
    SHADOW_PRIEST_UPGRADED = "ANY",
}

function addon:Board_ClickMyMinion(eid)
    -- Flüchtig gilt auch für eigene Diener (Kartentext: kein Ziel für Zauber/Heldenfähigkeiten)
    if SelIsSpellLike(selected) then
        local stE = addon:GE_State()
        for _, bm in ipairs(stE and stE.players[stE.myPlayerIdx].board or {}) do
            if bm.entityId == eid and IsElusive(bm) then return end
        end
    end
    if selected and selected.type == "hand" then
        local data = CD(selected.cardId)
        local tt = (selected.pendingChoice and CHOOSE_ONE_TARGET[selected.pendingChoice]) or CARD_TARGET_OVERRIDE[selected.cardId] or (data and data.targetType) or "NONE"
        local savedIdx = selected.idx
        local savedChoice = selected.pendingChoice
        if tt == "FRIENDLY" or tt == "FRIENDLY_MINION" or tt == "FRIENDLY_ANY" or tt == "ANY" or tt == "ANY_MINION" then
            local state = addon:GE_State()
            if selected.isMinion and state then
                if selected.cardId == "NEW1_017" or selected.cardId == "EX1_005" then
                    local ok = false
                    for _, bm in ipairs(state.players[state.myPlayerIdx].board) do
                        if bm.entityId == eid then
                            if selected.cardId == "NEW1_017" then
                                local d = ARKANA_CardData and ARKANA_CardData[bm.id]
                                ok = d and d.race == "MURLOC"
                            else  -- EX1_005 Großwildjäger: nur Diener mit mind. 7 Angriff
                                local a = bm.baseAttack + (bm.auraAttack or 0)
                                for _, e in ipairs(bm.enchantments or {}) do a = a + (e.attack or 0) end
                                ok = a >= 7
                            end
                            break
                        end
                    end
                    if not ok then return end
                end
                local sel = selected
                ClearHighlights()
                selected = sel
                selected.chosenTarget = eid
                addon:Board_ShowSlotButtons(#state.players[state.myPlayerIdx].board)
            else
                -- Validierung für ANY_MINION auf eigenen Diener
                if tt == "ANY_MINION" and state then
                    local myIdx = state.myPlayerIdx
                    local targetFound = false
                    local valid = true
                    for _, bm in ipairs(state.players[myIdx].board) do
                        if bm.entityId == eid then
                            targetFound = true
                            local a = bm.baseAttack + (bm.auraAttack or 0)
                            for _, e in ipairs(bm.enchantments or {}) do a = a + (e.attack or 0) end
                            if selected.cardId == "CS2_234" then valid = a <= 3
                            elseif selected.cardId == "EX1_622" then valid = a >= 5
                            elseif selected.cardId == "NEW1_017" then
                                local d = ARKANA_CardData and ARKANA_CardData[bm.id]
                                valid = d and d.race == "MURLOC"
                            end
                            break
                        end
                    end
                    if not targetFound or not valid then return end
                end
                ClearHighlights()
                addon:Net_PlayCard(savedIdx, eid, 0, savedChoice)
                addon:Board_Update()
            end
            return
        end
        if tt == "ENEMY_MINION" or tt == "ENEMY" then return end  -- eigene Diener ignorieren
        if selected.isMinion then return end  -- Diener braucht Slot-Button-Klick, kein Diener-Klick
        ClearHighlights()
        addon:Net_PlayCard(savedIdx, nil, 0, savedChoice)
        addon:Board_Update()
        return
    elseif selected and selected.type == "heropower" then
        local state = addon:GE_State()
        if state then
            local myIdx = state.myPlayerIdx
            local heroClass = state.players[myIdx].hero.heroPowerOverride or state.players[myIdx].hero.class or ""
            local tt = HERO_POWER_TARGET[heroClass]
            if tt == "FRIENDLY" or tt == "ANY" then
                ClearHighlights()
                addon:Net_HeroPower(eid)
                addon:Board_Update()
                return
            end
        end
        return
    end
    if selected and selected.type == "minion" and selected.eid == eid then
        ClearHighlights(); selected = nil; addon:Board_Update(); return
    end
    ClearHighlights()
    selected = { type = "minion", eid = eid }
    -- eigenen Diener highlighten
    local state = addon:GE_State()
    if not state then return end
    local myIdx = state.myPlayerIdx
    for i, m in ipairs(state.players[myIdx].board) do
        if m.entityId == eid then GB.playerBoard[i].highlight:Show() end
    end
end

function addon:Board_ClickEnemyMinion(eid)
    if not selected then return end
    -- Verstohlenheit: getarnte Gegner sind für Zauber/Kampfschreie/Heldenfähigkeit
    -- kein gültiges Ziel (Angriffe prüft die Engine schon in ValidateAttack)
    local stSt = addon:GE_State()
    if stSt then
        for _, bm in ipairs(stSt.players[stSt.myPlayerIdx == 1 and 2 or 1].board) do
            if bm.entityId == eid and (bm.stealthed or (IsElusive(bm) and SelIsSpellLike(selected))) then return end
        end
    end
    if selected.type == "hand" then
        local data = CD(selected.cardId)
        local tt = (selected.pendingChoice and CHOOSE_ONE_TARGET[selected.pendingChoice]) or CARD_TARGET_OVERRIDE[selected.cardId] or (data and data.targetType) or "NONE"
        if tt == "FRIENDLY" or tt == "FRIENDLY_MINION" or tt == "FRIENDLY_ANY" then
            return -- Ignore
        end
        local state = addon:GE_State()
        if selected.isMinion and state then
            if selected.cardId == "NEW1_017" or selected.cardId == "EX1_091" or selected.cardId == "EX1_005" then
                local peerIdx = state.myPlayerIdx == 1 and 2 or 1
                local ok = false
                for _, bm in ipairs(state.players[peerIdx].board) do
                    if bm.entityId == eid then
                        if selected.cardId == "NEW1_017" then
                            local d = ARKANA_CardData and ARKANA_CardData[bm.id]
                            ok = d and d.race == "MURLOC"
                        else  -- EX1_091 (≤2 Angriff) bzw. EX1_005 Großwildjäger (≥7 Angriff)
                            local a = bm.baseAttack + (bm.auraAttack or 0)
                            for _, e in ipairs(bm.enchantments or {}) do a = a + (e.attack or 0) end
                            if selected.cardId == "EX1_005" then ok = a >= 7 else ok = a <= 2 end
                        end
                        break
                    end
                end
                if not ok then return end
            end
            local sel = selected
            ClearHighlights()
            selected = sel
            selected.chosenTarget = eid
            addon:Board_ShowSlotButtons(#state.players[state.myPlayerIdx].board)
        else
            local savedIdx = selected.idx
            local savedChoice = selected.pendingChoice
            local savedCard = selected.cardId
            -- Ziel-Validierung für Zauber mit eingeschränkten Zielen
            if state then
                local peerIdx = state.myPlayerIdx == 1 and 2 or 1
                local targetFound = false
                local valid = true
                for _, bm in ipairs(state.players[peerIdx].board) do
                    if bm.entityId == eid then
                        targetFound = true
                        if savedCard == "CS2_108" then
                            valid = bm.damageTaken > 0
                        elseif savedCard == "CS2_072" then   -- Meucheln: nur unverletzte Diener
                            valid = bm.damageTaken == 0
                        elseif savedCard == "CS2_234" then
                            local a = bm.baseAttack + (bm.auraAttack or 0)
                            for _, e in ipairs(bm.enchantments or {}) do a = a + (e.attack or 0) end
                            valid = a <= 3
                        elseif savedCard == "EX1_622" then
                            local a = bm.baseAttack + (bm.auraAttack or 0)
                            for _, e in ipairs(bm.enchantments or {}) do a = a + (e.attack or 0) end
                            valid = a >= 5
                        elseif savedCard == "EX1_002" then
                            valid = false
                            if bm.tags then for _, t in ipairs(bm.tags) do if t.type == "TAUNT" then valid = true; break end end end
                        elseif savedCard == "NEW1_017" then
                            local d = ARKANA_CardData and ARKANA_CardData[bm.id]
                            valid = d and d.race == "MURLOC"
                        elseif savedCard == "EX1_334" then
                            local a = bm.baseAttack + (bm.auraAttack or 0)
                            for _, e in ipairs(bm.enchantments or {}) do a = a + (e.attack or 0) end
                            valid = a <= 3
                        end
                        break
                    end
                end
                if not targetFound or not valid then return end
            end
            ClearHighlights()
            addon:Net_PlayCard(savedIdx, eid, 0, savedChoice)
            addon:Board_Update()
        end
        return
    elseif selected.type == "minion" then
        addon:Net_Attack(selected.eid, eid)
    elseif selected.type == "heropower" then
        local state = addon:GE_State()
        if state then
            local myIdx = state.myPlayerIdx
            local heroClass = state.players[myIdx].hero.heroPowerOverride or state.players[myIdx].hero.class or ""
            local tt = HERO_POWER_TARGET[heroClass]
            if tt == "ANY" then
                ClearHighlights()
                addon:Net_HeroPower(eid)
                addon:Board_Update()
                return
            else
                return -- Klick ignorieren bei FRIENDLY (Priester)
            end
        end
    end
    ClearHighlights()
    addon:Board_Update()
end

function addon:Board_ClickEnemyHero()
    if not selected then return end
    local state = addon:GE_State()
    if not state then return end
    local peerIdx = state.myPlayerIdx == 1 and 2 or 1
    local eid = state.players[peerIdx].hero.entityId
    if selected.type == "hand" then
        local data = CD(selected.cardId)
        local tt = (selected.pendingChoice and CHOOSE_ONE_TARGET[selected.pendingChoice]) or CARD_TARGET_OVERRIDE[selected.cardId] or (data and data.targetType) or "NONE"
        -- ANY_MINION gehört hier ebenfalls hin: Diener-only-Karten dürfen den gegnerischen
        -- Helden NICHT als Ziel bekommen (er war anklickbar, der Effekt verpuffte dann still)
        if tt == "FRIENDLY" or tt == "FRIENDLY_MINION" or tt == "FRIENDLY_ANY" or tt == "ENEMY_MINION" or tt == "ANY_MINION" then
            return -- Ignore
        end
        if selected.isMinion then
            local sel = selected
            ClearHighlights()
            selected = sel
            selected.chosenTarget = eid
            addon:Board_ShowSlotButtons(#state.players[state.myPlayerIdx].board)
        else
            local savedIdx = selected.idx
            local savedChoice = selected.pendingChoice
            ClearHighlights()
            addon:Net_PlayCard(savedIdx, eid, 0, savedChoice)
            addon:Board_Update()
        end
        return
    elseif selected.type == "minion" then
        addon:Net_Attack(selected.eid, eid)
    elseif selected.type == "heropower" then
        local myIdx = state.myPlayerIdx
        local heroClass = state.players[myIdx].hero.heroPowerOverride or state.players[myIdx].hero.class or ""
        local tt = HERO_POWER_TARGET[heroClass]
        if tt == "ANY" then
            ClearHighlights()
            addon:Net_HeroPower(eid)
            addon:Board_Update()
            return
        else
            return -- Klick ignorieren bei FRIENDLY (Priester)
        end
    end
    ClearHighlights()
    addon:Board_Update()
end

function addon:Board_ClickMyHero()
    if selected and selected.type == "heropower" then
        local state = addon:GE_State()
        if state then
            local myIdx = state.myPlayerIdx
            local heroClass = state.players[myIdx].hero.heroPowerOverride or state.players[myIdx].hero.class or ""
            local tt = HERO_POWER_TARGET[heroClass]
            local eid = state.players[myIdx].hero.entityId
            if tt == "FRIENDLY" or tt == "ANY" then
                ClearHighlights()
                addon:Net_HeroPower(eid)
                addon:Board_Update()
                return
            end
        end
        return
    elseif selected and selected.type == "hand" then
        local data = CD(selected.cardId)
        local tt = (selected.pendingChoice and CHOOSE_ONE_TARGET[selected.pendingChoice]) or CARD_TARGET_OVERRIDE[selected.cardId] or (data and data.targetType) or "NONE"
        local savedIdx = selected.idx
        local savedChoice = selected.pendingChoice
        local state = addon:GE_State()
        if state then
            local myIdx = state.myPlayerIdx
            local eid = state.players[myIdx].hero.entityId
            if tt == "FRIENDLY" or tt == "FRIENDLY_ANY" or tt == "ANY" then
                if selected.isMinion then
                    local sel = selected
                    ClearHighlights()
                    selected = sel
                    selected.chosenTarget = eid
                    addon:Board_ShowSlotButtons(#state.players[myIdx].board)
                else
                    ClearHighlights()
                    addon:Net_PlayCard(savedIdx, eid, 0, savedChoice)
                    addon:Board_Update()
                end
                return
            end
        end
        return
    end
    -- Eigenen Helden anklicken: Angriff mit Waffe (oder Buff)
    ClearHighlights()
    local state = addon:GE_State()
    if not state then return end
    local myIdx  = state.myPlayerIdx
    local hero   = state.players[myIdx].hero
    local wep    = state.players[myIdx].weapon
    local effAtk = (hero.attack or 0) + (wep and wep.attack or 0)
    if effAtk > 0 then
        selected = { type = "minion", eid = hero.entityId }
        GB.playerHero.highlight:Show()
    end
end

local NO_TARGET_HP = {WARRIOR=true, DRUID=true, HUNTER=true, PALADIN=true, ROGUE=true, WARLOCK=true, SHAMAN=true, CLASSLESS=true, JARAXXUS=true}

function addon:Board_UseHeroPower()
    if addon.IsSpectating and addon:IsSpectating() then return end  -- Zuschauer: keine Aktion
    ClearHighlights()
    local state = addon:GE_State()
    if not state then return end
    local myIdx     = state.myPlayerIdx
    local heroClass = state.players[myIdx].hero.heroPowerOverride or state.players[myIdx].hero.class or ""
    if NO_TARGET_HP[heroClass] then
        addon:Net_HeroPower(nil)
        addon:Board_Update()
    else
        selected = { type = "heropower" }
        GB.heroPowerBtn:SetText("⚡ Ziel?")



        if GB and GB.targetBanner then
            GB.targetBannerText:SetText("Wähle Ziel für Heldenpower")
            GB.targetBanner:Show()
            GB.targetCancelBtn:ClearAllPoints()
            -- ans Brett ankern (nicht UIParent), sonst wandert der Button beim
            -- Verschieben des Bretts nicht mit (Tester-Meldung)
            GB.targetCancelBtn:SetPoint("CENTER", GB, "CENTER", 0, -30)
            GB.targetCancelBtn:Show()
            if GB.targetNoTargetBtn then GB.targetNoTargetBtn:Hide() end
        end
        
        local targetType = HERO_POWER_TARGET[heroClass]
        if targetType == "FRIENDLY" then
            GB.playerHero.highlight:Show()
            for i = 1, #state.players[myIdx].board do
                GB.playerBoard[i].highlight:Show()
            end
        elseif targetType == "ANY" then
            GB.playerHero.highlight:Show()
            GB.enemyHero.highlight:Show()
            for i = 1, #state.players[myIdx].board do
                GB.playerBoard[i].highlight:Show()
            end
            local peerIdx = myIdx == 1 and 2 or 1
            for i = 1, #state.players[peerIdx].board do
                GB.enemyBoard[i].highlight:Show()
            end
        end
        HideElusiveHighlights(state)   -- Flüchtig: auch keine Heldenfähigkeit
    end
end

-- ── GE-Callbacks ──────────────────────────────────────────────────────────────

local _prevGameStart = addon.GE_OnGameStart
function addon:GE_OnGameStart()
    -- Zuschauer bekommt keine Mulligan-Auswahl (kann nichts tauschen)
    if _prevGameStart and not (addon.IsSpectating and addon:IsSpectating()) then _prevGameStart(self) end
    logBuffer = {}
    if GB and GB.logScroll then
        GB.logScroll:Clear()
    end
    playerDisplayBoard = {}
    enemyDisplayBoard = {}
    -- Anim-Flags sind File-Locals: ein Leck aus dem Vorspiel darf nicht ins
    -- nächste Spiel überleben (blockierte Tode/Floats = wirkt wie Freeze)
    spellAnimating = false
    attackAnimating = false
    delayedFloats = {}
    prevHandEntityIds = nil
    prevEnemyHandEntityIds = nil
    prevManaState = nil
    -- Task 45: Hide DeckBuilder frame on game start
    if ARKANA_DeckBuilder and ARKANA_DeckBuilder.Hide then
        ARKANA_DeckBuilder:Hide()
    end
end

local _netTurnStart = addon.GE_TurnStart
function addon:GE_TurnStart(pIdx)
    _netTurnStart(self, pIdx)
    if addon.IsSpectating and addon:IsSpectating() then
        -- Während Catch-up still aufholen (Board nicht zeigen); live rendert Spec_ShowBoard.
        if addon.Spec_IsCatchup and addon:Spec_IsCatchup() then return end
        addon:Mulligan_Hide()
        if not GB then GB = BuildBoard() end
        GB:Show()
        ClearHighlights()
        addon:Board_Update()
        -- Visueller 90s-Countdown pro beobachtetem Zug (rein Anzeige; das Auto-Zugende
        -- in Network ist für Zuschauer separat geguarded). Startet bei jedem live
        -- beobachteten Zugbeginn neu → deckt sich ~mit dem echten Zug (Netzlatenz).
        StartTurnTicker()
        return
    end
    addon:Mulligan_Hide()
    if not GB then GB = BuildBoard() end
    GB:Show()
    ClearHighlights()
    addon:Board_Update()
    StartTurnTicker()
end

-- Endscreen (Text-Einflug + 10s-Countdown + Auto-Schließen) — gemeinsam für
-- Spieler (SIEG/NIEDERLAGE) und Zuschauer ("<Name> hat gewonnen!")
local function ShowEndScreen(msg, color, sub)
    GB.endGameText:SetText(color .. msg .. "|r")
    if GB.endGameRankText then GB.endGameRankText:SetText(sub or "") end
    GB.endGameOverlay:Show()
    -- Ergebnis ohne Einflug-, Zoom- oder Überschwingeffekt anzeigen.
    if GB.endGameTextFrame then
        GB.endGameTextFrame:SetScale(1)
        GB.endGameTextFrame:SetAlpha(1)
    end
    local secs = 10
    if GB.endGameCountdown then
        GB.endGameCountdown:SetText("Schließt in " .. secs .. "s ...")
    end
    C_Timer.NewTicker(1, function(t)
        secs = secs - 1
        if GB and GB.endGameCountdown then
            if secs > 0 then
                GB.endGameCountdown:SetText("Schließt in " .. secs .. "s ...")
            else
                GB.endGameCountdown:SetText("")
                t:Cancel()
            end
        end
    end, 10)
    C_Timer.After(10, function()
        if GB and GB.endGameOverlay:IsShown() then
            GB.endGameOverlay:Hide()
            if GB.logFrame then GB.logFrame:Hide() end
            GB:Hide()
            if addon.IsSpectating and addon:IsSpectating() and addon.Spec_Leave then
                addon:Spec_Leave()   -- Zuschauer: Watch-Session sauber beenden
            end
            addon:OpenMainMenu()
        end
    end)
end

-- Siegertext für Zuschauer: "<Name> HAT GEWONNEN!" statt SIEG/NIEDERLAGE
local function SpectatorEndText(winner)
    local p1, p2 = "?", "?"
    if addon.Spec_PlayerNames then p1, p2 = addon:Spec_PlayerNames() end
    if winner == "DRAW" then return "Unentschieden!", "|cffffff00" end
    local name = (winner == "first") and p1 or p2
    return tostring(name) .. " hat gewonnen!", "|cffffd700"
end

local _netGameEnd = addon.GE_OnGameEnd
function addon:GE_OnGameEnd(winner)
    _netGameEnd(self, winner)
    ClearHighlights()
    StopTurnTicker()
    HideMinionTooltip()
    pendingFloats = {}
    addon:Mulligan_Hide()
    -- Fullscreen-Auswahl-Overlays abräumen: bleiben sonst bei Spielende offen
    -- stehen (FULLSCREEN_DIALOG, über allem) und blockieren jeden Klick
    if addon.ChooseOne_Hide then addon:ChooseOne_Hide() end
    if addon.Tracking_Hide then addon:Tracking_Hide() end
    if not GB then return end
    if GB.sandboxPanel then GB.sandboxPanel:Hide() end
    if GB.endGameOverlay:IsShown() then return end   -- schon gezeigt (z.B. SPECEND kam zuerst)
    local msg, color, sub
    if addon.IsSpectating and addon:IsSpectating() then
        msg, color = SpectatorEndText(winner)
    else
        local state = addon:GE_State()
        local myRole = state and state.myRole
        if winner == "SANDBOX_END" then
            msg = "Sandbox beendet"; color = "|cffb66dff"
            sub = "Neutral beendet · keine Wertung"
        elseif winner == "DRAW" then
            msg = "Unentschieden!"; color = "|cffffff00"
        elseif winner == myRole then
            msg = "Sieg!"; color = "|cffffd700"
        else
            msg = "Niederlage"; color = "|cffff3333"
        end
        if winner == "SANDBOX_END" then
            -- Der neutrale Sandbox-Hinweis wurde bereits oben gesetzt.
        elseif addon.GE_IsPractice and addon:GE_IsPractice() then
            sub = "Sandbox · ungewertet"
        else
            sub = addon.RK_LastDelta   -- Stern-/Rang-Änderung (nil bei ungewertetem Spiel)
        end
    end
    ShowEndScreen(msg, color, sub)
end

-- ── Zuschauer-Panel (schwarzer Kasten rechts am Brett, wie das Log-Fenster links) ──

local function EnsureWatcherWidget()
    if not GB or GB.watcherPanel then return end
    -- Wie das Log-Fenster: an das Brett angedockt (rechts) und frei verschiebbar
    local panel = CreateFrame("Frame", "ARKANA_WatcherPanel", UIParent)
    panel:SetSize(150, 170)
    panel:SetPoint("TOPLEFT", GB, "TOPRIGHT", 10, 0)  -- rechts neben dem Brett, wie Log links
    panel:SetFrameStrata("HIGH")
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(); bg:SetColorTexture(0, 0, 0, 0.85)
    -- dünner Rahmen
    for _, e in ipairs({ {"TOPLEFT","TOPRIGHT",1,"h"}, {"BOTTOMLEFT","BOTTOMRIGHT",1,"h"},
                         {"TOPLEFT","BOTTOMLEFT",1,"v"}, {"TOPRIGHT","BOTTOMRIGHT",1,"v"} }) do
        local ln = panel:CreateTexture(nil, "OVERLAY")
        ln:SetColorTexture(0.3, 0.3, 0.4, 0.9)
        ln:SetPoint(e[1]); ln:SetPoint(e[2])
        if e[4] == "h" then ln:SetHeight(1) else ln:SetWidth(1) end
    end
    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOPLEFT", 8, -7)
    panel.title = title
    -- scrollbarer Namensbereich
    local sf = CreateFrame("ScrollFrame", "ARKANA_WatcherScroll", panel, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 8, -26)
    sf:SetPoint("BOTTOMRIGHT", -26, 8)
    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(112, 10)
    sf:SetScrollChild(content)
    local names = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    names:SetPoint("TOPLEFT"); names:SetWidth(112); names:SetJustifyH("LEFT")
    names:SetTextColor(0.85, 0.9, 1)
    panel.namesText = names
    panel.content = content
    -- Andock-Button im Kopf: setzt das (evtl. verschobene) Panel zurück an die Standard-Position
    local dock = CreateFrame("Button", nil, panel)
    dock:SetSize(16, 16)
    dock:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -4, -4)
    local dbg = dock:CreateTexture(nil, "BACKGROUND")
    dbg:SetAllPoints(); dbg:SetColorTexture(0.25, 0.25, 0.35, 0.9)
    local dl = dock:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dl:SetAllPoints(); dl:SetJustifyH("CENTER"); dl:SetText("[]")
    dock:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT"); GameTooltip:AddLine("Andocken (zurücksetzen)"); GameTooltip:Show()
    end)
    dock:SetScript("OnLeave", function() GameTooltip:Hide() end)
    dock:SetScript("OnClick", function()
        panel:ClearAllPoints()
        panel:SetPoint("TOPLEFT", GB, "TOPRIGHT", 10, 0)
    end)
    panel:Hide()
    GB.watcherPanel = panel
    -- Panel mit dem Brett ausblenden
    GB:HookScript("OnHide", function() panel:Hide() end)

    -- Toggle-Button AUSSERHALB des Bretts (oben rechts darüber, wie der Zuschauer-Banner):
    -- Panel immer auf-/zuklappbar, ohne das Spielfeld zu überdecken
    local tbtn = CreateFrame("Button", nil, GB)
    tbtn:SetSize(120, 22)
    tbtn:SetPoint("BOTTOMRIGHT", GB, "TOPRIGHT", 0, 4)
    local tbg = tbtn:CreateTexture(nil, "BACKGROUND")
    tbg:SetAllPoints(); tbg:SetColorTexture(0.1, 0.1, 0.15, 0.9)
    local tlbl = tbtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tlbl:SetAllPoints(); tlbl:SetJustifyH("CENTER")
    tbtn.label = tlbl
    tbtn:SetScript("OnClick", function()
        if panel:IsShown() then panel:Hide(); panel.userHidden = true
        else panel:Show(); panel.userHidden = false end
    end)
    tbtn:Hide()
    GB.watcherToggleBtn = tbtn
end

function addon:Spec_RefreshWatcherDisplay()
    if not GB then return end
    EnsureWatcherWidget()
    local count, names = 0, {}
    if addon.Spec_WatcherInfo then count, names = addon:Spec_WatcherInfo() end
    local p = GB.watcherPanel
    local btn = GB.watcherToggleBtn
    if count and count > 0 and GB:IsShown() then
        p.title:SetText("Zuschauer (" .. count .. ")")
        p.namesText:SetText(table.concat(names, "\n"))
        local h = (p.namesText:GetStringHeight() or 12) + 4
        p.content:SetHeight(math.max(h, 10))
        btn.label:SetText("<" .. count .. ">")
        btn:Show()
        if not p.userHidden then p:Show() end  -- vom Nutzer geschlossen? dann zu lassen
    else
        p:Hide()
        btn:Hide()
    end
end

-- ── Zuschauer-Board (read-only) ───────────────────────────────────────────────

local function EnsureSpecOverlay()
    if not GB then return end
    if GB.specBanner then return end
    -- Banner: oberhalb des Bretts (außerhalb der Gegner-Handreihe), damit es nichts überdeckt
    local b = GB:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    b:SetPoint("BOTTOM", GB, "TOP", 0, 6)
    b:SetText("|cffffd700Zuschauermodus|r")
    GB.specBanner = b
    -- Verlassen-Button: rechts mittig, wo sonst der (für Zuschauer versteckte)
    -- "Zug beenden"-Button sitzt — freie Zone, überdeckt keine Karten
    local leave = CreateFrame("Button", nil, GB, "GameMenuButtonTemplate")
    leave:SetSize(150, 40)
    leave:SetPoint("RIGHT", GB, "RIGHT", -8, 0)
    leave:SetText("Zuschauen verlassen")
    if leave:GetFontString() then leave:GetFontString():SetFontObject(GameFontNormalSmall) end
    leave:SetScript("OnClick", function() if addon.Spec_Leave then addon:Spec_Leave() end end)
    GB.specLeaveBtn = leave
end

-- Vor dem Aufbau der Zuschauer-Simulation (SPECINIT): Board verstecken, sauber starten
function addon:Spec_PrepareBoard()
    if GB then GB:Hide() end
end

-- Nach dem Catch-up (SPECDONE): read-only Board zeigen
function addon:Spec_ShowBoard()
    if not GB then GB = BuildBoard() end
    addon:Mulligan_Hide()
    EnsureSpecOverlay()
    -- Tester-Wunsch: gewertet/ungewertet direkt im Zuschauer-Banner
    GB.specBanner:SetText("|cffffd700Zuschauermodus|r  |cffaaaaaa–|r " ..
        ((addon.Spec_IsRankedGame and addon:Spec_IsRankedGame())
            and "|cffffd700gewertetes Spiel|r" or "|cffaaaaaaungewertet|r"))
    GB.specBanner:Show()
    GB.specLeaveBtn:Show()
    GB:Show()
    ClearHighlights()
    -- Countdown für den laufenden Beitritts-Zug (nur Näherung: startet bei 90, der echte
    -- Zug kann schon weiter sein — ab dem nächsten Zugbeginn deckt es sich wieder)
    StartTurnTicker()
end

-- Beim Verlassen / Spielende
function addon:Spec_HideBoard()
    StopTurnTicker()
    if GB then
        if GB.specBanner then
            GB.specBanner:SetText("|cffffd700Zuschauermodus|r")  -- Banner-Text zurücksetzen (kein Emoji: FRIZQT rendert es als leeren Kasten)
            GB.specBanner:Hide()
        end
        if GB.specLeaveBtn then GB.specLeaveBtn:Hide() end
        GB:Hide()
    end
    addon:OpenMainMenu()
end

-- Beobachtetes Spiel endete (z.B. Aufgabe): Banner umschriften, Board bleibt als
-- eingefrorener Endstand stehen; der Verlassen-Button schließt es
function addon:Spec_MarkEnded(winner)
    if not GB then return end
    EnsureSpecOverlay()
    GB.specBanner:SetText("|cffff5555Spiel beendet|r  |cffaaaaaa– Zuschauen verlassen|r")
    GB.specBanner:Show()
    GB.specLeaveBtn:Show()
    -- Endscreen wie beim Spieler ("<Name> hat gewonnen!"), schließt nach 10s
    -- automatisch; nicht doppelt anzeigen (Engine-Ende + SPECEND können beide kommen)
    if GB.endGameOverlay and not GB.endGameOverlay:IsShown() then
        ShowEndScreen(SpectatorEndText(winner))
    end
end

-- Schaltet alle Interaktionen ab (wird bei jedem Board_Update im Zuschauer-Modus
-- aufgerufen, überschreibt die dort gesetzten Klick-Handler)
function addon:Spec_LockBoard()
    if not GB then return end
    for _, s in ipairs(GB.hand)        do s:SetScript("OnClick", nil); s:SetScript("OnEnter", nil); s:SetScript("OnLeave", nil) end
    for _, s in ipairs(GB.playerBoard) do s:SetScript("OnClick", nil) end
    for _, s in ipairs(GB.enemyBoard)  do s:SetScript("OnClick", nil) end
    if GB.playerHero then GB.playerHero:SetScript("OnClick", nil) end
    if GB.enemyHero  then GB.enemyHero:SetScript("OnClick", nil)  end
    -- heroPowerBtn bleibt ENABLED, damit der Hover-Tooltip (ShowHeroPowerTooltip)
    -- funktioniert — die Aktion selbst ist in Board_UseHeroPower per IsSpectating
    -- geblockt. endTurnBtn wird nur versteckt (Klick-Handler bleibt für eigene Spiele).
    if GB.heroPowerBtn then GB.heroPowerBtn:SetEnabled(true) end
    if GB.endTurnBtn then GB.endTurnBtn:SetEnabled(false); GB.endTurnBtn:Hide() end
    if GB.concedeBtn then GB.concedeBtn:Hide() end
    EnsureSpecOverlay()
    GB.specBanner:Show()
    GB.specLeaveBtn:Show()
end

-- Kartennamen im Log-Text als Hyperlinks markieren (Tester-Wunsch: Karte per
-- Hover nachlesen). Zentral hier statt an jedem GE_Log-Callsite. Lookup einmalig,
-- längste Namen zuerst (sonst frisst ein kurzer Name den längeren Treffer).
local logCardNames   -- { {name, id}, ... } nach Namenslänge absteigend
local function LinkCardNames(msg)
    if msg:find("|H", 1, true) then return msg end   -- schon verlinkt (Re-Fill)
    if not logCardNames then
        if not ARKANA_CardData then return msg end
        logCardNames = {}
        for id, cd in pairs(ARKANA_CardData) do
            if cd.name and #cd.name >= 4 then
                logCardNames[#logCardNames + 1] = { name = cd.name, id = id }
            end
        end
        table.sort(logCardNames, function(a, b) return #a.name > #b.name end)
    end
    -- Treffer sammeln (plain find, erste Fundstelle je Name, keine Überlappung)
    local hits = {}
    for _, e in ipairs(logCardNames) do
        local s = msg:find(e.name, 1, true)
        if s then
            local ov = false
            for _, h in ipairs(hits) do
                if s < h.s + h.len and h.s < s + #e.name then ov = true; break end
            end
            if not ov then hits[#hits + 1] = { s = s, len = #e.name, id = e.id } end
        end
    end
    -- von hinten nach vorn einsetzen, damit die Positionen gültig bleiben
    table.sort(hits, function(a, b) return a.s > b.s end)
    for _, h in ipairs(hits) do
        msg = msg:sub(1, h.s - 1)
            -- Blizzard-Reihenfolge: Farbe UM den Link herum (|c…|H…|h Text |h|r).
            -- Farbcode innerhalb des Links ließ die Färbung offen weiterlaufen.
            .. "|cff88ccff|Harkanacard:" .. h.id .. "|h" .. msg:sub(h.s, h.s + h.len - 1) .. "|h|r"
            .. msg:sub(h.s + h.len)
    end
    return msg
end

function addon:GameLog(msg)
    msg = LinkCardNames(msg)
    logBuffer[#logBuffer + 1] = msg
    -- IMMER einschreiben, auch bei verstecktem Fenster (Tester: "Log verschluckt
    -- manchmal Zauber") — Einträge, die zwischen Show() und dem Buffer-Nachfüllen
    -- ankamen, gingen sonst verloren. Beim Öffnen wird ohnehin geleert+neu befüllt.
    if GB and GB.logScroll then
        GB.logScroll:AddMessage(msg)
    end
end

function addon:GE_OnDamage(entityId, amount)
    if not GB or not GB:IsShown() then return end
    local item = { eid=entityId, text="-"..amount, r=1, g=0.25, b=0.25 }
    if spellAnimating or attackAnimating then
        table.insert(delayedFloats, item)
    else
        table.insert(pendingFloats, item)
    end
end

-- Impact-Animation für Fatigue-Schaden (spells/assassinate_impact.m2). Nur für
-- Fatigue, nicht generisch für allen Schaden — Angriff/Zauber haben schon
-- eigene Impacts (AnimateAttack/AnimateSpellImpact); Fatigue hatte bisher gar
-- keinen visuellen Ausschlag, nur die Fließtext-Zahl aus GE_OnDamage.
function addon:GE_OnFatigueDamage(pIdx, amount)
    if not GB or not GB:IsShown() then return end
    local st = addon:GE_State()
    local myIdx = st and st.myPlayerIdx

    -- WICHTIG: noClip (letzter Parameter) muss true sein — der Heldenrahmen ist
    -- nur 132px breit und clippt (SetClipsChildren) das Modell auf diese Größe,
    -- egal welchen impactScale man einstellt. Mit noClip=false (frühere Version
    -- dieser Funktion) sah es deshalb bei jedem Scale-Wert fast identisch aus.
    if pIdx == myIdx then
        -- ── Eigener Held Fatigue ──
        if GB.playerHero and addon.AnimateSpellImpact then
            addon:AnimateSpellImpact(GB.playerHero, nil, {
                impact = 165620,
                impactScale = 1.0,      -- Skalierung für deinen eigenen Helden
                impactSpeed = 0.5,
                duration = 1.2,
                impactX = 0,            -- X-Offset (seitlich)
                impactY = 0,            -- Y-Offset (Tiefe/Höhe im 3D-Raum)
                impactZ = 0,            -- Z-Offset (hoch/runter)
            }, true)
        end
    else
        -- ── Gegner-Held Fatigue ──
        if GB.enemyHero and addon.AnimateSpellImpact then
            addon:AnimateSpellImpact(GB.enemyHero, nil, {
                impact = 165620,
                impactScale = 1.0,      -- Skalierung für den gegnerischen Helden
                impactSpeed = 0.5,
                duration = 1.2,
                impactX = 0,            -- X-Offset (seitlich)
                impactY = 0,            -- Y-Offset (Tiefe/Höhe im 3D-Raum)
                impactZ = 0,            -- Z-Offset (hoch/runter)
            }, true)
        end
    end
end

function addon:GE_OnHeal(entityId, amount)
    if not GB or not GB:IsShown() then return end
    if amount > 0 then
        local item = { eid=entityId, text="+"..amount, r=0.25, g=1, b=0.25 }
        if spellAnimating or attackAnimating then
            table.insert(delayedFloats, item)
        else
            table.insert(pendingFloats, item)
        end
        local st = addon:GE_State()
        local label = (entityId == 1 or entityId == 2) and
            ((st and entityId == st.myPlayerIdx) and "Dein Held" or "Gegner-Held") or "Diener"
        addon:GameLog("[Heilung] +" .. amount .. " auf " .. label)
    end
end

function addon:GetDelayedFloatFrames()
    local frames = {}
    for _, ev in ipairs(delayedFloats) do
        local frame = entityFrameMap[ev.eid]
        if frame then
            frames[frame] = true
        end
    end
    return frames
end

function addon:GetMassDispelTargets(pIdx)
    local state = addon:GE_State()
    if not state then return {} end
    local oppIdx = pIdx == 1 and 2 or 1
    local opp = state.players[oppIdx]
    if not opp or not opp.board then return {} end
    local frames = {}
    for _, m in ipairs(opp.board) do
        local frame = entityFrameMap[m.entityId]
        if frame then
            table.insert(frames, frame)
        end
    end
    return frames
end

function addon:TriggerDelayedFloats()
    for _, ev in ipairs(delayedFloats) do
        local frame = entityFrameMap[ev.eid]
        if frame then
            ShowFloatText(frame, ev.text, ev.r, ev.g, ev.b)
        end
    end
    delayedFloats = {}
    spellAnimating = false
    attackAnimating = false
    addon:Board_Update()
end

function addon:GetAndClearDelayedFloats()
    local copy = {}
    for _, item in ipairs(delayedFloats) do
        table.insert(copy, item)
    end
    delayedFloats = {}
    return copy
end

function addon:ShowFloatTextForFrame(frame, text, r, g, b)
    if frame then
        ShowFloatText(frame, text, r, g, b)
    end
end


-- ── Generische Secret-Animationsbausteine (siehe AnimationsListe.txt Teil 3/4) ──
-- Die Engine wendet den eigentlichen Effekt (Schaden/Rüstung/Bounce) SOFORT an
-- (synchron, noch bevor die UI-Animation überhaupt zu laufen beginnt — HP/Rüstung
-- sind also schon im nächsten Board_Update sichtbar). Damit der visuelle Effekt-
-- Ausschlag nicht wie ein 2s-Nachzügler wirkt, feuert er NICHT im onFinish von
-- addon:AnimateSecretTrigger (das erst nach Fliegen+Hovern+Fade bei ~2s liegt),
-- sondern parallel dazu bei ~0.4s — sobald die Karte sichtbar angekommen ist
-- (Dauer der Fly+Scale-Phase in AnimateSecretTrigger).

-- Impact auf einem oder mehreren Zielen. entityFrameMap deckt Diener UND Helden
-- über ihre entityId ab, daher funktioniert das auch für Helden-Ziele (Sprengfalle).
function addon:SecretAnimateDamageMinion(ownerIdx, secretId, targetEntityIds)
    if type(targetEntityIds) ~= "table" then targetEntityIds = { targetEntityIds } end
    addon:AnimateSecretTrigger(secretId, ownerIdx)
    C_Timer.After(0.4, function()
        for _, eid in ipairs(targetEntityIds) do
            local frame = entityFrameMap[eid]
            if frame then addon:AnimateSpellImpact(frame, secretId) end
        end
    end)
end

-- Eigener Name für Klarheit (Auge um Auge), gleiche Mechanik wie oben
function addon:SecretAnimateDamageHero(ownerIdx, secretId, targetHeroEntityId)
    addon:SecretAnimateDamageMinion(ownerIdx, secretId, targetHeroEntityId)
end

-- Rüstungs-/Schild-Flash auf dem eigenen Helden (Eisbarriere, und als
-- Ersatz-Visual für den reinen Ward-Flash bei Eisblock)
function addon:SecretAnimateGiveArmor(ownerIdx, secretId)
    addon:AnimateSecretTrigger(secretId, ownerIdx)
    C_Timer.After(0.4, function()
        local st = addon:GE_State()
        local myIdx = st and st.myPlayerIdx
        local heroFrame = (ownerIdx == myIdx) and GB.playerHero or GB.enemyHero
        if heroFrame then
            addon:AnimateSpellImpact(heroFrame, secretId, { impact = 166014, impactScale = 1.2, noCamera = true })
        end
    end)
end

-- Eisblock: reiner Ward-Flash, kein Redirect/Summon → gleiches Visual wie GiveArmor
function addon:SecretAnimateProtectHeroShield(ownerIdx, secretId)
    addon:SecretAnimateGiveArmor(ownerIdx, secretId)
end

-- Ziel-Diener fadet weg (kehrt auf die Hand seines Besitzers zurück)
function addon:SecretAnimateBounceMinion(ownerIdx, secretId, targetEntityId)
    addon:AnimateSecretTrigger(secretId, ownerIdx)
    C_Timer.After(0.4, function()
        local frame = entityFrameMap[targetEntityId]
        if not frame then return end
        local fadeGroup = frame:CreateAnimationGroup()
        local fo = fadeGroup:CreateAnimation("Alpha")
        fo:SetFromAlpha(1); fo:SetToAlpha(0); fo:SetDuration(0.3)
        fadeGroup:SetScript("OnFinished", function()
            frame:SetAlpha(1)
            addon:Board_Update()
        end)
        fadeGroup:Play()
    end)
end

-- Zerstäuben: Angreifer-Karte hovert in die Mitte (ohne Shake), Geheimnis daneben,
-- Assassinate-Impact, beide faden. Angriffs-Animation + Schadenszahlen unterdrückt
-- (der Handler läuft in CheckSecrets VOR GE_OnAttack → Flag wirkt rechtzeitig).
function addon:SecretAnimateDestroyCard(ownerIdx, secretId, targetEntityId)
    local frame = entityFrameMap[targetEntityId]
    -- Karten-ID des Angreifers aus den Display-Boards (Engine hat ihn schon getötet)
    local cardId
    for _, list in ipairs({ playerDisplayBoard, enemyDisplayBoard }) do
        for _, item in ipairs(list) do
            if item.m.entityId == targetEntityId then
                cardId = item.m.displayId or item.m.id
            end
        end
    end
    if not frame or not cardId or not addon.AnimateVaporize then
        addon:AnimateSecretTrigger(secretId, ownerIdx)
        return
    end
    addon.vaporizeSuppressAttack = targetEntityId   -- GE_OnAttack für diesen Angriff überspringen
    animatingEntities[targetEntityId] = true        -- Brett-Slot bleibt unsichtbar (Karte fliegt separat)
    local sx, sy = frame:GetCenter()
    addon:Board_Update()
    addon:AnimateVaporize(secretId, ownerIdx, cardId, sx, sy, function()
        animatingEntities[targetEntityId] = nil
        addon:Board_Update()
    end)
end

-- (alter Ablauf, ersetzt durch AnimateVaporize — Funktion bleibt für andere Nutzer erhalten)
function addon:SecretAnimateDestroyCardFade(ownerIdx, secretId, targetEntityId)
    local frame = entityFrameMap[targetEntityId]
    if not frame then
        addon:AnimateSecretTrigger(secretId, ownerIdx)
        return
    end
    if frame.attackGroup then frame.attackGroup:Pause() end
    addon:AnimateSecretTrigger(secretId, ownerIdx, function()
        local fadeGroup = frame:CreateAnimationGroup()
        local fo = fadeGroup:CreateAnimation("Alpha")
        fo:SetFromAlpha(1)
        fo:SetToAlpha(0)
        fo:SetDuration(0.25)
        fadeGroup:SetScript("OnFinished", function()
            frame:Hide()
            frame.vaporized = nil
            if frame.attackGroup then
                frame.attackGroup:Stop()
                frame.attackGroup = nil
            end
            addon:Board_Update()
        end)
        fadeGroup:Play()
    end)
end

-- Spiegelgestalt: Kopie fadet an der Position der Karte ein und fliegt zum Slot
function addon:SecretAnimateCopyCard(ownerIdx, secretId)
    local st = addon:GE_State()
    local ownerBoard = st and st.players[ownerIdx].board
    local copyMinion = ownerBoard and ownerBoard[#ownerBoard]
    if not copyMinion then
        addon:AnimateSecretTrigger(secretId, ownerIdx)
        return
    end
    local entityId = copyMinion.entityId
    animatingEntities[entityId] = true
    local slotIndex = #ownerBoard
    addon.mirrorEntityTriggered = true
    addon:AnimateSecretTrigger(secretId, ownerIdx, nil, copyMinion.id, entityId, slotIndex)
end

-- Gegenzauber: konterte Zauberkarte fadet aus statt zu treffen, kein Impact
function addon:SecretAnimateCounterSpell(ownerIdx, secretId)
    addon:AnimateSecretTrigger(secretId, ownerIdx)
end

-- Zauberformerin: Verteidiger wird neues Zauberziel. Der eigentliche Redirect
-- auf den Diener-Frame passiert über GE_OnSecretEffect unten (feuert NACHDEM
-- die Engine den Verteidiger beschworen hat), addon.spellbenderTriggered
-- schaltet nur den Redirect-Modus in AnimateSpellProjectile scharf.
function addon:SecretAnimateProtectMinion(ownerIdx, secretId)
    addon.spellbenderTriggered = true
    addon.spellbenderRedirectEntityId = nil
    addon:AnimateSecretTrigger(secretId, ownerIdx)
end

-- Bridge für Animations.lua, das keinen Zugriff auf das lokale entityFrameMap hat
function addon:GetEntityFrame(entityId)
    return entityFrameMap[entityId]
end

-- Feuert NACH dem eigentlichen Secret-Effekt (Engine hat data bereits mutiert,
-- z.B. neu beschworene Entities existieren schon im Spielzustand)
function addon:GE_OnSecretEffect(ownerIdx, secretId, data)
    -- Zuschauer-Catch-up kann feuern, bevor das Brett je gebaut wurde (GB=nil);
    -- alle Zweige sind rein visuell, pendingSummonPops würden sonst nur lecken
    if not GB or not GB:IsShown() then return end
    if secretId == "tt_010" and data and data.redirectTarget then
        -- Zauberformerin: Projektil soll auf den beschworenen Diener zielen,
        -- nicht auf die (nur visuelle) Geheimnis-Karte
        addon.spellbenderRedirectEntityId = data.redirectTarget
    elseif secretId == "EX1_554" and data and data.summonedEntityIds then
        -- Schlangenfalle: 3 neu beschworene Diener bekommen beim nächsten
        -- Board_Update einen Pop-Puls (Frame existiert erst danach)
        for _, eid in ipairs(data.summonedEntityIds) do
            pendingSummonPops[#pendingSummonPops+1] = eid
        end
    elseif secretId == "EX1_136" and data and data.revivedEntityId then
        -- Erlösung: wiederbelebter Diener bekommt denselben Pop-Puls
        pendingSummonPops[#pendingSummonPops+1] = data.revivedEntityId
    elseif secretId == "EX1_295" then
        -- Eisblock: Eis-Overlay + Frost-Impact am geretteten Helden
        local st = addon:GE_State()
        local myIdx = st and st.myPlayerIdx
        local heroFrame = (ownerIdx == myIdx) and GB.playerHero or GB.enemyHero
        if heroFrame then
            if heroFrame.iceBlockOverlay then heroFrame.iceBlockOverlay:Show() end
            PlaySound(840)
            if addon.AnimateSpellImpact then
                addon:AnimateSpellImpact(heroFrame, nil, {
                    impact = 1599028, -- spells/cfx_mage_frostbolt_impactchest.m2
                    impactScale = 2.5, noCamera = true, duration = 1.2, impactSize = 300,
                })
            end
        end
    end
end

-- ── Dispatch: secretId → Animationshandler ──────────────────────────────────
-- Secrets ohne eigenen Eintrag fallen auf den generischen Karten-Reveal zurück
-- (siehe AnimationsListe.txt: Schlangenfalle/Erlösung bewusst ohne Extra-
-- Animation belassen — Redirect-Ziel bei Heldenopfer/Irreführung wird direkt
-- in ExecAttack() aufgelöst, nicht über diese Tabelle).
local SECRET_ANIMATIONS = {
    ["EX1_294"] = function(ownerIdx, data) addon:SecretAnimateCopyCard(ownerIdx, "EX1_294") end,
    ["EX1_594"] = function(ownerIdx, data)
        if data and data.attackerEId then
            addon:SecretAnimateDestroyCard(ownerIdx, "EX1_594", data.attackerEId)
        else
            addon:AnimateSecretTrigger("EX1_594", ownerIdx)
        end
    end,
    ["EX1_287"] = function(ownerIdx, data) addon:SecretAnimateCounterSpell(ownerIdx, "EX1_287") end,
    ["tt_010"]  = function(ownerIdx, data) addon:SecretAnimateProtectMinion(ownerIdx, "tt_010") end,

    ["EX1_609"] = function(ownerIdx, data) -- Scharfschießen: 4 Schaden am gespielten Diener
        if data and data.m then
            addon:SecretAnimateDamageMinion(ownerIdx, "EX1_609", data.m.entityId)
        else
            addon:AnimateSecretTrigger("EX1_609", ownerIdx)
        end
    end,
    ["EX1_379"] = function(ownerIdx, data) -- Buße: Leben des gespielten Dieners auf 1
        if data and data.m then
            addon:SecretAnimateDamageMinion(ownerIdx, "EX1_379", data.m.entityId)
        else
            addon:AnimateSecretTrigger("EX1_379", ownerIdx)
        end
    end,
    ["EX1_610"] = function(ownerIdx, data) -- Sprengfalle: 2 Schaden an alle Feinde
        local st = addon:GE_State()
        if not st then addon:AnimateSecretTrigger("EX1_610", ownerIdx); return end
        local enemyIdx = (ownerIdx == 1) and 2 or 1
        local targets = {}
        for _, m in ipairs(st.players[enemyIdx].board) do targets[#targets+1] = m.entityId end
        targets[#targets+1] = st.players[enemyIdx].hero.entityId
        addon:SecretAnimateDamageMinion(ownerIdx, "EX1_610", targets)
    end,
    ["EX1_132"] = function(ownerIdx, data) -- Auge um Auge: Spiegelschaden an gegn. Held
        local st = addon:GE_State()
        if not st then addon:AnimateSecretTrigger("EX1_132", ownerIdx); return end
        local enemyIdx = (ownerIdx == 1) and 2 or 1
        addon:SecretAnimateDamageHero(ownerIdx, "EX1_132", st.players[enemyIdx].hero.entityId)
    end,
    ["EX1_289"] = function(ownerIdx, data) addon:SecretAnimateGiveArmor(ownerIdx, "EX1_289") end,        -- Eisbarriere
    ["EX1_295"] = function(ownerIdx, data) addon:SecretAnimateProtectHeroShield(ownerIdx, "EX1_295") end, -- Eisblock
    ["EX1_611"] = function(ownerIdx, data) -- Eiskältefalle: Angreifer zurück auf die Hand
        if data and data.attackerEId then
            addon:SecretAnimateBounceMinion(ownerIdx, "EX1_611", data.attackerEId)
        else
            addon:AnimateSecretTrigger("EX1_611", ownerIdx)
        end
    end,
}

function addon:GE_OnSecretTrigger(ownerIdx, secretId, data)
    -- Standard-Guard (wie GE_OnDamage/GE_OnHeroPower): beim Zuschauen können Aktionen
    -- eintreffen, bevor das Brett je gebaut wurde → die Handler unten fassen GB/ARKANA_GameBoard an
    if not GB or not GB:IsShown() then return end
    local handler = SECRET_ANIMATIONS[secretId]
    if handler then
        handler(ownerIdx, data)
    else
        addon:AnimateSecretTrigger(secretId, ownerIdx)
    end
end

function addon:ClearMirrorEntityAnimation(entityId)
    animatingEntities[entityId] = nil
    addon:Board_Update()
end

function addon:GE_OnSpellCountered()
    addon.spellCountered = true
end

function addon:IsSpellAnimating()
    return spellAnimating
end

function addon:SetSpellAnimating(val)
    spellAnimating = val
end

function addon:GE_OnCardPlay(pIdx, cardId, handIdx, boardPos, targetEntityId, choiceId)
    local startX, startY
    local st = addon:GE_State()
    if not st then return end
    
    local myIdx = st.myPlayerIdx
    local btn
    if pIdx == myIdx then
        btn = GB and GB.hand and GB.hand[handIdx + 1]
    else
        btn = GB and GB.enemyHand and GB.enemyHand[handIdx + 1]
    end
    
    if btn and btn:IsShown() then
        startX, startY = btn:GetCenter()
    end
    
    if not startX or not startY then
        -- Default to center of screen (already in UIParent units)
        startX = GetScreenWidth() / 2
        startY = GetScreenHeight() / 2
    end
    
    local cardData = CD(cardId)
    local isMinion = cardData and cardData.type == "MINION"
    
    if isMinion then
        -- Clamp boardPos to the actual insertion index where the engine inserts the minion.
        -- This ensures the animation targets the correct newly-added slot index.
        local board = st.players[pIdx].board
        local pos = (boardPos >= 0 and boardPos <= #board) and (boardPos + 1) or (#board + 1)
        
        pendingPlayAnimation = {
            pIdx = pIdx,
            cardId = cardId,
            startX = startX,
            startY = startY,
            boardPos = pos - 1
        }
    else
        spellAnimating = true
        delayedFloats = {}
        local targetFrame = targetEntityId and targetEntityId ~= 0 and entityFrameMap[targetEntityId] or nil
        
        -- Support Choose One choice IDs or fall back to main card ID
        local visualId = choiceId or cardId
        local override = addon.CARD_VISUAL_OVERRIDES and (addon.CARD_VISUAL_OVERRIDES[choiceId] or addon.CARD_VISUAL_OVERRIDES[cardId])
        if not targetFrame and override and override.isAOE and addon.ENABLE_AOE_SPELL_EFFECTS then
            targetFrame = GB
        end
        
        addon:AnimatePlaySpell(visualId, startX, startY, targetFrame, nil, pIdx)
    end
end

function addon:GE_OnTracking(pIdx, choices)
    local st = addon:GE_State()
    if not st then return end
    
    local myIdx = st.myPlayerIdx
    if pIdx == myIdx then
        addon:Tracking_Show(choices, function(chosenId)
            addon:Net_TrackingChoose(chosenId)
        end)
    end
end

function addon:GE_OnBattlecry(pIdx, cardId, targetId, mPos)
    if not targetId or targetId == 0 then return end
    local targetFrame = entityFrameMap[targetId]
    if targetFrame then
        spellAnimating = true
        delayedFloats = {}
        
        -- Battlecry minion is played from hand, so the card is always floating in the center.
        -- We always launch the projectile from the screen center.
        local startSourceX = GetScreenWidth() / 2
        local startSourceY = GetScreenHeight() / 2
        
        local cardData = CD(cardId)
        local hasBattlecry = false
        if cardData and cardData.tags then
            for _, tag in ipairs(cardData.tags) do
                if tag.type == "BATTLECRY" then
                    hasBattlecry = true
                    break
                end
            end
        end
        local override = addon.CARD_VISUAL_OVERRIDES and addon.CARD_VISUAL_OVERRIDES[cardId]
        if hasBattlecry or (override and override.isBattlecry) then
            C_Timer.After(0.35, function()
                addon:AnimateSpellProjectile(targetFrame, cardId, addon.USE_3D_SPELL_EFFECTS, startSourceX, startSourceY)
            end)
        else
            addon:AnimateSpellProjectile(targetFrame, cardId, addon.USE_3D_SPELL_EFFECTS, startSourceX, startSourceY)
        end
    end
end

function addon:GE_OnHeroPower(pIdx, class, targetEntityId)
    -- Zuschauer-Catch-up kann feuern, bevor das Brett je gebaut wurde (GB=nil)
    if not GB or not GB:IsShown() then return end
    local state = addon:GE_State()
    if not state then return end
    
    local isMyHeroPower = (pIdx == state.myPlayerIdx)
    local casterFrame = isMyHeroPower and GB.playerHero or GB.enemyHero
    if not casterFrame then return end

    local targetFrame = targetEntityId and entityFrameMap[targetEntityId]
    -- Auto-Ziel-Heldenpowers senden targetEntityId=0 (Protokoll-Sentinel) — das
    -- Ziel wie in der Engine ableiten, sonst spielt der Impact am eigenen Helden
    -- und das Projektil hat kein Ziel (Jäger: immer der gegnerische Held)
    if not targetFrame and class == "HUNTER" then
        targetFrame = isMyHeroPower and GB.enemyHero or GB.playerHero
    end

    local hpVisuals = {
        MAGE = {
            projectile = 1327009,      -- spells/cfx_mage_fireball_missile.m2
            projScale = 1.0,
            autoRotate = true,
            impact = 1327007,         -- spells/cfx_mage_fireball_impact.m2
            impactScale = 0.6,
            noCamera = true,
        },
        PRIEST = {
            projectile = nil,
            impact = 850704,          -- spells/flashheal_base.m2
            impactScale = 0.8,
            noCamera = true,
        },
        SHADOW_PRIEST = {
            projectile = 1955423,     -- spells/cfx_warlock_shadowbolt_missile.m2
            projScale = 1.0,
            autoRotate = true,
            impact = 1664779,         -- spells/cfx_priest_mindblast_impacthead.m2
            impactScale = 1,
            impactSize = 100,         -- Macht das 3D-Rendertab groß genug, damit nichts abschneidet!
            noCamera = true,
        },
        SHADOW_PRIEST_UPGRADED = {
            projectile = 1955423,     -- spells/cfx_warlock_shadowbolt_missile.m2
            projScale = 1.2,
            autoRotate = true,
            impact = 1664779,         -- spells/cfx_priest_mindblast_impacthead.m2
            impactScale = 0.5,
            impactSize = 400,         -- Macht das 3D-Rendertab groß genug, damit nichts abschneidet!
            noCamera = true,
        },
        HUNTER = {
            projectile = 166315,      -- Cupid's arrow
            projScale = 2.5,
            autoRotate = true,
            baseYaw = 3.14,           -- Pfeilspitze zeigt bei Default-Yaw nach rechts statt in
                                      -- Flugrichtung → 90° (1.57) zusätzlich zum autoRotate-Standard
            impact = 166314,
            impactScale = 1.5,
            impactYaw = 2.36,
            noCamera = true,
        },
        WARRIOR = {
            projectile = nil,
            impact = 166014,          -- spells/shieldblock.m2
            impactScale = 1.2,
            selfCast = true,
            noCamera = true,
        },
        DRUID = {
            projectile = nil,
            impact = nil,             -- 165682 (claw_impact.m2) verursachte ACCESS_VIOLATION-Clientcrash, fällt auf ImpactModels.DEFAULT zurück
            impactScale = 1.2,
            selfCast = true,
            noCamera = true,
        },
        PALADIN = {
            projectile = nil,
            impact = 166197,          -- paladin blessing/holy light
            impactScale = 1.2,
            selfCast = true,
            noCamera = true,
        },
        WARLOCK = {
            projectile = nil,
            impact = 166795,          -- shadow/lifetap impact
            impactScale = 1.2,
            selfCast = true,
            noCamera = true,
        },
        SHAMAN = {
            projectile = nil,
            impact = 165780,          -- spells/chainlightning_impact_chest.m2
            impactScale = 1.2,
            selfCast = true,
            noCamera = true,
        },
    }

    local cfg = hpVisuals[class]
    if not cfg then return end

    spellAnimating = true
    delayedFloats = {}

    if cfg.selfCast or not targetFrame then
        addon:AnimateSpellImpact(casterFrame, nil, cfg, true)
        C_Timer.After(0.15, function()
            if addon.TriggerDelayedFloats then addon:TriggerDelayedFloats() end
        end)
    else
        if cfg.projectile then
            -- casterFrame direkt übergeben (statt GetCenter-Zahlen): der Frame-Zweig
            -- von AnimateSpellProjectile rechnet die Brett-Skala korrekt um
            addon:AnimateSpellProjectile(targetFrame, nil, addon.USE_3D_SPELL_EFFECTS, casterFrame, nil, cfg)
        else
            addon:AnimateSpellImpact(targetFrame, nil, cfg)
            C_Timer.After(0.15, function()
                if addon.TriggerDelayedFloats then addon:TriggerDelayedFloats() end
            end)
        end
    end
end

-- fallbackDefenderEId: bei Redirect-Secrets, die einen neuen Diener beschwören
-- (z.B. Heldenopfer), existiert dessen Frame im entityFrameMap noch nicht (das
-- Board wurde seit der Beschwörung noch nicht neu aufgebaut) — dann auf das
-- ursprüngliche Ziel zurückfallen, statt die Animation ganz zu überspringen.
function addon:GE_OnAttack(attackerEId, defenderEId, fallbackDefenderEId)
    -- Zerstäuben: der Angriff wurde abgebrochen, die Vaporize-Choreo läuft separat —
    -- weder Angriffs-Animation noch Schadenszahlen abspielen
    if addon.vaporizeSuppressAttack == attackerEId then
        addon.vaporizeSuppressAttack = nil
        return
    end
    attackAnimating = true
    delayedFloats = {}
    local attackerFrame = entityFrameMap[attackerEId]
    local defenderFrame = entityFrameMap[defenderEId]
    if not defenderFrame and fallbackDefenderEId then
        defenderFrame = entityFrameMap[fallbackDefenderEId]
    end
    if attackerFrame and defenderFrame then
        local st = addon:GE_State()
        local isWeaponAttack = false
        if st then
            for pIdx = 1, 2 do
                if st.players[pIdx].hero.entityId == attackerEId and st.players[pIdx].weapon then
                    isWeaponAttack = true
                    break
                end
            end
        end

        addon:AnimateAttack(attackerFrame, defenderFrame, nil, isWeaponAttack)
    else
        -- Frames fehlen (frisch beschworener Diener, Zuschauer-Catch-up): keine
        -- Animation möglich → Flag sofort freigeben, sonst hängt es für immer
        attackAnimating = false
    end
end

-- Slot-Buttons: zwischen den Feldern positioniert
local SLOT_GAP = 8
local SLOT7_W  = 7 * MINION_W + 6 * SLOT_GAP
local SLOT7_X0 = -SLOT7_W / 2 + MINION_W / 2

function addon:Board_ShowSlotButtons(n)
    if not GB.slotBtns then GB.slotBtns = {} end
    local count = math.min(n + 1, 8)  -- max 8 Positionen (Brett voll = 7 Minions, keine neue Position)
    if n >= 7 then addon:Board_HideSlotButtons(); return end
    for i = 1, 8 do
        if not GB.slotBtns[i] then
            local sb = CreateFrame("Button", nil, GB)
            sb:SetSize(20, MINION_H)
            sb:SetFrameStrata("HIGH")
            local sbBg = sb:CreateTexture(nil, "BACKGROUND")
            sbBg:SetAllPoints(); sbBg:SetColorTexture(0.2, 1, 0.2, 0.7)
            local sbTxt = sb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            sbTxt:SetAllPoints(); sbTxt:SetText("+")
            sb:Hide()
            GB.slotBtns[i] = sb
        end
    end
    for i = 1, count do
        local sb = GB.slotBtns[i]
        -- Position: links neben Slot i-1 (0-basiert = boardPos i-1)
        -- boardPos i-1 → vor Slot i-1 = zwischen Slot i-2 und Slot i-1
        local x
        if i == 1 then
            x = SLOT7_X0 - (MINION_W / 2 + SLOT_GAP / 2 + 10)  -- ganz links
        else
            local prevSlotX = SLOT7_X0 + (i - 2) * (MINION_W + SLOT_GAP)
            x = prevSlotX + MINION_W / 2 + SLOT_GAP / 2  -- zwischen Slot i-2 und i-1
        end
        sb:ClearAllPoints()
        sb:SetPoint("CENTER", GB, "CENTER", x, -65)
        sb.boardPos = i - 1  -- 0-basiert
        sb:SetScript("OnClick", function(self) addon:Board_ClickSlot(self.boardPos) end)
        sb:Show()
    end
    for i = count + 1, 8 do
        if GB.slotBtns[i] then GB.slotBtns[i]:Hide() end
    end
end

function addon:Board_HideSlotButtons()
    if GB.slotBtns then
        for _, sb in ipairs(GB.slotBtns) do sb:Hide() end
    end
end

function addon:Board_ClickSlot(boardPos)
    if not selected or selected.type ~= "hand" then return end
    local savedIdx = selected.idx
    local savedChoice = selected.pendingChoice
    local target = selected.chosenTarget
    ClearHighlights()
    addon:Board_HideSlotButtons()
    addon:Net_PlayCard(savedIdx, target, boardPos, savedChoice)
    addon:Board_Update()
end

function addon:ResetUIPositions()
    if GB then
        GB:ClearAllPoints()
        GB:SetPoint("CENTER")
    end
    local lf = _G["ARKANA_LogFrame"]
    if lf then
        lf:ClearAllPoints()
        if GB then
            lf:SetPoint("TOPRIGHT", GB, "TOPLEFT", -10, 0)
        else
            lf:SetPoint("CENTER", UIParent, "CENTER", -600, 0)
        end
        -- ScrollingMessageFrame verliert Inhalt beim Repositionieren → Buffer neu einlesen
        if lf:IsShown() and GB and GB.logScroll then
            GB.logScroll:Clear()
            for _, msg in ipairs(logBuffer) do
                GB.logScroll:AddMessage(msg)
            end
        end
    end
    -- Tester-Wunsch: /arkana reset setzt AUCH Größe, Tooltip-Größe und Deckkraft zurück
    if ARKANA_Settings then
        ARKANA_Settings.windowScale  = 1.0
        ARKANA_Settings.boardScale   = 1.0
        ARKANA_Settings.tooltipScale = 1.0
        ARKANA_Settings.boardAlpha   = 1.0
        if addon.UI_SetTheme then addon:UI_SetTheme("STANDARD") end
    end
    addon:ApplyScales()
    if addon.RefreshScalePanel then addon:RefreshScalePanel() end
    print("|cff00ff00[Arkana]|r Position, Größe, Deckkraft und Theme zurückgesetzt.")
end

function addon:Board_IsActive()
    return GB ~= nil and GB:IsShown()
end
