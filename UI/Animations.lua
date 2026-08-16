local addon = Arkana

-- Configuration toggle: Set to true for 3D spell models, false for 2D spell sprites
addon.USE_3D_SPELL_EFFECTS = true
-- Set to true to enable AOE spell animations (visuals on the board/multiple targets)
local ENABLE_AOE_SPELL_EFFECTS = false
addon.ENABLE_AOE_SPELL_EFFECTS = ENABLE_AOE_SPELL_EFFECTS

-- Visual overrides for specific cards (Battlecries, custom spells)
local CARD_VISUAL_OVERRIDES = {
    -- Moonfire (Mondfeuer) - vertical moonbeam
    ["CS2_008"] = {
        projectile = nil,
        impact = 166593, -- spells/moonfire_impact_base.m2
        impactScale = 1,
    },
    -- Fireball (Feuerball) - Mage spell
    ["CS2_029"] = {
        projectile = 1327009, -- spells/cfx_mage_fireball_missile.m2
        projScale = 1.2,
        autoRotate = true,
        impact = 1327007, -- spells/cfx_mage_fireball_impact.m2
        impactScale = 0.6,
    },
    -- Pyroblast (Pyroschlag) - Mage spell, großer Feuerball
    ["EX1_279"] = {
        projectile = 1327018, -- pyroblast missile
        projScale = 1.2,
        autoRotate = true,
        impact = 1327017, -- pyroblast impact
        impactScale = 0.6,
    },
    -- Elven Archer (Elfenbogenschützin) - shoots hunter arrow
    ["CS2_189"] = {
        projectile = 166315,
        projScale = 3,
        autoRotate = true,
        impact = 166314,
        impactScale = 2,
        impactYaw = 2.36,
        isBattlecry = true,
        noCamera = true,
    },
    -- Voodoo Doctor (Vodoodoktor) - lesser heal impact (no projectile)
    ["EX1_011"] = {
        projectile = nil,
        impact = 850704, -- spells/lesserheal_base.m2
        impactScale = 1.2,
        isBattlecry = true,
        noCamera = true,
    },
    -- Mind Control (Gedankenkontrolle) - cast on hero, impact on minion (no projectile)
    ["CS1_113"] = {
        projectile = 166658,
        projScale = 1.5,
        impact = 949712, -- spells/cfx_priest_mindgames_impact.m2
        impactScale = 0.3,
        impactSize = 600,
        noCamera = true,
    },
    -- Shadow Madness (Dunkler Wahnsinn) - cast on hero, impact on minion (no projectile)
    ["EX1_334"] = {
        projectile = 166658,
        projScale = 1.5,
        impact = 949712,
        impactScale = 0.3,
        impactSize = 600,
        noCamera = true,
    },
    -- Cabal Shadow Priest (Kabaleschattenpriesterin) - cast on minion, impact on target (no projectile)
    ["EX1_091"] = {
        projectile = 166658,
        projScale = 1.5,
        impact = 949712,
        impactScale = 0.3,
        impactSize = 600,
        isBattlecry = true,
        noCamera = true,
    },
    -- Mind Control Tech (Gedankenkontrolleur) - cast on minion, impact on target (no projectile)
    ["EX1_085"] = {
        projectile = 166658,
        projScale = 1.5,
        impact = 949712,
        impactScale = 0.3,
        impactSize = 600,
        isBattlecry = true,
        noCamera = true,
    },
    -- Holy Light (Heiliges Licht) - paladin/holy flash heal (no projectile)
    ["CS2_089"] = {
        projectile = nil,
        impact = 850704, -- spells/flashheal_base.m2
        impactScale = 1.3,
        noCamera = true,
    },
    -- Argentumbeschützer (Argent Protector) - paladin/holy flash heal (no projectile, isBattlecry)
    ["EX1_362"] = {
        projectile = nil,
        impact = 850704, -- spells/flashheal_base.m2
        impactScale = 1.3,
        noCamera = true,
        isBattlecry = true,
    },
    -- Ironbeak Owl (Eisenschnabeleule) - silence effect
    ["CS2_203"] = {
        projectile = nil,
        impact = 512411, -- spells/silence_state.m2
        impactScale = 1.2,
        isBattlecry = true,
    },
    -- Silence (Stille) - Priest spell silence
    ["EX1_332"] = {
        projectile = nil,
        impact = 512411, -- spells/silence_state.m2
        impactScale = 1.2,
    },
    -- Consecration (Weihe) - centered on board, birds-eye view, 3s duration
    ["CS2_093"] = {
        projectile = nil,
        impact = 1058980, -- spells/consecration_impact_base_pulse.m2 (ground cracks)
        impactScale = 3.0,
        isAOE = true,
        pitch = 1.57,
        duration = 3.0,
        noCamera = false,
    },
    -- Whirlwind (Wirbelwind) - hits all targets individually, physischer Schaden
    ["EX1_400"] = {
        projectile = nil,
        impact = 165646, -- spells/backstab_impact_chest.m2
        impactScale = 1.2,
    },
    -- Flamestrike (Flammenstoß) - centered on board, birds-eye, 3s duration
    -- Einzel-Impact pro Ziel: generischer "elementarer" Treffer (User-Wunsch)
    ["CS2_032"] = {
        projectile = nil,
        impact = 165795, -- spells/clearcasting_impact_chest.m2
        impactScale = 2.5,
        isAOE = true,
        pitch = 1.1,
        duration = 3.0,
        noCamera = true,
    },
    -- Blizzard - frostballs falling from above onto each target individually
    ["CS2_028"] = {
        projectile = nil,
        impact = 165795, -- spells/clearcasting_impact_chest.m2
        impactScale = 1.2,
        pitch = 1.1,
        duration = 2.0,
        noCamera = true,
    },
    -- Hellfire (Höllenfeuer) - centered on board, birds-eye, 3s duration
    ["CS2_062"] = {
        projectile = nil,
        impact = 165795, -- spells/clearcasting_impact_chest.m2
        impactScale = 2.5,
        isAOE = true,
        pitch = 1.1,
        duration = 3.0,
        noCamera = true,
    },
    -- Starfall (Sternenregen) AOE Choice - rain on all targets individually
    ["NEW1_007a"] = {
        projectile = nil,
        impact = 165795, -- spells/clearcasting_impact_chest.m2
        impactScale = 1.2,
        pitch = 1.1,
        duration = 3.0,
        noCamera = true,
    },
    -- Starfall (Sternenregen) Single Target Choice - falling star missile
    ["NEW1_007b"] = {
        projectile = 240877, -- spells/druid_starfall_missile.m2
        impact = 1063414, -- generic impact
        impactScale = 1.0,
    },
    -- Mass Dispel (Massenbannung) - silence effect on all targets
    ["EX1_626"] = {
        projectile = nil,
        impact = 512411, -- spells/silence_state.m2
        impactScale = 1.2,
    },
    -- Arcane Missiles (Arkane Geschosse)
    ["EX1_277"] = {
        projectile = 165570,
        projScale = 1.0,
        projDuration = 0.6,   -- Langsamerer Flug
        missileGap = 0.22,    -- Schnellerer Abschuss-Abstand für Überlappung
        autoRotate = true,
        baseYaw = 3.10,
        projPitch = 1.76,
        impact = 950910,
        impactScale = 1.0,
        cardFadeDelay = 1.3,  -- Zauberkarte länger stehen lassen (Geschoss-Kette läuft noch)
    },
    -- Counterspell (Gegenzauber): Silence-Impact auf der gekonterten Zauberkarte
    ["EX1_287"] = {
        projectile = nil,
        impact = 512411, -- spells/silence_state.m2 (wie Massenbannung)
        impactScale = 1.2,
    },
    -- Polymorph (Verwandlung)
    ["CS2_022"] = {
        projectile = nil,
        impact = 165970, -- spells/druidmorph_impact_base.m2
        impactScale = 1.0,
    },
    ["VAN_CS2_022"] = {
        projectile = nil,
        impact = 165970,
        impactScale = 1.0,
    },
    -- Hex (Verhexung)
    ["EX1_246"] = {
        projectile = nil,
        impact = 165970, -- spells/druidmorph_impact_base.m2
        impactScale = 1.0,
    },
    ["VAN_EX1_246"] = {
        projectile = nil,
        impact = 165970,
        impactScale = 1.0,
    }
}
addon.CARD_VISUAL_OVERRIDES = CARD_VISUAL_OVERRIDES

-- ── Frame-Pools für Projektile/Impacts/Dummies ───────────────────────────────
-- WoW gibt Frames NIE wieder frei: ohne Wiederverwendung erzeugt jeder Zauber
-- neue PlayerModel-Frames mit geladenen M2s — nach mehreren Partien hunderte
-- (Tester: "Client hängt sich nach mehreren Runden auf"). Der gen-Zähler
-- entwertet alte C_Timer-Closures, wenn ein Frame vor deren Ablauf schon
-- wiederverwendet wurde. MUSS vor der ersten Verwendung stehen (locals!).
local framePools = { proj3d = {}, proj2d = {}, imp3d = {}, imp2d = {}, point = {} }

