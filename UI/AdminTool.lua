local addon = Arkana

local adminFrame
local BOOSTER_ORDER = { "C", "X", "L" }
local BOOSTER_NAME = { C = "Classic", X = "Custom", L = "Legendär" }

local COLOR = addon:UI_RegisterThemePalette({})

local function Solid(texture, color)
    addon:UI_BindThemeTexture(texture, color)
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

local function SelectorArrow(parent, text, onClick)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(28, 32)
    button:RegisterForClicks("LeftButtonUp")

    local label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("CENTER")
    label:SetText(text)
    label:SetTextColor(0.76, 0.70, 0.90, 1)
    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    addon:UI_BindThemeTexture(highlight, COLOR.purple, 0.16)

    button:SetScript("OnEnter", function() label:SetTextColor(1, 1, 1, 1) end)
    button:SetScript("OnLeave", function() label:SetTextColor(0.76, 0.70, 0.90, 1) end)
    button:SetScript("OnClick", onClick)
    return button
end

local function InnerPanel(parent, y, height)
    local panel = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    panel:SetPoint("TOPLEFT", 20, y)
    panel:SetPoint("TOPRIGHT", -20, y)
    panel:SetHeight(height)
    panel:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    panel:SetBackdropColor(unpack(COLOR.inner))
    panel:SetBackdropBorderColor(unpack(COLOR.purpleSoft))
    return panel
end

local function SelectedTarget()
    if not UnitExists("target") or not UnitIsPlayer("target") then return nil end
    local name, realm = UnitName("target")
    if not name or name == "" then return nil end
    if realm and realm ~= "" then return name .. "-" .. realm end
    return name
end

