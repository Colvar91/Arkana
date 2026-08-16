local addon = Arkana
local rankChannelAPI = addon.Spec_ConsumeRankChannelAPI and addon:Spec_ConsumeRankChannelAPI()
addon.Spec_ConsumeRankChannelAPI = nil

-- ═══════════════════════════════════════════════════════════════════════════════
-- Ranked-System (Vorbild: Classic-Ranglisten 2013-2020), Regeln mit User beschlossen:
-- - Rang 25 → 1, darüber Legende; Sterne je Rang: 25-21=2, 20-16=3, 15-11=4, 10-1=5
-- - Sieg +1★ (+1 Bonusstern ab 3 Siegen in Folge, nur bis Rang 6)
-- - Niederlage −1★ (bei Rang 25-21 kein Verlust); KEINE Floors (Abstieg immer möglich)
-- - Legende: Punkte = Siege−Niederlagen seit Aufstieg; Platzierung über alle Legenden
--   (Tiebreak: früherer Aufstieg, dann Name); kein Abstieg zurück auf Rang 1
-- Der Rang wird nicht als fertiger Wert gespeichert, sondern jederzeit aus der
-- vollständigen Ergebnis-Historie berechnet (Fold); es gibt keinen Zeit-Reset.
-- ═══════════════════════════════════════════════════════════════════════════════

local RANK_TEX = "Interface\\AddOns\\Arkana\\Textures\\Ranks\\rank"
local RANKED_SCOPE = "PERMANENT"

-- ── Anti-Boosting (⚠ MUSS auf ALLEN Clients identisch sein — Teil der Rang-Mathematik!)
-- Gegner-Sperre: Nach einem gewerteten Match gegen X ist X gesperrt, bis man
-- RK_LOCK_OTHERS VERSCHIEDENE andere Spieler besiegt hat (User-Regel statt Tages-Cap).
-- Rang-Nähe: Siege zählen nur gegen Gegner im Abstand ≤ RK_MAX_RANK_DIFF Rängen
-- (Legende zählt wie Rang 0; Ersatz fürs Matchmaking des Originals).
local RK_LOCK_OTHERS   = 5
local RK_MAX_RANK_DIFF = 5

-- Kartenrücken "Legendär" (CardBacks.lua id 5) — automatisch beim Legende-Aufstieg
local LEGEND_BACK_ID = 5

local Fold

local function RData()
    ARKANA_CharData = ARKANA_CharData or {}
    local r = ARKANA_CharData.ranked or {}
    ARKANA_CharData.ranked = r
    r.results = r.results or {}
    return r
end

local function StarsPerRank(rank)
    if rank >= 21 then return 2
    elseif rank >= 16 then return 3
    elseif rank >= 11 then return 4
    else return 5 end
end

