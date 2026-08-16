local addon = Arkana

local COF = nil
local CARD_W, CARD_H = 155, 260
local FALLBACK = "Interface\\AddOns\\Arkana\\Textures\\fallback.tga"

local function CreateChoiceSlot(parent)
    local f = CreateFrame("Button", nil, parent)
    f:SetSize(CARD_W, CARD_H)

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(); bg:SetColorTexture(0.1, 0.1, 0.2, 0.95)

    local art = f:CreateTexture(nil, "ARTWORK")
    art:SetPoint("TOPLEFT", 4, -4); art:SetPoint("BOTTOMRIGHT", -4, 50)
    f.art = art

    local hl = f:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(); hl:SetColorTexture(1, 1, 0, 0.2)

    local cost = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    cost:SetPoint("TOPLEFT", 6, -6); f.costText = cost

    local name = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    name:SetPoint("BOTTOMLEFT", 4, 14); name:SetPoint("BOTTOMRIGHT", -4, 14)
    name:SetJustifyH("CENTER"); name:SetWordWrap(false); f.nameText = name

    local desc = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("BOTTOM", 0, 2); desc:SetPoint("LEFT", 4, 0); desc:SetPoint("RIGHT", -4, 0)
    desc:SetJustifyH("CENTER"); desc:SetWordWrap(true); f.descText = desc

    return f
end

local function BuildChooseOneFrame()
    local f = CreateFrame("Frame", "ARKANA_ChooseOneFrame", UIParent)
    f:SetAllPoints(UIParent)
    f:SetFrameStrata("FULLSCREEN_DIALOG")

    local overlay = f:CreateTexture(nil, "BACKGROUND")
    overlay:SetAllPoints(); overlay:SetColorTexture(0, 0, 0, 0.8)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("CENTER", 0, 165)
    title:SetText("|cffffd700Wählt aus:|r")

    local cancelBtn = CreateFrame("Button", nil, f, "GameMenuButtonTemplate")
    cancelBtn:SetSize(120, 34); cancelBtn:SetPoint("CENTER", 0, -168)
    cancelBtn:SetText("Abbrechen")
    cancelBtn:SetScript("OnClick", function()
        f:Hide()
    end)

    f.slots = { CreateChoiceSlot(f), CreateChoiceSlot(f) }
    f.slots[1]:SetPoint("CENTER", -95, 0)
    f.slots[2]:SetPoint("CENTER",  95, 0)

    f:Hide()
    return f
end

function addon:ChooseOne_Show(optA, optB, callback)
    if not COF then COF = BuildChooseOneFrame() end

    local opts = { optA, optB }
    for i, id in ipairs(opts) do
        local slot = COF.slots[i]
        local cd = ARKANA_CardData and ARKANA_CardData[id]
        if cd and cd.artTexture then
            local skinArt = addon.CS_ArtFor and addon:CS_ArtFor(id, true)   -- eigene Wahl
            slot.art:SetTexture(skinArt or cd.artTexture)
        else slot.art:SetTexture(FALLBACK) end
        slot.art:SetTexCoord(0, 1, 0, 0.691)
        slot.costText:SetText(cd and ("|cffffd700" .. (cd.cost or 0) .. "|r") or "")
        slot.nameText:SetText(cd and cd.name or id)
        slot.descText:SetText(cd and cd.text or "")
        slot:SetScript("OnClick", function()
            COF:Hide()
            callback(id)
        end)
    end

    COF:Show()
end

function addon:ChooseOne_Hide()
    if COF then COF:Hide() end
end

local TRF = nil

local function BuildTrackingFrame()
    local f = CreateFrame("Frame", "ARKANA_TrackingFrame", UIParent)
    f:SetAllPoints(UIParent)
    f:SetFrameStrata("FULLSCREEN_DIALOG")

    local overlay = f:CreateTexture(nil, "BACKGROUND")
    overlay:SetAllPoints(); overlay:SetColorTexture(0, 0, 0, 0.8)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("CENTER", 0, 165)
    title:SetText("|cffffd700Fährtenlesen: Wählt eine Karte|r")

    -- Bewusst KEIN Schließen-Button: Die Karte ist beim Öffnen schon bezahlt
    -- (ExecPlay), Abbrechen sendete kein TRACKING_CHOOSE → Wahl blieb in beiden
    -- Engines ewig offen. Echtes HS erlaubt bei Fährtenlesen kein Abbrechen.
    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hint:SetPoint("CENTER", 0, -168)
    hint:SetTextColor(0.7, 0.7, 0.7)
    hint:SetText("Eine Karte muss gewählt werden — die anderen werden verbrannt.")

    f.slots = { CreateChoiceSlot(f), CreateChoiceSlot(f), CreateChoiceSlot(f) }
    
    f:Hide()
    return f
end

function addon:Tracking_Show(choices, callback)
    if not TRF then TRF = BuildTrackingFrame() end

    local n = #choices
    if n == 0 then
        TRF:Hide()
        return
    end

    for i = 1, 3 do
        TRF.slots[i]:Hide()
    end

    if n == 1 then
        TRF.slots[1]:SetPoint("CENTER", 0, 0)
        TRF.slots[1]:Show()
    elseif n == 2 then
        TRF.slots[1]:SetPoint("CENTER", -95, 0)
        TRF.slots[2]:SetPoint("CENTER",  95, 0)
        TRF.slots[1]:Show()
        TRF.slots[2]:Show()
    else
        TRF.slots[1]:SetPoint("CENTER", -180, 0)
        TRF.slots[2]:SetPoint("CENTER",  0, 0)
        TRF.slots[3]:SetPoint("CENTER",  180, 0)
        TRF.slots[1]:Show()
        TRF.slots[2]:Show()
        TRF.slots[3]:Show()
    end

    for i = 1, n do
        local id = choices[i]
        local slot = TRF.slots[i]
        local cd = ARKANA_CardData and ARKANA_CardData[id]
        if cd and cd.artTexture then
            local skinArt = addon.CS_ArtFor and addon:CS_ArtFor(id, true)   -- eigene Karten (Fährtenlesen)
            slot.art:SetTexture(skinArt or cd.artTexture)
        else
            slot.art:SetTexture(FALLBACK)
        end
        slot.art:SetTexCoord(0, 1, 0, 0.691)
        slot.costText:SetText(cd and ("|cffffd700" .. (cd.cost or 0) .. "|r") or "")
        slot.nameText:SetText(cd and cd.name or id)
        slot.descText:SetText(cd and cd.text or "")
        
        slot:SetScript("OnClick", function()
            TRF:Hide()
            callback(id)
        end)
    end

    TRF:Show()
end

function addon:Tracking_Hide()
    if TRF then TRF:Hide() end
end
