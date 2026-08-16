local addon = Arkana

local outFrame, inFrame
local CLASS_LABEL = {
    DRUID="Druide", HUNTER="Jäger", MAGE="Magier", PALADIN="Paladin",
    PRIEST="Priester", ROGUE="Schurke", SHAMAN="Schamane", WARLOCK="Hexenmeister",
    WARRIOR="Krieger", CLASSLESS="Test",
}

-- ── outgoing (wir haben herausgefordert) ─────────────────────────────────────

local function MakeOutgoing()
    local f = CreateFrame("Frame", "ARKANA_OutgoingChallenge", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(300, 120)
    f:SetPoint("CENTER")
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    if addon.UI_RegisterScalableFrame then addon:UI_RegisterScalableFrame(f) end
    f.TitleText:SetText("Herausforderung")

    f.msg = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.msg:SetPoint("TOP", f, "TOP", 0, -42)
    f.msg:SetWidth(260)
    f.msg:SetJustifyH("CENTER")

    local btn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btn:SetSize(120, 26)
    btn:SetPoint("BOTTOM", f, "BOTTOM", 0, 14)
    btn:SetText("Abbrechen")
    btn:SetScript("OnClick", function() addon:DeclineChallenge() end)
    return f
end

-- ── incoming (wir wurden herausgefordert) ────────────────────────────────────

local function MakeIncoming()
    local f = CreateFrame("Frame", "ARKANA_IncomingChallenge", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(300, 140)
    f:SetPoint("CENTER")
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    if addon.UI_RegisterScalableFrame then addon:UI_RegisterScalableFrame(f) end
    f.TitleText:SetText("Herausforderung")

    f.msg = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.msg:SetPoint("TOP", f, "TOP", 0, -42)
    f.msg:SetWidth(260)
    f.msg:SetJustifyH("CENTER")

    local btnAccept = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnAccept:SetSize(110, 26)
    btnAccept:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -5, 14)
    btnAccept:SetText("Annehmen")
    btnAccept:SetScript("OnClick", function() addon:AcceptChallenge() end)

    local btnDecline = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnDecline:SetSize(110, 26)
    btnDecline:SetPoint("BOTTOMLEFT", f, "BOTTOM", 5, 14)
    btnDecline:SetText("Ablehnen")
    btnDecline:SetScript("OnClick", function() addon:DeclineChallenge() end)
    return f
end

-- ── public ────────────────────────────────────────────────────────────────────

local function HideMainMenu()
    local mf = _G["ARKANA_MainMenu"]
    if mf then mf:Hide() end
end

function addon:ShowOutgoingChallenge(peer)
    if not outFrame then outFrame = MakeOutgoing() end
    if inFrame then inFrame:Hide() end
    HideMainMenu()
    outFrame.msg:SetText("Warte auf Antwort von\n|cffffff00" .. peer .. "|r ...")
    outFrame:Show()
end

function addon:ShowIncomingChallenge(sender, heroClass, ranked)
    if not inFrame then inFrame = MakeIncoming() end
    if outFrame then outFrame:Hide() end
    HideMainMenu()
    inFrame.msg:SetText("|cffffff00" .. sender .. "|r\nfordert dich heraus als " ..
        (CLASS_LABEL[heroClass] or heroClass or "?") .. "!" ..
        (ranked and "\n|cffffd700Gewertetes Spiel (Ranked)|r" or ""))
    inFrame:Show()
end

function addon:HideChallengeWindow()
    if outFrame then outFrame:Hide() end
    if inFrame  then inFrame:Hide()  end
end

-- Herausforderungen werden ausschließlich an das aktuell angewählte Spielerziel
-- gesendet. Dadurch gibt es weder eine freie Namenseingabe noch Tippfehler.
function addon:ChallengeTarget()
    if not UnitExists("target") or not UnitIsPlayer("target") or UnitIsUnit("target", "player") then
        print("|cffff0000[Arkana]|r Wähle zuerst einen anderen Spieler als Ziel aus.")
        return false
    end

    local name, realm = UnitName("target")
    if not name or name == "" then
        print("|cffff0000[Arkana]|r Das ausgewählte Spielerziel konnte nicht gelesen werden.")
        return false
    end
    if realm and realm ~= "" then name = name .. "-" .. realm end
    return addon:StartChallenge(name) == true
end