-- Rang aus der Ergebnis-Historie falten — deterministisch, überall nachrechenbar.
-- best/bestLegend = bester jemals erreichter Stand
-- lastRated = war das LETZTE Ergebnis gewertet (für die Chat-Meldung)
Fold = function(results)
    local s = { rank = 25, stars = 0, streak = 0, legend = false, points = 0, since = nil,
                best = 25, bestLegend = false, lastRated = true }
    local locked = {}   -- [gegner] = { [andere]=true, n=Anzahl } — Gegner-Sperre aktiv
    for _, r in ipairs(results) do
        local opp = r.o or "?"
        -- Rang-Nähe: r.pr = Gegner-Rang beim Match (0 = Legende, nil = Alt-Eintrag → ok).
        -- pr > 25 = kaputter Alt-Eintrag (ACCEPT-Bug bis 2026-07-10 las den Deck-Hash
        -- als Rang) → wie nil behandeln, sonst bleiben diese Spiele für immer ungewertet
        local rankOk = true
        if r.pr ~= nil and r.pr <= 25 then
            local myCode = s.legend and 0 or s.rank
            local oppCode = r.pr
            rankOk = math.abs(myCode - oppCode) <= RK_MAX_RANK_DIFF
        end
        local rated = (locked[opp] == nil) and rankOk
        s.lastRated = rated
        if r.w == 1 then
            if rated then
                s.streak = s.streak + 1
                if s.legend then
                    s.points = s.points + 1
                else
                    local gain = 1 + ((s.streak >= 3 and s.rank > 5) and 1 or 0)
                    s.stars = s.stars + gain
                    while not s.legend and s.stars > StarsPerRank(s.rank) do
                        s.stars = s.stars - StarsPerRank(s.rank)
                        if s.rank == 1 then
                            s.legend, s.points, s.since = true, 0, r.t
                            s.bestLegend = true
                        else
                            s.rank = s.rank - 1
                            if s.rank < s.best then s.best = s.rank end
                        end
                    end
                end
                -- Sieg schaltet gesperrte Gegner frei (zählt als "anderer Spieler")
                for lockedOpp, set in pairs(locked) do
                    if lockedOpp ~= opp and not set[opp] then
                        set[opp] = true
                        set.n = (set.n or 0) + 1
                        if set.n >= RK_LOCK_OTHERS then locked[lockedOpp] = nil end
                    end
                end
                locked[opp] = {}   -- Gegner sperren, bis RK_LOCK_OTHERS andere besiegt
            end
        elseif r.w == 0 then
            -- JEDE Niederlage bricht die Serie — auch eine ungewertete (Gegner-Sperre/
            -- Rang-Abstand). Sonst hält ein Rückspiel gegen denselben Gegner den
            -- Bonusstern am Leben, obwohl man dazwischen verloren hat.
            s.streak = 0
            if rated then
                if s.legend then
                    s.points = s.points - 1
                elseif s.rank <= 20 then   -- Rang 25-21 verliert keine Sterne (Original)
                    s.stars = s.stars - 1
                    if s.stars < 0 then    -- KEINE Floors: Abstieg jederzeit möglich
                        s.rank = s.rank + 1
                        s.stars = StarsPerRank(s.rank) - 1
                    end
                end
                locked[opp] = locked[opp] or {}   -- auch nach Niederlage gesperrt
            end
        end
    end
    return s
end

local function MyName()
    return ((UnitName("player") or ""):match("^[^-]+") or ""):lower()
end

-- ── Öffentliche Zustands-/Anzeige-Helfer ─────────────────────────────────────────

function addon:RK_State(results)
    return Fold(results or RData().results)
end

function addon:RK_Icon(st)
    st = st or Fold(RData().results)
    return RANK_TEX .. (st.legend and "Legende" or st.rank) .. ".tga"   -- Legende: eigenes Medaillon (rankLegende.tga)
end

-- Sterne als Textur-Escapes — die Unicode-Sterne ★/☆ fehlen in FRIZQT (→ Kästchen)
local STAR_ON  = "|TInterface\\COMMON\\Indicator-Yellow:12|t"
local STAR_OFF = "|TInterface\\COMMON\\Indicator-Gray:12|t"
local function StarText(stars, max)
    return string.rep(STAR_ON, stars) .. string.rep(STAR_OFF, max - stars)
end

function addon:RK_Text(st)
    st = st or Fold(RData().results)
    if st.legend then
        local place = addon:RK_LegendPlace()
        return "Legende" .. (place and (" #" .. place) or "") ..
               " (" .. (st.points >= 0 and "+" or "") .. st.points .. ")"
    end
    return "Rang " .. st.rank .. "  " .. StarText(st.stars, StarsPerRank(st.rank))
end

-- Getrennte Zeilen für das Hauptmenü: Rang oben, Fortschritt/Punkte darunter.
function addon:RK_PointsText(st)
    st = st or Fold(RData().results)
    if st.legend then
        return "Punkte: " .. (st.points >= 0 and "+" or "") .. st.points
    end
    local maximum = StarsPerRank(st.rank)
    return "Punkte: " .. st.stars .. "/" .. maximum .. "  " .. StarText(st.stars, maximum)
