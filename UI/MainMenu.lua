local addon = Arkana

local mainMenuFrame
local cosmeticsFrame

local DECK_CLASS_HEX = {
    DRUID = "FF7D0A", HUNTER = "ABD473", MAGE = "69CCF0",
    PALADIN = "F58CBA", PRIEST = "FFFFFF", ROGUE = "FFF569",
    SHAMAN = "0070DE", WARLOCK = "9482C9", WARRIOR = "C79C6E",
}

local function IsSelectableDeck(deck)
    if not deck or type(deck.cards) ~= "table" or #deck.cards ~= 30 then return false end
    if not addon.COL_Count then return true end
    local counts = {}
    for _, cardId in ipairs(deck.cards) do
        counts[cardId] = (counts[cardId] or 0) + 1
        if counts[cardId] > addon:COL_Count(cardId) then return false end
    end
    return true
end

local function GetActiveDeckText()
    local idx = ARKANA_CharData and ARKANA_CharData.activeDeckIndex
    if idx and ARKANA_Decks and ARKANA_Decks[idx] then
        local d = ARKANA_Decks[idx]
        if IsSelectableDeck(d) then
            local color = DECK_CLASS_HEX[tostring(d.class or ""):upper()] or "EAE3FF"
            return "|cff" .. color .. tostring(d.name or "Unbenanntes Deck") .. "|r"
        end
    end
    return "(kein vollständiges Deck aktiv)"
end

