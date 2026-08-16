local addon = Arkana

local SUPPORTED_TC = { NONE = true, DAMAGED_ENEMY_MINION = true }

-- Bewusst gesperrte Karten (Effekt absichtlich nicht implementiert)
local BLOCKED_CARDS = {
    EX1_560 = true,   -- Nozdormu: 15s-Zug-Timer bewusst rausgelassen
}
local CLASSES = { "DRUID","HUNTER","MAGE","PALADIN","PRIEST","ROGUE","SHAMAN","WARLOCK","WARRIOR" }
local CLASS_DE = {
    DRUID="Druide", HUNTER="Jäger", MAGE="Magier", PALADIN="Paladin",
    PRIEST="Priester", ROGUE="Schurke", SHAMAN="Schamane", WARLOCK="Hexenmeister", WARRIOR="Krieger",
    NEUTRAL="Neutral", CLASSLESS="Test [Alle]",
}
local ROW_H = 18
-- Karten-IDs, die seit dem letzten Öffnen der Sammlung neu dazukamen (gelber Rahmen)
local newCardMarks = {}
local RARITY_COLOR = {
    FREE      = "|cffbbbbbb",
    COMMON    = "|cffffffff",
    RARE      = "|cff0070dd",
    EPIC      = "|cffa335ee",
    LEGENDARY = "|cffff8000",
}
local RARITY_LABEL = {
    FREE = "Free", COMMON = "Common", RARE = "Rare", EPIC = "Epic", LEGENDARY = "Legendary",
}

-- Schlüsselwort-Erklärungen für den Karten-Tooltip. Keyed auf die tag.type-Werte
-- aus ClassicCardData; reine Effekt-Tags (DEAL_DAMAGE etc.) stehen bewusst NICHT
-- drin, damit nur echte Schlüsselwort-Fähigkeiten erklärt werden.
local KEYWORD_DESC = {
    TAUNT        = { "Spott",             "Feinde müssen zuerst diesen Diener angreifen." },
    CHARGE       = { "Ansturm",           "Kann sofort angreifen." },
    STEALTH      = { "Verstohlenheit",    "Kann nicht angegriffen oder als Ziel gewählt werden, bis er angreift." },
    DIVINE_SHIELD= { "Göttlicher Schild", "Verhindert den ersten erlittenen Schaden." },
    WINDFURY     = { "Windzorn",          "Kann pro Runde zweimal angreifen." },
    DEATHRATTLE  = { "Todesröcheln",      "Löst einen Effekt aus, wenn der Diener stirbt." },
    BATTLECRY    = { "Kampfschrei",       "Löst einen Effekt aus, wenn der Diener gespielt wird." },
    OVERLOAD     = { "Überladung",        "Sperrt in der nächsten Runde Mana." },
    FREEZE       = { "Einfrieren",        "Eingefrorene Charaktere setzen ihren nächsten Angriff aus." },
    SILENCE      = { "Zum Schweigen bringen", "Entfernt alle Texte und Effekte des Ziels." },
    SPELL_DAMAGE = { "Zauberschaden",     "Erhöht den Schaden deiner Zauber." },
    SECRET       = { "Geheimnis",         "Verborgen, bis eine bestimmte Bedingung es auslöst." },
}

local currentClass   = "CLASSLESS"
local currentDeckIdx = nil
local editingCards   = {}
local editingName    = "Neues Deck"
local classFilter    = "ALL"
local gridMode       = false
local deckGridMode   = false

local dbFrame

local EDITOR_COLOR = addon:UI_RegisterThemePalette({})

local function CreateEditorButton(parent, labelText, width, height, onClick, variant)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(width, height)
    button:RegisterForClicks("LeftButtonUp")

    local border = button:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints()
    addon:UI_BindThemeTexture(border, EDITOR_COLOR.purpleSoft)

    local background = button:CreateTexture(nil, "BACKGROUND", nil, 1)
    background:SetPoint("TOPLEFT", 1, -1)
    background:SetPoint("BOTTOMRIGHT", -1, 1)
    addon:UI_BindThemeTexture(background, EDITOR_COLOR.button)

    local label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER")
    label:SetText(labelText)
    label:SetTextColor(0.92, 0.89, 1, 1)

    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetPoint("TOPLEFT", 1, -1)
    highlight:SetPoint("BOTTOMRIGHT", -1, 1)
    addon:UI_BindThemeTexture(highlight, EDITOR_COLOR.purple, 0.18)

    function button:SetText(text) label:SetText(text) end
    local function RefreshEnabled(self)
        local enabled = self:IsEnabled()
        background:SetColorTexture(unpack(EDITOR_COLOR.button))
        border:SetColorTexture(unpack(EDITOR_COLOR.purpleSoft))
        label:SetTextColor(enabled and 0.92 or 0.45, enabled and 0.89 or 0.43, enabled and 1 or 0.50, 1)
        self:SetAlpha(enabled and 1 or 0.55)
    end
    button:SetScript("OnEnable", RefreshEnabled)
    button:SetScript("OnDisable", RefreshEnabled)
    button:SetScript("OnEnter", function(self)
        if not self:IsEnabled() then return end
        border:SetColorTexture(unpack(EDITOR_COLOR.purple))
        label:SetTextColor(1, 1, 1, 1)
    end)
    button:SetScript("OnLeave", function(self) RefreshEnabled(self) end)
    if onClick then button:SetScript("OnClick", onClick) end
    return button
end

