local addon = Arkana

local boosterFrame
local CARD_TEX_V = 388 / 512
local PACK_REVEAL_DURATION = 2.40
local BOOSTER_ORDER = { "C", "X", "L" }
local BOOSTER_INFO = {
    C = {
        name = "Classic", texture = "Interface\\AddOns\\Arkana\\Textures\\Packs\\Classic.tga",
        description = "Fünf Karten · mindestens eine Karte ist Rare oder besser.",
    },
    X = {
        name = "Custom", texture = "Interface\\AddOns\\Arkana\\Textures\\Packs\\CardPack_10.tga",
        description = "Fünf Karten ab Rare · mindestens eine Karte ist Epic oder besser.",
    },
    L = {
        name = "Legendär", texture = "Interface\\AddOns\\Arkana\\Textures\\Packs\\CardPack_11.tga",
        description = "Fünf Karten · eine legendäre Karte ist garantiert.",
    },
}

local COLOR = addon:UI_RegisterThemePalette({})

local RARITY_COLOR = {
    COMMON    = { 0.95, 0.95, 0.95 },
    RARE      = { 0.15, 0.55, 1.00 },
    EPIC      = { 0.72, 0.30, 0.95 },
    LEGENDARY = { 1.00, 0.50, 0.10 },
}
local RARITY_LABEL = {
    COMMON = "Common", RARE = "Rare", EPIC = "Epic", LEGENDARY = "Legendary",
}
local CLASS_LABEL = {
    DRUID="Druide", HUNTER="Jäger", MAGE="Magier", PALADIN="Paladin",
    PRIEST="Priester", ROGUE="Schurke", SHAMAN="Schamane", WARLOCK="Hexenmeister",
    WARRIOR="Krieger", NEUTRAL="Neutral",
}

local function Solid(texture, color)
    addon:UI_BindThemeTexture(texture, color)
end

local function AnimateCardReveal(slot)
    local elapsed, duration = 0, 0.24
    slot:SetAlpha(0)
    slot:SetScale(0.72)
    slot:Show()
    slot:SetScript("OnUpdate", function(self, delta)
        elapsed = elapsed + delta
        local progress = math.min(1, elapsed / duration)
        local eased = 1 - (1 - progress) * (1 - progress)
        self:SetAlpha(progress)
        self:SetScale(0.72 + 0.28 * eased + math.sin(progress * math.pi) * 0.04)
        if progress >= 1 then
            self:SetScript("OnUpdate", nil)
            self:SetAlpha(1)
            self:SetScale(1)
        end
    end)
end

local function ModernButton(parent, text, width, height, onClick)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(width, height)
    button:RegisterForClicks("LeftButtonUp")
    local border = button:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints()
    Solid(border, COLOR.purpleSoft)
    local background = button:CreateTexture(nil, "BACKGROUND", nil, 1)
    background:SetPoint("TOPLEFT", 1, -1)
    background:SetPoint("BOTTOMRIGHT", -1, 1)
    Solid(background, COLOR.button)
    local label = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("CENTER")
    label:SetText(text)
    label:SetTextColor(0.92, 0.89, 1, 1)
    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetPoint("TOPLEFT", 1, -1)
    highlight:SetPoint("BOTTOMRIGHT", -1, 1)
    addon:UI_BindThemeTexture(highlight, COLOR.purple, 0.18)
    button:SetScript("OnEnter", function()
        border:SetColorTexture(unpack(COLOR.purple))
        label:SetTextColor(1, 1, 1, 1)
    end)
    button:SetScript("OnLeave", function()
        Solid(border, COLOR.purpleSoft)
        label:SetTextColor(0.92, 0.89, 1, 1)
    end)
    button:SetScript("OnClick", onClick)
    return button
end