local function CreateAdminTool()
    local isRoot = addon.ADM_IsRootAdmin and addon:ADM_IsRootAdmin()
    local f = CreateFrame("Frame", "ARKANA_AdminTool", UIParent, "BackdropTemplate")
    f:SetSize(430, isRoot and 475 or 310)
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
    subtitle:SetText(isRoot and "Arkana-Spielleitung" or "Booster-Verteilung")

    local closeX = ModernButton(f, "×", 26, 24, function() f:Hide() end)
    closeX:SetPoint("TOPRIGHT", -9, -9)

    local topLine = f:CreateTexture(nil, "ARTWORK")
    topLine:SetHeight(2)
    topLine:SetPoint("TOPLEFT", 20, -63)
    topLine:SetPoint("TOPRIGHT", -20, -63)
    Solid(topLine, COLOR.purple)

    local targetPanel = InnerPanel(f, -72, 65)
    local targetTitle = targetPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    targetTitle:SetPoint("TOP", 0, -8)
    targetTitle:SetText("Ausgewähltes Ziel")
    f.targetText = targetPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.targetText:SetPoint("TOP", targetTitle, "BOTTOM", 0, -8)

    if isRoot then
        local basePanel = InnerPanel(f, -147, 72)
        local baseTitle = basePanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        baseTitle:SetPoint("TOPLEFT", 12, -10)
        baseTitle:SetText("Basispaket")
        local baseInfo = basePanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        baseInfo:SetPoint("TOPLEFT", baseTitle, "BOTTOMLEFT", 0, -5)
        baseInfo:SetPoint("RIGHT", basePanel, "RIGHT", -180, 0)
        baseInfo:SetJustifyH("LEFT")
        baseInfo:SetText("Nur kostenlose Karten · je 2x")
        local baseButton = ModernButton(basePanel, "Paket senden", 158, 36, function()
            local target = SelectedTarget()
            if not target then f:SetStatus("Bitte zuerst einen Spieler als Ziel auswählen.", false); return end
            local ok, message = addon:ADM_SendBasePackage(target)
            f:SetStatus(message, ok)
        end)
        baseButton:SetPoint("RIGHT", -10, 0)
    end

    local boosterY = isRoot and -229 or -147
    local boosterPanel = InnerPanel(f, boosterY, 82)
    f.boosterType = "C"
    local boosterHeading = boosterPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    boosterHeading:SetPoint("TOPLEFT", 12, -9)
    boosterHeading:SetText("Booster-Typ")
    local boosterInfo = boosterPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    boosterInfo:SetPoint("TOPRIGHT", -12, -11)
    boosterInfo:SetJustifyH("RIGHT")
    boosterInfo:SetText(isRoot and "1–9 · Empfängerlimit 9" or
        "1–3 · Verteilerlimit 3")

    local boosterSelector = CreateFrame("Frame", nil, boosterPanel, "BackdropTemplate")
    boosterSelector:SetSize(142, 34)
    boosterSelector:SetPoint("BOTTOMLEFT", 10, 10)
    boosterSelector:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    boosterSelector:SetBackdropColor(unpack(COLOR.button))
    boosterSelector:SetBackdropBorderColor(unpack(COLOR.purpleSoft))
    f.boosterSelector = boosterSelector

    local boosterTitle = boosterSelector:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    boosterTitle:SetJustifyH("CENTER")
    f.boosterTitle = boosterTitle

    if isRoot then
        local previousBooster = SelectorArrow(boosterSelector, "<", function()
            f:CycleBoosterType(-1)
        end)
        previousBooster:SetPoint("LEFT", 1, 0)
        f.previousBooster = previousBooster

        local nextBooster = SelectorArrow(boosterSelector, ">", function()
            f:CycleBoosterType(1)
        end)
        nextBooster:SetPoint("RIGHT", -1, 0)
        f.nextBooster = nextBooster

        local leftDivider = boosterSelector:CreateTexture(nil, "ARTWORK")
        leftDivider:SetSize(1, 22)
        leftDivider:SetPoint("LEFT", previousBooster, "RIGHT", 0, 0)
        Solid(leftDivider, COLOR.purpleSoft)
        local rightDivider = boosterSelector:CreateTexture(nil, "ARTWORK")
        rightDivider:SetSize(1, 22)
        rightDivider:SetPoint("RIGHT", nextBooster, "LEFT", 0, 0)
        Solid(rightDivider, COLOR.purpleSoft)

        boosterTitle:SetPoint("LEFT", previousBooster, "RIGHT", 2, 0)
        boosterTitle:SetPoint("RIGHT", nextBooster, "LEFT", -2, 0)
    else
        boosterTitle:SetPoint("LEFT", 8, 0)
        boosterTitle:SetPoint("RIGHT", -8, 0)
    end

    f.amountBox = CreateFrame("EditBox", nil, boosterPanel, "BackdropTemplate")
    f.amountBox:SetSize(50, 34)
    f.amountBox:SetPoint("LEFT", boosterSelector, "RIGHT", 10, 0)
    f.amountBox:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    f.amountBox:SetBackdropColor(0.025, 0.020, 0.040, 1)
    f.amountBox:SetBackdropBorderColor(unpack(COLOR.purpleSoft))
    f.amountBox:SetFontObject("GameFontHighlight")
    f.amountBox:SetJustifyH("CENTER")
    f.amountBox:SetAutoFocus(false)
    f.amountBox:SetNumeric(true)
    f.amountBox:SetMaxLetters(1)
    f.amountBox:SetText(isRoot and "9" or "3")
    f.amountBox:SetScript("OnEscapePressed", f.amountBox.ClearFocus)
    f.amountBox:SetScript("OnEnterPressed", f.amountBox.ClearFocus)
    f.amountBox:SetScript("OnEditFocusGained", function(self)
        self:SetBackdropBorderColor(unpack(COLOR.purple))
        self:HighlightText()
    end)
    f.amountBox:SetScript("OnEditFocusLost", function(self)
        self:SetBackdropBorderColor(unpack(COLOR.purpleSoft))
    end)

    local boosterButton = ModernButton(boosterPanel, "Booster senden", 158, 36, function()
        local target = SelectedTarget()
        if not target then f:SetStatus("Bitte zuerst einen Spieler als Ziel auswählen.", false); return end
        local ok, message = addon:ADM_SendBoosters(target, f.amountBox:GetText(), f.boosterType)
        f:SetStatus(message, ok)
    end)
    boosterButton:SetPoint("BOTTOMRIGHT", -10, 9)

    if isRoot then
        local distributorPanel = InnerPanel(f, -321, 72)
        local distributorTitle = distributorPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        distributorTitle:SetPoint("TOPLEFT", 12, -10)
        distributorTitle:SetText("Booster-Verteiler")
        f.distributorInfo = distributorPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        f.distributorInfo:SetPoint("TOPLEFT", distributorTitle, "BOTTOMLEFT", 0, -5)
        f.distributorInfo:SetPoint("RIGHT", distributorPanel, "RIGHT", -195, 0)
        f.distributorInfo:SetJustifyH("LEFT")
        local removeButton = ModernButton(distributorPanel, "Entfernen", 82, 36, function()
            local target = SelectedTarget()
            if not target then f:SetStatus("Bitte einen Spieler auswählen.", false); return end
            local ok, message = addon:ADM_SendDistributorRemoval(target)
            f:SetStatus(message, ok)
        end)
        removeButton:SetPoint("RIGHT", -10, 0)
        local distributorButton = ModernButton(distributorPanel, "Hinzufügen", 82, 36, function()
            local target = SelectedTarget()
            if not target then f:SetStatus("Bitte einen Spieler auswählen.", false); return end
            local ok, message = addon:ADM_SendDistributorAccess(target)
            f:SetStatus(message, ok)
        end)
        distributorButton:SetPoint("RIGHT", removeButton, "LEFT", -6, 0)
    end

    f.status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    local statusY = isRoot and -405 or -242
    f.status:SetPoint("TOPLEFT", 24, statusY)
    f.status:SetPoint("TOPRIGHT", -24, statusY)
    f.status:SetJustifyH("CENTER")
    f.status:SetText("Ziel muss online sein.")
    f.status:SetTextColor(0.62, 0.60, 0.68, 1)

    local back = ModernButton(f, "Zurück", 168, 30, function()
        f:Hide()
        addon:OpenMainMenu()
    end)
    back:SetPoint("BOTTOM", 0, 14)

    function f:SetStatus(message, ok)
        self.status:SetText(message or "")
        if ok == nil then
            self.status:SetTextColor(0.62, 0.60, 0.68, 1)
        elseif ok then
            self.status:SetTextColor(0.35, 0.95, 0.55, 1)
        else
            self.status:SetTextColor(1.00, 0.35, 0.40, 1)
        end
    end

    function f:CycleBoosterType(direction)
        if not isRoot then
            self.boosterType = "C"
            self:RefreshBoosterType()
            return
        end
        local index = 1
        for i, key in ipairs(BOOSTER_ORDER) do
            if key == self.boosterType then index = i; break end
        end
        index = ((index - 1 + direction) % #BOOSTER_ORDER) + 1
        self.boosterType = BOOSTER_ORDER[index]
        self:RefreshBoosterType()
    end

    function f:RefreshBoosterType()
        if not isRoot then self.boosterType = "C" end
        self.boosterTitle:SetText(BOOSTER_NAME[self.boosterType])
    end

    function f:RefreshTarget()
        local target = SelectedTarget()
        self.targetText:SetText(target or "Kein Spieler ausgewählt")
        self.targetText:SetTextColor(target and 0.92 or 0.65, target and 0.82 or 0.62,
            target and 1.00 or 0.68, 1)
    end

    function f:RefreshDistributorSummary()
        if not self.distributorInfo then return end
        local count = addon.ADM_DistributorCount and addon:ADM_DistributorCount() or 0
        self.distributorInfo:SetText("Aktiv: " .. count .. " · nur Booster")
    end

    f:RegisterEvent("PLAYER_TARGET_CHANGED")
    f:SetScript("OnEvent", function(self) self:RefreshTarget() end)
    f:SetScript("OnShow", function(self)
        self:RefreshTarget()
        self:RefreshBoosterType()
        self:RefreshDistributorSummary()
        self:SetStatus("Ziel muss online sein.", nil)
    end)

    table.insert(UISpecialFrames, f:GetName())
    return f
end

function addon:ADM_UpdateStatus(message, ok)
    if adminFrame and adminFrame:IsShown() then adminFrame:SetStatus(message, ok) end
end

function addon:ADM_UpdateDistributorSummary()
    if adminFrame and adminFrame.RefreshDistributorSummary then
        adminFrame:RefreshDistributorSummary()
    end
end

function addon:ADM_CloseIfUnauthorized()
    if adminFrame and adminFrame:IsShown() and
       (not addon.ADM_CanUse or not addon:ADM_CanUse()) then
        adminFrame:Hide()
    end
end

function addon:OpenAdminTool()
    if not addon.ADM_CanUse or not addon:ADM_CanUse() then
        print("|cffff4040[Arkana]|r Keine Berechtigung zur Booster-Verteilung.")
        return
    end
    if not adminFrame then adminFrame = CreateAdminTool() end
    adminFrame:Show()
end