end

-- ── Match-Aufzeichnung ───────────────────────────────────────────────────────────

local currentMatch = nil   -- { peer, sid, pr } — nur gesetzt, wenn das Spiel GEWERTET ist

-- peerRank = angesagter Rang des Gegners beim Match-Start (0 = Legende, nil = alter Client)
function addon:RK_MatchStart(peer, sessionId, ranked, peerRank)
    currentMatch = ranked and { peer = (tostring(peer or "")):lower(), sid = tostring(sessionId or ""),
                                pr = tonumber(peerRank) } or nil
    if not ranked then return end
    -- VORAB prüfen, ob das Ergebnis zählen würde (Gegner-Sperre/Rang-Abstand) — die
    -- Anzeige darf nie "gewertet" sagen, wenn das Ergebnis am Ende ungewertet wäre.
    -- Probe-Ergebnis anhängen, falten, wieder entfernen (Fold ist rein lesend sonst).
    local r = RData()
    r.results[#r.results + 1] = { w = 1, o = currentMatch.peer, sid = "?", t = time(), pr = currentMatch.pr }
    local rated = Fold(r.results).lastRated
    table.remove(r.results)
    if rated then
        print("|cffffd700[Arkana-Ranked]|r Gewertetes Spiel gegen " .. tostring(peer) .. "!")
    else
        print("|cffffff00[Arkana-Ranked]|r Duell gegen " .. tostring(peer) ..
              ": Ergebnis zählt für DICH NICHT — Gegner-Sperre (erst " .. RK_LOCK_OTHERS ..
              " andere Spieler besiegen) oder Rang-Abstand > " .. RK_MAX_RANK_DIFF .. ".")
    end
end

-- Aus GE_EndGame (result = "w"/"l"/"d"); Unentschieden ändert nichts
function addon:RK_OnGameEnd(result)
    addon.RK_LastDelta = nil   -- fürs End-Screen; nil = ungewertetes/kein Spiel
    if not currentMatch then return end
    local m = currentMatch
    currentMatch = nil
    if addon.IsSpectating and addon:IsSpectating() then return end
    if result ~= "w" and result ~= "l" then return end
    local r = RData()
    local before = Fold(r.results)   -- Stand VOR diesem Ergebnis (für die Delta-Anzeige)
    r.results[#r.results + 1] = { w = result == "w" and 1 or 0, o = m.peer, sid = m.sid, t = time(), pr = m.pr }
    local st = Fold(r.results)
    -- Delta-Text: was hat dieses Spiel geändert? (Chat + End-Screen)
    local delta
    if not st.lastRated then
        delta = "|cffaaaaaaUngewertet: Gegner-Sperre (erst " .. RK_LOCK_OTHERS ..
                " andere Spieler besiegen) oder Rang-Abstand > " .. RK_MAX_RANK_DIFF .. "|r"
    elseif st.legend and not before.legend then
        delta = "|cffffd700Legende erreicht!|r"
    elseif st.legend then
        local d = st.points - before.points
        delta = (d >= 0 and "|cff20ff20+" or "|cffff4040") .. d ..
                (math.abs(d) == 1 and " Legendenpunkt" or " Legendenpunkte") .. "|r"
    elseif st.rank < before.rank then
        delta = "|cff20ff20Aufstieg! Rang " .. before.rank .. " → Rang " .. st.rank .. "|r"
    elseif st.rank > before.rank then
        delta = "|cffff4040Abstieg: Rang " .. before.rank .. " → Rang " .. st.rank .. "|r"
    else
        local d = st.stars - before.stars
        if d > 0 then
            delta = "|cff20ff20+" .. d .. (d == 1 and " Stern" or " Sterne (Siegesserie!)") .. "|r"
        elseif d < 0 then
            delta = "|cffff4040" .. d .. " Stern|r"
        else
            delta = "|cffaaaaaaKein Sternverlust (Rang 25-21)|r"
        end
    end
    addon.RK_LastDelta = delta .. "  —  " .. addon:RK_Text(st)
    print("|cffffd700[Arkana-Ranked]|r " .. (result == "w" and "Sieg!" or "Niederlage.") ..
          "  " .. delta .. "  →  " .. addon:RK_Text(st))
    -- Legende-Belohnung: Kartenrücken automatisch freischalten (idempotent)
    if st.legend and addon.CB_GrantLegendBack then addon:CB_GrantLegendBack(LEGEND_BACK_ID) end
    addon:RK_Announce()
end

-- ── Rang-Ansagen (Ladder-Anzeige) ───────────────────────────────────────────────

local known = {}   -- [name] = { legend, rank, stars, points, since, t }
addon.RK_Known = known

local lastAnnounce = 0
function addon:RK_Announce(throttled)
    if not rankChannelAPI then return end
    if not (ARKANA_Settings and ARKANA_Settings.rankSharing == true) then return end
    local minimumInterval = throttled and 60 or 10
    if time() - lastAnnounce < minimumInterval then return end
    lastAnnounce = time()
    local st = Fold(RData().results)
    rankChannelAPI.Announce(string.format("RKINFO|%s|%d|%d|%d|%d|%d|%s",
        RANKED_SCOPE, st.legend and 1 or 0, st.rank, st.stars, st.points, st.since or 0,
        "-"))
end

function addon:RK_OnInfo(p, sender)
    local name = ((sender or ""):match("^[^-]+") or ""):lower()
    if name == "" or name == MyName() or (p[2] or "") ~= RANKED_SCOPE then return end
    known[name] = { legend = p[3] == "1", rank = tonumber(p[4]) or 25,
                    stars = tonumber(p[5]) or 0, points = tonumber(p[6]) or 0,
                    since = tonumber(p[7]) or 0, t = time() }
    if addon.RK_LadderRefresh then addon:RK_LadderRefresh() end
end

-- Legend-Platzierung: Punkte absteigend, früherer Aufstieg, dann Name
function addon:RK_LegendPlace()
    local st = Fold(RData().results)
    if not st.legend then return nil end
    local me = MyName()
    local list = { { n = me, p = st.points, s = st.since or 0 } }
    for n, k in pairs(known) do
        if k.legend then list[#list + 1] = { n = n, p = k.points, s = k.since or 0 } end
    end
    table.sort(list, function(a, b)
        if a.p ~= b.p then return a.p > b.p end
        if a.s ~= b.s then return a.s < b.s end
        return a.n < b.n
    end)
    for i, e in ipairs(list) do if e.n == me then return i end end
end

-- ── Ranglisten-Fenster ───────────────────────────────────────────────────────────

local LADDER_UI = addon:UI_RegisterThemePalette({})

local function CreateLadderButton(parent, text, width, height, onClick)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(width, height)
    local border = button:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints(); addon:UI_BindThemeTexture(border, LADDER_UI.purpleSoft)
    local bg = button:CreateTexture(nil, "BACKGROUND", nil, 1)
    bg:SetPoint("TOPLEFT", 1, -1); bg:SetPoint("BOTTOMRIGHT", -1, 1)
    addon:UI_BindThemeTexture(bg, LADDER_UI.button)
    local label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER"); label:SetText(text); label:SetTextColor(0.92, 0.89, 1, 1)
    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetPoint("TOPLEFT", 1, -1); highlight:SetPoint("BOTTOMRIGHT", -1, 1)
    addon:UI_BindThemeTexture(highlight, LADDER_UI.purple, 0.18)
    button:SetScript("OnEnter", function()
        border:SetColorTexture(unpack(LADDER_UI.purple))
        label:SetTextColor(1, 1, 1, 1)
    end)
    button:SetScript("OnLeave", function()
        border:SetColorTexture(unpack(LADDER_UI.purpleSoft))
        label:SetTextColor(0.92, 0.89, 1, 1)
    end)
    button:SetScript("OnClick", onClick)
    return button
end

local function EnableLadderScrolling(scroll)
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
        self:SetVerticalScroll(math.max(0, math.min(maximum, self:GetVerticalScroll() - delta * 64)))
    end)
end

local LADDER_ICON = 54
local LADDER_ROW_H = 72

local ladder

local function LadderRows()
    -- Eigener Eintrag + alle bekannten Ansagen; Legenden zuerst (nach Punkten),
    -- dann nach Rang aufsteigend / Sternen absteigend
    local st = Fold(RData().results)
    local rows = { { n = MyName(), legend = st.legend, rank = st.rank, stars = st.stars,
                     points = st.points, since = st.since or 0, me = true } }
    for n, k in pairs(known) do
        rows[#rows + 1] = { n = n, legend = k.legend, rank = k.rank, stars = k.stars,
                            points = k.points, since = k.since or 0 }
    end
    table.sort(rows, function(a, b)
        if a.legend ~= b.legend then return a.legend end
        if a.legend then
            if a.points ~= b.points then return a.points > b.points end
            if a.since ~= b.since then return a.since < b.since end
            return a.n < b.n
        end
        if a.rank ~= b.rank then return a.rank < b.rank end
        if a.stars ~= b.stars then return a.stars > b.stars end
        return a.n < b.n
    end)
    return rows
end

function addon:RK_LadderRefresh()
    if not ladder or not ladder:IsShown() then return end
    local rows = LadderRows()
    for _, line in ipairs(ladder.lines) do line:Hide() end
    local legendPlace = 0
    for i, r in ipairs(rows) do
        local line = ladder.lines[i]
        if not line then
            line = CreateFrame("Frame", nil, ladder.content, "BackdropTemplate")
            line:SetSize(376, LADDER_ROW_H - 6)
            line:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8X8",
                edgeFile = "Interface\\Buttons\\WHITE8X8",
                edgeSize = 1,
            })
            line:SetBackdropColor(unpack(LADDER_UI.row))
            line:SetBackdropBorderColor(unpack(LADDER_UI.purpleSoft))
            local hover = line:CreateTexture(nil, "HIGHLIGHT")
            hover:SetPoint("TOPLEFT", 1, -1)
            hover:SetPoint("BOTTOMRIGHT", -1, 1)
            addon:UI_BindThemeTexture(hover, LADDER_UI.purple, 0.12)
            line.icon = line:CreateTexture(nil, "ARTWORK")
            line.icon:SetSize(50, 50)
            line.icon:SetPoint("LEFT", 10, 0)
            line.name = line:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            line.name:SetPoint("TOPLEFT", line, "TOPLEFT", 65, -10)
            line.name:SetPoint("TOPRIGHT", line, "TOPRIGHT", -65, -10)
            line.name:SetJustifyH("CENTER")
            line.info = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            line.info:SetPoint("TOPLEFT", line.name, "BOTTOMLEFT", 0, -5)
            line.info:SetPoint("TOPRIGHT", line.name, "BOTTOMRIGHT", 0, -5)
            line.info:SetJustifyH("CENTER")
            ladder.lines[i] = line
        end
        line:SetPoint("TOPLEFT", 4, -(i - 1) * LADDER_ROW_H - 3)
        line.icon:SetTexture(RANK_TEX .. (r.legend and "Legende" or r.rank) .. ".tga")
        local disp = r.n:sub(1, 1):upper() .. r.n:sub(2)
        local info
        if r.legend then
            legendPlace = legendPlace + 1
            info = "Legende #" .. legendPlace .. " (" .. (r.points >= 0 and "+" or "") .. r.points .. ")"
        else
            info = "Rang " .. r.rank .. "  " .. StarText(r.stars, StarsPerRank(r.rank))
        end
        line.name:SetText((r.me and "|cffffd700" or "|cffffffff") .. disp .. "|r")
        line.info:SetText(info)
        line:SetBackdropColor(r.me and 0.085 or LADDER_UI.row[1], r.me and 0.060 or LADDER_UI.row[2],
            r.me and 0.125 or LADDER_UI.row[3], 0.96)
        line:SetBackdropBorderColor(unpack(r.me and { 0.66, 0.45, 0.16, 1 } or LADDER_UI.purpleSoft))
        line:Show()
    end
    ladder.content:SetHeight(#rows * LADDER_ROW_H + 8)
end

-- Legende-Rücken ggf. nachträglich freischalten. Diese Anmeldung bleibt unabhängig
-- von der entfernten Ranganzeige im Spieler-Tooltip bestehen.
local rankLoginEv = CreateFrame("Frame")
rankLoginEv:RegisterEvent("PLAYER_LOGIN")
rankLoginEv:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    C_Timer.After(3, function()
        local st = Fold(RData().results)
        if st.legend and addon.CB_GrantLegendBack then addon:CB_GrantLegendBack(LEGEND_BACK_ID) end
    end)
end)