local function SelectAdjacentDeck(direction)
    ARKANA_CharData = ARKANA_CharData or {}
    local selectable = {}
    for index, deck in ipairs(ARKANA_Decks or {}) do
        if IsSelectableDeck(deck) then selectable[#selectable + 1] = index end
    end
    if #selectable == 0 then
        ARKANA_CharData.activeDeckIndex = nil
        if mainMenuFrame and mainMenuFrame.RefreshSummary then mainMenuFrame:RefreshSummary() end
        print("|cffff0000[Arkana]|r Es ist noch kein vollständiges Deck aus verfügbaren Karten vorhanden.")
        return false
    end
    local current = tonumber(ARKANA_CharData.activeDeckIndex)
    local position
    for i, deckIndex in ipairs(selectable) do
        if deckIndex == current then position = i break end
    end
    if not position then
        position = direction < 0 and #selectable or 1
    else
        position = ((position - 1 + direction) % #selectable) + 1
    end
    ARKANA_CharData.activeDeckIndex = selectable[position]
    if mainMenuFrame and mainMenuFrame.RefreshSummary then mainMenuFrame:RefreshSummary() end
    return true
end

local COLOR = addon:UI_RegisterThemePalette({})

local function SetSolid(texture, color)
    addon:UI_BindThemeTexture(texture, color)
end

local function CreateModernButton(parent, text, width, height, onClick)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(width, height)
    button:RegisterForClicks("LeftButtonUp")

    local border = button:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints()
    SetSolid(border, COLOR.purpleSoft)

    local background = button:CreateTexture(nil, "BACKGROUND", nil, 1)
    background:SetPoint("TOPLEFT", 1, -1)
    background:SetPoint("BOTTOMRIGHT", -1, 1)
    SetSolid(background, COLOR.button)

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
        SetSolid(border, COLOR.purpleSoft)
        label:SetTextColor(0.92, 0.89, 1, 1)
    end)
    button.label = label
    function button:SetText(value) self.label:SetText(value) end
    button:SetScript("OnClick", onClick)
    return button
end

local function CreateMainMenu()
    local f = CreateFrame("Frame", "ARKANA_MainMenu", UIParent, "BackdropTemplate")
    f:SetSize(390, 492)
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

    local build = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    build:SetPoint("TOP", title, "BOTTOM", 0, -2)
    build:SetText("Build " .. (ARKANA_BUILD or "?"))

    local topLine = f:CreateTexture(nil, "ARTWORK")
    topLine:SetHeight(2)
    topLine:SetPoint("TOPLEFT", 20, -63)
    topLine:SetPoint("TOPRIGHT", -20, -63)
    SetSolid(topLine, COLOR.purple)

    local infoPanel = CreateFrame("Frame", nil, f, "BackdropTemplate")
    infoPanel:SetPoint("TOPLEFT", 20, -70)
    infoPanel:SetPoint("TOPRIGHT", -20, -70)
    infoPanel:SetHeight(55)
    infoPanel:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    infoPanel:SetBackdropColor(unpack(COLOR.inner))
    infoPanel:SetBackdropBorderColor(unpack(COLOR.purpleSoft))

    local closeX = CreateModernButton(f, "×", 26, 24, function() f:Hide() end)
    closeX:SetPoint("TOPRIGHT", -9, -9)

    local deckTitle = infoPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    deckTitle:SetPoint("TOP", infoPanel, "TOP", 0, -5)
    deckTitle:SetText("Aktives Deck")

    local previousDeck = CreateModernButton(infoPanel, "<", 30, 28, function()
        SelectAdjacentDeck(-1)
    end)
    previousDeck:SetPoint("LEFT", infoPanel, "LEFT", 8, -6)

    local nextDeck = CreateModernButton(infoPanel, ">", 30, 28, function()
        SelectAdjacentDeck(1)
    end)
    nextDeck:SetPoint("RIGHT", infoPanel, "RIGHT", -8, -6)

    f.deckLabel = infoPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.deckLabel:SetPoint("LEFT", previousDeck, "RIGHT", 8, 0)
    f.deckLabel:SetPoint("RIGHT", nextDeck, "LEFT", -8, 0)
    f.deckLabel:SetJustifyH("CENTER")
    f.deckLabel:SetText(GetActiveDeckText())

    local buttons = {
        { label = "Decks",          action = function() f:Hide(); addon:OpenDeckBuilder() end },
        { label = "Herausfordern",  action = function() if addon.ChallengeTarget then addon:ChallengeTarget() end end },
        { label = "Sandbox", sandboxAccess = true, action = function()
            if addon.Sandbox_Start then
                addon:Sandbox_Start()
            else
                print("|cffff0000[Arkana]|r Das Sandbox-Modul wurde nicht geladen. Bitte Addon-Dateien prüfen und /reload ausführen.")
            end
        end },
        { label = "Zuschauen",      action = function() f:Hide(); if addon.Spec_ShowLobby then addon:Spec_ShowLobby() end end },
        { label = "Rangliste",      action = function() f:Hide(); if addon.RK_ShowLadder then addon:RK_ShowLadder() end end },
        { label = "Booster",        action = function() f:Hide(); addon:OpenBoosterWindow() end },
        { label = "Kosmetik",       action = function() f:Hide(); addon:OpenCosmeticsMenu() end },
        { label = "Einstellungen",  action = function() f:Hide(); addon:ToggleScalePanel() end },
    }
    buttons[#buttons + 1] = {
        label = "Verteilung",
        access = true,
        action = function() f:Hide(); addon:OpenAdminTool() end,
    }
    f.menuButtons = {}
    for i, data in ipairs(buttons) do
        local btn = CreateModernButton(f, data.label, 168, 42, data.action)
        btn.requiresAccess = data.access == true
        btn.requiresSandboxAccess = data.sandboxAccess == true
        f.menuButtons[#f.menuButtons + 1] = btn
    end

    local rankPanel = CreateFrame("Frame", nil, f, "BackdropTemplate")
    local rankY = -336
    rankPanel:SetPoint("TOPLEFT", 20, rankY)
    rankPanel:SetPoint("TOPRIGHT", -20, rankY)
    rankPanel:SetHeight(82)
    rankPanel:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    rankPanel:SetBackdropColor(unpack(COLOR.inner))
    rankPanel:SetBackdropBorderColor(unpack(COLOR.purpleSoft))

    f.rankIcon = rankPanel:CreateTexture(nil, "ARTWORK")
    f.rankIcon:SetSize(54, 54)
    f.rankIcon:SetPoint("TOP", rankPanel, "TOP", 0, -4)

    f.rankPoints = rankPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.rankPoints:SetPoint("TOP", f.rankIcon, "BOTTOM", 0, -2)
    f.rankPoints:SetPoint("LEFT", rankPanel, "LEFT", 8, 0)
    f.rankPoints:SetPoint("RIGHT", rankPanel, "RIGHT", -8, 0)
    f.rankPoints:SetJustifyH("CENTER")

    local bottomLine = f:CreateTexture(nil, "ARTWORK")
    bottomLine:SetHeight(1)
    bottomLine:SetPoint("BOTTOMLEFT", 20, 63)
    bottomLine:SetPoint("BOTTOMRIGHT", -20, 63)
    SetSolid(bottomLine, COLOR.purpleSoft)

    local close = CreateModernButton(f, "Schließen", 168, 30, function() f:Hide() end)
    close:SetPoint("BOTTOM", 0, 27)

    -- Credits
    local credits = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    credits:SetPoint("BOTTOM", f, "BOTTOM", 0, 8)
    credits:SetText("Created by Tecro, Varoo")

    function f:RefreshSummary()
        self.deckLabel:SetText(GetActiveDeckText())
        if addon.RK_Icon then self.rankIcon:SetTexture(addon:RK_Icon()) end
        if addon.RK_PointsText then self.rankPoints:SetText(addon:RK_PointsText()) end
    end

    function f:RefreshAccess()
        local allowed = addon.ADM_CanUse and addon:ADM_CanUse()
        local sandboxAllowed = addon.SEC_CanUseSandbox and addon:SEC_CanUseSandbox()
        local visible = {}
        for _, button in ipairs(self.menuButtons) do
            if (button.requiresAccess and not allowed) or
               (button.requiresSandboxAccess and not sandboxAllowed) then
                button:Hide()
            else
                button:Show()
                visible[#visible + 1] = button
            end
        end
        for i, button in ipairs(visible) do
            local column = (i - 1) % 2
            local row = math.floor((i - 1) / 2)
            local x = (i == #visible and #visible % 2 == 1) and 111 or (23 + column * 176)
            button:ClearAllPoints()
            button:SetPoint("TOPLEFT", self, "TOPLEFT", x, -136 - row * 50)
        end
        -- Nur die Spielleitung sieht mit "Verteilung" eine ungerade fünfte
        -- Button-Zeile. Das Fenster wächst dann mit, statt Rangbereich und Button
        -- übereinander zu legen.
        local extraRows = math.max(0, math.ceil(#visible / 2) - 4)
        self:SetHeight(492 + extraRows * 50)
        rankPanel:ClearAllPoints()
        rankPanel:SetPoint("TOPLEFT", 20, rankY - extraRows * 50)
        rankPanel:SetPoint("TOPRIGHT", -20, rankY - extraRows * 50)
    end

    f:SetScript("OnShow", function(self)
        self:RefreshAccess()
        self:RefreshSummary()
    end)

    table.insert(UISpecialFrames, f:GetName())
    return f
end

function addon:OpenMainMenu()
    if not mainMenuFrame then mainMenuFrame = CreateMainMenu() end
    mainMenuFrame:Show()
end

function addon:MM_Hide()
    if mainMenuFrame then mainMenuFrame:Hide() end
end

function addon:MM_RefreshAccess()
    if mainMenuFrame and mainMenuFrame.RefreshAccess then mainMenuFrame:RefreshAccess() end
end

local function CreateCosmeticsMenu()
    local f = CreateFrame("Frame", "ARKANA_CosmeticsMenu", UIParent, "BackdropTemplate")
    f:SetSize(390, 300)
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
    if addon.UI_RegisterScalableFrame then addon:UI_RegisterScalableFrame(f) end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("Kosmetik")
    title:SetTextColor(unpack(COLOR.title))

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOP", title, "BOTTOM", 0, -4)
    hint:SetText("Wähle den Bereich, den du anpassen möchtest.")

    local closeX = CreateModernButton(f, "×", 26, 24, function() f:Hide() end)
    closeX:SetPoint("TOPRIGHT", -9, -9)

    local topLine = f:CreateTexture(nil, "ARTWORK")
    topLine:SetHeight(2)
    topLine:SetPoint("TOPLEFT", 20, -65)
    topLine:SetPoint("TOPRIGHT", -20, -65)
    SetSolid(topLine, COLOR.purple)

    local function OpenChild(openChild)
        if not openChild then return end
        f.openingChild = true
        f:Hide()
        f.openingChild = false
        openChild(addon)
    end
    local choices = {
        { label = "Kartenrücken", action = function() OpenChild(addon.CB_ShowGallery) end },
        { label = "Karten-Skins", action = function() OpenChild(addon.CS_ShowGallery) end },
        { label = "Helden-Skins", action = function() OpenChild(addon.HS_ShowGallery) end },
    }
    for i, choice in ipairs(choices) do
        local button = CreateModernButton(f, choice.label, 330, 42, choice.action)
        button:SetPoint("TOP", f, "TOP", 0, -80 - (i - 1) * 50)
    end

    local back = CreateModernButton(f, "Zurück", 168, 30, function()
        f:Hide()
    end)
    back:SetPoint("BOTTOM", 0, 17)

    f:SetScript("OnHide", function(self)
        if not self.openingChild then addon:OpenMainMenu() end
    end)

    table.insert(UISpecialFrames, f:GetName())
    return f
end

function addon:OpenCosmeticsMenu()
    addon:MM_Hide()
    if not cosmeticsFrame then cosmeticsFrame = CreateCosmeticsMenu() end
    cosmeticsFrame:Show()
end

-- ── Einstellungsfenster: Menüs, Spielbrett, Tooltips und Deckkraft ──────────────
local scalePanel

local function MakeScaleSlider(name, parent, y, label, key, lo, hi)
    local s = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    s:SetWidth(200)
    s:SetHeight(16)
    s:SetPoint("TOP", parent, "TOP", 0, y)
    s:SetMinMaxValues(lo or 0.5, hi or 2.0)
    s:SetValueStep(0.05)
    s:SetObeyStepOnDrag(true)
    _G[name .. "Low"]:Hide()
    _G[name .. "High"]:Hide()
    _G[name .. "Text"]:SetTextColor(unpack(COLOR.title))
    local function SetLabel(val)
        _G[name .. "Text"]:SetText(string.format("%s: %d%%", label, val * 100))
    end
    s:SetScript("OnValueChanged", function(self, val)
        val = math.floor(val * 20 + 0.5) / 20  -- auf 0.05er-Schritte runden
        ARKANA_Settings[key] = val
        SetLabel(val)
        addon:ApplyScales()
    end)
    s.Refresh = function(self)
        local val = ARKANA_Settings[key] or 1.0
        self:SetValue(val)
        SetLabel(val)
    end
    return s
end

function addon:ToggleScalePanel()
    if scalePanel and scalePanel:IsShown() then scalePanel:Hide(); return end
    if not scalePanel then
        scalePanel = CreateFrame("Frame", "ARKANA_ScalePanel", UIParent, "BackdropTemplate")
        scalePanel:SetSize(350, 500)
        scalePanel:SetPoint("CENTER")
        scalePanel:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1,
        })
        scalePanel:SetBackdropColor(unpack(COLOR.panel))
        scalePanel:SetBackdropBorderColor(unpack(COLOR.panelBorder))
        scalePanel:SetFrameStrata("DIALOG")
        scalePanel:SetMovable(true)
        scalePanel:EnableMouse(true)
        scalePanel:RegisterForDrag("LeftButton")
        scalePanel:SetScript("OnDragStart", scalePanel.StartMoving)
        scalePanel:SetScript("OnDragStop", scalePanel.StopMovingOrSizing)
        scalePanel:SetClampedToScreen(true)
        if addon.UI_RegisterThemeFrame then addon:UI_RegisterThemeFrame(scalePanel) end

        local title = scalePanel:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
        title:SetPoint("TOP", 0, -16)
        title:SetText("Einstellungen")
        title:SetTextColor(unpack(COLOR.title))
        local subtitle = scalePanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        subtitle:SetPoint("TOP", title, "BOTTOM", 0, -3)
        subtitle:SetText("Darstellung und Datenschutz")

        local closeX = CreateModernButton(scalePanel, "×", 26, 24, function() scalePanel:Hide() end)
        closeX:SetPoint("TOPRIGHT", -9, -9)
        local topLine = scalePanel:CreateTexture(nil, "ARTWORK")
        topLine:SetHeight(2)
        topLine:SetPoint("TOPLEFT", 20, -62)
        topLine:SetPoint("TOPRIGHT", -20, -62)
        SetSolid(topLine, COLOR.purple)

        local themeTitle = scalePanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        themeTitle:SetPoint("TOP", scalePanel, "TOP", 0, -78)
        themeTitle:SetText("Farbthema")
        local previousTheme = CreateModernButton(scalePanel, "<", 34, 28, function()
            scalePanel:CycleTheme(-1)
        end)
        previousTheme:SetPoint("TOPLEFT", 33, -95)
        local nextTheme = CreateModernButton(scalePanel, ">", 34, 28, function()
            scalePanel:CycleTheme(1)
        end)
        nextTheme:SetPoint("TOPRIGHT", -33, -95)
        scalePanel.themeValue = scalePanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        scalePanel.themeValue:SetPoint("LEFT", previousTheme, "RIGHT", 8, 0)
        scalePanel.themeValue:SetPoint("RIGHT", nextTheme, "LEFT", -8, 0)
        scalePanel.themeValue:SetJustifyH("CENTER")

        function scalePanel:CycleTheme(direction)
            local order = addon:UI_ThemeOrder()
            local current = addon:UI_CurrentTheme()
            local index = 1
            for i, key in ipairs(order) do if key == current then index = i break end end
            index = ((index - 1 + direction) % #order) + 1
            addon:UI_SetTheme(order[index])
            self:RefreshTheme()
        end

        function scalePanel:RefreshTheme()
            self.themeValue:SetText(addon:UI_ThemeName(addon:UI_CurrentTheme()))
            self.themeValue:SetTextColor(unpack(COLOR.title))
        end

        scalePanel.windowSlider = MakeScaleSlider("ARKANA_ScaleSliderWindows", scalePanel, -150, "Fenster", "windowScale", 0.6, 1.5)
        scalePanel.boardSlider = MakeScaleSlider("ARKANA_ScaleSliderBoard", scalePanel, -200, "Spielbrett", "boardScale", 0.5, 2.0)
        scalePanel.tipSlider = MakeScaleSlider("ARKANA_ScaleSliderTip", scalePanel, -250, "Tooltips extra", "tooltipScale", 0.5, 2.0)
        scalePanel.alphaSlider = MakeScaleSlider("ARKANA_ScaleSliderAlpha", scalePanel, -300, "Spielbrett-Deckkraft", "boardAlpha", 0.2, 1.0)

        local privacyTitle = scalePanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        privacyTitle:SetPoint("TOP", scalePanel, "TOP", 0, -332)
        privacyTitle:SetText("Datenschutz · freiwillige Freigaben")

        scalePanel.spectatorToggle = CreateModernButton(scalePanel, "", 296, 30, function()
            ARKANA_Settings.spectatorSharing = not ARKANA_Settings.spectatorSharing
            scalePanel:RefreshPrivacy()
        end)
        scalePanel.spectatorToggle:SetPoint("TOP", scalePanel, "TOP", 0, -350)
        scalePanel.spectatorToggle:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Zuschauerfreigabe", 1, 0.82, 0)
            GameTooltip:AddLine("Gilt ab dem nächsten Duell. Das Spiel erscheint nur, wenn beide Spieler zugestimmt haben.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        scalePanel.spectatorToggle:HookScript("OnLeave", function() GameTooltip:Hide() end)

        scalePanel.rankToggle = CreateModernButton(scalePanel, "", 296, 30, function()
            ARKANA_Settings.rankSharing = not ARKANA_Settings.rankSharing
            scalePanel:RefreshPrivacy()
            if ARKANA_Settings.rankSharing and addon.RK_Announce then addon:RK_Announce() end
        end)
        scalePanel.rankToggle:SetPoint("TOP", scalePanel, "TOP", 0, -390)

        function scalePanel:RefreshPrivacy()
            self.spectatorToggle:SetText("Zuschauen erlauben: " .. (ARKANA_Settings.spectatorSharing and "An" or "Aus"))
            self.rankToggle:SetText("Rang öffentlich teilen: " .. (ARKANA_Settings.rankSharing and "An" or "Aus"))
        end

        local resetBtn = CreateModernButton(scalePanel, "Zurücksetzen", 135, 30, function() addon:ResetUIPositions() end)
        resetBtn:SetPoint("BOTTOMLEFT", 22, 15)
        local backBtn = CreateModernButton(scalePanel, "Zurück", 135, 30, function()
            scalePanel:Hide()
            addon:OpenMainMenu()
        end)
        backBtn:SetPoint("BOTTOMRIGHT", -22, 15)

        table.insert(UISpecialFrames, scalePanel:GetName())
    end
    scalePanel.windowSlider:Refresh()
    scalePanel.boardSlider:Refresh()
    scalePanel.tipSlider:Refresh()
    scalePanel.alphaSlider:Refresh()
    scalePanel:RefreshTheme()
    scalePanel:RefreshPrivacy()
    scalePanel:Show()
end

-- Von /arkana reset aufgerufen, damit die Regler die neuen Werte zeigen
function addon:RefreshScalePanel()
    if not scalePanel or not scalePanel:IsShown() then return end
    scalePanel.windowSlider:Refresh()
    scalePanel.boardSlider:Refresh()
    scalePanel.tipSlider:Refresh()
    scalePanel.alphaSlider:Refresh()
    scalePanel:RefreshTheme()
    scalePanel:RefreshPrivacy()
end

-- ── Minimap-Button: Klick = /arkana-Menü an/aus, Ziehen = am Minimap-Rand verschieben ─
-- Position (Winkel in Grad) persistent in ARKANA_Settings.minimapPos.
local function CreateMinimapButton()
    local b = CreateFrame("Button", "ARKANA_MinimapButton", Minimap)
    b:SetSize(32, 32)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local icon = b:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", -1, 1)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Rune_01")   -- Ruhestein
    icon:SetMask("Interface\\CharacterFrame\\TempPortraitAlphaMask")

    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    local function Reposition()
        local angle = math.rad((ARKANA_Settings and ARKANA_Settings.minimapPos) or 220)
        b:ClearAllPoints()
        b:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(angle), 80 * math.sin(angle))
    end
    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local scale = Minimap:GetEffectiveScale()
            local cx, cy = GetCursorPosition()
            ARKANA_Settings.minimapPos = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
            Reposition()
        end)
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

    -- Rechtsklick öffnet direkt die Einstellungen.
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            addon:ToggleScalePanel()
            return
        end
        if mainMenuFrame and mainMenuFrame:IsShown() then
            mainMenuFrame:Hide()
        else
            addon:OpenMainMenu()
        end
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Arkana", 1, 0.82, 0)
        GameTooltip:AddLine("Klick: Menü öffnen/schließen", 1, 1, 1)
        GameTooltip:AddLine("Rechtsklick: Einstellungen", 1, 1, 1)
        GameTooltip:AddLine("Ziehen: Button verschieben", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)

    Reposition()
end

-- Erst nach PLAYER_LOGIN erzeugen (SavedVariables mit minimapPos sind dann geladen)
local mmEv = CreateFrame("Frame")
mmEv:RegisterEvent("PLAYER_LOGIN")
mmEv:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    CreateMinimapButton()
end)

function addon:ShowStats()
    local g = ARKANA_Stats.global
    print(string.format("|cff00ff00[Arkana]|r Statistik — Siege: %d  Niederlagen: %d  Unentschieden: %d", g.w, g.l, g.d))
    for name, s in pairs(ARKANA_Stats.decks) do
        print(string.format("  %s: %dS / %dN / %dU", name, s.w, s.l, s.d))
    end
end
