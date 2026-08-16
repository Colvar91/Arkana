local addon = Arkana

local CLASS_DE = {
    DRUID="Druide", HUNTER="Jäger", MAGE="Magier", PALADIN="Paladin",
    PRIEST="Priester", ROGUE="Schurke", SHAMAN="Schamane", WARLOCK="Hexenmeister",
    WARRIOR="Krieger", CLASSLESS="Test",
}
local function ClassDE(c) return CLASS_DE[c or ""] or c or "?" end

local LOBBY_UI = addon:UI_RegisterThemePalette({})

local function CreateLobbyButton(parent, text, width, height, onClick)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(width, height)
    local border = button:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints(); addon:UI_BindThemeTexture(border, LOBBY_UI.purpleSoft)
    local bg = button:CreateTexture(nil, "BACKGROUND", nil, 1)
    bg:SetPoint("TOPLEFT", 1, -1); bg:SetPoint("BOTTOMRIGHT", -1, 1)
    addon:UI_BindThemeTexture(bg, LOBBY_UI.button)
    local label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER"); label:SetText(text); label:SetTextColor(0.92, 0.89, 1, 1)
    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetPoint("TOPLEFT", 1, -1); highlight:SetPoint("BOTTOMRIGHT", -1, 1)
    addon:UI_BindThemeTexture(highlight, LOBBY_UI.purple, 0.18)
    local function RefreshEnabled(self)
        local enabled = self:IsEnabled()
        self:SetAlpha(enabled and 1 or 0.45)
        border:SetColorTexture(unpack(LOBBY_UI.purpleSoft))
        label:SetTextColor(enabled and 0.92 or 0.5, enabled and 0.89 or 0.48, enabled and 1 or 0.55, 1)
    end
    button:SetScript("OnEnable", RefreshEnabled)
    button:SetScript("OnDisable", RefreshEnabled)
    button:SetScript("OnEnter", function(self)
        if not self:IsEnabled() then return end
        border:SetColorTexture(unpack(LOBBY_UI.purple))
        label:SetTextColor(1, 1, 1, 1)
    end)
    button:SetScript("OnLeave", RefreshEnabled)
    button:SetScript("OnClick", onClick)
    return button
end

local function EnableLobbyScrolling(scroll)
    local function HideTemplateBar()
        if scroll.ScrollBar then scroll.ScrollBar:Hide() end
        for _, child in ipairs({ scroll:GetChildren() }) do
            if child.GetObjectType and child:GetObjectType() == "Slider" then child:Hide() end
        end
    end
    HideTemplateBar()
    C_Timer.After(0, HideTemplateBar)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maximum = self:GetVerticalScrollRange() or 0
        self:SetVerticalScroll(math.max(0, math.min(maximum, self:GetVerticalScroll() - delta * 62)))
    end)
end

local ROW_H = 62
local lobbyFrame
local refreshTicker

-- Zeile im Scroll-Inhalt bei Bedarf erzeugen / wiederverwenden
local function GetRow(f, i)
    local row = f.rowPool[i]
    if row then return row end
    row = CreateFrame("Frame", nil, f.content, "BackdropTemplate")
    row:SetSize(496, 56)
    row:SetPoint("TOPLEFT", 4, -(i - 1) * ROW_H - 3)
    row:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    row:SetBackdropColor(unpack(LOBBY_UI.row))
    row:SetBackdropBorderColor(unpack(LOBBY_UI.purpleSoft))

    row.title = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.title:SetPoint("TOPLEFT", 12, -9)
    row.title:SetPoint("RIGHT", row, "RIGHT", -112, 0)
    row.title:SetJustifyH("LEFT")
    row.title:SetWordWrap(false)

    row.meta = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.meta:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -6)
    row.meta:SetPoint("RIGHT", row, "RIGHT", -112, 0)
    row.meta:SetJustifyH("LEFT")
    row.meta:SetWordWrap(false)

    local watch = CreateLobbyButton(row, "Zuschauen", 96, 30)
    watch:SetPoint("RIGHT", -8, 0)
    row.watchBtn = watch
    f.rowPool[i] = row
    return row
end