local function CreateBoosterWindow()
    local f = CreateFrame("Frame", "ARKANA_BoosterWindow", UIParent, "BackdropTemplate")
    f:SetSize(650, 430)
    f:SetPoint("CENTER")
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    f:SetBackdropColor(unpack(COLOR.panel))
    f:SetBackdropBorderColor(unpack(COLOR.panelBorder))
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("DIALOG")
    f:Hide()
    if addon.UI_RegisterScalableFrame then addon:UI_RegisterScalableFrame(f) end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("Arkana")
    title:SetTextColor(unpack(COLOR.title))
    local subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    subtitle:SetPoint("TOP", title, "BOTTOM", 0, -2)
    f.subtitle = subtitle
    f.boosterType = "C"
    local previousBooster = ModernButton(f, "<", 26, 24, function()
        if not f.revealing then f:CycleBoosterType(-1) end
    end)
    previousBooster:SetPoint("TOP", -105, -32)
    local nextBooster = ModernButton(f, ">", 26, 24, function()
        if not f.revealing then f:CycleBoosterType(1) end
    end)
    nextBooster:SetPoint("TOP", 105, -32)
    f.previousBooster, f.nextBooster = previousBooster, nextBooster

    local closeX = ModernButton(f, "×", 26, 24, function() f:Hide() end)
    closeX:SetPoint("TOPRIGHT", -9, -9)
    local topLine = f:CreateTexture(nil, "ARTWORK")
    topLine:SetHeight(2)
    topLine:SetPoint("TOPLEFT", 20, -63)
    topLine:SetPoint("TOPRIGHT", -20, -63)
    Solid(topLine, COLOR.purple)

    f.countText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.countText:SetPoint("TOP", 0, -78)

    local openButton = ModernButton(f, "1 Booster öffnen", 180, 36, function()
        if f.revealing then return end
        local cards, err, remaining = addon:COL_OpenBooster(f.boosterType)
        if not cards then
            f:SetStatus(err or "Booster konnte nicht geöffnet werden.", false)
            f:RefreshCount()
            return
        end
        f:RefreshCount(remaining)
        f:AnimateBooster(cards)
    end)
    openButton:SetPoint("TOP", 0, -105)
    f.openButton = openButton

    local resultPanel = CreateFrame("Frame", nil, f, "BackdropTemplate")
    resultPanel:SetPoint("TOPLEFT", 20, -151)
    resultPanel:SetPoint("TOPRIGHT", -20, -151)
    resultPanel:SetHeight(206)
    resultPanel:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    resultPanel:SetBackdropColor(unpack(COLOR.inner))
    resultPanel:SetBackdropBorderColor(unpack(COLOR.purpleSoft))

    f.emptyText = resultPanel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    f.emptyText:SetPoint("CENTER")
    f.emptyText:SetText("Öffne einen Booster, um die enthaltenen Karten zu sehen.")

    -- Pack-Motiv für die erste Animationsphase. Das Pack erscheint ohne farbigen
    -- Leuchthintergrund, bevor die Karten nacheinander aufgedeckt werden.
    f.packReveal = CreateFrame("Frame", nil, resultPanel)
    f.packReveal:SetSize(142, 184)
    -- Die Pack-Textur besitzt oben und unten unterschiedlich viel transparenten
    -- Rand. Der kleine Versatz richtet das sichtbare Motiv optisch mittig aus.
    f.packReveal:SetPoint("CENTER", 0, -10)
    f.packReveal:SetFrameLevel(resultPanel:GetFrameLevel() + 20)
    f.packReveal.art = f.packReveal:CreateTexture(nil, "ARTWORK")
    f.packReveal.art:SetAllPoints()
    f.packReveal.art:SetTexture(BOOSTER_INFO.C.texture)
    -- Native Animationsgruppen laufen im WoW-UI ohne eine Lua-Funktion bei jedem
    -- Bildframe. Vier gegenläufige Bewegungen ergeben pro Schleife wieder exakt
    -- den Ausgangspunkt und verhindern Positionsdrift.
    f.packReveal.shake = f.packReveal:CreateAnimationGroup()
    f.packReveal.shake:SetLooping("REPEAT")
    local shakeOffsets = { { 6, 1 }, { -12, -2 }, { 12, 2 }, { -6, -1 } }
    for order, offset in ipairs(shakeOffsets) do
        local move = f.packReveal.shake:CreateAnimation("Translation")
        move:SetOffset(offset[1], offset[2])
        move:SetDuration((order == 1 or order == 4) and 0.10 or 0.13)
        move:SetOrder(order)
        move:SetSmoothing("IN_OUT")
    end
    f.packReveal.fade = f.packReveal:CreateAnimationGroup()
    local fade = f.packReveal.fade:CreateAnimation("Alpha")
    fade:SetFromAlpha(0)
    fade:SetToAlpha(1)
    fade:SetDuration(0.28)
    fade:SetOrder(1)
    fade:SetSmoothing("OUT")
    f.packReveal:Hide()

    f.cardSlots = {}
    for i = 1, 5 do
        local slot = CreateFrame("Button", nil, resultPanel)
        slot:SetSize(112, 184)
        slot:SetPoint("TOPLEFT", 13 + (i - 1) * 118, -11)
        local glow = slot:CreateTexture(nil, "BACKGROUND")
        glow:SetPoint("TOPLEFT", -2, 2)
        glow:SetPoint("BOTTOMRIGHT", 2, -2)
        addon:UI_BindThemeTexture(glow, COLOR.purpleSoft, 0.8)
        local art = slot:CreateTexture(nil, "ARTWORK")
        art:SetSize(108, 168)
        art:SetPoint("CENTER")
        art:SetTexCoord(0, 1, 0, CARD_TEX_V)
        slot.art, slot.glow = art, glow
        slot:SetScript("OnEnter", function(self)
            if not self.card then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.card.name or self.card.id, 1, 0.82, 0)
            GameTooltip:AddLine((RARITY_LABEL[self.card.rarity] or self.card.rarity or "") .. " · " ..
                (CLASS_LABEL[self.card.class] or self.card.class or "Neutral"), 1, 1, 1)
            if self.card.text and self.card.text ~= "" then GameTooltip:AddLine(self.card.text, 0.9, 0.9, 0.9, true) end
            GameTooltip:Show()
        end)
        slot:SetScript("OnLeave", function() GameTooltip:Hide() end)
        slot:Hide()
        f.cardSlots[i] = slot
    end

    f.status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.status:SetPoint("TOPLEFT", 24, -369)
    f.status:SetPoint("TOPRIGHT", -24, -369)
    f.status:SetJustifyH("CENTER")

    local back = ModernButton(f, "Zurück", 168, 30, function()
        f:Hide()
        addon:OpenMainMenu()
    end)
    back:SetPoint("BOTTOM", 0, 13)

    function f:RefreshCount(knownCount)
        local count = knownCount
        if count == nil then
            count = addon.COL_BoosterCount and addon:COL_BoosterCount(self.boosterType) or 0
        end
        self.countText:SetText("Verfügbar: |cffffd866" .. count .. "|r " ..
            BOOSTER_INFO[self.boosterType].name .. "-Booster")
    end

    function f:CycleBoosterType(direction)
        local index = 1
        for i, key in ipairs(BOOSTER_ORDER) do
            if key == self.boosterType then index = i; break end
        end
        index = ((index - 1 + direction) % #BOOSTER_ORDER) + 1
        self.boosterType = BOOSTER_ORDER[index]
        self:ResetView()
        self:RefreshBoosterType()
    end

    function f:RefreshBoosterType()
        local info = BOOSTER_INFO[self.boosterType]
        self.subtitle:SetText(info.name .. "-Booster")
        self.packReveal.art:SetTexture(info.texture)
        self:RefreshCount()
        if not self.revealing then self:SetStatus(info.description, nil) end
    end

    function f:SetStatus(message, ok)
        self.status:SetText(message or "")
        if ok == nil then
            self.status:SetTextColor(0.78, 0.68, 1.00, 1)
        elseif ok then
            self.status:SetTextColor(0.35, 0.95, 0.55, 1)
        else
            self.status:SetTextColor(1.00, 0.35, 0.40, 1)
        end
    end

    function f:ShowCards(cardIds, prepareOnly)
        self.emptyText:Hide()
        for i, slot in ipairs(self.cardSlots) do
            slot:SetScript("OnUpdate", nil)
            slot:SetAlpha(1)
            slot:SetScale(1)
            local card = ARKANA_CardData and ARKANA_CardData[cardIds[i]]
            slot.card = card
            if card then
                slot.art:SetTexture((addon.CS_ArtFor and addon:CS_ArtFor(card.id, true)) or card.artTexture or
                    ("Interface\\AddOns\\Arkana\\Textures\\Cards\\" .. card.id .. ".tga"))
                local color = RARITY_COLOR[card.rarity] or RARITY_COLOR.COMMON
                slot.glow:SetColorTexture(color[1], color[2], color[3], 0.72)
                slot:SetShown(not prepareOnly)
            else
                slot:Hide()
            end
        end
    end

    function f:AnimateBooster(cardIds)
        self.revealToken = (self.revealToken or 0) + 1
        local token = self.revealToken
        self.revealing = true
        self.openButton:Disable()
        self.previousBooster:Disable()
        self.nextBooster:Disable()
        self.openButton:SetAlpha(0.52)
        self:SetStatus("Booster wird geöffnet …", nil)
        self:ShowCards(cardIds, true)

        local pack = self.packReveal
        pack:SetScript("OnUpdate", nil)
        pack:SetAlpha(1)
        pack:SetScale(1)
        pack:Show()
        pack.fade:Stop()
        pack.shake:Stop()
        pack.fade:Play()
        pack.shake:Play()

        C_Timer.After(PACK_REVEAL_DURATION, function()
            if self.revealToken ~= token then return end
            pack.fade:Stop()
            pack.shake:Stop()
            pack:SetAlpha(1)
            pack:SetScale(1)
            pack:Hide()

            for i = 1, #self.cardSlots do
                local index = i
                C_Timer.After((index - 1) * 0.18, function()
                    if self.revealToken ~= token then return end
                    local slot = self.cardSlots[index]
                    if slot and slot.card then AnimateCardReveal(slot) end
                    if index == #self.cardSlots then
                        C_Timer.After(0.28, function()
                            if self.revealToken ~= token then return end
                            self.revealing = false
                            self.openButton:Enable()
                            self.previousBooster:Enable()
                            self.nextBooster:Enable()
                            self.openButton:SetAlpha(1)
                            self:SetStatus(BOOSTER_INFO[self.boosterType].description, true)
                        end)
                    end
                end)
            end
        end)
    end

    function f:ResetView()
        -- Offene Timer erkennen am geänderten Token, dass ihre Animation verworfen
        -- wurde. Der bereits gezogene Kartenbesitz bleibt selbstverständlich erhalten.
        self.revealToken = (self.revealToken or 0) + 1
        self.revealing = false
        self.packReveal:SetScript("OnUpdate", nil)
        self.packReveal.fade:Stop()
        self.packReveal.shake:Stop()
        self.packReveal:SetAlpha(1)
        self.packReveal:SetScale(1)
        self.packReveal:Hide()
        for _, slot in ipairs(self.cardSlots) do
            slot:SetScript("OnUpdate", nil)
            slot:SetAlpha(1)
            slot:SetScale(1)
            slot.card = nil
            slot.art:SetTexture(nil)
            slot:Hide()
        end
        self.openButton:Enable()
        self.previousBooster:Enable()
        self.nextBooster:Enable()
        self.openButton:SetAlpha(1)
        self.emptyText:Show()
        self:SetStatus(BOOSTER_INFO[self.boosterType].description, nil)
        GameTooltip:Hide()
    end

    f:SetScript("OnShow", function(self)
        self:RefreshBoosterType()
    end)
    f:SetScript("OnHide", function(self) self:ResetView() end)

    table.insert(UISpecialFrames, f:GetName())
    return f
end

function addon:BO_RefreshIfShown()
    if boosterFrame and boosterFrame:IsShown() then boosterFrame:RefreshCount() end
end

function addon:OpenBoosterWindow()
    if not boosterFrame then boosterFrame = CreateBoosterWindow() end
    boosterFrame:Show()
end
