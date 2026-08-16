local addon = Arkana

local MF            = nil
local selectedIdx   = {}   -- set: [0-based handIdx] = true  → diese Karten tauschen

local CARD_W, CARD_H  = 155, 260
local CARD_TEX_V      = 0.691   -- obere 69.1% der 256x512-Textur = Karten-Render ohne Padding
local FALLBACK = "Interface\\AddOns\\Arkana\\Textures\\fallback.tga"

local function CardData(id)
    return ARKANA_CardData and ARKANA_CardData[id] or nil
end

local function CreateCardSlot(parent, i)
    local f = CreateFrame("Button", nil, parent)
    f:SetSize(CARD_W, CARD_H)

    -- Hintergrund
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.1, 0.1, 0.2, 0.95)
    f.bg = bg

    -- Karten-Art (147×206 bei CARD_W=155, CARD_H=260 → Seitenverhältnis ~1:1.40, keine Stauchung)
    local art = f:CreateTexture(nil, "ARTWORK")
    art:SetPoint("TOPLEFT", 4, -4)
    art:SetPoint("BOTTOMRIGHT", -4, 50)
    f.art = art

    -- Highlight (ausgewählt = tauschen)
    local hl = f:CreateTexture(nil, "OVERLAY")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 0.2, 0.2, 0.35)
    hl:Hide()
    f.highlight = hl

    -- Kosten (oben links)
    local cost = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    cost:SetPoint("TOPLEFT", 6, -6)
    f.costText = cost

    -- Name (unten)
    local name = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    name:SetPoint("BOTTOMLEFT", 4, 14)
    name:SetPoint("BOTTOMRIGHT", -4, 14)
    name:SetJustifyH("CENTER")
    name:SetWordWrap(false)
    f.nameText = name

    -- Stats (Angriff/Leben, unten)
    local stats = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    stats:SetPoint("BOTTOM", 0, 2)
    stats:SetJustifyH("CENTER")
    f.statsText = stats

    -- Tauschen-Label
    local swap = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    swap:SetAllPoints()
    swap:SetJustifyH("CENTER")
    swap:SetJustifyV("MIDDLE")
    swap:SetText("|cffff4444Tauschen|r")
    swap:Hide()
    f.swapLabel = swap

    f:SetScript("OnClick", function(self)
        local idx = self.handIdx
        if selectedIdx[idx] then
            selectedIdx[idx] = nil
            self.highlight:Hide()
            self.swapLabel:Hide()
        else
            selectedIdx[idx] = true
            self.highlight:Show()
            self.swapLabel:Show()
        end
    end)

    return f
end

local function BuildMulliganFrame()
    local f = CreateFrame("Frame", "ARKANA_MulliganFrame", UIParent)
    f:SetAllPoints(UIParent)
    f:SetFrameStrata("FULLSCREEN")

    -- Dunkles Overlay
    local overlay = f:CreateTexture(nil, "BACKGROUND")
    overlay:SetAllPoints()
    overlay:SetColorTexture(0, 0, 0, 0.75)

    -- Titel
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("CENTER", 0, 165)
    title:SetText("|cffffd700Mulligan – Karten zum Tauschen wählen|r")
    f.title = title

    local sub = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sub:SetPoint("CENTER", 0, 143)
    sub:SetText("Klicke eine Karte um sie zu tauschen. Warte auf deinen Gegner.")
    f.sub = sub

    -- Kartenslots (max 4)
    f.slots = {}
    for i = 1, 4 do
        local slot = CreateCardSlot(f, i)
        f.slots[i] = slot
    end

    -- Bestätigen-Button
    local btn = CreateFrame("Button", nil, f, "GameMenuButtonTemplate")
    btn:SetSize(180, 40)
    btn:SetPoint("CENTER", 0, -168)
    btn:SetText("Bestätigen")
    btn:SetScript("OnClick", function()
        addon:Net_MulliganDone(selectedIdx)
        btn:SetEnabled(false)
        btn:SetText("Warte auf Gegner…")
        -- Slots nicht mehr klickbar
        for _, s in ipairs(f.slots) do s:SetScript("OnClick", nil) end
    end)
    f.confirmBtn = btn

    f:Hide()
    return f
end

local function Mulligan_Populate(f)
    local state = addon:GE_State()
    if not state then return end
    local myIdx = state.myPlayerIdx
    local hand  = state.players[myIdx].hand

    -- Karten ohne Coin zeigen (Coin ist immer letztes Element bei P2)
    local cards = {}
    for _, c in ipairs(hand) do
        if c.id ~= "GAME_005" then cards[#cards+1] = c end
    end

    local n     = #cards
    local gap   = 20
    local total = n * CARD_W + (n - 1) * gap
    local startX = -total / 2 + CARD_W / 2

    for i = 1, 4 do
        local slot = f.slots[i]
        if i <= n then
            local card   = cards[i]
            local data   = CardData(card.id)
            slot.handIdx = i - 1  -- 0-basiert
            slot:SetPoint("CENTER", startX + (i - 1) * (CARD_W + gap), 0)
            slot:Show()
            -- Textur (eigene Hand → gewählter Karten-Skin, sonst Original)
            if data and data.artTexture then
                local skinArt = addon.CS_ArtFor and addon:CS_ArtFor(card.id, true)
                slot.art:SetTexture(skinArt or data.artTexture)
            else
                slot.art:SetTexture(FALLBACK)
            end
            slot.art:SetTexCoord(0, 1, 0, CARD_TEX_V)
            -- Texte
            slot.costText:SetText("|cffffd700" .. (card.cost or 0) .. "|r")
            slot.nameText:SetText(data and data.name or card.id)
            if data and data.type == "MINION" then
                slot.statsText:SetText((data.attack or "?") .. "/" .. (data.health or "?"))
            else
                slot.statsText:SetText(data and data.type or "")
            end
        else
            slot:Hide()
        end
    end
end

-- ── Public ────────────────────────────────────────────────────────────────────

function addon:Mulligan_Show()
    -- Zuschauer tauschen nichts — der Schutz sitzt HIER und nicht nur im
    -- GE_OnGameStart-Wrapper (GameBoard.lua): jeder Weg ins Fenster läuft
    -- durch diese Funktion, ein zweiter Aufrufer würde den Wrapper umgehen.
    if addon.IsSpectating and addon:IsSpectating() then return end
    if not MF then MF = BuildMulliganFrame() end
    selectedIdx = {}
    for _, s in ipairs(MF.slots) do
        s.highlight:Hide()
        s.swapLabel:Hide()
        s:SetScript("OnClick", MF.slots[1]:GetScript("OnClick"))
    end
    -- Slots einzeln neu belegen (OnClick braucht slot-Referenz, nicht global)
    for i, s in ipairs(MF.slots) do
        s:SetScript("OnClick", function(self)
            local idx = self.handIdx
            if not idx then return end
            if selectedIdx[idx] then
                selectedIdx[idx] = nil
                self.highlight:Hide()
                self.swapLabel:Hide()
            else
                selectedIdx[idx] = true
                self.highlight:Show()
                self.swapLabel:Show()
            end
        end)
    end
    MF.confirmBtn:SetEnabled(true)
    MF.confirmBtn:SetText("Bestätigen")
    Mulligan_Populate(MF)
    MF:Show()
end

function addon:Mulligan_Hide()
    if MF then MF:Hide() end
end

-- ── GE_OnGameStart Override ───────────────────────────────────────────────────

function addon:GE_OnGameStart()
    addon:Mulligan_Show()
end