local function BuildLobby()
    local f = CreateFrame("Frame", "ARKANA_SpectatorLobby", UIParent, "BackdropTemplate")
    f:SetSize(540, 420)
    f:SetPoint("CENTER")
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    f:SetBackdropColor(unpack(LOBBY_UI.panel))
    f:SetBackdropBorderColor(unpack(LOBBY_UI.panelBorder))
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    if addon.UI_RegisterScalableFrame then addon:UI_RegisterScalableFrame(f) end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 20, -12)
    title:SetText("Arkana")
    title:SetTextColor(unpack(LOBBY_UI.title))
    local subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    subtitle:SetPoint("LEFT", title, "RIGHT", 8, 0)
    subtitle:SetText("Aktive Spiele")

    local closeX = CreateLobbyButton(f, "×", 28, 24, function() f:Hide() end)
    closeX:SetPoint("TOPRIGHT", -10, -9)

    local topLine = f:CreateTexture(nil, "ARTWORK")
    topLine:SetHeight(2); topLine:SetPoint("TOPLEFT", 18, -46); topLine:SetPoint("TOPRIGHT", -18, -46)
    addon:UI_BindThemeTexture(topLine, LOBBY_UI.purple)

    -- Hinweis (auf Fensterbreite begrenzt + Zeilenumbruch, damit nichts herausragt)
    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 20, -57)
    hint:SetPoint("TOPRIGHT", -20, -57)
    hint:SetJustifyH("LEFT")
    hint:SetWordWrap(true)
    hint:SetText("Laufende Duelle · automatische Aktualisierung alle 5 Sekunden")

    -- Scrollbarer Listenbereich (skaliert auf beliebig viele Matches)
    local sf = CreateFrame("ScrollFrame", "ARKANA_LobbyScroll", f, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 16, -78)
    sf:SetPoint("BOTTOMRIGHT", -16, 56)
    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(504, 10)
    sf:SetScrollChild(content)
    EnableLobbyScrolling(sf)
    f.scrollFrame = sf
    f.content = content
    f.rowPool = {}   -- Zeilen werden bei Bedarf erzeugt und wiederverwendet

    -- "Keine Spiele"-Text (über dem Scrollbereich)
    local empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    empty:SetPoint("TOP", sf, "TOP", 0, -20)
    empty:SetText("Keine laufenden Spiele gefunden.")
    f.emptyText = empty

    -- Schließen
    local close = CreateLobbyButton(f, "Schließen", 150, 30, function() f:Hide() end)
    close:SetPoint("BOTTOM", 0, 14)

    -- Auto-Suche: solange das Fenster offen ist, alle 5s die Liste neu aufbauen/suchen
    f:SetScript("OnShow", function()
        if addon.Spec_EnsureChannel then addon:Spec_EnsureChannel() end
        addon:Spec_RefreshLobbyWindow()
        if refreshTicker then refreshTicker:Cancel() end
        refreshTicker = C_Timer.NewTicker(5, function() addon:Spec_RefreshLobbyWindow() end)
    end)
    f:SetScript("OnHide", function()
        if refreshTicker then refreshTicker:Cancel(); refreshTicker = nil end
    end)

    f:Hide()  -- versteckt starten, damit Spec_ShowLobby():Show() das OnShow (→ Refresh-Ticker) auslöst
    table.insert(UISpecialFrames, f:GetName())
    return f
end

function addon:Spec_RefreshLobbyWindow()
    if not lobbyFrame or not lobbyFrame:IsShown() then return end
    local list = (addon.Spec_GetLobby and addon:Spec_GetLobby()) or {}
    lobbyFrame.emptyText:SetShown(#list == 0)
    for i, g in ipairs(list) do
        local row = GetRow(lobbyFrame, i)
        row.title:SetText(string.format("|cffffd700%s|r  |cff8b7aa8%s|r  |cffffffffgegen|r  |cffffd700%s|r  |cff8b7aa8%s|r",
            g.hostName or "?", ClassDE(g.hostClass), g.oppName or "?", ClassDE(g.oppClass)))
        row.meta:SetText(string.format("Zug %d  ·  %s%s", g.turnNum or 0,
            g.ranked and "|cffffd700gewertet|r" or "|cffaaaaaaungewertet|r",
            g.versionOk and "" or ("  · |cffff4444andere Version (" .. tostring(g.build or "unbekannt") .. ")|r")))
        row.watchBtn:SetEnabled(g.versionOk and true or false)
        row.watchBtn:SetScript("OnClick", function()
            lobbyFrame:Hide()
            if addon.Spec_Watch then addon:Spec_Watch(g.sessionId) end
        end)
        row:Show()
    end
    -- überzählige Zeilen ausblenden
    for i = #list + 1, #lobbyFrame.rowPool do lobbyFrame.rowPool[i]:Hide() end
    -- Scroll-Inhaltshöhe an die Anzahl anpassen → Scrollbar erscheint automatisch bei Überlauf
    lobbyFrame.content:SetHeight(math.max(#list * ROW_H, 10))
end

-- Von /arkana spectate (Main.lua) aufgerufen
function addon:Spec_ShowLobby()
    if not lobbyFrame then lobbyFrame = BuildLobby() end
    lobbyFrame:Show()          -- löst OnShow (Refresh-Ticker) aus, falls vorher versteckt
    addon:Spec_RefreshLobbyWindow()  -- sofort befüllen (auch falls Fenster bereits offen war)
end