local function CreateEditorEditBox(parent, width, height)
    local box = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    if width and height then box:SetSize(width, height) end
    box:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    box:SetBackdropColor(0.035, 0.030, 0.055, 1)
    box:SetBackdropBorderColor(unpack(EDITOR_COLOR.purpleSoft))
    box:SetFontObject(GameFontHighlightSmall)
    box:SetTextColor(0.96, 0.94, 1, 1)
    box:SetTextInsets(8, 8, 0, 0)
    box:SetAutoFocus(false)
    box:SetScript("OnEditFocusGained", function(self)
        self:SetBackdropBorderColor(unpack(EDITOR_COLOR.purple))
    end)
    box:SetScript("OnEditFocusLost", function(self)
        self:SetBackdropBorderColor(unpack(EDITOR_COLOR.purpleSoft))
    end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return box
end

-- ── helpers ───────────────────────────────────────────────────────────────────

local function IsSupported(card)
    if BLOCKED_CARDS[card.id] then return false end
    if currentClass == "CLASSLESS" then return true end
    if not SUPPORTED_TC[card.targetCondition or "NONE"] then return false end
    return true
end

-- Regel-Limit für die vollständige Sammlung: Legendär 1, sonst 2.
local function MaxCopies(card)
    local rule = card.rarity == "LEGENDARY" and 1 or 2
    if addon.COL_Count then rule = math.min(rule, addon:COL_Count(card.id)) end
    return rule
end

local function CountInDeck(cardId)
    local n = 0
    for _, id in ipairs(editingCards) do if id == cardId then n = n + 1 end end
    return n
end

-- Angriff/Leben für die Textlisten (Kartenübersicht + Deckliste). Gelb, damit es
-- sich von der Anzahl-Angabe am Zeilenende abhebt — die sieht sonst genauso aus.
-- Zauber haben keine Werte und bekommen deshalb nichts.
local function StatStr(card)
    if card.type ~= "MINION" and card.type ~= "WEAPON" then return "" end
    local right = (card.type == "WEAPON") and (card.durability or 0) or (card.health or 0)
    return string.format(" |cffffcc00%d/%d|r", card.attack or 0, right)
end

local function GetAvailableCards()
    local list = {}
    local searchText = ""
    if dbFrame and dbFrame.searchBox then
        searchText = dbFrame.searchBox:GetText():lower()
    end
    for _, card in pairs(ARKANA_CardData) do
        if card.collectible then
            local cardClass = card.class or "NEUTRAL"
            local classMatch = false
            if classFilter == "ALL" or classFilter == "CLASSLESS" then
                classMatch = true
            elseif classFilter == "NEUTRAL" then
                classMatch = (cardClass == "NEUTRAL")
            else
                classMatch = (cardClass == classFilter or cardClass == "NEUTRAL")
            end
            -- Filter "Nur Wunschliste": zeigt genau die vorgemerkten Karten
            if classMatch and ARKANA_Settings.dbWishOnly and addon.WL_Has and not addon:WL_Has(card.id) then
                classMatch = false
            end
            -- Suche trifft auch frühere Kartennamen (altNames), z.B. "Sukkubus"
            if classMatch and ARKANA_CardMatchesName(card, searchText) then
                list[#list + 1] = card
            end
        end
    end
    table.sort(list, function(a, b)
        local ac = a.class or "NEUTRAL"
        local bc = b.class or "NEUTRAL"
        local aNeutral = ac == "NEUTRAL"
        local bNeutral = bc == "NEUTRAL"
        if aNeutral ~= bNeutral then return bNeutral end
        if ac ~= bc then return ac < bc end
        if (a.cost or 0) ~= (b.cost or 0) then return (a.cost or 0) < (b.cost or 0) end
        return (a.name or "") < (b.name or "")
    end)
    if dbFrame and dbFrame.colCountLbl then
        dbFrame.colCountLbl:SetText(#list .. " Karten")
    end
    return list
end

-- Von Kosmetik-/Kompatibilitätsabläufen gerufen: offenen Deck-Builder auffrischen.
function addon:DB_RefreshIfShown()
    if dbFrame and dbFrame:IsShown() and dbFrame.Refresh then dbFrame:Refresh() end
end

local function GetDeckCardsSorted()
    local counts, seen, list = {}, {}, {}
    for _, id in ipairs(editingCards) do counts[id] = (counts[id] or 0) + 1 end
    for _, id in ipairs(editingCards) do
        if not seen[id] then
            seen[id] = true
            list[#list + 1] = { card = ARKANA_CardData[id], count = counts[id] }
        end
    end
    table.sort(list, function(a, b)
        if a.card.cost ~= b.card.cost then return a.card.cost < b.card.cost end
        return a.card.name < b.card.name
    end)
    return list
end

-- ── tooltip ───────────────────────────────────────────────────────────────────

local tipFrame

local function ShowTip(card, anchor, artOverride)
    if not tipFrame then
        tipFrame = CreateFrame("Frame", nil, UIParent)
        tipFrame:SetSize(410, 308)
        tipFrame:SetFrameStrata("TOOLTIP")
        tipFrame:SetScale(ARKANA_Settings and (ARKANA_Settings.boardScale or 1.0) * (ARKANA_Settings.tooltipScale or 1.0) or 1.0)
        addon.deckBuilderTooltip = tipFrame
        local bg = tipFrame:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(); bg:SetColorTexture(0, 0, 0, 0.9)
        local border = tipFrame:CreateTexture(nil, "BORDER")
        border:SetPoint("TOPLEFT", -1, 1); border:SetPoint("BOTTOMRIGHT", 1, -1)
        border:SetColorTexture(0.35, 0.35, 0.5, 1)
        local art = tipFrame:CreateTexture(nil, "ARTWORK")
        art:SetPoint("TOPLEFT", -25, 55); art:SetSize(246, 362.4)
        tipFrame.art = art
        tipFrame.lbl = tipFrame:CreateFontString(nil, "OVERLAY")
        tipFrame.lbl:SetFont("Fonts\\FRIZQT__.TTF", 12, "")
        tipFrame.lbl:SetPoint("TOPLEFT", art, "TOPRIGHT", -17, -65)
        tipFrame.lbl:SetWidth(201); tipFrame.lbl:SetJustifyH("LEFT"); tipFrame.lbl:SetWordWrap(true)
    end
    tipFrame.art:SetTexture(artOverride
        or (addon.CS_ArtFor and addon:CS_ArtFor(card.id, true))
        or ("Interface\\AddOns\\Arkana\\Textures\\Cards\\" .. card.id .. ".tga"))
    tipFrame.art:SetTexCoord(0, 1, 0, 0.758)
    local typeStr = card.type == "MINION" and "Diener" or card.type == "SPELL" and "Zauber" or "Waffe"
    local statsStr = ""
    if card.type == "MINION" then
        statsStr = string.format("  %d/%d", card.attack or 0, card.health or 0)
    elseif card.type == "WEAPON" then
        statsStr = string.format("  %d/%d", card.attack or 0, card.health or 0)
    end
    local rc = ({ FREE="|cffbbbbbb",COMMON="|cffffffff",RARE="|cff0070dd",EPIC="|cffa335ee",LEGENDARY="|cffff8000" })[card.rarity or "COMMON"] or ""
    local lines = {
        string.format("|cffffff00%s|r", card.name or "?"),
        string.format("[%s]%s  Mana: %d", typeStr, statsStr, card.cost or 0),
        string.format("Klasse: %s  (%s%s|r)", CLASS_DE[card.class] or card.class or "Neutral",
            rc, RARITY_LABEL[card.rarity] or card.rarity or ""),
    }
    if card.text and card.text ~= "" then lines[#lines+1] = ""; lines[#lines+1] = card.text end
    -- Schlüsselwort-Erklärungen (Ansturm/Spott/Verstohlenheit …) aus den Karten-Tags
    if card.tags then
        local seen = {}
        for _, tag in ipairs(card.tags) do
            local kw = KEYWORD_DESC[tag.type]
            if kw and not seen[tag.type] then
                seen[tag.type] = true
                lines[#lines+1] = string.format("|cff33ccff%s:|r %s", kw[1], kw[2])
            end
        end
    end
    tipFrame.lbl:SetText(table.concat(lines, "\n"))
    local h = math.max(248, tipFrame.lbl:GetStringHeight() + 16)
    tipFrame:SetHeight(h)
    tipFrame:ClearAllPoints()
    local x = anchor:GetCenter()
    local screenW = GetScreenWidth()
    if x and screenW and x > screenW / 2 then
        tipFrame:SetPoint("RIGHT", anchor, "LEFT", -4, 0)
    else
        tipFrame:SetPoint("LEFT", anchor, "RIGHT", 4, 0)
    end
    tipFrame:Show()
end

local function HideTip() if tipFrame then tipFrame:Hide() end end

-- Karten-Tooltip (großes Art + Text) für andere Module.
-- artOverride: abweichende Textur (z.B. Skin-Art statt Original)
function addon:DB_ShowCardTip(card, anchor, artOverride) ShowTip(card, anchor, artOverride) end
function addon:DB_HideCardTip() HideTip() end

-- ── dropdown ──────────────────────────────────────────────────────────────────

local openDD = nil
local ddClickout

local function CloseDropdown()
    if openDD then openDD.popup:Hide(); openDD = nil end
    if ddClickout then ddClickout:Hide() end
end

local function MakeDropdown(parent, w)
    if not ddClickout then
        ddClickout = CreateFrame("Frame", nil, UIParent)
        ddClickout:SetAllPoints()
        ddClickout:SetFrameStrata("FULLSCREEN_DIALOG")
        ddClickout:SetFrameLevel(190)
        ddClickout:EnableMouse(true)
        ddClickout:SetScript("OnMouseDown", CloseDropdown)
        ddClickout:Hide()
    end

    local ITEM_H = 24
    local dd = { itemCount = 0, rowFrames = {} }

    local ddFrame = CreateFrame("Button", nil, parent, "BackdropTemplate")
    ddFrame:SetSize(w, 22)
    ddFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    ddFrame:SetBackdropColor(unpack(EDITOR_COLOR.button))
    ddFrame:SetBackdropBorderColor(unpack(EDITOR_COLOR.purpleSoft))
    dd.btn = ddFrame

    local text = ddFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", ddFrame, "LEFT", 9, 0)
    text:SetPoint("RIGHT", ddFrame, "RIGHT", -25, 0)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    text:SetTextColor(0.94, 0.91, 1, 1)

    local arrow = ddFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    arrow:SetPoint("RIGHT", ddFrame, "RIGHT", -8, 1)
    arrow:SetText("v")
    arrow:SetTextColor(0.78, 0.60, 1, 1)

    ddFrame:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(unpack(EDITOR_COLOR.purple))
    end)
    ddFrame:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(unpack(EDITOR_COLOR.purpleSoft))
    end)

    local popup = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    popup:SetSize(w, ITEM_H)
    popup:SetFrameStrata("FULLSCREEN_DIALOG")
    popup:SetFrameLevel(200)
    popup:SetClampedToScreen(true)
    popup:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    popup:SetBackdropColor(0.035, 0.028, 0.055, 0.99)
    popup:SetBackdropBorderColor(unpack(EDITOR_COLOR.purple))
    popup:Hide()
    dd.popup = popup

    local cont = CreateFrame("Frame", nil, popup)
    cont:SetPoint("TOPLEFT", 2, -2)
    cont:SetPoint("BOTTOMRIGHT", -2, 2)
    dd.cont = cont

    ddFrame:SetScript("OnClick", function()
        if openDD == dd then
            CloseDropdown()
        else
            CloseDropdown()
            openDD = dd
            popup:ClearAllPoints()
            popup:SetPoint("TOPLEFT", ddFrame, "BOTTOMLEFT", 0, -3)
            ddClickout:Show()
            popup:Show()
        end
    end)

    function dd:Populate(items)
        self.itemCount = #items
        for i = #self.rowFrames + 1, #items do
            local r = CreateFrame("Button", nil, cont)
            r:SetHeight(ITEM_H)
            r:SetPoint("TOPLEFT", cont, "TOPLEFT", 0, -(i-1)*ITEM_H)
            r:SetPoint("TOPRIGHT", cont, "TOPRIGHT", 0, -(i-1)*ITEM_H)
            local hl = r:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints(); addon:UI_BindThemeTexture(hl, EDITOR_COLOR.purple, 0.24)
            r.lbl = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            r.lbl:SetPoint("LEFT", r, "LEFT", 9, 0)
            r.lbl:SetPoint("RIGHT", r, "RIGHT", -8, 0)
            r.lbl:SetJustifyH("LEFT")
            r.lbl:SetWordWrap(false)
            self.rowFrames[i] = r
        end
        for i = #items + 1, #self.rowFrames do self.rowFrames[i]:Hide() end
        for i, item in ipairs(items) do
            local r = self.rowFrames[i]
            r.lbl:SetText(item.text)
            r:SetScript("OnClick", function()
                CloseDropdown()
                if item.onSelect then item.onSelect() end
            end)
            if item.tooltip then
                r:SetScript("OnEnter", function(s)
                    GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
                    GameTooltip:SetText(item.tooltip, 1, 1, 1, nil, true)
                    GameTooltip:Show()
                end)
                r:SetScript("OnLeave", function() GameTooltip:Hide() end)
            else
                r:SetScript("OnEnter", nil)
                r:SetScript("OnLeave", nil)
            end
            r:Show()
        end
        local h = math.max(#items * ITEM_H + 4, 1)
        popup:SetHeight(h)
    end

    function dd:SetLabel(lblText) text:SetText(lblText) end

    return dd
end

-- ── scroll list ───────────────────────────────────────────────────────────────

local function EnableCleanScrolling(sf, step)
    local function HideTemplateBar()
        if sf.ScrollBar then sf.ScrollBar:Hide() end
        for _, child in ipairs({ sf:GetChildren() }) do
            if child.GetObjectType and child:GetObjectType() == "Slider" then child:Hide() end
        end
    end
    HideTemplateBar()
    C_Timer.After(0, HideTemplateBar)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
        local maximum = self:GetVerticalScrollRange() or 0
        local target = self:GetVerticalScroll() - delta * (step or 72)
        self:SetVerticalScroll(math.max(0, math.min(maximum, target)))
    end)
end

local function MakeScrollList(parent, x, y, w, h)
    local sf = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    sf:SetSize(w, h)
    local c = CreateFrame("Frame", nil, sf)
    c:SetSize(w, 1)
    sf:SetScrollChild(c)
    EnableCleanScrolling(sf, ROW_H * 4)
    sf.content = c
    sf.rowW = w - 2
    sf.rows = {}
    return sf
end

local function GetRow(sf, i)
    if not sf.rows[i] then
        local row = CreateFrame("Button", nil, sf.content)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")   -- Rechtsklick = Wunschliste
        row:SetSize(sf.rowW, ROW_H)
        row:SetPoint("TOPLEFT", sf.content, "TOPLEFT", 2, -(i-1)*ROW_H)
        row:SetHighlightTexture("")
        row.hl = row:CreateTexture(nil, "BACKGROUND")
        row.hl:SetAllPoints(); row.hl:SetColorTexture(1, 1, 0, 0.15); row.hl:Hide()
        row:SetScript("OnEnter", function(s) s.hl:Show(); if s.card then ShowTip(s.card, s) end end)
        row:SetScript("OnLeave", function(s) s.hl:Hide(); HideTip() end)
        row.lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.lbl:SetAllPoints(); row.lbl:SetJustifyH("LEFT"); row.lbl:SetJustifyV("MIDDLE")
        sf.rows[i] = row
    end
    return sf.rows[i]
end

local function HideRows(sf, from)
    for i = from, #sf.rows do sf.rows[i]:Hide() end
end

-- ── refresh ───────────────────────────────────────────────────────────────────

local function RefreshAvail(sf)
    local cards = GetAvailableCards()
    local rows = {}
    local lastClass = nil
    for _, card in ipairs(cards) do
        local cc = card.class or "NEUTRAL"
        if cc ~= lastClass then
            rows[#rows+1] = { isSep = true, class = cc }
            lastClass = cc
        end
        rows[#rows+1] = { isSep = false, card = card }
    end
    for i, entry in ipairs(rows) do
        local row = GetRow(sf, i)
        if entry.isSep then
            row.card = nil
            local lbl = entry.class == "NEUTRAL" and "Neutrale" or (CLASS_DE[entry.class] or entry.class)
            row.lbl:SetText(" |cffc9a7ff" .. lbl .. "|r")
            row:SetScript("OnClick", nil)
            row:SetScript("OnEnter", nil)
            row:SetScript("OnLeave", nil)
            row:EnableMouse(false)
            row:Show()
        else
            local card = entry.card
            local inDeck = CountInDeck(card.id)
            local maxCop = MaxCopies(card)
            local sup    = IsSupported(card)
            local rc     = RARITY_COLOR[card.rarity or "COMMON"] or "|cffffffff"
            local star   = (addon.WL_Has and addon:WL_Has(card.id)) and "|cffffd700★|r " or ""
            local label  = string.format("%s[%d] %s%s|r%s (%s)  %d/%d", star, card.cost, rc, card.name, StatStr(card), card.rarity:sub(1,1), inDeck, maxCop)
            row.card = card
            row:EnableMouse(true)
            row:SetScript("OnEnter", function(s) s.hl:Show(); if s.card then ShowTip(s.card, s) end end)
            row:SetScript("OnLeave", function(s) s.hl:Hide(); HideTip() end)
            local canAdd = sup and inDeck < maxCop and #editingCards < 30
            if not sup then
                row.lbl:SetText("|cff777777" .. label .. " [nicht unterstützt]|r")
            elseif not canAdd then
                row.lbl:SetText("|cff666666" .. label .. "|r")
            else
                row.lbl:SetText(label)
            end
            -- Rechtsklick merkt die Karte vor, auch wenn sie (noch) nicht spielbar ist
            row:SetScript("OnClick", function(_, button)
                if button == "RightButton" then
                    if addon.WL_Toggle then addon:WL_Toggle(card.id); dbFrame:Refresh() end
                elseif canAdd then
                    editingCards[#editingCards+1] = card.id
                    dbFrame:Refresh()
                end
            end)
            row:Show()
        end
    end
    HideRows(sf, #rows + 1)
    sf.content:SetHeight(math.max(#rows * ROW_H, 1))
end

local function UpdateDeckCount(countLbl)
    local count = #editingCards
    countLbl:SetText(count .. " / 30 Karten")
    if count == 30 then
        countLbl:SetTextColor(0.25, 1, 0.45)
    elseif count > 30 then
        countLbl:SetTextColor(1, 0.25, 0.25)
    else
        countLbl:SetTextColor(1, 0.78, 0.25)
    end
end

local function RefreshDeck(sf, countLbl)
    local list = GetDeckCardsSorted()
    for i, entry in ipairs(list) do
        local row = GetRow(sf, i)
        local card = entry.card
        local rc   = RARITY_COLOR[card.rarity or "COMMON"] or "|cffffffff"
        row.lbl:SetText(string.format("[%d] %s%s|r%s  x%d", card.cost, rc, card.name, StatStr(card), entry.count))
        row.card = card
        row:SetScript("OnClick", function()
            for j = #editingCards, 1, -1 do
                if editingCards[j] == card.id then table.remove(editingCards, j); break end
            end
            dbFrame:Refresh()
        end)
        row:Show()
    end
    HideRows(sf, #list + 1)
    sf.content:SetHeight(math.max(#list * ROW_H, 1))
    UpdateDeckCount(countLbl)
end

-- ── save / load / delete ──────────────────────────────────────────────────────

local function SaveDeck(nameBox)
    local name = nameBox:GetText()
    if name == "" then print("|cffff0000[Arkana]|r Name darf nicht leer sein."); return end
    -- CLASSLESS ist nur der interne "keine Klasse gewählt"-Zustand, keine spielbare Klasse
    if currentClass == "CLASSLESS" then
        print("|cffff0000[Arkana]|r Bitte zuerst eine Klasse wählen."); return
    end
    if #editingCards < 30 then
        print("|cffffff00[Arkana]|r Warnung: Deck unvollständig (" .. #editingCards .. "/30).")
    elseif #editingCards > 30 then
        print("|cffff0000[Arkana]|r Zu viele Karten (" .. #editingCards .. "/30)."); return
    end
    local deck = { name = name, class = currentClass, cards = {} }
    for i, id in ipairs(editingCards) do deck.cards[i] = id end
    if currentDeckIdx then
        local oldName = ARKANA_Decks[currentDeckIdx].name
        if oldName ~= name and ARKANA_Stats.decks[oldName] then
            print("|cffffff00[Arkana]|r Warnung: Umbenennen löscht Statistik für '" .. oldName .. "'.")
            ARKANA_Stats.decks[oldName] = nil
        end
        ARKANA_Decks[currentDeckIdx] = deck
        print("|cff00ff00[Arkana]|r Deck '" .. name .. "' aktualisiert.")
    else
        ARKANA_Decks[#ARKANA_Decks+1] = deck
        currentDeckIdx = #ARKANA_Decks
        print("|cff00ff00[Arkana]|r Deck '" .. name .. "' gespeichert.")
    end
    dbFrame:RefreshSelector(); dbFrame:Refresh()
end

local function LoadDeck(idx)
    local d = ARKANA_Decks[idx]; if not d then return end
    currentDeckIdx = idx; currentClass = d.class; editingName = d.name
    editingCards = {}; for i, id in ipairs(d.cards) do editingCards[i] = id end
    dbFrame:RefreshSelector(); dbFrame:Refresh()
end

local function DeleteDeck()
    if not currentDeckIdx then print("|cffff0000[Arkana]|r Kein Deck ausgewählt."); return end
    local name = ARKANA_Decks[currentDeckIdx].name
    table.remove(ARKANA_Decks, currentDeckIdx)
    local active = ARKANA_CharData.activeDeckIndex or 0
    if active == currentDeckIdx then ARKANA_CharData.activeDeckIndex = nil
    elseif active > currentDeckIdx then ARKANA_CharData.activeDeckIndex = active - 1 end
    currentDeckIdx = nil; editingCards = {}; editingName = "Neues Deck"; currentClass = "CLASSLESS"
    print("|cff00ff00[Arkana]|r Deck '" .. name .. "' gelöscht.")
    dbFrame:RefreshSelector(); dbFrame:Refresh()
end

-- ── frame ─────────────────────────────────────────────────────────────────────

local function Build()
    local f = CreateFrame("Frame", "ARKANA_DeckBuilder", UIParent, "BackdropTemplate")
    f:SetSize(960, 640)
    f:SetPoint("CENTER")
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    f:SetBackdropColor(unpack(EDITOR_COLOR.panel))
    f:SetBackdropBorderColor(unpack(EDITOR_COLOR.panelBorder))
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetClampedToScreen(true)
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)
    f:SetScript("OnHide", function() CloseDropdown(); HideTip() end)
    f:Hide()
    if addon.UI_RegisterScalableFrame then addon:UI_RegisterScalableFrame(f) end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -12)
    title:SetText("Arkana")
    title:SetTextColor(unpack(EDITOR_COLOR.title))
    local subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    subtitle:SetPoint("LEFT", title, "RIGHT", 8, 0)
    subtitle:SetText("Decks")

    local close = CreateEditorButton(f, "×", 28, 24, function() f:Hide() end)
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -9)

    local workspaceBg = f:CreateTexture(nil, "BACKGROUND")
    workspaceBg:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -44)
    workspaceBg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -5, 5)
    workspaceBg:SetColorTexture(0.025, 0.020, 0.045, 0.97)

    local topAccent = f:CreateTexture(nil, "ARTWORK")
    topAccent:SetHeight(2)
    topAccent:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -120)
    topAccent:SetPoint("TOPRIGHT", f, "TOPRIGHT", -18, -120)
    addon:UI_BindThemeTexture(topAccent, EDITOR_COLOR.purple)

    local function CreateSectionBackdrop(x, width)
        local panel = CreateFrame("Frame", nil, f, "BackdropTemplate")
        panel:SetFrameLevel(f:GetFrameLevel())
        panel:SetPoint("TOPLEFT", f, "TOPLEFT", x, -128)
        panel:SetSize(width, 452)
        panel:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1,
        })
        panel:SetBackdropColor(unpack(EDITOR_COLOR.section))
        panel:SetBackdropBorderColor(unpack(EDITOR_COLOR.purpleSoft))
        return panel
    end
    CreateSectionBackdrop(18, 592)
    CreateSectionBackdrop(628, 314)

    -- ── Zeile 1: Deck-Dropdown + Name + Aktions-Buttons + Icon-Buttons ──────────
    local deckLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    deckLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 22, -58)
    deckLabel:SetText("Deck:")
    deckLabel:SetTextColor(0.74, 0.69, 0.84, 1)

    local deckDD = MakeDropdown(f, 184)
    deckDD.btn:SetPoint("LEFT", deckLabel, "RIGHT", 6, 0)
    f.deckDD = deckDD

    local nameLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameLabel:SetPoint("LEFT", deckDD.btn, "RIGHT", 10, 0)
    nameLabel:SetText("Name:")
    nameLabel:SetTextColor(0.74, 0.69, 0.84, 1)
    local nameBox = CreateEditorEditBox(f, 150, 22)
    nameBox:SetPoint("LEFT", nameLabel, "RIGHT", 4, 0)
    nameBox:SetAutoFocus(false)
    f.nameBox = nameBox

    local bSave = CreateEditorButton(f, "Speichern", 82, 22, function() SaveDeck(f.nameBox) end)
    bSave:SetPoint("LEFT", nameBox, "RIGHT", 6, 0)

    local bDelete = CreateEditorButton(f, "Löschen", 70, 22, DeleteDeck, "danger")
    bDelete:SetPoint("LEFT", bSave, "RIGHT", 4, 0)
    f.bDelete = bDelete

    local bImport = CreateEditorButton(f, "Import", 66, 22, function() addon:DB_ShowCodeWindow("", true) end)
    bImport:SetPoint("TOPRIGHT", f, "TOPRIGHT", -18, -55)
    bImport:HookScript("OnEnter", function(s)
        GameTooltip:SetOwner(s, "ANCHOR_TOP"); GameTooltip:SetText("Deck importieren"); GameTooltip:Show()
    end)
    bImport:HookScript("OnLeave", function() GameTooltip:Hide() end)

    local bShare = CreateEditorButton(f, "Export", 66, 22)
    bShare:SetPoint("RIGHT", bImport, "LEFT", -4, 0)
    bShare:SetScript("OnClick", function()
        local name = f.nameBox:GetText()
        if name == "" then print("|cffff0000[Arkana]|r Name darf nicht leer sein."); return end
        if #editingCards == 0 then print("|cffff0000[Arkana]|r Deck ist leer."); return end
        addon:DB_ShowCodeWindow(name:gsub("[|#]", "") .. "#" .. table.concat(editingCards, ","), false)
    end)
    bShare:HookScript("OnEnter", function(s)
        GameTooltip:SetOwner(s, "ANCHOR_TOP"); GameTooltip:SetText("Deck teilen (exportieren)"); GameTooltip:Show()
    end)
    bShare:HookScript("OnLeave", function() GameTooltip:Hide() end)

    -- ── Zeile 2: Suche + Klasse-DD + Filter-DD ────────────────────────────────
    local searchLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    searchLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 22, -91)
    searchLabel:SetText("Suche:")
    searchLabel:SetTextColor(0.74, 0.69, 0.84, 1)
    local searchBox = CreateEditorEditBox(f, 190, 22)
    searchBox:SetPoint("LEFT", searchLabel, "RIGHT", 4, 0)
    searchBox:SetAutoFocus(false)
    searchBox:SetScript("OnTextChanged", function() f:Refresh() end)
    f.searchBox = searchBox

    local clsLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    clsLabel:SetPoint("LEFT", searchBox, "RIGHT", 12, 0)
    clsLabel:SetText("Klasse:")
    clsLabel:SetTextColor(0.74, 0.69, 0.84, 1)
    local clsDD = MakeDropdown(f, 120)
    clsDD.btn:SetPoint("LEFT", clsLabel, "RIGHT", 6, 0)
    f.clsDD = clsDD

    local filterLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    filterLabel:SetPoint("LEFT", clsDD.btn, "RIGHT", 10, 0)
    filterLabel:SetText("Filter:")
    filterLabel:SetTextColor(0.74, 0.69, 0.84, 1)
    local filterDD = MakeDropdown(f, 112)
    filterDD.btn:SetPoint("LEFT", filterLabel, "RIGHT", 6, 0)
    f.filterDD = filterDD

    -- ── Spalten-Header ────────────────────────────────────────────────────────
    local hAvail = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hAvail:SetPoint("TOPLEFT", f, "TOPLEFT", 28, -142)
    hAvail:SetText("Kartensammlung")
    hAvail:SetTextColor(unpack(EDITOR_COLOR.title))

    local availHint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    availHint:SetPoint("TOPLEFT", hAvail, "BOTTOMLEFT", 0, -2)
    availHint:SetText("Linksklick: hinzufügen  ·  Rechtsklick: Favorit")

    -- Anzahl der Karten, die den aktuellen Filtern entsprechen.
    local colCount = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    colCount:SetPoint("TOPRIGHT", f, "TOPLEFT", 530, -144)
    f.colCountLbl = colCount

    -- Toggle grid mode button next to left header
    local bAvailToggle
    bAvailToggle = CreateEditorButton(f, "Raster", 58, 22, function()
        gridMode = not gridMode
        if ARKANA_Settings then ARKANA_Settings.dbGridMode = gridMode end
        bAvailToggle:SetText(gridMode and "Liste" or "Raster")
        f:Refresh()
    end)
    bAvailToggle:SetPoint("TOPRIGHT", f, "TOPLEFT", 600, -137)
    f.bAvailToggle = bAvailToggle

    -- Merkliste: Rechtsklick auf eine Karte markiert sie als Favorit.
    local wishCb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    wishCb:SetSize(22, 22)
    wishCb:SetPoint("LEFT", filterDD.btn, "RIGHT", 8, 0)
    local wishLbl = wishCb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    wishLbl:SetPoint("LEFT", wishCb, "RIGHT", 2, 0)
    wishLbl:SetText("Nur Favoriten")
    wishCb:SetChecked(ARKANA_Settings.dbWishOnly and true or false)
    wishCb:SetScript("OnClick", function(self)
        ARKANA_Settings.dbWishOnly = self:GetChecked() and true or false
        f:Refresh()
    end)
    wishCb:SetScript("OnEnter", function(s)
        GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
        GameTooltip:SetText("Favoriten", 1, 0.82, 0)
        GameTooltip:AddLine("Rechtsklick auf eine Karte = merken / vergessen (★).", 1, 1, 1)
        GameTooltip:AddLine("Der Filter zeigt nur deine markierten Favoriten.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    wishCb:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local hDeck = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hDeck:SetPoint("TOPLEFT", f, "TOPLEFT", 640, -142)
    hDeck:SetText("Deckinhalt")
    hDeck:SetTextColor(unpack(EDITOR_COLOR.title))

    local deckHint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    deckHint:SetPoint("TOPLEFT", hDeck, "BOTTOMLEFT", 0, -2)
    deckHint:SetText("Klick auf eine Karte: entfernen")

    -- Toggle grid mode button next to right header
    local bDeckToggle
    bDeckToggle = CreateEditorButton(f, "Raster", 58, 22, function()
        deckGridMode = not deckGridMode
        if ARKANA_Settings then ARKANA_Settings.dbDeckGridMode = deckGridMode end
        bDeckToggle:SetText(deckGridMode and "Liste" or "Raster")
        f:Refresh()
    end)
    bDeckToggle:SetPoint("TOPRIGHT", f, "TOPRIGHT", -30, -137)
    f.bDeckToggle = bDeckToggle

    -- ── Scroll-Listen ─────────────────────────────────────────────────────────
    local topOff = 178
    local listH  = 382
    f.availSF = MakeScrollList(f, 22,  topOff, 584, listH)
    f.deckSF  = MakeScrollList(f, 632, topOff, 306, listH)

    -- ScrollFrame for grid view (occupies the exact same space as availSF)
    local cardGridSF = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    cardGridSF:SetPoint("TOPLEFT", f, "TOPLEFT", 22, -178)
    cardGridSF:SetSize(584, 382)
    local gridContent = CreateFrame("Frame", nil, cardGridSF)
    gridContent:SetSize(580, 1)
    cardGridSF:SetScrollChild(gridContent)
    EnableCleanScrolling(cardGridSF, 96)
    cardGridSF:Hide()
    f.cardGridSF = cardGridSF
    f.gridContent = gridContent

    -- ScrollFrame for deck grid view (occupies the exact same space as deckSF)
    local deckGridSF = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    deckGridSF:SetPoint("TOPLEFT", f, "TOPLEFT", 632, -178)
    deckGridSF:SetSize(306, 382)
    local deckGridContent = CreateFrame("Frame", nil, deckGridSF)
    deckGridContent:SetSize(302, 1)
    deckGridSF:SetScrollChild(deckGridContent)
    EnableCleanScrolling(deckGridSF, 96)
    deckGridSF:Hide()
    f.deckGridSF = deckGridSF
    f.deckGridContent = deckGridContent

    f.countLbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.countLbl:SetPoint("TOPRIGHT", f, "TOPRIGHT", -98, -142)
    f.countLbl:SetText("0 / 30 Karten")

    f.emptyDeckText = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    f.emptyDeckText:SetPoint("CENTER", f, "TOPLEFT", 785, -340)
    f.emptyDeckText:SetWidth(250)
    f.emptyDeckText:SetJustifyH("CENTER")
    f.emptyDeckText:SetText("Noch keine Karten im Deck\n\nWähle links eine Karte aus.")

    -- ── Bottom ────────────────────────────────────────────────────────────────
    local bBack = CreateEditorButton(f, "Zurück", 96, 28, function() f:Hide(); addon:OpenMainMenu() end)
    bBack:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -30, 8)

    -- Left card size slider (Available cards)
    local sizeSlider = CreateFrame("Slider", "ARKANA_DB_SizeSlider", f, "OptionsSliderTemplate")
    sizeSlider:SetWidth(150)
    sizeSlider:SetHeight(16)
    sizeSlider:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 20, 14)
    sizeSlider:SetMinMaxValues(60, 170)
    sizeSlider:SetValueStep(5)
    sizeSlider:SetObeyStepOnDrag(true)

    _G[sizeSlider:GetName() .. "Text"]:Hide()
    _G[sizeSlider:GetName() .. "Low"]:Hide()
    _G[sizeSlider:GetName() .. "High"]:Hide()

    local sizeLabel = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    sizeLabel:SetPoint("BOTTOMLEFT", sizeSlider, "TOPLEFT", 0, 3)
    sizeLabel:SetText("Kartengröße Sammlung")
    f.sizeLabel = sizeLabel

    sizeSlider:SetScript("OnValueChanged", function(self, val)
        val = math.floor(val)
        if ARKANA_Settings then
            ARKANA_Settings.dbCardSize = val
        end
        f:Refresh()
    end)
    f.sizeSlider = sizeSlider

    -- Right card size slider (Deck cards)
    local deckSizeSlider = CreateFrame("Slider", "ARKANA_DB_DeckSizeSlider", f, "OptionsSliderTemplate")
    deckSizeSlider:SetWidth(150)
    deckSizeSlider:SetHeight(16)
    deckSizeSlider:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 640, 14)
    deckSizeSlider:SetMinMaxValues(60, 170)
    deckSizeSlider:SetValueStep(5)
    deckSizeSlider:SetObeyStepOnDrag(true)

    _G[deckSizeSlider:GetName() .. "Text"]:Hide()
    _G[deckSizeSlider:GetName() .. "Low"]:Hide()
    _G[deckSizeSlider:GetName() .. "High"]:Hide()

    local deckSizeLabel = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    deckSizeLabel:SetPoint("BOTTOMLEFT", deckSizeSlider, "TOPLEFT", 0, 3)
    deckSizeLabel:SetText("Kartengröße Deck")
    f.deckSizeLabel = deckSizeLabel

    deckSizeSlider:SetScript("OnValueChanged", function(self, val)
        val = math.floor(val)
        if ARKANA_Settings then
            ARKANA_Settings.dbDeckCardSize = val
        end
        f:Refresh()
    end)
    f.deckSizeSlider = deckSizeSlider

    -- ── methods ───────────────────────────────────────────────────────────────


    local gridPool = {}

    local gridHeaderPool = {}
    local function GetGridHeader(idx)
        local h = gridHeaderPool[idx]
        if not h then
            h = f.gridContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            h:SetWidth(564)
            h:SetJustifyH("CENTER")
            gridHeaderPool[idx] = h
        end
        return h
    end

    local function RefreshGrid()
        local cards = GetAvailableCards()
        for _, t in ipairs(gridPool) do t:Hide() end
        for _, h in ipairs(gridHeaderPool) do h:Hide() end

        local thumbW = ARKANA_Settings.dbCardSize or 80
        local thumbH = math.floor(thumbW * 1.375)
        local thumbGapX = 8
        local thumbGapY = 6

        local availW = f.cardGridSF:GetWidth() - 4
        if availW <= 0 then availW = 580 end
        local thumbCols = math.max(2, math.floor((availW + thumbGapX) / (thumbW + thumbGapX)))

        local col = 0
        local yOffset = 0
        local lastClass = nil
        local headerIdx = 0

        for i, card in ipairs(cards) do
            local cc = card.class or "NEUTRAL"
            if cc ~= lastClass then
                if col > 0 then
                    yOffset = yOffset + thumbH + thumbGapY
                    col = 0
                end
                headerIdx = headerIdx + 1
                local h = GetGridHeader(headerIdx)
                local lbl = cc == "NEUTRAL" and "Neutrale" or (CLASS_DE[cc] or cc)
                h:SetText("|cffc9a7ff" .. lbl .. "|r")
                h:ClearAllPoints()
                h:SetPoint("TOPLEFT", f.gridContent, "TOPLEFT", 8, -yOffset - 4)
                h:Show()
                yOffset = yOffset + 20
                lastClass = cc
            end

            local t = gridPool[i]
            if not t then
                t = CreateFrame("Button", nil, f.gridContent)
                
                local art = t:CreateTexture(nil, "ARTWORK")
                art:SetAllPoints()
                t.art = art
                
                local hl = t:CreateTexture(nil, "HIGHLIGHT")
                hl:SetAllPoints()
                hl:SetColorTexture(1, 1, 1, 0.15)
                t.hl = hl
                
                local border = t:CreateTexture(nil, "OVERLAY")
                border:SetPoint("TOPLEFT", -1, 1)
                border:SetPoint("BOTTOMRIGHT", 1, -1)
                border:SetColorTexture(0, 0, 0, 0)
                t.border = border

                -- Premium Mana Gem texture
                local manaBg = t:CreateTexture(nil, "OVERLAY")
                manaBg:SetTexture("Interface\\AddOns\\Arkana\\Textures\\Frames\\cost-mana.tga")
                t.manaBg = manaBg
                
                local costLbl = t:CreateFontString(nil, "OVERLAY")
                costLbl:SetTextColor(1, 1, 1)
                t.costLbl = costLbl

                -- Gewählt-Anzeige unten links ("(2/2)" = im Deck/Limit)
                local leftLbl = t:CreateFontString(nil, "OVERLAY")
                leftLbl:SetTextColor(0.9, 0.9, 0.9)
                t.leftLbl = leftLbl

                -- NEU-Rahmen (gelb): vier dünne Kanten, wachsen mit der Zellgröße mit
                t.newEdges = {}
                for k = 1, 4 do
                    local e = t:CreateTexture(nil, "OVERLAY")
                    e:SetColorTexture(1, 0.85, 0, 1)
                    if k == 1 then
                        e:SetPoint("TOPLEFT"); e:SetPoint("TOPRIGHT"); e:SetHeight(2)
                    elseif k == 2 then
                        e:SetPoint("BOTTOMLEFT"); e:SetPoint("BOTTOMRIGHT"); e:SetHeight(2)
                    elseif k == 3 then
                        e:SetPoint("TOPLEFT"); e:SetPoint("BOTTOMLEFT"); e:SetWidth(2)
                    else
                        e:SetPoint("TOPRIGHT"); e:SetPoint("BOTTOMRIGHT"); e:SetWidth(2)
                    end
                    e:Hide()
                    t.newEdges[k] = e
                end

                -- Wunschliste-Stern oben rechts (Rechtsklick setzt/entfernt ihn).
                -- Echtes Stern-Symbol statt Textzeichen — auf dem Kartenbild deutlich
                -- besser zu sehen.
                t.wishStar = t:CreateTexture(nil, "OVERLAY")
                t.wishStar:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_1")
                t.wishStar:Hide()

                t:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                t:SetScript("OnEnter", function(s) if s.card then ShowTip(s.card, s) end end)
                t:SetScript("OnLeave", function() HideTip() end)
                gridPool[i] = t
            end

            t:SetSize(thumbW, thumbH)

            local crystalSize = math.floor(thumbW * 0.45)
            if crystalSize < 16 then crystalSize = 16 end
            t.manaBg:SetSize(crystalSize, crystalSize)
            t.manaBg:ClearAllPoints()
            t.manaBg:SetPoint("TOPLEFT", t, "TOPLEFT", math.floor(thumbW * 0.05), -math.floor(thumbH * 0.08))
            
            local fontSize = math.floor(crystalSize * 0.45)
            if fontSize < 9 then fontSize = 9 end
            t.costLbl:SetFont("Fonts\\FRIZQT__.TTF", fontSize, "OUTLINE")
            t.costLbl:ClearAllPoints()
            t.costLbl:SetPoint("TOPLEFT", t.manaBg, "TOPLEFT", math.floor(crystalSize * 0.09), -math.floor(crystalSize * 0.07))

            t.card = card
            t.art:SetTexture((addon.CS_ArtFor and addon:CS_ArtFor(card.id, true))
                or ("Interface\\AddOns\\Arkana\\Textures\\Cards\\" .. card.id .. ".tga"))
            t.art:SetTexCoord(0, 1, 0, 0.758)
            t.costLbl:SetText(card.cost or "0")

            local badgeFont = math.max(9, math.floor(thumbW * 0.16))
            local pad = math.max(2, math.floor(thumbW * 0.05))
            t.leftLbl:SetFont("Fonts\\FRIZQT__.TTF", badgeFont, "OUTLINE")
            t.leftLbl:ClearAllPoints()
            t.leftLbl:SetPoint("BOTTOMLEFT", t, "BOTTOMLEFT", pad, pad)

            local inDeck = CountInDeck(card.id)
            local maxCop = MaxCopies(card)
            local sup    = IsSupported(card)
            local owned  = addon.COL_Count and addon:COL_Count(card.id) or 2

            -- Im Deck/Limit unten links, sobald die Karte gewählt wurde.
            t.leftLbl:SetText(inDeck > 0 and string.format("(%d/%d)", inDeck, maxCop) or "")

            local isNew = newCardMarks[card.id] and true or false
            for _, e in ipairs(t.newEdges) do e:SetShown(isNew) end

            -- Einheitliche Optik ohne Farb-Rahmen: alles, was nicht (mehr) ins Deck
            -- kann (nicht besessen, Limit erreicht, Deck voll, nicht unterstützt),
            -- wird schlicht ausgegraut; der Rest ist normal und klickbar.
            t.border:SetColorTexture(0, 0, 0, 0)
            local canAdd = not (owned == 0 or not sup or inDeck >= maxCop or #editingCards >= 30)
            t:SetAlpha(canAdd and 1 or 0.45)
            t.art:SetDesaturated(not canAdd)
            -- Rechtsklick = Wunschliste (geht auch bei ausgegrauten, also gerade den
            -- fehlenden Karten — genau die will man sich merken)
            local starSize = math.max(16, math.floor(thumbW * 0.28))
            t.wishStar:SetSize(starSize, starSize)
            t.wishStar:ClearAllPoints()
            t.wishStar:SetPoint("TOPRIGHT", t, "TOPRIGHT", 3, 3)
            t.wishStar:SetShown((addon.WL_Has and addon:WL_Has(card.id)) and true or false)
            t:SetScript("OnClick", function(_, button)
                if button == "RightButton" then
                    if addon.WL_Toggle then addon:WL_Toggle(card.id); f:Refresh() end
                elseif canAdd then
                    editingCards[#editingCards+1] = card.id; f:Refresh()
                end
            end)

            local x = col * (thumbW + thumbGapX)
            local y = -yOffset
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", f.gridContent, "TOPLEFT", x, y)
            t:Show()

            col = col + 1
            if col >= thumbCols then
                col = 0
                yOffset = yOffset + thumbH + thumbGapY
            end
        end

        local finalHeight = yOffset
        if col > 0 then
            finalHeight = finalHeight + thumbH + thumbGapY
        end
        f.gridContent:SetHeight(math.max(finalHeight, 1))
    end

    local deckGridPool = {}

    local function RefreshDeckGrid()
        local deckCards = GetDeckCardsSorted()
        for _, t in ipairs(deckGridPool) do t:Hide() end

        local thumbW = ARKANA_Settings.dbDeckCardSize or 80
        local thumbH = math.floor(thumbW * 1.375)
        local thumbGapX = 8
        local thumbGapY = 6

        local deckW = f.deckGridSF:GetWidth() - 4
        if deckW <= 0 then deckW = 302 end
        local thumbCols = math.max(2, math.floor((deckW + thumbGapX) / (thumbW + thumbGapX)))

        local col, row = 0, 0
        for i, entry in ipairs(deckCards) do
            local card = entry.card
            local count = entry.count
            local t = deckGridPool[i]
            if not t then
                t = CreateFrame("Button", nil, f.deckGridContent)
                
                local art = t:CreateTexture(nil, "ARTWORK")
                art:SetAllPoints()
                t.art = art
                
                local hl = t:CreateTexture(nil, "HIGHLIGHT")
                hl:SetAllPoints()
                hl:SetColorTexture(1, 1, 1, 0.15)
                t.hl = hl
                
                local border = t:CreateTexture(nil, "OVERLAY")
                border:SetPoint("TOPLEFT", -1, 1)
                border:SetPoint("BOTTOMRIGHT", 1, -1)
                border:SetColorTexture(0, 0, 0, 0)
                t.border = border

                -- Premium Mana Gem texture
                local manaBg = t:CreateTexture(nil, "OVERLAY")
                manaBg:SetTexture("Interface\\AddOns\\Arkana\\Textures\\Frames\\cost-mana.tga")
                t.manaBg = manaBg
                
                local costLbl = t:CreateFontString(nil, "OVERLAY")
                costLbl:SetTextColor(1, 1, 1)
                t.costLbl = costLbl

                -- Card Count Badge (bottom right)
                local countLbl = t:CreateFontString(nil, "OVERLAY")
                countLbl:SetTextColor(1, 0.8, 0) -- Gold text
                t.countLbl = countLbl
                
                t:SetScript("OnEnter", function(s) if s.card then ShowTip(s.card, s) end end)
                t:SetScript("OnLeave", function() HideTip() end)
                deckGridPool[i] = t
            end

            t:SetSize(thumbW, thumbH)

            local crystalSize = math.floor(thumbW * 0.45)
            if crystalSize < 16 then crystalSize = 16 end
            t.manaBg:SetSize(crystalSize, crystalSize)
            t.manaBg:ClearAllPoints()
            t.manaBg:SetPoint("TOPLEFT", t, "TOPLEFT", math.floor(thumbW * 0.05), -math.floor(thumbH * 0.08))
            
            local fontSize = math.floor(crystalSize * 0.45)
            if fontSize < 9 then fontSize = 9 end
            t.costLbl:SetFont("Fonts\\FRIZQT__.TTF", fontSize, "OUTLINE")
            t.costLbl:ClearAllPoints()
            t.costLbl:SetPoint("TOPLEFT", t.manaBg, "TOPLEFT", math.floor(crystalSize * 0.09), -math.floor(crystalSize * 0.07))

            local badgeFontSize = math.floor(thumbW * 0.175)
            if badgeFontSize < 9 then badgeFontSize = 9 end
            t.countLbl:SetFont("Fonts\\FRIZQT__.TTF", badgeFontSize, "OUTLINE")
            t.countLbl:ClearAllPoints()
            t.countLbl:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", -math.max(2, math.floor(thumbW * 0.05)), math.max(2, math.floor(thumbW * 0.05)))

            t.card = card
            t.art:SetTexture((addon.CS_ArtFor and addon:CS_ArtFor(card.id, true))
                or ("Interface\\AddOns\\Arkana\\Textures\\Cards\\" .. card.id .. ".tga"))
            t.art:SetTexCoord(0, 1, 0, 0.758)
            t.costLbl:SetText(card.cost or "0")
            
            t.countLbl:SetText("x" .. count)

            t:SetAlpha(1)
            t.border:SetColorTexture(0, 0, 0, 0)
            t:SetScript("OnClick", function()
                for idx, id in ipairs(editingCards) do
                    if id == card.id then
                        table.remove(editingCards, idx)
                        break
                    end
                end
                f:Refresh()
            end)

            local x = col * (thumbW + thumbGapX)
            local y = -(row * (thumbH + thumbGapY))
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", f.deckGridContent, "TOPLEFT", x, y)
            t:Show()

            col = col + 1
            if col >= thumbCols then col = 0; row = row + 1 end
        end

        local totalRows = math.ceil(#deckCards / thumbCols)
        f.deckGridContent:SetHeight(math.max(totalRows * (thumbH + thumbGapY), 1))
    end


    function f:RefreshSelector()
        local activeIdx = ARKANA_CharData.activeDeckIndex
        local items = {}
        -- erste Option: neues Deck
        items[1] = {
            text = "|cff00cc44+ Neues Deck erstellen|r",
            onSelect = function()
                currentDeckIdx = nil; editingCards = {}; editingName = "Neues Deck"; currentClass = "CLASSLESS"
                f:RefreshSelector(); f:Refresh()
            end
        }
        for i, deck in ipairs(ARKANA_Decks) do
            local isCurrent = (i == currentDeckIdx)
            local isActive  = (i == activeIdx)
            local label
            if isCurrent and isActive then
                label = "|cff00ff00" .. deck.name .. " [aktiv]|r"
            elseif isCurrent then
                label = "|cff00ff00" .. deck.name .. "|r"
            elseif isActive then
                label = "|cffffd700" .. deck.name .. " [aktiv]|r"
            else
                label = deck.name
            end
            local idx = i
            items[#items+1] = { text = label, onSelect = function() LoadDeck(idx) end }
        end
        deckDD:Populate(items)
        if currentDeckIdx then
            local d = ARKANA_Decks[currentDeckIdx]
            local lbl = d and d.name or "?"
            if currentDeckIdx == activeIdx then lbl = lbl .. " [aktiv]" end
            deckDD:SetLabel(lbl)
            f.bDelete:Enable()
        else
            deckDD:SetLabel("+ Neues Deck")
            f.bDelete:Disable()
        end
    end

    function f:Refresh()
        self.nameBox:SetText(editingName)
        self.emptyDeckText:SetShown(#editingCards == 0)

        -- Klassen-DD
        do
            local items = {}
            items[1] = {
                text = (currentClass == "CLASSLESS") and "|cff00ff00<Keine>|r" or "<Keine>",
                onSelect = function()
                    currentClass = "CLASSLESS"; classFilter = "CLASSLESS"; editingCards = {}
                    f:RefreshSelector(); f:Refresh()
                end
            }
            for _, cls in ipairs(CLASSES) do
                if cls ~= "CLASSLESS" then
                    local name_ = CLASS_DE[cls] or cls
                    local isCurrent = (cls == currentClass)
                    local cls_ = cls
                    items[#items+1] = {
                        text = isCurrent and ("|cff00ff00" .. name_ .. "|r") or name_,
                        tooltip = addon.HERO_POWER_DESC and addon.HERO_POWER_DESC[cls_],
                        onSelect = function()
                            currentClass = cls_; classFilter = cls_; editingCards = {}
                            f:RefreshSelector(); f:Refresh()
                        end
                    }
                end
            end
            clsDD:Populate(items)
            clsDD:SetLabel((currentClass == "CLASSLESS") and "<Keine>" or (CLASS_DE[currentClass] or currentClass))
        end

        -- Filter-DD
        do
            local opts = {
                { key="ALL",     label="<Alle>" },
                { key="NEUTRAL", label="Neutral" },
            }
            for _, cls in ipairs(CLASSES) do
                if cls ~= "CLASSLESS" then
                    opts[#opts+1] = { key=cls, label=CLASS_DE[cls] or cls }
                end
            end
            local items = {}
            for _, opt in ipairs(opts) do
                local isCurrent = (opt.key == classFilter)
                local k, lbl = opt.key, opt.label
                items[#items+1] = {
                    text = isCurrent and ("|cff00ff00" .. lbl .. "|r") or lbl,
                    onSelect = function() classFilter = k; f:Refresh() end
                }
            end
            filterDD:Populate(items)
            local filterName
            if classFilter == "ALL" or classFilter == "CLASSLESS" then filterName = "<Alle>"
            elseif classFilter == "NEUTRAL" then filterName = "Neutral"
            else filterName = CLASS_DE[classFilter] or classFilter end
            filterDD:SetLabel(filterName)
        end

        if gridMode then
            self.availSF:Hide()
            self.cardGridSF:Show()
            RefreshGrid()
        else
            self.cardGridSF:Hide()
            self.availSF:Show()
            RefreshAvail(self.availSF)
        end

        if deckGridMode then
            self.deckSF:Hide()
            self.deckGridSF:Show()
            RefreshDeckGrid()
            UpdateDeckCount(self.countLbl)
        else
            self.deckGridSF:Hide()
            self.deckSF:Show()
            RefreshDeck(self.deckSF, self.countLbl)
        end

        if gridMode then
            self.sizeSlider:Show()
            self.sizeLabel:Show()
        else
            self.sizeSlider:Hide()
            self.sizeLabel:Hide()
        end

        if deckGridMode then
            self.deckSizeSlider:Show()
            self.deckSizeLabel:Show()
        else
            self.deckSizeSlider:Hide()
            self.deckSizeLabel:Hide()
        end
    end

    f:SetScript("OnShow", function(self)
        -- Alte NEU-Markierungen einmalig übernehmen und anschließend verwerfen.
        newCardMarks = (ARKANA_CharData and ARKANA_CharData.newCards) or {}
        if ARKANA_CharData then ARKANA_CharData.newCards = nil end
        gridMode = ARKANA_Settings and ARKANA_Settings.dbGridMode or false
        deckGridMode = ARKANA_Settings and ARKANA_Settings.dbDeckGridMode or false
        if bAvailToggle then
            bAvailToggle:SetText(gridMode and "Liste" or "Raster")
        end
        if bDeckToggle then
            bDeckToggle:SetText(deckGridMode and "Liste" or "Raster")
        end

        local currentSize = ARKANA_Settings and ARKANA_Settings.dbCardSize or 80
        if self.sizeSlider then
            self.sizeSlider:SetValue(currentSize)
        end

        local currentDeckSize = ARKANA_Settings and ARKANA_Settings.dbDeckCardSize or 80
        if self.deckSizeSlider then
            self.deckSizeSlider:SetValue(currentDeckSize)
        end

        self:RefreshSelector()
        self:Refresh()
    end)

    return f
end

-- ── code window + import ──────────────────────────────────────────────────────

local codeWin

function addon:DB_ShowCodeWindow(code, isImport)
    if not codeWin then
        codeWin = CreateFrame("Frame", "ARKANA_CodeWin", UIParent, "BasicFrameTemplateWithInset")
        codeWin:SetSize(500, 130)
        codeWin:SetPoint("CENTER")
        codeWin:SetMovable(true); codeWin:EnableMouse(true)
        codeWin:RegisterForDrag("LeftButton")
        codeWin:SetScript("OnDragStart", codeWin.StartMoving)
        codeWin:SetScript("OnDragStop",  codeWin.StopMovingOrSizing)
        codeWin:SetFrameStrata("TOOLTIP")
        if addon.UI_RegisterScalableFrame then addon:UI_RegisterScalableFrame(codeWin) end

        local eb = CreateEditorEditBox(codeWin)
        eb:SetPoint("TOPLEFT",  codeWin, "TOPLEFT",  12, -30)
        eb:SetPoint("BOTTOMRIGHT", codeWin, "BOTTOMRIGHT", -12, 36)
        eb:SetAutoFocus(true); eb:SetMaxLetters(2000)
        eb:SetTextInsets(6, 6, 0, 0)
        eb:SetScript("OnEscapePressed", function() codeWin:Hide() end)
        codeWin.eb = eb

        local okBtn = CreateFrame("Button", nil, codeWin, "UIPanelButtonTemplate")
        okBtn:SetSize(100, 22)
        okBtn:SetPoint("BOTTOMRIGHT", codeWin, "BOTTOMRIGHT", -10, 8)
        codeWin.okBtn = okBtn

        local cancelBtn = CreateFrame("Button", nil, codeWin, "UIPanelButtonTemplate")
        cancelBtn:SetSize(80, 22)
        cancelBtn:SetPoint("RIGHT", okBtn, "LEFT", -6, 0)
        cancelBtn:SetText("Schliessen")
        cancelBtn:SetScript("OnClick", function() codeWin:Hide() end)

        eb:SetScript("OnEnterPressed", function() okBtn:Click() end)
    end

    codeWin.isImport = isImport
    codeWin.okBtn:SetScript("OnClick", function()
        if codeWin.isImport then addon:DB_ImportDeck(codeWin.eb:GetText()) end
        codeWin:Hide()
    end)

    if isImport then
        codeWin.TitleText:SetText("Deck-Code einfuegen (Strg+V)")
        codeWin.okBtn:SetText("Importieren")
        codeWin.eb:SetText("")
    else
        codeWin.TitleText:SetText("Deck-Code kopieren (Strg+C)")
        codeWin.okBtn:SetText("Fertig")
        codeWin.eb:SetText(code)
        codeWin.eb:HighlightText()
    end
    codeWin:Show()
    codeWin.eb:SetFocus()
end

function addon:DB_ImportDeck(codeStr)
    if not codeStr or codeStr == "" then return end
    codeStr = codeStr:gsub("%s", "")
    local sep = codeStr:find("#")
    if not sep then print("|cffff0000[Arkana]|r Ungueltiger Deck-Code ('#' fehlt)."); return end

    local deckName = codeStr:sub(1, sep-1)
    if deckName == "" then print("|cffff0000[Arkana]|r Deck-Name darf nicht leer sein."); return end

    local cards, skipped = {}, {}
    for id in codeStr:sub(sep+1):gmatch("[^,]+") do
        if ARKANA_CardData[id] and not BLOCKED_CARDS[id] then cards[#cards+1] = id
        else skipped[#skipped+1] = id end
    end

    if #skipped > 0 then
        print("|cffff8800[Arkana]|r " .. #skipped .. " unbekannte ID(s) uebersprungen: " .. table.concat(skipped, ", "))
    end
    if #cards == 0 then print("|cffff0000[Arkana]|r Keine gueltigen Karten im Code."); return end
    if #cards < 30 then
        print("|cffff8800[Arkana]|r Nur " .. #cards .. "/30 Karten — Deck wird importiert, kann aber nicht aktiviert werden.")
    end

    local counts = {}
    for _, id in ipairs(cards) do counts[id] = (counts[id] or 0) + 1 end
    for id, n in pairs(counts) do
        local cd = ARKANA_CardData[id]
        if n > ((cd.rarity == "LEGENDARY") and 1 or 2) then
            print("|cffff0000[Arkana]|r Kartenlimit verletzt: " .. (cd.name or id)); return
        end
    end

    -- Klasse VOR dem Sammlungs-Filter erkennen — sie soll auch dann stimmen,
    -- wenn ausgerechnet die Klassenkarten fehlen und weggelassen werden
    local classSet = {}
    for _, id in ipairs(cards) do
        local cd = ARKANA_CardData[id]
        if cd and cd.class and cd.class ~= "NEUTRAL" then classSet[cd.class] = true end
    end
    local detectedClass, n = "CLASSLESS", 0
    for c in pairs(classSet) do n = n + 1; detectedClass = c end
    if n ~= 1 then detectedClass = "CLASSLESS" end

    -- Sammlung: fehlende Karten weglassen statt den ganzen Import abzulehnen —
    -- Klasse + besessene Karten kommen an, der Rest wird gemeldet
    if addon.COL_Count then
        local kept, missing, dropped, seen = {}, {}, 0, {}
        for _, id in ipairs(cards) do
            seen[id] = (seen[id] or 0) + 1
            if seen[id] <= addon:COL_Count(id) then
                kept[#kept + 1] = id
            else
                dropped = dropped + 1
                local nm = (ARKANA_CardData[id].name or id)
                missing[nm] = (missing[nm] or 0) + 1
            end
        end
        if dropped > 0 then
            local parts = {}
            for nm, cnt in pairs(missing) do parts[#parts + 1] = nm .. (cnt > 1 and (" x" .. cnt) or "") end
            table.sort(parts)
            print("|cffff8800[Arkana]|r " .. dropped .. " Karte(n) fehlen in deiner Sammlung und wurden weggelassen: " ..
                  table.concat(parts, ", "))
            print("|cffff8800[Arkana]|r Deck hat " .. #kept .. "/30 Karten — unter Decks auffüllen, dann aktivieren.")
        end
        cards = kept
        if #cards == 0 then print("|cffff0000[Arkana]|r Keine der Karten ist in deiner Sammlung."); return end
    end

    local finalName, suffix = deckName, 1
    while true do
        local exists = false
        for _, d in ipairs(ARKANA_Decks) do if d.name == finalName then exists = true; break end end
        if not exists then break end
        finalName = deckName .. "_Import" .. suffix; suffix = suffix + 1
    end

    ARKANA_Decks = ARKANA_Decks or {}
    table.insert(ARKANA_Decks, { name = finalName, class = detectedClass, cards = cards })
    print("|cff00ff00[Arkana]|r Deck '" .. finalName .. "' importiert (Klasse: " .. (CLASS_DE[detectedClass] or detectedClass) .. ").")

    if dbFrame then dbFrame:RefreshSelector(); dbFrame:Refresh() end
end

function addon:OpenDeckBuilder()
    if not dbFrame then dbFrame = Build() end
    dbFrame:Show()
end