function addon:RK_ShowLadder()
    if addon.MM_Hide then addon:MM_Hide() end
    if not ladder then
        local f = CreateFrame("Frame", "ARKANA_RankLadder", UIParent, "BackdropTemplate")
        f:SetSize(420, 500)
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
        f:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1,
        })
        f:SetBackdropColor(unpack(LADDER_UI.panel))
        f:SetBackdropBorderColor(unpack(LADDER_UI.panelBorder))
        f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
        f:SetToplevel(true)   -- angeklicktes Fenster kommt nach vorn
        f:SetClampedToScreen(true)
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        f:SetFrameStrata("DIALOG")
        if addon.UI_RegisterScalableFrame then addon:UI_RegisterScalableFrame(f) end

        local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOPLEFT", 20, -12)
        title:SetText("Arkana")
        title:SetTextColor(unpack(LADDER_UI.title))
        local subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        subtitle:SetPoint("LEFT", title, "RIGHT", 8, 0)
        subtitle:SetText("Rangliste")
        local closeX = CreateLadderButton(f, "×", 28, 24, function() f:Hide() end)
        closeX:SetPoint("TOPRIGHT", -10, -9)
        local topLine = f:CreateTexture(nil, "ARTWORK")
        topLine:SetHeight(2); topLine:SetPoint("TOPLEFT", 18, -46); topLine:SetPoint("TOPRIGHT", -18, -46)
        addon:UI_BindThemeTexture(topLine, LADDER_UI.purple)
        local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        hint:SetPoint("TOPLEFT", 20, -57)
        hint:SetText("Ränge der Arkana-Spieler")

        local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 16, -76)
        scroll:SetPoint("BOTTOMRIGHT", -16, 56)
        f.content = CreateFrame("Frame", nil, scroll)
        scroll:SetScrollChild(f.content)
        f.content:SetSize(384, 10)
        EnableLadderScrolling(scroll)
        f.lines = {}

        local close = CreateLadderButton(f, "Schließen", 150, 30, function() f:Hide() end)
        close:SetPoint("BOTTOM", 0, 14)

        f:SetScript("OnShow", function() addon:RK_LadderRefresh() end)
        f:SetScript("OnHide", function() addon:OpenMainMenu() end)
        table.insert(UISpecialFrames, f:GetName())
        ladder = f
    end
    ladder:Show()
    addon:RK_LadderRefresh()
    -- Anwesende um ihre Rang-Ansage bitten (Antwort: RKINFO, gedrosselt)
    if rankChannelAPI then rankChannelAPI.Request() end
    C_Timer.After(1.5, function() addon:RK_LadderRefresh() end)
end