local function AcquirePooled(kind)
    local pool = framePools[kind]
    local f
    for _, p in ipairs(pool) do
        if not p.inUse then f = p; break end
    end
    if not f then
        f = CreateFrame("Frame", nil, UIParent)
        if kind == "proj3d" or kind == "imp3d" then
            f.model = CreateFrame("PlayerModel", nil, f)
            f.model:SetAllPoints(f)
        elseif kind == "proj2d" or kind == "imp2d" then
            f.tex = f:CreateTexture(nil, "OVERLAY")
            f.tex:SetAllPoints()
        end
        pool[#pool + 1] = f
    end
    f.inUse = true
    f.gen = (f.gen or 0) + 1
    f:SetAlpha(1)
    f:SetScale(1)
    return f
end

local function ReleasePooled(f)
    f:SetScript("OnUpdate", nil)
    if f.model then
        f.model:SetScript("OnUpdate", nil)
        f.model:ClearModel()
    end
    f:Hide()
    f:ClearAllPoints()
    f:SetParent(UIParent)   -- keine Referenz auf Brett-Slots behalten
    f.inUse = false
end

local animFramePool = {}
-- Alle Koordinaten für die Anim-Frames (GetCenter von Brett-Kindern, GetSlotCoords)
-- kommen aus dem Skalenraum des BRETTS. Die Anim-Frames hängen aber an UIParent —
-- seit dem Brett-Scale-Slider (boardScale ≠ 1, Session 30) verschob das jede
-- Animation Richtung unten-links (Faktor 1/boardScale). Deshalb bekommen die
-- Pool-Frames dieselbe effektive Skala wie das Brett: dann ist ihr Koordinaten-
-- raum identisch und ALLE Brett-Raum-Werte (Slots, Helden, Hand, beide Seiten)
-- verankern korrekt — und die Karten skalieren optisch mit dem Brett mit.
local function BoardRelScale()
    return (ARKANA_GameBoard and UIParent:GetEffectiveScale() > 0)
        and (ARKANA_GameBoard:GetEffectiveScale() / UIParent:GetEffectiveScale())
        or 1.0
end
local function GetAnimFrame()
    for _, f in ipairs(animFramePool) do
        if not f:IsShown() and not f.inUse then
            f.inUse = true
            f:SetScale(BoardRelScale())
            return f
        end
    end
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetFrameStrata("TOOLTIP") -- Draw on top of everything
    f:SetScale(BoardRelScale())
    local tex = f:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetTexCoord(0, 1, 0, 0.758) -- Crop bottom transparent padding
    f.tex = tex
    f.inUse = true
    table.insert(animFramePool, f)
    return f
end

-- Map card IDs to spell schools dynamically based on CardData class fields
local function GetSpellSchool(cardId)
    local card = ARKANA_CardData and ARKANA_CardData[cardId]
    if not card then return "DEFAULT" end
    
    local class = card.class
    local id = cardId
    
    -- Specific override maps for Mage (who has Fire, Frost, Arcane)
    if class == "MAGE" then
        if id == "CS2_029" or id == "CS2_032" then -- Fireball, Flamestrike
            return "FIRE"
        elseif id == "CS2_024" or id == "EX1_275" or id == "CS2_026" or id == "CS2_028" or id == "CS2_031" then -- Frostbolt, Cone of Cold, Frost Nova, Blizzard, Ice Lance
            return "FROST"
        else
            return "ARCANE"
        end
    end
    
    -- Specific overrides for Priest (Holy vs Shadow)
    if class == "PRIEST" then
        if id == "DS1_233" or id == "CS2_233" or id == "EX1_622" or id == "CS1_113" then
            -- Mind Blast, Shadow Word: Pain, Shadow Word: Death, Mind Control
            return "SHADOW"
        else
            return "HOLY"
        end
    end
    
    -- Specific overrides for Shaman (Nature vs Fire vs Frost)
    if class == "SHAMAN" then
        if id == "EX1_241" then -- Lavaeruption
            return "FIRE"
        elseif id == "CS2_037" then -- Frostschock
            return "FROST"
        else
            return "NATURE"
        end
    end
    
    -- General class-to-school mapping
    if class == "DRUID" then
        return "NATURE"
    elseif class == "PALADIN" then
        return "HOLY"
    elseif class == "WARLOCK" then
        if id == "CS2_062" then -- Hellfire
            return "FIRE"
        end
        return "SHADOW"
    end
    
    return "DEFAULT"
end

-- Animate a minion moving across the board when control changes
function addon:AnimateControlChange(cardId, startX, startY, targetX, targetY, onFinish)
    local f = GetAnimFrame()
    f:ClearAllPoints()
    local w, h = 88, 122
    f:SetSize(w, h)
    f:SetPoint("CENTER", UIParent, "BOTTOMLEFT", startX, startY)
    
    local color = addon.tokenColors and addon.tokenColors[cardId]
    if color then
        f.tex:SetTexture("Interface\\Buttons\\WHITE8X8")
        f.tex:SetVertexColor(color[1], color[2], color[3])
        f.tex:SetTexCoord(0, 1, 0, 1)
    else
        f.tex:SetTexture((addon.CS_AnyArt and addon:CS_AnyArt(cardId))
        or ("Interface\\AddOns\\Arkana\\Textures\\Cards\\" .. cardId .. ".tga"))
        f.tex:SetVertexColor(1, 1, 1)
        f.tex:SetTexCoord(0, 1, 0, 0.758)
    end
    
    f:SetAlpha(1)
    f:Show()

    local group = f:CreateAnimationGroup()
    
    local trans = group:CreateAnimation("Translation")
    trans:SetOffset(targetX - startX, targetY - startY)
    trans:SetDuration(0.6)  -- slower movement for a nice visual swing
    trans:SetSmoothing("IN_OUT")

    group:SetScript("OnFinished", function()
        f:Hide()
        f.inUse = false
        -- Reset to defaults when returning to pool
        f.tex:SetTexCoord(0, 1, 0, 0.758)
        f.tex:SetVertexColor(1, 1, 1)
        if onFinish then onFinish() end
    end)

    group:Play()
end

-- Fly a minion card to its board slot
function addon:AnimatePlayCard(cardId, startX, startY, targetX, targetY, onFinish)
    local f = GetAnimFrame()
    f:ClearAllPoints()
    local w, h = 88, 122
    f:SetSize(w, h)
    f:SetPoint("CENTER", UIParent, "BOTTOMLEFT", startX, startY)
    f.tex:SetTexture((addon.CS_AnyArt and addon:CS_AnyArt(cardId))
        or ("Interface\\AddOns\\Arkana\\Textures\\Cards\\" .. cardId .. ".tga"))
    f:SetAlpha(1)
    f:Show()

    local group = f:CreateAnimationGroup()
    
    local trans = group:CreateAnimation("Translation")
    trans:SetOffset(targetX - startX, targetY - startY)
    trans:SetDuration(0.35)
    trans:SetSmoothing("IN_OUT")

    group:SetScript("OnFinished", function()
        f:Hide()
        f.inUse = false
        if onFinish then onFinish() end
    end)

    group:Play()
end

-- Fly a newly drawn card from the deck into its hand slot, flipping from
-- card-back to front partway through the flight. faceDown=true keeps it as a
-- card back the whole time (opponent draws — the card identity is hidden).
function addon:AnimateCardDraw(cardId, startX, startY, targetX, targetY, onFinish, faceDown)
    local f = GetAnimFrame()
    f:ClearAllPoints()
    local w, h = 88, 122
    f:SetSize(w, h)
    f:SetPoint("CENTER", UIParent, "BOTTOMLEFT", startX, startY)
    -- Kartenrücken-Skin des Ziehenden: faceDown = Gegner zieht, sonst wir selbst
    local backTex
    if faceDown then
        backTex = addon.CB_PeerBackTexture and addon:CB_PeerBackTexture()
    else
        backTex = addon.CB_MyBackTexture and addon:CB_MyBackTexture()
    end
    f.tex:SetTexture(backTex or "Interface\\AddOns\\Arkana\\Textures\\card_back.tga")
    f:SetAlpha(1)
    f:Show()

    local group = f:CreateAnimationGroup()

    local trans = group:CreateAnimation("Translation")
    trans:SetOffset(targetX - startX, targetY - startY)
    trans:SetDuration(0.35)
    trans:SetSmoothing("IN_OUT")

    if not faceDown then
        C_Timer.After(0.18, function()
            if f:IsShown() then
                f.tex:SetTexture((addon.CS_AnyArt and addon:CS_AnyArt(cardId))
        or ("Interface\\AddOns\\Arkana\\Textures\\Cards\\" .. cardId .. ".tga"))
            end
        end)
    end

    group:SetScript("OnFinished", function()
        f:Hide()
        f.inUse = false
        if onFinish then onFinish() end
    end)

    group:Play()
end

-- Quick "pop" pulse for stat gems (ATK/HP) when the value changes.
-- BEWUSST OHNE AnimationGroup UND OHNE SetScale: Auf diesem Core (a) hinterlassen
-- Scale-Animationen bei Unterbrechung dauerhaft veränderte Frame-Scales
-- (kumulativer Schrumpf-Drift, vererbt über positions-gepoolte Gem-Frames an
-- Slot-Nachrücker) und (b) löst SetScale auf verankerten Kind-Frames die Anker
-- für 1-2 Frames im falschen Koordinatenraum auf → Gem "teleportiert" kurz an
-- den oberen Bildschirmrand (Video-Analyse "Zahlenfliegen.mp4", Frames 53-54).
-- Der Puls läuft daher über die Frame-GRÖSSE (SetSize, absolute Werte) — die
-- Verankerung bleibt dabei auf jedem Core stabil.
-- die Zahl selbst pulsiert nicht mit (FontString-Größe ist fix) —
-- nur der Gem-Hintergrund. Reicht als Feedback; Font-Puls nachrüsten falls vermisst.
function addon:AnimateStatPop(frame)
    if not frame then return end
    if not frame.popBaseW then
        local w, h = frame:GetSize()
        if not w or w == 0 then return end
        frame.popBaseW, frame.popBaseH = w, h   -- Basisgröße EINMALIG merken (nie aus laufendem Puls lesen)
    end
    frame.popT = 0
    if frame.popRunning then return end   -- läuft schon: Zeit-Reset genügt
    frame.popRunning = true
    frame:SetScript("OnUpdate", function(self, dt)
        self.popT = self.popT + dt
        local t = self.popT
        local f
        if t < 0.12 then
            f = 1 + 0.35 * (t / 0.12)
        elseif t < 0.27 then
            f = 1.35 - 0.35 * ((t - 0.12) / 0.15)
        else
            self:SetSize(self.popBaseW, self.popBaseH)
            self:SetScript("OnUpdate", nil)
            self.popRunning = nil
            return
        end
        self:SetSize(self.popBaseW * f, self.popBaseH * f)
    end)
end

-- Fly the original minion card that triggers Mirror Entity to board center, hover, and fly to board slot
function addon:AnimatePlayCopiedCard(cardId, startX, startY, targetX, targetY, onFinish)
    local f = GetAnimFrame()
    f:ClearAllPoints()
    local w, h = 88, 122
    f:SetSize(w, h)
    f:SetPoint("CENTER", UIParent, "BOTTOMLEFT", startX, startY)
    f.tex:SetTexture((addon.CS_AnyArt and addon:CS_AnyArt(cardId))
        or ("Interface\\AddOns\\Arkana\\Textures\\Cards\\" .. cardId .. ".tga"))
    f:SetAlpha(1)
    f:Show()

    local hX, hY
    if ARKANA_GameBoard then
        hX, hY = ARKANA_GameBoard:GetCenter()
    end
    if not hX or not hY then
        hX = GetScreenWidth() / 2
        hY = GetScreenHeight() / 2
    end

    local group = f:CreateAnimationGroup()

    -- Phase 1: Fly to hover position and scale up (0.35s)
    local trans1 = group:CreateAnimation("Translation")
    trans1:SetOffset(hX - startX, hY - startY)
    trans1:SetDuration(0.35)
    trans1:SetSmoothing("OUT")
    trans1:SetOrder(1)

    local scale1 = group:CreateAnimation("Scale")
    scale1:SetScale(1.4, 1.4)
    scale1:SetDuration(0.35)
    scale1:SetSmoothing("OUT")
    scale1:SetOrder(1)

    -- Phase 2: Flug zum Brett-Slot — erst NACHDEM die Spiegelgestalt-Kopie gelandet
    -- ist (Kopie: fade-in ab 0.8s + 0.25s + 1.4s Pause + 0.5s Flug ≈ fertig bei 2.95s;
    -- Original startet bei 0.35s + 2.8s = 3.15s). Reihenfolge laut User-Choreo:
    -- erst Kopie auf ihren Slot, dann der gespielte Diener auf seinen.
    local trans2 = group:CreateAnimation("Translation")
    trans2:SetOffset(targetX - hX, targetY - hY)
    trans2:SetDuration(0.5)
    trans2:SetSmoothing("IN")
    trans2:SetStartDelay(2.8)
    trans2:SetOrder(2)

    local scale2 = group:CreateAnimation("Scale")
    scale2:SetScale(0.714, 0.714)
    scale2:SetDuration(0.5)
    scale2:SetSmoothing("IN")
    scale2:SetStartDelay(2.8)
    scale2:SetOrder(2)

    -- Kein Shake: der Diener hovert nur (wie Kampfschrei-Präsentation, ohne Wackeln)

    group:SetScript("OnFinished", function()
        f:Hide()
        f.inUse = false
        if onFinish then onFinish() end
    end)

    group:Play()
end

-- Fly a battlecry minion card to center, play effect, then fly to board slot
function addon:AnimatePlayBattlecryCard(cardId, startX, startY, targetX, targetY, onFinish)
    local f = GetAnimFrame()
    addon.activeBattlecryFrame = f
    f:ClearAllPoints()
    local w, h = 88, 122
    f:SetSize(w, h)
    f:SetPoint("CENTER", UIParent, "BOTTOMLEFT", startX, startY)
    f.tex:SetTexture((addon.CS_AnyArt and addon:CS_AnyArt(cardId))
        or ("Interface\\AddOns\\Arkana\\Textures\\Cards\\" .. cardId .. ".tga"))
    f:SetAlpha(1)
    f:Show()

    local centerX, centerY
    if ARKANA_GameBoard then
        centerX, centerY = ARKANA_GameBoard:GetCenter()
    end
    if not centerX or not centerY then
        centerX = GetScreenWidth() / 2
        centerY = GetScreenHeight() / 2
    end

    local group = f:CreateAnimationGroup()

    -- Phase 1: Fly to center and scale up (duration 0.35s)
    local trans1 = group:CreateAnimation("Translation")
    trans1:SetOffset(centerX - startX, centerY - startY)
    trans1:SetDuration(0.35)
    trans1:SetSmoothing("OUT")
    trans1:SetOrder(1)

    local scale1 = group:CreateAnimation("Scale")
    scale1:SetScale(1.4, 1.4)
    scale1:SetDuration(0.35)
    scale1:SetSmoothing("OUT")
    scale1:SetOrder(1)

    -- Phase 2: Fly to board and scale back down (starts after 1.1s delay: 0.35s travel + 0.75s battlecry pause)
    local trans2 = group:CreateAnimation("Translation")
    trans2:SetOffset(targetX - centerX, targetY - centerY)
    trans2:SetDuration(0.35)
    trans2:SetSmoothing("IN")
    trans2:SetStartDelay(1.1)
    trans2:SetOrder(2)

    local scale2 = group:CreateAnimation("Scale")
    scale2:SetScale(0.714, 0.714)
    scale2:SetDuration(0.35)
    scale2:SetSmoothing("IN")
    scale2:SetStartDelay(1.1)
    scale2:SetOrder(2)

    -- Trigger shake in center after phase 1
    C_Timer.After(0.35, function()
        addon:AnimateShake(f)
    end)

    group:SetScript("OnFinished", function()
        f:Hide()
        f.inUse = false
        if addon.activeBattlecryFrame == f then
            addon.activeBattlecryFrame = nil
        end
        if onFinish then onFinish() end
    end)

    group:Play()
end

-- Fly a spell card to screen center, enlarge, pause, and fade out
function addon:AnimatePlaySpell(cardId, startX, startY, targetFrame, onFinish, casterIdx)
    local f = GetAnimFrame()
    addon.activeSpellAnimFrame = f
    f:ClearAllPoints()
    local w, h = 88, 122
    f:SetSize(w, h)
    f:SetPoint("CENTER", UIParent, "BOTTOMLEFT", startX, startY)
    
    local isOpponentSecret = false
    local isSecret = false
    local state = addon:GE_State()
    local cardData = ARKANA_CardData and ARKANA_CardData[cardId]
    if cardData and cardData.tags then
        for _, t in ipairs(cardData.tags) do
            if t.type == "SECRET" then
                isSecret = true
                if casterIdx and state and casterIdx ~= state.myPlayerIdx then
                    isOpponentSecret = true
                end
                break
            end
        end
    end
    
    local texPath
    if isOpponentSecret then
        texPath = (addon.CB_PeerBackTexture and addon:CB_PeerBackTexture())
            or "Interface\\AddOns\\Arkana\\Textures\\card_back.tga"
    else
        texPath = (addon.CS_AnyArt and addon:CS_AnyArt(cardId))
            or ("Interface\\AddOns\\Arkana\\Textures\\Cards\\" .. cardId .. ".tga")
    end
    
    f.tex:SetTexture(texPath)
    f:SetAlpha(1)
    f:Show()

    local targetX, targetY
    if ARKANA_GameBoard then
        targetX, targetY = ARKANA_GameBoard:GetCenter()
    end
    if not targetX or not targetY then
        targetX = GetScreenWidth() / 2
        targetY = GetScreenHeight() / 2
    end

    local isCountered = not not addon.spellCountered
    if isCountered then
        targetX = targetX + 130
    end

    local startTime = GetTime()
    local duration = 0.35

    f:SetScript("OnUpdate", function(self, elapsed)
        local pct = (GetTime() - startTime) / duration
        if pct >= 1 then
            self:SetScript("OnUpdate", nil)
            self:SetScale(1.4 * BoardRelScale())
            self:ClearAllPoints()
            self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", targetX / 1.4, targetY / 1.4)
            
            if not isSecret then
                addon:AnimateShake(self)
            end
            
            if addon.spellCountered then
                addon.spellCountered = nil
                -- Gegenzauber: Silence-Effekt auf der gekonterten Karte (wie Massenbannung)
                C_Timer.After(0.6, function()
                    if self:IsShown() and addon.AnimateSpellImpact then
                        addon:AnimateSpellImpact(self, "EX1_287", nil, true)
                    end
                end)
                C_Timer.After(1.8, function()
                    local fadeStartTime = GetTime()
                    local fadeDuration = 0.25
                    self:SetScript("OnUpdate", function(self, elapsed)
                        local fadePct = (GetTime() - fadeStartTime) / fadeDuration
                        if fadePct >= 1 then
                            self:SetScript("OnUpdate", nil)
                            self:Hide()
                            self.inUse = false
                            if addon.activeSpellAnimFrame == self then
                                addon.activeSpellAnimFrame = nil
                            end
                        else
                            self:SetAlpha(1 - fadePct)
                        end
                    end)
                end)
                C_Timer.After(0.15, function()
                    if addon.TriggerDelayedFloats then addon:TriggerDelayedFloats() end
                end)
            else
                local boardFrame = ARKANA_GameBoard
                local state = addon:GE_State()
                local casterFrame
                if state and casterIdx then
                    local isMySpell = (casterIdx == state.myPlayerIdx)
                    casterFrame = isMySpell and boardFrame.playerHero or boardFrame.enemyHero
                end
                
                if cardId == "EX1_277" then
                    -- Geschosse starten an der Zauberkarte (Mitte, wo sie hovert), NICHT am Helden
                    local launchSource = AcquirePooled("point")
                    launchSource:SetSize(1, 1)
                    launchSource:SetScale(BoardRelScale())   -- targetX/Y sind Brett-Raum
                    launchSource:SetPoint("CENTER", UIParent, "BOTTOMLEFT", targetX, targetY)
                    launchSource:Show()

                    local hits = addon.GetAndClearDelayedFloats and addon:GetAndClearDelayedFloats() or {}
                    local override = CARD_VISUAL_OVERRIDES["EX1_277"]
                    local GAP = override and override.missileGap or 0.15  -- Pause nach Einschlag, bevor das nächste Geschoss startet

                    addon:SetSpellAnimating(true)

                    -- Strikt nacheinander: Geschoss i fliegt → Einschlag → Schadenzahl →
                    -- kurze Pause → Geschoss i+1 startet erst dann. (Nicht überlappend.)
                    local function fireNext(i)
                        if i > #hits then
                            ReleasePooled(launchSource)
                            addon:SetSpellAnimating(false)
                            addon:Board_Update()
                            return
                        end
                        local hit = hits[i]
                        local tFrame = addon:GetEntityFrame(hit.eid)
                        -- Ziel-Frame weg ODER ohne Anker (Ziel schon tot/entfernt):
                        -- Geschoss überspringen und Kette WEITERFÜHREN — sonst bräche
                        -- AnimateSpellProjectile still ab und die Restkette verfiele
                        -- (Tester: Geschoss auf totes Ziel → Softlock)
                        if not tFrame or not tFrame:GetCenter() then fireNext(i + 1); return end
                        addon:AnimateSpellProjectile(tFrame, "EX1_277", addon.USE_3D_SPELL_EFFECTS, launchSource, nil, override, function()
                            -- AnimateSpellImpact hat via TriggerDelayedFloats das
                            -- spellAnimating-Flag zurückgesetzt → wieder setzen, sonst
                            -- stirbt/verschwindet das Ziel mitten in der Geschoss-Kette
                            -- und die Folge-Geschosse finden keinen Frame mehr
                            addon:SetSpellAnimating(true)
                            addon:ShowFloatTextForFrame(tFrame, hit.text, hit.r, hit.g, hit.b)
                            addon:Board_Update()
                            C_Timer.After(GAP, function() fireNext(i + 1) end)
                        end)
                    end

                    if #hits == 0 then
                        ReleasePooled(launchSource)
                        addon:SetSpellAnimating(false)
                    else
                        fireNext(1)
                    end
                elseif targetFrame and targetFrame ~= boardFrame then
                    -- self (die hovernde Zauberkarte) als Startpunkt übergeben statt
                    -- der nackten Brett-Raum-Zahlen: der Frame-Zweig von
                    -- AnimateSpellProjectile rechnet die Skala korrekt um
                    addon:AnimateSpellProjectile(targetFrame, cardId, addon.USE_3D_SPELL_EFFECTS, self)
                elseif targetFrame == boardFrame then
                    if ENABLE_AOE_SPELL_EFFECTS then
                        addon:AnimateSpellProjectile(boardFrame, cardId, addon.USE_3D_SPELL_EFFECTS)
                    else
                        C_Timer.After(0.15, function()
                            if addon.TriggerDelayedFloats then addon:TriggerDelayedFloats() end
                        end)
                    end
                else
                    C_Timer.After(0.15, function()
                        -- Einzel-Impacts auf jedem betroffenen Ziel immer zeigen, unabhängig
                        -- vom Kamerafahrt-Flag — der Flächeneffekt (Vogelperspektive-Kamera)
                        -- bleibt bewusst deaktiviert, die Impacts selbst nicht (User-Entscheidung)
                        if addon.AnimateAOEImpacts then
                            addon:AnimateAOEImpacts(cardId, casterIdx)
                        else
                            if addon.TriggerDelayedFloats then addon:TriggerDelayedFloats() end
                        end
                    end)
                end
                
                -- Kartenanzeige-Dauer: per Override verlängerbar (z.B. Arkane Geschosse,
                -- deren Geschoss-Kette länger läuft als der Standard-Fade)
                -- Tester-Feedback: 2.0s statt 0.8s, damit man neben dem Log
                -- nachvollziehen kann, welcher Zauber gerade gespielt wurde
                local cardFadeDelay = (CARD_VISUAL_OVERRIDES[cardId] and CARD_VISUAL_OVERRIDES[cardId].cardFadeDelay) or 2.0
                C_Timer.After(cardFadeDelay, function()
                    local fadeStartTime = GetTime()
                    local fadeDuration = 0.25
                    self:SetScript("OnUpdate", function(self, elapsed)
                        local fadePct = (GetTime() - fadeStartTime) / fadeDuration
                        if fadePct >= 1 then
                            self:SetScript("OnUpdate", nil)
                            self:Hide()
                            self.inUse = false
                            if addon.activeSpellAnimFrame == self then
                                addon.activeSpellAnimFrame = nil
                            end
                            if onFinish then onFinish() end
                        else
                            self:SetAlpha(1 - fadePct)
                        end
                    end)
                end)
            end
        else
            local curScale = 1.0 + (1.4 - 1.0) * pct
            local curX = startX + (targetX - startX) * pct
            local curY = startY + (targetY - startY) * pct
            self:SetScale(curScale * BoardRelScale())
            self:ClearAllPoints()
            self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", curX / curScale, curY / curScale)
        end
    end)
end

-- Spawns and fires a spell projectile (3D model or 2D sprite)
local MissileModels = {
    FIRE = 1327009,      -- spells/cfx_mage_fireball_missile.m2
    FROST = 166214,     -- spells/frostbolt.m2
    SHADOW = 1955423,   -- spells/cfx_warlock_shadowbolt_missile.m2
    ARCANE = 165569,    -- spells/arcane_missile.m2
    HOLY = 1368708,     -- spells/cfx_paladin_holywrath_missile.m2
    NATURE = 167213,    -- spells/wrath_missile.m2
    DEFAULT = 165569
}

local ImpactModels = {
    FIRE = 1327007,     -- spells/cfx_mage_fireball_impact.m2
    FROST = 1599028,    -- spells/cfx_mage_frostbolt_impactchest.m2
    SHADOW = 166814,    -- spells/shadowbolt_chest_impact.m2
    ARCANE = 1063414,   -- spells/explosion_arcane_impact.m2
    HOLY = 1397424,     -- spells/7fx_priest_lightswrath_impactbase.m2
    NATURE = 165780,    -- spells/chainlightning_impact_chest.m2
    DEFAULT = 1063414
}

local MissileScales = {
    FIRE = 1.0,
    FROST = 1.0,
    SHADOW = 1.0,
    ARCANE = 1.0,
    HOLY = 1.0,
    NATURE = 1.0,
    DEFAULT = 1.0
}

local ImpactScales = {
    FIRE = 1.0,
    FROST = 1.0,
    SHADOW = 1.0,
    ARCANE = 1.0,
    HOLY = 1.0,
    NATURE = 1.0,
    DEFAULT = 0.1
}

local MissileSizes = {
    FIRE = 120,
    FROST = 120,
    SHADOW = 120,
    ARCANE = 120,
    HOLY = 120,
    NATURE = 120,
    DEFAULT = 120
}

local ImpactSizes = {
    FIRE = 160,
    FROST = 160,
    SHADOW = 160,
    ARCANE = 160,
    HOLY = 160,
    NATURE = 160,
    DEFAULT = 160
}

function addon:AnimateSpellProjectile(targetFrame, cardId, is3D, customStartX, customStartY, customOverride, onHitCallback)
    local boardCenterX, boardCenterY
    if ARKANA_GameBoard then
        boardCenterX, boardCenterY = ARKANA_GameBoard:GetCenter()
        if boardCenterX and boardCenterY then
            local bScale = ARKANA_GameBoard:GetEffectiveScale() / UIParent:GetEffectiveScale()
            boardCenterX = boardCenterX * bScale
            boardCenterY = boardCenterY * bScale
        end
    end
    if not boardCenterX or not boardCenterY then
        boardCenterX = GetScreenWidth() / 2
        boardCenterY = GetScreenHeight() / 2
    end
    local startX, startY
    local casterFrame

    if type(customStartX) == "table" and customStartX.GetCenter then
        casterFrame = customStartX
        startX, startY = casterFrame:GetCenter()
        if startX and startY then
            local scale = casterFrame:GetEffectiveScale() / UIParent:GetEffectiveScale()
            startX = startX * scale
            startY = startY * scale
        end
    else
        startX = customStartX or boardCenterX
        startY = customStartY or boardCenterY
    end

    local tx, ty = targetFrame:GetCenter()
    if not tx or not ty then
        -- Ziel-Frame ohne Anker (z.B. gerade gestorben): Animation still abbrechen,
        -- aber Modal-Flags/Floats freigeben — sonst bleibt spellAnimating für
        -- immer true (Tode/Kontrollwechsel blockiert = wirkt wie Addon-Freeze)
        addon:TriggerDelayedFloats()
        return
    end
    local tScale = targetFrame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    tx = tx * tScale
    ty = ty * tScale

    local isRedirected = not not addon.spellbenderTriggered
    local bx, by
    if isRedirected then
        if addon.activeSecretFrame then
            bx, by = addon.activeSecretFrame:GetCenter()
            if bx and by then
                local sScale = addon.activeSecretFrame:GetEffectiveScale() / UIParent:GetEffectiveScale()
                bx = bx * sScale
                by = by * sScale
            end
        end
        if not bx or not by then
            bx = boardCenterX - 130
            by = boardCenterY
        end
    end
    
    -- Check visual overrides
    local school = cardId and GetSpellSchool(cardId) or "DEFAULT"
    local override = customOverride or (cardId and CARD_VISUAL_OVERRIDES[cardId])
    local projModel = MissileModels[school] or MissileModels.DEFAULT
    local noProj = false
    
    if override then
        if override.projectile == nil and override.impact then
            noProj = true
        else
            projModel = override.projectile or projModel
        end
    end
    
    local projScale = (override and (override.projScale or 1.0)) or MissileScales[school] or 1.0
    
    if is3D and override and override.cast then
        local castTarget = casterFrame
        local dummy
        if startX and startY and not casterFrame then
            dummy = AcquirePooled("point")
            dummy:SetSize(1, 1)
            dummy:SetPoint("CENTER", UIParent, "BOTTOMLEFT", startX, startY)
            dummy:Show()
            castTarget = dummy
        end
        if castTarget then
            addon:AnimateSpellImpact(castTarget, nil, {
                impact = override.cast,
                impactScale = override.castScale or 1.0,
                impactSize = override.castSize or 200,
                noCamera = true,
            }, true)
            if dummy then
                local gen = dummy.gen
                C_Timer.After(2.0, function()
                    if dummy.gen == gen then ReleasePooled(dummy) end
                end)
            end
        end
    end
    
    if noProj then
        C_Timer.After(0.15, function()
            if isRedirected then
                addon.spellbenderTriggered = nil
                local hitTarget = (addon.spellbenderRedirectEntityId and addon.GetEntityFrame
                    and addon:GetEntityFrame(addon.spellbenderRedirectEntityId))
                    or addon.activeSecretFrame or targetFrame
                addon.spellbenderRedirectEntityId = nil
                addon:AnimateSpellImpact(hitTarget, cardId, override, true)
            else
                addon:AnimateSpellImpact(targetFrame, cardId, override)
            end
        end)
        return
    end
    
    local animFrame
    if is3D then
        -- 1. Carrier-Frame (2D-Bewegung) + PlayerModel aus dem Pool
        local sizeVal = (override and (override.projSize or 120)) or MissileSizes[school] or 120
        animFrame = AcquirePooled("proj3d")
        animFrame:SetSize(sizeVal, sizeVal)

        local proj = animFrame.model
        proj:ClearModel()
        proj:SetModel(projModel)
        if not (override and override.noCamera) then
            proj:SetCamera(0)
        end

        local gen = animFrame.gen
        C_Timer.After(0.02, function()
            if animFrame.gen ~= gen or not proj:IsShown() then return end
            proj:SetSequence(0)
            local px = override and override.projX or 0
            local py = override and override.projY or 0
            local pz = override and override.projZ or 0
            proj:SetPosition(px, py, pz)
            local pYaw = 0
            if override then
                pYaw = override.projYaw or override.yaw or 0
                if override.autoRotate then
                    local angle = math.atan2(ty - startY, tx - startX)
                    local base = override.baseYaw or 1.57
                    pYaw = base + (angle - 1.57)
                end
            end
            proj:SetFacing(pYaw)
            proj:SetScale(projScale)
            -- immer setzen (Pool-Reuse: sonst bleiben Pitch/Roll vom Vorgänger)
            proj:SetPitch(override and (override.projPitch or override.pitch) or 0)
            proj:SetRoll(override and (override.projRoll or override.roll) or 0)
        end)
    else
        -- 2D-Sprite aus dem Pool
        animFrame = AcquirePooled("proj2d")
        animFrame:SetSize(40, 40)
        local tex = animFrame.tex
        tex:SetTexture("Interface\\Buttons\\UI-Common-MouseHilight")

        -- Color code based on spell school
        if school == "FIRE" then
            tex:SetVertexColor(1, 0.35, 0)
        elseif school == "FROST" then
            tex:SetVertexColor(0.3, 0.7, 1)
        elseif school == "SHADOW" then
            tex:SetVertexColor(0.6, 0.1, 0.9)
        elseif school == "NATURE" then
            tex:SetVertexColor(0.2, 0.9, 0.2)
        elseif school == "HOLY" then
            tex:SetVertexColor(1, 0.85, 0.3)
        else
            tex:SetVertexColor(0.8, 0.8, 1)
        end
    end
    
    animFrame:SetFrameStrata("TOOLTIP")
    animFrame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", startX, startY)
    animFrame:Show()
    
    -- Animate flight using OnUpdate to force the 3D viewport to redraw during movement
    local startTime = GetTime()
    local duration = isRedirected and 1.0 or (override and override.projDuration) or 0.35
    
    local midX, midY
    if isRedirected then
        midX = startX + (tx - startX) * 0.5
        midY = startY + (ty - startY) * 0.5
    end

    animFrame:SetScript("OnUpdate", function(self, elapsed)
        local elapsedSec = GetTime() - startTime
        if elapsedSec >= duration then
            ReleasePooled(self)
            if isRedirected then
                addon.spellbenderTriggered = nil
                -- Ziel = der beschworene Verteidiger-Diener. Falls sein Frame existiert,
                -- direkt darauf einschlagen (mit Clipping wie ein normaler Diener-Impact);
                -- sonst Fallback auf die Geheimnis-Karten-Position (bx,by).
                local mf = addon.spellbenderRedirectEntityId and addon.GetEntityFrame
                    and addon:GetEntityFrame(addon.spellbenderRedirectEntityId)
                addon.spellbenderRedirectEntityId = nil
                if mf then
                    addon:AnimateSpellImpact(mf, cardId, customOverride)
                else
                    local dummy = AcquirePooled("point")
                    dummy:SetSize(1, 1)
                    dummy:SetPoint("CENTER", UIParent, "BOTTOMLEFT", bx, by)
                    dummy:Show()
                    addon:AnimateSpellImpact(dummy, cardId, customOverride, true)
                    local dgen = dummy.gen
                    C_Timer.After(1.5, function()
                        if dummy.gen == dgen then ReleasePooled(dummy) end
                    end)
                end
            else
                addon:AnimateSpellImpact(targetFrame, cardId, customOverride)
            end
            if onHitCallback then
                onHitCallback()
            end
        else
            local curX, curY
            if isRedirected then
                if elapsedSec < 0.25 then
                    local pct = elapsedSec / 0.25
                    curX = startX + (midX - startX) * pct
                    curY = startY + (midY - startY) * pct
                elseif elapsedSec < 0.75 then
                    curX = midX
                    curY = midY
                else
                    local pct = (elapsedSec - 0.75) / 0.25
                    -- Zielposition = Verteidiger-Diener (falls Frame da), KONSISTENT skaliert
                    -- (frameEffScale/UIParentEffScale — wie startX/tx oben), sonst bx,by (Karte).
                    local ex, ey = bx, by
                    local mf = addon.spellbenderRedirectEntityId and addon.GetEntityFrame
                        and addon:GetEntityFrame(addon.spellbenderRedirectEntityId)
                    if mf then
                        local mx, my = mf:GetCenter()
                        if mx and my then
                            local ms = mf:GetEffectiveScale() / UIParent:GetEffectiveScale()
                            ex, ey = mx * ms, my * ms
                        end
                    end
                    curX = midX + (ex - midX) * pct
                    curY = midY + (ey - midY) * pct
                end
            else
                local pct = elapsedSec / duration
                curX = startX + (tx - startX) * pct
                curY = startY + (ty - startY) * pct
            end
            self:ClearAllPoints()
            self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", curX, curY)
        end
    end)
end

-- Explodes projectile on target and triggers target shake
function addon:AnimateSpellImpact(targetFrame, cardId, customOverride, noClip)
    if addon.TriggerDelayedFloats then addon:TriggerDelayedFloats() end
    
    local tx, ty = targetFrame:GetCenter()
    if not tx or not ty then return end
    -- GetCenter liefert Koordinaten im Skalierungsraum des Frames — für die
    -- UIParent-Positionierung (noClip-Zweig) in den UIParent-Raum umrechnen.
    -- Sonst landet der Impact bei skalierten Frames (z.B. 1.4x-Zauberkarte beim
    -- Gegenzauber, skaliertes Brett) versetzt. (Gleiche Lehre wie Projektil-Fix S24.)
    local sf = targetFrame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    tx, ty = tx * sf, ty * sf

    local school = cardId and GetSpellSchool(cardId) or "DEFAULT"
    local impModel = ImpactModels[school] or ImpactModels.DEFAULT
    local duration = 0.6
    
    local override = customOverride or (cardId and CARD_VISUAL_OVERRIDES[cardId])
    if override then
        impModel = override.impact or impModel
        if override.duration then
            duration = override.duration
        end
    end
    
    local scaleVal = (override and (override.impactScale or 1.0)) or ImpactScales[school] or 1.0
    
    local useClip = not noClip and targetFrame ~= UIParent
    
    local imp
    if addon.USE_3D_SPELL_EFFECTS then
        -- Carrier-Frame + PlayerModel aus dem Pool (SetPoint macht das Funktionsende)
        local sizeVal = (override and (override.impactSize or 160)) or ImpactSizes[school] or 160
        imp = AcquirePooled("imp3d")
        imp:SetParent(useClip and targetFrame or UIParent)
        imp:SetSize(sizeVal, sizeVal)

        local model = imp.model
        model:ClearModel()
        model:SetModel(impModel)
        if not (override and override.noCamera) then
            model:SetCamera(0)
        end

        local gen = imp.gen
        C_Timer.After(0.02, function()
            if imp.gen ~= gen or not model:IsShown() then return end
            local ix = override and override.impactX or 0
            local iy = override and override.impactY or 0
            local iz = override and override.impactZ or 0
            local impPitch = override and (override.impactPitch or override.pitch)
            local impRoll  = override and (override.impactRoll or override.roll)
            local impYaw   = override and (override.impactYaw or override.yaw)
            local speed    = override and override.impactSpeed
            local useCustomSpeed = speed and speed ~= 1.0 and speed > 0

            if useCustomSpeed then
                model:SetSequenceTime(0, 0)
            else
                model:SetSequence(0)
            end

            -- Transform jeden Frame neu anwenden statt nur einmalig: WoW lädt
            -- 3D-Modelle asynchron, ein einmaliger SetScale-Aufruf kann "verpuffen",
            -- wenn das Modell zu dem Zeitpunkt noch nicht fertig geladen ist —
            -- fällt besonders auf, wenn zwei Impacts kurz hintereinander laufen
            -- (z.B. Fatigue bei beiden Spielern). Gleiche Lehre wie beim M2-Viewer-Fix.
            local elapsedMs = 0
            model:SetScript("OnUpdate", function(self, elapsed)
                self:SetPosition(ix, iy, iz)
                -- SetScale() skaliert den (per SetAllPoints fix verankerten) Frame,
                -- nicht zuverlässig den sichtbaren 3D-Inhalt — SetModelScale() ist
                -- der richtige Aufruf dafür (gleiche Lehre wie beim M2-Viewer-Fix).
                if self.SetModelScale then self:SetModelScale(scaleVal) else self:SetScale(scaleVal) end
                -- immer setzen (Pool-Reuse: sonst bleiben Pitch/Roll vom Vorgänger)
                self:SetPitch(impPitch or 0)
                self:SetRoll(impRoll or 0)
                self:SetFacing(impYaw or 0)
                if useCustomSpeed then
                    -- Modell manuell per SetSequenceTime abspielen statt SetSequence(0),
                    -- das immer mit normalem Tempo läuft — so wird die Animation selbst
                    -- langsamer/schneller, nicht nur die Anzeigedauer danach verlängert.
                    elapsedMs = elapsedMs + (elapsed * 1000 * speed)
                    self:SetSequenceTime(0, elapsedMs)
                end
            end)
        end)
        
        -- Automatisches Aufräumen nach Ablauf (gen-Guard: Frame könnte schon
        -- wiederverwendet sein, dann darf der alte Timer ihn nicht anfassen)
        C_Timer.After(duration, function()
            if imp.gen == gen then ReleasePooled(imp) end
            -- Clip wieder AUS: blieb sonst dauerhaft auf dem Ziel-Frame und
            -- beschnitt dessen spätere Angriffs-Animationen aufs Ruhe-Rechteck
            -- (Tester: "Helden-Animation verschwindet außerhalb des Containers",
            -- immer nach Heilung/Selfcast-Impact auf dem Helden).
            -- bei ÜBERLAPPENDEN Impacts auf demselben Frame endet der
            -- Clip mit dem ersten — der zweite läuft kurz unbeschnitten (kosmetisch).
            if useClip and targetFrame.SetClipsChildren then
                targetFrame:SetClipsChildren(false)
            end
        end)
    else
        -- 2D-Sprite-Explosion aus dem Pool
        imp = AcquirePooled("imp2d")
        imp:SetParent(useClip and targetFrame or UIParent)
        imp:SetSize(90, 90)

        local tex = imp.tex
        tex:SetTexture("Interface\\Buttons\\UI-Common-MouseHilight")

        -- Color code impact flare
        if school == "FIRE" then
            tex:SetVertexColor(1, 0.4, 0)
        elseif school == "FROST" then
            tex:SetVertexColor(0.3, 0.7, 1)
        elseif school == "SHADOW" then
            tex:SetVertexColor(0.7, 0.1, 1)
        elseif school == "NATURE" then
            tex:SetVertexColor(0.2, 0.9, 0.2)
        elseif school == "HOLY" then
            tex:SetVertexColor(1, 0.9, 0.4)
        else
            tex:SetVertexColor(0.9, 0.9, 1)
        end

        -- Explode & fade group: einmalig am Pool-Frame anlegen, danach nur noch
        -- abspielen — CreateAnimationGroup pro Einschlag leckt (nie freigebbar)
        if not imp.impactGroup then
            local group = imp:CreateAnimationGroup()
            local scale = group:CreateAnimation("Scale")
            scale:SetScale(1.8, 1.8)
            scale:SetDuration(0.2)
            scale:SetSmoothing("OUT")

            local fade = group:CreateAnimation("Alpha")
            fade:SetFromAlpha(1)
            fade:SetToAlpha(0)
            fade:SetDuration(0.2)

            group:SetScript("OnFinished", function()
                local tf = imp.clipTarget
                imp.clipTarget = nil
                ReleasePooled(imp)
                -- Clip wieder AUS (s. 3D-Zweig): nie dauerhaft auf dem Ziel lassen
                if tf and tf.SetClipsChildren then
                    tf:SetClipsChildren(false)
                end
            end)
            imp.impactGroup = group
        end
        imp.clipTarget = useClip and targetFrame or nil
        imp.impactGroup:Stop()
        imp.impactGroup:Play()
    end

    if useClip then
        if targetFrame.SetClipsChildren then
            targetFrame:SetClipsChildren(true)
        end
        -- Strata explizit anheben (nicht nur Level): sonst kann ein Geschwister-
        -- Frame mit höherer Strata (z.B. der klickbare heroPowerBtn beim eigenen
        -- Helden) den Impact teilweise verdecken, obwohl der Level-Vergleich
        -- eigentlich dafür spräche, dass der Impact obenauf liegt.
        imp:SetFrameStrata("TOOLTIP")
        imp:SetFrameLevel(targetFrame:GetFrameLevel() + 10)
        imp:SetPoint("CENTER", targetFrame, "CENTER", 0, 0)
    else
        imp:SetFrameStrata("TOOLTIP")
        imp:SetPoint("CENTER", UIParent, "BOTTOMLEFT", tx, ty)
    end
    imp:Show()
    
    -- Shake the target frame on impact
    addon:AnimateShake(targetFrame)
end

-- Triggers impact on all frames affected by an AOE spell
function addon:AnimateAOEImpacts(cardId, casterIdx)
    local targets = {}
    if cardId == "EX1_626" and casterIdx then
        local frames = addon.GetMassDispelTargets and addon:GetMassDispelTargets(casterIdx) or {}
        for _, frame in ipairs(frames) do
            targets[frame] = true
        end
    else
        targets = addon.GetDelayedFloatFrames and addon:GetDelayedFloatFrames() or {}
    end
    
    if addon.TriggerDelayedFloats then addon:TriggerDelayedFloats() end


    for frame in pairs(targets) do
        addon:AnimateSpellImpact(frame, cardId)
    end
end

-- Diener-Sterbeanimation: schrumpft + fadet aus statt eines statischen
-- Alpha-Werts. Läuft über ~0.5s, danach bleibt der Frame bei Alpha 0/Scale
-- 0.55 bis die 1s-Death-Delay-Frist (GameBoard.lua UpdateDisplayBoard) abläuft
-- und der Slot für den nächsten Diener wiederverwendet wird (dort Reset).
function addon:AnimateMinionDeath(frame, onDone)
    if not frame then return end
    if frame.deathGroup then frame.deathGroup:Stop() end
    frame:SetAlpha(1)
    frame:SetScale(1.0)

    -- Gruppe einmalig anlegen, wiederverwenden (Struktur statisch; Gruppe pro
    -- Tod leckt auf den positions-gepoolten Slot-Frames)
    if not frame.deathGroup then
        local group = frame:CreateAnimationGroup()
        frame.deathGroup = group

        local shrink = group:CreateAnimation("Scale")
        shrink:SetScale(0.55, 0.55)
        shrink:SetDuration(0.5)
        shrink:SetSmoothing("IN")
        shrink:SetOrder(1)

        local fade = group:CreateAnimation("Alpha")
        fade:SetFromAlpha(1)
        fade:SetToAlpha(0)
        fade:SetDuration(0.5)
        fade:SetOrder(1)
    end

    -- onDone entfernt das Display-Item exakt am Animations-Ende (kein Pop-back).
    -- WICHTIG: den Slot-Frame hier NIE dauerhaft auf Alpha 0 setzen — die Frames
    -- sind positions-gepoolt; rückt ein Nachbar in den Slot nach, würde er das
    -- Alpha erben und unsichtbar bleiben, bis der nächste Board_Update läuft.
    -- OnFinished pro Aufruf neu setzen (onDone-Closure), ersetzt den alten Handler.
    frame.deathGroup:SetScript("OnFinished", function(_, requested)
        if requested then return end  -- Stop() = Frame wird gerade neu verwendet
        if onDone then onDone() end
    end)

    frame.deathGroup:Play()
end

-- Attack shake animation for the defender (minion or hero)
function addon:AnimateShake(frame)
    if not frame then return end

    -- Gruppe einmalig anlegen und wiederverwenden: CreateAnimationGroup pro
    -- Treffer leckt auf den langlebigen Brett-Frames (Frames/Gruppen werden
    -- von WoW nie freigegeben — tausende nach mehreren Runden)
    if frame.shakeGroup then
        frame.shakeGroup:Stop()
        frame.shakeGroup:Play()
        return
    end
    local group = frame:CreateAnimationGroup()
    frame.shakeGroup = group

    -- Quick shake sequence returning to origin (6 - 12 + 6 = 0)
    local s1 = group:CreateAnimation("Translation")
    s1:SetOffset(6, 2)
    s1:SetDuration(0.03)
    s1:SetOrder(1)

    local s2 = group:CreateAnimation("Translation")
    s2:SetOffset(-12, -4)
    s2:SetDuration(0.04)
    s2:SetOrder(2)

    local s3 = group:CreateAnimation("Translation")
    s3:SetOffset(6, 2)
    s3:SetDuration(0.03)
    s3:SetOrder(3)

    group:Play()
end

-- Sicherheitsnetz (analog zum SetScale(1.0) in Board_Update): setzt einen evtl.
-- hängengebliebenen Angriffs-Lift zurück, falls OnStop/OnFinished auf diesem
-- Core mal nicht feuern — aber nie, solange der Angriff noch läuft.
function addon:ResetAttackLift(frame)
    if not frame or (frame.attackGroup and frame.attackGroup:IsPlaying()) then return end
    if frame.arkanaBaseLevel then frame:SetFrameLevel(frame.arkanaBaseLevel) end
    for _, key in ipairs({ "atkGem", "hpGem" }) do
        local gem = frame[key]
        if gem and gem.arkanaBaseLevel then gem:SetFrameLevel(gem.arkanaBaseLevel) end
    end
end

-- Attack animation (wind up, dash, retreat). isWeaponAttack fügt einen
-- Waffen-Schwung (Rotation) über die Translation, für Helden-Angriffe mit
-- ausgerüsteter Waffe.
function addon:AnimateAttack(attackerFrame, defenderFrame, onFinish, isWeaponAttack)
    if not attackerFrame or not defenderFrame then
        if onFinish then onFinish() end
        addon:TriggerDelayedFloats()   -- attackAnimating freigeben (s. AnimateSpellProjectile)
        return
    end

    local ax, ay = attackerFrame:GetCenter()
    local dx, dy = defenderFrame:GetCenter()
    if not ax or not ay or not dx or not dy then
        if onFinish then onFinish() end
        addon:TriggerDelayedFloats()
        return
    end
    -- GetCenter liefert Koordinaten im EIGENEN Skalenraum des Frames. Haben
    -- Angreifer/Verteidiger (z.B. durch einen verirrten Scale) unterschiedliche
    -- effektive Skalen, zeigt der rohe Differenzvektor ins Nirgendwo (Frame
    -- fliegt unters Brett). Deshalb: über Screen-Koordinaten normieren.
    local as = attackerFrame:GetEffectiveScale()
    local ds = defenderFrame:GetEffectiveScale()
    if as ~= ds and as > 0 then
        dx = dx * ds / as
        dy = dy * ds / as
    end

    -- Gruppe + 3 Translationen einmalig am Frame anlegen, danach nur Offsets
    -- setzen — CreateAnimationGroup pro Angriff leckt auf den langlebigen
    -- Brett-Frames (WoW gibt Gruppen nie frei; Struktur ist seit S31 statisch)
    if attackerFrame.attackGroup then
        attackerFrame.attackGroup:Stop()
    else
        local g = attackerFrame:CreateAnimationGroup()
        local w = g:CreateAnimation("Translation")
        w:SetDuration(0.15); w:SetOrder(1)
        local d = g:CreateAnimation("Translation")
        d:SetDuration(0.08); d:SetSmoothing("IN"); d:SetOrder(2)
        local r = g:CreateAnimation("Translation")
        r:SetDuration(0.2); r:SetSmoothing("OUT"); r:SetOrder(3)
        attackerFrame.attackGroup = g
        attackerFrame.attackAnims = { windup = w, dash = d, retreat = r }
    end
    local group = attackerFrame.attackGroup

    -- Während des Angriffs ÜBER allen Board-Elementen zeichnen — sonst taucht der
    -- Angreifer beim Flug über fremde Frames (Gegner-Reihe/Held) hinter ihnen ab.
    -- IDEMPOTENTER FrameLevel-Lift: Basis-Level EINMALIG merken, Lift = Basis+40,
    -- Restore = Basis. Der alte RELATIVE Lift (aktuelles Level + 40) leckte:
    -- Stop() (Angriff unterbrochen) feuert kein OnFinished → Restore entfiel →
    -- das Level KROCH mit jedem unterbrochenen Angriff höher. Folge: gekrochene
    -- Frames verdeckten alles, was bei Nachbarn über den Feldrand ragt (Karten/
    -- Schwert-Symbole "verschwinden außerhalb des eigenen Felds"), und spätere
    -- Angreifer flogen HINTER ihnen ("Angriff unterm Brett"). Ein Strata-Lift
    -- (DIALOG, Build 07-11-a) ist KEINE Alternative: SetFrameStrata re-leveled
    -- die Frames auf diesem Core zusätzlich → Effekt auf allen Feldern.
    -- Gems haben ABSOLUTE Level (folgen dem Parent nicht) → mit liften.
    -- Sicherheitsnetz: Ein Impact (AnimateSpellImpact, useClip) könnte dem
    -- Angreifer ein hängengebliebenes SetClipsChildren hinterlassen haben —
    -- der Angriff würde dann aufs Ruhe-Rechteck beschnitten. Immer lösen.
    if attackerFrame.SetClipsChildren then
        attackerFrame:SetClipsChildren(false)
    end
    local LIFT = 40
    local GEM_KEYS = { "atkGem", "hpGem" }
    local function Lift(frame)
        if not frame.arkanaBaseLevel then frame.arkanaBaseLevel = frame:GetFrameLevel() end
        frame:SetFrameLevel(frame.arkanaBaseLevel + LIFT)
    end
    Lift(attackerFrame)
    for _, key in ipairs(GEM_KEYS) do
        if attackerFrame[key] then Lift(attackerFrame[key]) end
    end
    local function RestoreLevels()
        attackerFrame:SetFrameLevel(attackerFrame.arkanaBaseLevel)
        for _, key in ipairs(GEM_KEYS) do
            local gem = attackerFrame[key]
            if gem and gem.arkanaBaseLevel then gem:SetFrameLevel(gem.arkanaBaseLevel) end
        end
    end

    local vx = dx - ax
    local vy = dy - ay

    -- Phase 1: Wind up (pull back by 15%)
    local wux = -0.15 * vx
    local wuy = -0.15 * vy
    attackerFrame.attackAnims.windup:SetOffset(wux, wuy)

    -- Phase 2: Dash (strike defender)
    attackerFrame.attackAnims.dash:SetOffset(vx - wux, vy - wuy)

    -- Phase 3: Retreat
    attackerFrame.attackAnims.retreat:SetOffset(-vx, -vy)

    -- Waffen-Schwung (Rotation-Animationen) ENDGÜLTIG ENTFERNT (Session 31,
    -- Build 07-11-c): Nach dem idempotenten Level-Lift layerten alle DIENER-
    -- Angriffe korrekt, nur Helden-Angriffe (= einziger Rotation-Nutzer) nicht —
    -- auf diesem Core rendert ein Frame mit laufender Rotation-Animation in der
    -- falschen Render-Reihenfolge (FrameLevel wird ignoriert), die Flugrichtung
    -- selbst stimmt. isWeaponAttack bleibt als Parameter; ein core-sicherer
    -- Schwung wäre per OnUpdate + portrait:SetRotation() (Textur-Rotation statt
    -- Frame-Animation) nachrüstbar, falls der Schwung optisch vermisst wird.

    -- Trigger the defender shake exactly on impact (after windup + dash = 0.23s)
    C_Timer.After(0.23, function()
        addon:AnimateShake(defenderFrame)
        if addon.TriggerDelayedFloats then addon:TriggerDelayedFloats() end
    end)

    -- Auch bei Stop() (nächster Angriff unterbricht) zurücksetzen — OnFinished
    -- feuert dann nicht; das war das Leck des alten Codes
    group:SetScript("OnStop", RestoreLevels)
    group:SetScript("OnFinished", function()
        RestoreLevels()
        if onFinish then onFinish() end
    end)

    group:Play()
end

-- Zerstäuben (EX1_594): Angreifer-Karte hovert in die Brettmitte (ohne Shake),
-- das Geheimnis deckt sich daneben auf, Assassinate-Impact (165620) auf der Karte,
-- danach faden beide aus. Der normale Angriffs-/Schadens-Ablauf ist unterdrückt.
function addon:AnimateVaporize(secretId, ownerIdx, cardId, startX, startY, onFinish)
    local f = GetAnimFrame()
    f:ClearAllPoints()
    f:SetSize(88, 122)
    if not startX or not startY then
        startX = GetScreenWidth() / 2
        startY = GetScreenHeight() / 2
    end
    f:SetPoint("CENTER", UIParent, "BOTTOMLEFT", startX, startY)
    f.tex:SetTexture((addon.CS_AnyArt and addon:CS_AnyArt(cardId))
        or ("Interface\\AddOns\\Arkana\\Textures\\Cards\\" .. cardId .. ".tga"))
    f:SetAlpha(1)
    f:Show()

    local cx, cy
    if ARKANA_GameBoard then cx, cy = ARKANA_GameBoard:GetCenter() end
    cx = cx or GetScreenWidth() / 2
    cy = cy or GetScreenHeight() / 2

    addon:SetSpellAnimating(true)   -- Secret-Reveal weicht dadurch auf Mitte-130 aus

    local group = f:CreateAnimationGroup()
    local trans = group:CreateAnimation("Translation")
    trans:SetOffset(cx - startX, cy - startY)
    trans:SetDuration(0.35); trans:SetSmoothing("OUT"); trans:SetOrder(1)
    local scale = group:CreateAnimation("Scale")
    scale:SetScale(1.4, 1.4); scale:SetDuration(0.35); scale:SetSmoothing("OUT"); scale:SetOrder(1)
    -- Nach dem Impact ausfaden (Fade beginnt bei 0.35 + 1.45 = 1.8s)
    local fade = group:CreateAnimation("Alpha")
    fade:SetFromAlpha(1); fade:SetToAlpha(0)
    fade:SetStartDelay(1.45); fade:SetDuration(0.25); fade:SetOrder(2)

    group:SetScript("OnFinished", function()
        f:Hide()
        f.inUse = false
        addon:SetSpellAnimating(false)
        if addon.TriggerDelayedFloats then addon:TriggerDelayedFloats() end
        if onFinish then onFinish() end
    end)

    -- Geheimnis daneben aufdecken, sobald die Karte in der Mitte angekommen ist
    C_Timer.After(0.4, function()
        addon:AnimateSecretTrigger(secretId, ownerIdx)
    end)
    -- Assassinate-Impact auf der gehoverten Karte
    C_Timer.After(1.0, function()
        if f:IsShown() and addon.AnimateSpellImpact then
            addon:AnimateSpellImpact(f, nil, { impact = 165620, impactScale = 1.0 }, true)
        end
    end)

    group:Play()
end

function addon:AnimateSecretTrigger(secretId, ownerIdx, onFinish, copyMinionId, copyMinionEntityId, copyMinionSlotIndex)
    PlaySound(840)
    
    local f = GetAnimFrame()
    addon.activeSecretFrame = f
    f:ClearAllPoints()
    local w, h = 120, 166
    f:SetSize(w, h)
    
    local boardFrame = ARKANA_GameBoard
    local centerX, centerY
    if boardFrame then
        centerX, centerY = boardFrame:GetCenter()
    end
    if not centerX or not centerY then
        centerX = GetScreenWidth() / 2
        centerY = GetScreenHeight() / 2
    end

    -- Get start position near secret owner's hero frame
    local startX, startY
    local state = addon:GE_State()
    local myIdx = state and state.myPlayerIdx or 1
    local heroFrame = (ownerIdx == myIdx) and boardFrame.playerHero or boardFrame.enemyHero
    if heroFrame then
        startX, startY = heroFrame:GetCenter()
    end
    if not startX or not startY then
        startX = centerX
        startY = (ownerIdx == myIdx) and 100 or (GetScreenHeight() - 100)
    end
    
    f:SetPoint("CENTER", UIParent, "BOTTOMLEFT", startX, startY)
    f.tex:SetTexture((addon.CS_AnyArt and addon:CS_AnyArt(secretId))
        or ("Interface\\AddOns\\Arkana\\Textures\\Cards\\" .. secretId .. ".tga"))
    f:SetAlpha(1)
    f:Show()
    
    -- Check if a spell or battlecry card is currently animating in the center of the screen
    local isCardAnimating = false
    if addon:IsSpellAnimating() then
        isCardAnimating = true
    end
    
    local targetX = centerX
    local targetY = centerY
    if isCardAnimating or secretId == "EX1_294" or addon.mirrorEntityTriggered then
        targetX = centerX - 130
    end
    
    local group = f:CreateAnimationGroup()
    
    -- Phase 1: Fly to target position and scale up
    local trans = group:CreateAnimation("Translation")
    trans:SetOffset(targetX - startX, targetY - startY)
    trans:SetDuration(0.4)
    trans:SetSmoothing("OUT")
    trans:SetOrder(1)
    
    local scale = group:CreateAnimation("Scale")
    scale:SetScale(1.4, 1.4)
    scale:SetDuration(0.4)
    scale:SetSmoothing("OUT")
    scale:SetOrder(1)
    
    local fadeDelay = 1.8
    if secretId == "EX1_294" or secretId == "tt_010" then
        -- Spiegelgestalt/Zauberformerin faden früher aus, damit sie synchron mit
        -- der Redirect-Phase des laufenden Zauber-Projektils verschwinden
        fadeDelay = 0.8
    end
    
    -- Phase 2: Fade out after pause
    local fade = group:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0)
    fade:SetStartDelay(fadeDelay)
    fade:SetDuration(0.25)
    fade:SetOrder(2)
    
    -- Set/manage spellAnimating state
    local wasAnimating = addon:IsSpellAnimating()
    if not wasAnimating then
        addon:SetSpellAnimating(true)
    end
    
    group:SetScript("OnFinished", function()
        f:Hide()
        f.inUse = false
        if addon.activeSecretFrame == f then
            addon.activeSecretFrame = nil
        end
        if addon.spellbenderTriggered then
            addon.spellbenderTriggered = nil
        end
        if not wasAnimating then
            addon:SetSpellAnimating(false)
            if addon.TriggerDelayedFloats then
                addon:TriggerDelayedFloats()
            end
        end
        if onFinish then onFinish() end
    end)
    
    -- Spawn mirror minion card copy if applicable
    if copyMinionId and copyMinionEntityId and copyMinionSlotIndex then
        C_Timer.After(0.8, function()
            local boardFrame = ARKANA_GameBoard
            if not boardFrame then return end
            
            local isMyBoard = (ownerIdx == myIdx)
            local boardFrames = isMyBoard and boardFrame.playerBoard or boardFrame.enemyBoard
            local targetFrame = boardFrames[copyMinionSlotIndex]
            if not targetFrame then return end
            
            local tx, ty = targetFrame:GetCenter()
            if not tx or not ty then return end
            
            local mf = GetAnimFrame()
            mf:ClearAllPoints()
            local w, h = 88, 122
            mf:SetSize(w, h)
            local mfX = centerX - 130
            mf:SetPoint("CENTER", UIParent, "BOTTOMLEFT", mfX, centerY)
            mf.tex:SetTexture((addon.CS_AnyArt and addon:CS_AnyArt(copyMinionId))
                or ("Interface\\AddOns\\Arkana\\Textures\\Cards\\" .. copyMinionId .. ".tga"))
            mf:SetAlpha(0)
            mf:Show()
            
            local fadeGroup = mf:CreateAnimationGroup()
            local fi = fadeGroup:CreateAnimation("Alpha")
            fi:SetFromAlpha(0)
            fi:SetToAlpha(1)
            fi:SetDuration(0.25)
            
            fadeGroup:SetScript("OnFinished", function()
                C_Timer.After(1.4, function()
                    if not mf:IsShown() then return end
                    local flyGroup = mf:CreateAnimationGroup()
                    local trans = flyGroup:CreateAnimation("Translation")
                    trans:SetOffset(tx - mfX, ty - centerY)
                    trans:SetDuration(0.5)
                    trans:SetSmoothing("IN")
                    
                    local scale = flyGroup:CreateAnimation("Scale")
                    scale:SetScale(0.714, 0.714)
                    scale:SetDuration(0.5)
                    scale:SetSmoothing("IN")
                    
                    flyGroup:SetScript("OnFinished", function()
                        mf:Hide()
                        mf.inUse = false
                        if addon.ClearMirrorEntityAnimation then
                            addon:ClearMirrorEntityAnimation(copyMinionEntityId)
                        end
                        addon.mirrorEntityTriggered = nil
                    end)
                    
                    flyGroup:Play()
                end)
            end)
            
            mf:SetScale(1.4 * BoardRelScale())
            mf:SetAlpha(0)
            fadeGroup:Play()
        end)
    end
    
    group:Play()
end
