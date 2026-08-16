local addon = Arkana
local PREFIX          = "ARKANA"
local PROTOCOL_VER    = 3   -- v3: Zuschauerfreigabe wird von beiden Spielern bestätigt

-- prio (optional): "ALERT" für duell-kritische Nachrichten — die teilen sich die
-- Chat-Drossel sonst mit den dicken Login-Audits und warten
-- bei gedrosseltem Hintergrund-Client (2 WoW-Fenster) spürbar lange in der Queue.
function addon:SendComm(msg, target, prio)
    if not target or target == "" then return end
    self:SendCommMessage(PREFIX, msg, "WHISPER", target, prio)
end

-- ── name helpers ──────────────────────────────────────────────────────────────

local function Norm(name)
    local realm = GetRealmName()
    local n, r  = name:match("^(.+)-(.+)$")
    local result = (n and r == realm) and n or name
    return result:lower()
end

local function Me() return Norm(UnitName("player")) end

-- In ausdrücklich als OOC-Bereich markierten Orten dürfen keine Arkana-Duelle
-- initiiert werden. Je nach Karten-/Serverkonfiguration steht der Ortsname als
-- Unterzone, Minimaptext oder Zone bereit; deshalb werden alle Anzeigen exakt
-- und ohne Teiltreffer geprüft.
local function LocationKey(value)
    return tostring(value or ""):lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
end

function addon:CH_CanChallengeHere()
    local locations = {
        (GetSubZoneText and GetSubZoneText()) or "",
        (GetMinimapZoneText and GetMinimapZoneText()) or "",
        (GetZoneText and GetZoneText()) or "",
        (GetRealZoneText and GetRealZoneText()) or "",
    }
    for _, location in ipairs(locations) do
        if LocationKey(location) == "ooc-gebiet" then
            return false, location
        end
    end
    return true
end

local function RandId()
    return string.format("%08x", math.random(0, 2147483647))
end

-- ── deck helpers ──────────────────────────────────────────────────────────────

-- Besitz-Prüfung unmittelbar vor dem Duell. Der Deck-Builder prüft die Sammlung
-- zwar beim Zusammenstellen, aber Decks liegen in den SavedVariables — wer sie dort
-- ändert, umgeht das UI komplett. Gleiche Regel wie Deck-Builder/Import:
-- COL_Count zählt FREE-Karten nur mit gültigem Basispaket als 2 Kopien.
local function UnownedCard(deck)
    if not addon.COL_Count then return nil end
    local seen = {}
    for _, id in ipairs(deck.cards or {}) do
        seen[id] = (seen[id] or 0) + 1
        if seen[id] > addon:COL_Count(id) then
            local cd = ARKANA_CardData and ARKANA_CardData[id]
            return (cd and cd.name) or id
        end
    end
    return nil
end

local function ActiveDeck()
    local idx = ARKANA_CharData and ARKANA_CharData.activeDeckIndex
    local deck = idx and ARKANA_Decks[idx] or nil
    if deck then
        local missing = UnownedCard(deck)
        if missing then
            print("|cffff0000[Arkana]|r Deck '" .. tostring(deck.name) .. "' enthält Karten, die nicht in deiner " ..
                  "Sammlung sind (" .. tostring(missing) .. ") — nicht spielbar. Bitte unter Decks neu zusammenstellen.")
            return nil
        end
    end
    return deck
end

local function DeckHash(cards)
    local s = {}
    for i, id in ipairs(cards) do s[i] = id end
    table.sort(s)
    return ARKANA_CRC32(table.concat(s, "|"))
end

local function ValidateDeck(cards, heroClass, expectedHash)
    if heroClass == "CLASSLESS" then
        return false, "Ungültige Klasse (CLASSLESS ist keine spielbare Klasse)"
    end
    if #cards ~= 30 then
        return false, "Nicht 30 Karten (" .. #cards .. ")"
    end
    if DeckHash(cards) ~= expectedHash then
        return false, "Deck-Hash stimmt nicht"
    end
    local counts = {}
    for _, id in ipairs(cards) do
        local card = ARKANA_CardData[id]
        if not card then return false, "Unbekannte Karte: " .. id end
        if card.class ~= "NEUTRAL" and card.class ~= heroClass then
            return false, "Falsche Klasse (" .. id .. ")"
        end
        counts[id] = (counts[id] or 0) + 1
        if counts[id] > (card.rarity == "LEGENDARY" and 1 or 2) then
            return false, "Zu viele Kopien: " .. id
        end
    end
    return true
end

-- ── challenge state ───────────────────────────────────────────────────────────

local cs = {}

local gs_peerName       = nil
local gs_sessionId      = nil
local gs_myActionNo     = 0
local gs_turnTimer      = nil
local gs_disconnTimer   = nil
local gs_keepaliveTicker = nil

-- Handshake ist duell-kritisch → ALERT (gleiche Prio wie SendInGame, damit die
-- Reihenfolge in der Drossel-Queue erhalten bleibt)
local function ToPeer(msg) addon:SendComm(msg, cs.peer, "ALERT") end

local gs_startResend = nil   -- GAME_START-Wiederholung, bis der Gegner antwortet

local function StopStartResend()
    if gs_startResend then gs_startResend:Cancel(); gs_startResend = nil end
end

local function ClearCS()
    if cs.deckTimer then cs.deckTimer:Cancel() end
    cs = {}
end

local function StopGameTimers()
    if gs_turnTimer      then gs_turnTimer:Cancel();      gs_turnTimer      = nil end
    if gs_disconnTimer   then gs_disconnTimer:Cancel();   gs_disconnTimer   = nil end
    if gs_keepaliveTicker then gs_keepaliveTicker:Cancel(); gs_keepaliveTicker = nil end
end

local function ResetDisconnTimer()
    if gs_disconnTimer then gs_disconnTimer:Cancel() end
    -- 30s statt 10s: Ladebildschirme/Chat-Drosselung überbrücken locker mehr
    -- als 10s und lösten sonst falsche Unentschieden aus
    gs_disconnTimer = C_Timer.NewTimer(30, function()
        print("|cffff0000[Arkana]|r Verbindung verloren (30s Timeout).")
        addon:GE_EndGame("DRAW")
        StopGameTimers()
    end)
end

-- Empfangene Peer-Nachricht der laufenden Session: Lebenszeichen + Beleg, dass
-- der Gegner das GAME_START hat (Resend-Ticker stoppen)
local function PeerAlive()
    StopStartResend()
    ResetDisconnTimer()
end

local function SendInGame(msgType, ...)
    if not gs_peerName or not gs_sessionId then return end
    gs_myActionNo = gs_myActionNo + 1
    local parts = {msgType, gs_sessionId, tostring(gs_myActionNo)}
    for _, v in ipairs({...}) do parts[#parts+1] = tostring(v) end
    addon:SendComm(table.concat(parts, "|"), gs_peerName, "ALERT")
    ResetDisconnTimer()
end

-- Zuschauer-Spiegelung: jede angewandte Aktion (eigene + Peer) an Spectator melden.
-- No-op auf allen Clients außer dem Host (Spec_RecordAction prüft host-Status selbst).
local function RecordOwn(actionType, ...)
    local st = addon:GE_State()
    if st and addon.Spec_RecordAction then addon:Spec_RecordAction(st.myPlayerIdx, actionType, ...) end
end
local function RecordPeer(actionType, ...)
    local st = addon:GE_State()
    if st and addon.Spec_RecordAction then addon:Spec_RecordAction(3 - st.myPlayerIdx, actionType, ...) end
end

-- ── Cheat-Meldungen: Regelverstoß + Zustands-Abweichung ─────────────────────────
-- Zwei unabhängige Netze:
--  R = die Regelprüfung in GE_ApplyAs hat eine unerlaubte AKTION gesehen
--      (Karte ohne Mana, zweiter Angriff, Zug beenden ohne am Zug zu sein …)
--  X = gleiche Aktionen, anderes ERGEBNIS → beim Gegner rechnen manipulierte Regeln
--      oder Kartendaten (fängt genau das, was die Regelprüfung nicht sehen kann)
-- Bewusst je Spiel und Art nur EINE lokale Meldung — sonst wird aus dem Alarm
-- ein Spam-Vektor. Es werden keine Spielerdaten an Dritte übertragen.
-- (Muss VOR dem Empfangs-Handler stehen: ein `local function` unterhalb seines Aufrufers
--  ist in Lua nil.)
local cheatReported = {}
local function ActorName(pIdx)
    local st = addon:GE_State()
    if gs_peerName and st and pIdx ~= st.myPlayerIdx then return gs_peerName end
    if addon.Spec_NameFor then return addon:Spec_NameFor(pIdx) or "?" end
    return "?"
end

local function ReportCheat(kind, who, detail)
    local key = kind .. "|" .. tostring(who)
    if cheatReported[key] then return end
    cheatReported[key] = true
    print("|cffff0000[Arkana]|r Unregelmäßigkeit im Spiel mit " .. tostring(who) .. ": " .. detail)
    if addon.GameLog then
        addon:GameLog("|cffff0000Unregelmäßigkeit (" .. tostring(who) .. "): " .. detail .. "|r")
    end
end

function addon:GE_OnRuleViolation(pIdx, actionType, err)
    ReportCheat("R", ActorName(pIdx), tostring(actionType) .. ": " .. tostring(err))
end

local function StartGameTimers()
    StopGameTimers()
    ResetDisconnTimer()
    gs_keepaliveTicker = C_Timer.NewTicker(5, function()
        if gs_peerName and gs_sessionId then
            addon:SendComm("PING|" .. gs_sessionId, gs_peerName)
        end
    end)
end

local function StartDeckTimer()
    cs.deckTimer = C_Timer.NewTimer(30, function()
        print("|cffff0000[Arkana]|r Challenge abgebrochen: Kein Deck empfangen (30s).")
        ToPeer("DECLINE|" .. cs.challengeId)
        addon:HideChallengeWindow()
        ClearCS()
    end)
end

local function TryStartGame()
    if not (cs.myDeckSent and cs.peerDeckOk) then return end
    if cs.role ~= "challenger" then return end
    local seed = math.random(1, 2000000000)
    -- Auslosung wer beginnt (vorher: Herausforderer immer "first"). P1 beginnt,
    -- P2 bekommt die Münze (Engine). Die Rolle des Gegners geht explizit in
    -- Feld 5 mit — Empfänger liest sie (Protokoll v2).
    local iAmFirst = math.random(0, 1) == 1
    local myRole   = iAmFirst and "first" or "second"
    local startMsg = string.format("GAME_START|%s|%s|%d|%s",
        cs.challengeId, cs.sessionId, seed, iAmFirst and "second" or "first")
    ToPeer(startMsg)
    addon:Info("|cff00ff00[Arkana]|r Spiel startet! Session: " .. cs.sessionId .. "  Seed: " .. seed)
    addon:Info(iAmFirst and "|cff00ff00[Arkana]|r Auslosung: Du beginnst!"
                         or "|cff00ff00[Arkana]|r Auslosung: Gegner beginnt — du bekommst die Münze.")
    local deck = ActiveDeck()
    local spectatorSharing = ARKANA_Settings and ARKANA_Settings.spectatorSharing == true
                          and cs.peerSpectatorSharing == true
    addon:GE_StartGame(cs.sessionId, seed, myRole, deck.cards, cs.peerDeck, deck.class, cs.peerHeroClass)
    gs_peerName   = cs.peer
    gs_sessionId  = cs.sessionId
    gs_myActionNo = 0
    cheatReported = {}
    -- Host (Herausforderer, unabhängig von der Rolle): spiegelt den Aktions-Stream
    -- für Zuschauer. Decks/Klassen in P1/P2-Reihenfolge (first zuerst)!
    if addon.Spec_OnGameStart then
        if iAmFirst then
            addon:Spec_OnGameStart(true, cs.sessionId, seed, deck.cards, cs.peerDeck, deck.class, cs.peerHeroClass, cs.ranked, spectatorSharing)
        else
            addon:Spec_OnGameStart(true, cs.sessionId, seed, cs.peerDeck, deck.cards, cs.peerHeroClass, deck.class, cs.ranked, spectatorSharing)
        end
    end
    if addon.CB_OnGameStart then addon:CB_OnGameStart(gs_peerName) end
    if addon.RK_MatchStart then addon:RK_MatchStart(cs.peer, cs.sessionId, cs.ranked, cs.peerRank) end
    StartGameTimers()
    -- GAME_START wiederholen, bis der Gegner erstmals antwortet (PeerAlive in den
    -- Empfangs-Zweigen stoppt den Ticker) — geht das Paket verloren/hängt es,
    -- wartete der Gegner sonst ewig auf den Spielstart. Duplikate sind harmlos:
    -- der Empfänger hat sein cs nach dem ersten GAME_START geleert und ignoriert den Rest.
    do
        local peer, tries = cs.peer, 0
        StopStartResend()
        gs_startResend = C_Timer.NewTicker(5, function()
            tries = tries + 1
            if tries > 6 or not gs_sessionId then StopStartResend(); return end
            addon:SendComm(startMsg, peer, "ALERT")
        end)
    end
    addon:HideChallengeWindow()
    ClearCS()
end

local function SendMyDeck()
    local deck = ActiveDeck()
    if not deck then
        print("|cffff0000[Arkana]|r Kein aktives Deck — Challenge abgebrochen.")
        ToPeer("DECLINE|" .. cs.challengeId)
        addon:HideChallengeWindow()
        ClearCS()
        return
    end
    ToPeer(string.format("DECK|%s|%s", cs.challengeId, table.concat(deck.cards, ",")))
    cs.myDeckSent = true
    StartDeckTimer()
    TryStartGame()
end

-- Eigener Rang für den Handshake (0 = Legende); Anti-Boosting-Rang-Nähe-Regel
local function MyRankCode()
    if not addon.RK_State then return 25 end
    local st = addon:RK_State()
    return st.legend and 0 or st.rank
end

-- ── public API ────────────────────────────────────────────────────────────────

function addon:StartChallenge(target)
    local locationAllowed, location = addon:CH_CanChallengeHere()
    if not locationAllowed then
        print("|cffff0000[Arkana]|r Im Gebiet \"" .. tostring(location or "OOC-Gebiet") ..
              "\" können keine Spieler herausgefordert werden.")
        return false
    end
    if not target or target == "" then
        print("|cffff0000[Arkana]|r Wähle zuerst einen anderen Spieler als Ziel aus.")
        return false
    end
    if not ActiveDeck() then
        print("|cffff0000[Arkana]|r Kein aktives Deck gesetzt.")
        return false
    end
    if cs.peer then
        print("|cffff0000[Arkana]|r Bereits eine aktive Herausforderung.")
        return false
    end
    local deck = ActiveDeck()
    ClearCS()
    cs.role        = "challenger"
    cs.peer        = Norm(target)
    cs.challengeId = RandId()
    cs.sessionId   = RandId()

    -- Normale Spieler-Herausforderungen sind immer ungewertet. Eine spätere
    -- Turnierleiter-Freigabe bekommt einen eigenen, kontrollierten Ablauf.
    -- Feld 8: eigener Rang (0 = Legende) für die Rang-Nähe-Regel (Anti-Boosting)
    cs.ranked = false
    -- Feld 9: Build-Kennung; Feld 10: sichtbare Zuschauerfreigabe dieses Spielers.
    ToPeer(string.format("CHALLENGE|%s|%d|%s|%s|%s|%s|%d|%s|%s",
        cs.challengeId, PROTOCOL_VER,
        tostring(ARKANA_CATALOG_HASH), deck.class, tostring(DeckHash(deck.cards)),
        cs.ranked and "1" or "0", MyRankCode(), tostring(ARKANA_BUILD),
        ARKANA_Settings.spectatorSharing and "1" or "0"))

    addon:ShowOutgoingChallenge(cs.peer)
    addon:Info("|cff00ff00[Arkana]|r Herausforderung an " .. cs.peer .. " gesendet.")
    return true
end

function addon:AcceptChallenge()
    if not cs.challengeId then return end
    local deck = ActiveDeck()
    if not deck then
        print("|cffff0000[Arkana]|r Kein aktives Deck.")
        self:DeclineChallenge()
        return
    end
    -- Feld 8: Bestätigung der Wertung zurück an den Herausforderer — der wertet nur,
    -- wenn diese Bestätigung ankommt (Schutz vor alten Clients, die Feld 7 ignorieren)
    ToPeer(string.format("ACCEPT|%s|%d|%s|%s|%s|%d|%s|%s|%s",
        cs.challengeId, PROTOCOL_VER,
        tostring(ARKANA_CATALOG_HASH), deck.class, tostring(DeckHash(deck.cards)),
        MyRankCode(), cs.ranked and "1" or "0", tostring(ARKANA_BUILD),
        ARKANA_Settings.spectatorSharing and "1" or "0"))
    addon:HideChallengeWindow()
    SendMyDeck()
end

function addon:DeclineChallenge()
    if not cs.challengeId then return end
    ToPeer("DECLINE|" .. cs.challengeId)
    addon:HideChallengeWindow()
    ClearCS()
end

-- ── incoming messages ─────────────────────────────────────────────────────────

local function Split(str)
    local t = {}
    for p in str:gmatch("[^|]+") do t[#t+1] = p end
    return t
end

function addon:OnCommReceived(prefix, message, dist, sender)
    if prefix ~= PREFIX then return end
    sender = Norm(sender)
    if sender == Me() then return end

    local p = Split(message)
    local t = p[1]

    -- ── Signierte Arkana-Freigaben und Empfangsbestätigungen ──
    if t == "ADMGRANT" or t == "ADMACK" then
        if addon.ADM_OnComm then addon:ADM_OnComm(t, p, sender, dist) end
        return
    end

    -- ── Zuschauer-Nachrichten (SPEC*) an das Spectator-Modul delegieren ──
    if addon.Spec_OnComm and addon:Spec_OnComm(t, p, sender, dist) then return end

    -- Alle übrigen Arkana-Pakete sind zielgerichtet. Modifizierte Clients dürfen
    -- Challenges, Duellaktionen oder Kosmetik nicht über Gruppe/Kanal einschleusen.
    if dist ~= "WHISPER" then return end

    -- ── Kartenrücken-/Karten-Skin-Ansage des Gegners (Verifikation in CardBacks.lua) ──
    if t == "CBACK" then
        if not gs_peerName or sender ~= gs_peerName then return end
        if addon.CB_OnComm then addon:CB_OnComm(p, sender) end
        return
    end
    if t == "CSKIN" then
        if not gs_peerName or sender ~= gs_peerName then return end
        if addon.CS_OnComm then addon:CS_OnComm(p, sender) end
        return
    end
    if t == "HSKIN" then
        if not gs_peerName or sender ~= gs_peerName then return end
        if addon.HS_OnComm then addon:HS_OnComm(p, sender) end
        return
    end

    -- ── CHALLENGE ──
    if t == "CHALLENGE" then
        local cid, pver, catHash, heroClass, deckHash =
            p[2], tonumber(p[3]), tonumber(p[4]), p[5], tonumber(p[6])
        if not cid then return end

        if pver ~= PROTOCOL_VER then
            -- Grund als Feld 3 mitschicken (alte Clients ignorieren Extra-Felder),
            -- sonst sieht der Herausforderer nur ein kommentarloses "abgelehnt"
            self:SendComm("DECLINE|" .. cid .. "|Addon-Version passt nicht (beide Seiten aktualisieren, /arkana build vergleichen)", sender)
            print("|cffff0000[Arkana]|r Challenge von " .. sender .. " abgelehnt: Protokoll-Version inkompatibel (er v" ..
                  tostring(pver) .. ", du v" .. PROTOCOL_VER .. ") — Addon-Update nötig.")
            return
        end
        if catHash ~= ARKANA_CATALOG_HASH then
            self:SendComm("DECLINE|" .. cid .. "|Kartendaten unterschiedlich (Addon-Stände vergleichen)", sender)
            print("|cffff0000[Arkana]|r Challenge von " .. sender .. " abgelehnt: Kartendaten unterschiedlich.")
            return
        end
        -- Gleicher Protokollstand, aber anderer Build (z.B. UI-/Kartenfixes) → Duell verhindern
        if p[9] ~= tostring(ARKANA_BUILD) then
            self:SendComm("DECLINE|" .. cid .. "|Andere Addon-Version (Gegner: " .. tostring(ARKANA_BUILD) ..
                          ", du: " .. tostring(p[9] or "unbekannt") .. ") — bitte die aktuelle Version installieren", sender)
            print("|cffff0000[Arkana]|r Challenge von " .. sender .. " abgelehnt: andere Addon-Version (er: " ..
                  tostring(p[9] or "unbekannt") .. ", du: " .. tostring(ARKANA_BUILD) .. ").")
            return
        end
        if gs_peerName or (addon.GE_Active and addon:GE_Active()) or (addon.Board_IsActive and addon:Board_IsActive()) then
            self:SendComm("DECLINE|" .. cid, sender)
            return
        end
        -- gleichzeitige Challenges
        if cs.peer == sender and cs.role == "challenger" then
            if Me() > sender then
                ClearCS()  -- wir werden Challengee
            else
                return      -- wir bleiben Challenger
            end
        end
        if cs.peer then
            self:SendComm("DECLINE|" .. cid, sender); return
        end
        if p[7] == "1" then
            self:SendComm("DECLINE|" .. cid .. "|Gewertete Spiele können nur durch die Turnierleitung gestartet werden", sender)
            print("|cffffff00[Arkana]|r Gewertete Herausforderung von " .. sender ..
                  " abgelehnt: Wertung ist für normale Spieler-Herausforderungen deaktiviert.")
            return
        end
        cs.role          = "challengee"
        cs.peer          = sender
        cs.challengeId   = cid
        cs.peerHeroClass = heroClass
        cs.peerDeckHash  = deckHash
        cs.ranked        = false
        cs.peerRank      = tonumber(p[8])  -- Gegner-Rang (0 = Legende, nil = alter Client)
        cs.peerSpectatorSharing = p[10] == "1"
        addon:ShowIncomingChallenge(sender, heroClass, false)

    -- ── ACCEPT ──
    elseif t == "ACCEPT" then
        if sender ~= cs.peer or p[2] ~= cs.challengeId then return end
        cs.peerRank = tonumber(p[7])   -- Gegner-Rang (0 = Legende, nil = alter Client)
        -- ⚠ war fälschlich p[6] (= Deck-Hash!) → Rang-Abstand-Prüfung schlug beim
        -- Herausforderer IMMER fehl, sein Match blieb ungewertet (Tester-Bug 2026-07-10)
        if tonumber(p[3]) ~= PROTOCOL_VER or tonumber(p[4]) ~= ARKANA_CATALOG_HASH then
            self:DeclineChallenge()
            print("|cffff0000[Arkana]|r Challenge abgebrochen: Protokoll/Catalog-Mismatch nach ACCEPT.")
            return
        end
        if p[9] ~= tostring(ARKANA_BUILD) then
            self:DeclineChallenge()
            print("|cffff0000[Arkana]|r Duell abgebrochen: " .. sender .. " hat eine andere Addon-Version (er: " ..
                  tostring(p[9] or "unbekannt") .. ", du: " .. tostring(ARKANA_BUILD) .. ") — bitte beide die aktuelle Version installieren.")
            return
        end
        cs.peerHeroClass = p[5]
        cs.peerDeckHash  = tonumber(p[6])
        cs.peerSpectatorSharing = p[10] == "1"
        -- Wertung nur mit Bestätigung des Gegners (ACCEPT-Feld 8) — sonst könnte der
        -- Herausforderer glauben, es sei gewertet, während der Gegner ungewertet spielt
        if cs.ranked and p[8] ~= "1" then
            cs.ranked = false
            print("|cffffff00[Arkana-Ranked]|r " .. sender .. " bestätigt die Wertung nicht (alte Addon-Version?) — Duell läuft ungewertet.")
        end
        print("|cff00ff00[Arkana]|r " .. sender .. " hat deine " ..
              (cs.ranked and "|cffffd700Gewertete|r " or "") .. "Herausforderung angenommen.")
        addon:HideChallengeWindow()
        SendMyDeck()

    -- ── DECLINE ──
    elseif t == "DECLINE" then
        if sender ~= cs.peer or p[2] ~= cs.challengeId then return end
        print("|cffff0000[Arkana]|r " .. (cs.ranked and "Gewertete Herausforderung" or "Herausforderung") ..
              " abgelehnt von " .. sender .. "." ..
              ((p[3] and p[3] ~= "") and (" Grund: " .. p[3]) or ""))
        addon:HideChallengeWindow()
        ClearCS()

    -- ── DECK ──
    elseif t == "DECK" then
        if sender ~= cs.peer or p[2] ~= cs.challengeId then return end
        local cards = {}
        for id in (p[3] or ""):gmatch("[^,]+") do cards[#cards+1] = id end
        local ok, err = ValidateDeck(cards, cs.peerHeroClass, cs.peerDeckHash)
        if not ok then
            print("|cffff0000[Arkana]|r Ungültiges Deck von " .. sender .. ": " .. (err or "?"))
            ToPeer("DECLINE|" .. cs.challengeId)
            addon:HideChallengeWindow()
            ClearCS()
            return
        end
        cs.peerDeck   = cards
        cs.peerDeckOk = true
        if cs.deckTimer then cs.deckTimer:Cancel(); cs.deckTimer = nil end
        -- Challengee: ab jetzt wird auf GAME_START gewartet — ohne Timeout blieb
        -- ein verlorener Spielstart für immer hängen (cs blockierte jede weitere
        -- Challenge bis zum /reload). 45s > 6 Resend-Versuche des Herausforderers.
        if cs.role == "challengee" then
            local cid = cs.challengeId
            cs.deckTimer = C_Timer.NewTimer(45, function()
                if cs.challengeId == cid then
                    print("|cffff0000[Arkana]|r Challenge abgebrochen: Kein Spielstart empfangen (45s).")
                    addon:HideChallengeWindow()
                    ClearCS()
                end
            end)
        end
        TryStartGame()

    -- ── GAME_START ──
    elseif t == "GAME_START" then
        if sender ~= cs.peer or p[2] ~= cs.challengeId then return end
        local sessionId = p[3]
        local seed      = tonumber(p[4])
        -- Ausgeloste eigene Rolle aus Feld 5 (v2); Fallback "second" = altes Verhalten
        local myRole    = (p[5] == "first") and "first" or "second"
        addon:Info("|cff00ff00[Arkana]|r Spiel startet! Session: " .. (sessionId or "?") .. "  Seed: " .. tostring(seed))
        addon:Info(myRole == "first" and "|cff00ff00[Arkana]|r Auslosung: Du beginnst!"
                                      or "|cff00ff00[Arkana]|r Auslosung: Gegner beginnt — du bekommst die Münze.")
        local deck = ActiveDeck()
        local spectatorSharing = ARKANA_Settings and ARKANA_Settings.spectatorSharing == true
                              and cs.peerSpectatorSharing == true
        addon:GE_StartGame(sessionId, seed, myRole, deck.cards, cs.peerDeck, deck.class, cs.peerHeroClass)
        gs_peerName   = cs.peer
        gs_sessionId  = sessionId
        gs_myActionNo = 0
        cheatReported = {}
        -- Herausgeforderter ist NICHT der Zuschauer-Host (Herausforderer relayt);
        -- Aufruf mit isHost=false ist ein No-op, hält die Aufrufe aber symmetrisch
        -- (Decks/Klassen in P1/P2-Reihenfolge).
        if addon.Spec_OnGameStart then
            if myRole == "first" then
                addon:Spec_OnGameStart(false, sessionId, seed, deck.cards, cs.peerDeck, deck.class, cs.peerHeroClass, cs.ranked, spectatorSharing)
            else
                addon:Spec_OnGameStart(false, sessionId, seed, cs.peerDeck, deck.cards, cs.peerHeroClass, deck.class, cs.ranked, spectatorSharing)
            end
        end
        if addon.CB_OnGameStart then addon:CB_OnGameStart(gs_peerName) end
        if addon.RK_MatchStart then addon:RK_MatchStart(cs.peer, sessionId, cs.ranked, cs.peerRank) end
        StartGameTimers()
        addon:HideChallengeWindow()
        ClearCS()

    -- ── In-Game Nachrichten ──
    elseif t == "PLAY" then
        if sender ~= gs_peerName or p[2] ~= gs_sessionId then return end
        local choiceId = (p[8] ~= "" and p[8] ~= nil) and p[8] or nil
        addon:GE_ApplyPeer("PLAY", tonumber(p[4]), tonumber(p[6]), tonumber(p[7]), choiceId)
        RecordPeer("PLAY", tonumber(p[4]), tonumber(p[6]) or 0, tonumber(p[7]) or 0, choiceId or "")
        addon:Board_Update()
        PeerAlive()

    elseif t == "ATTACK" then
        if sender ~= gs_peerName or p[2] ~= gs_sessionId then return end
        addon:GE_ApplyPeer("ATTACK", tonumber(p[4]), tonumber(p[5]))
        RecordPeer("ATTACK", tonumber(p[4]), tonumber(p[5]))
        addon:Board_Update()
        PeerAlive()

    elseif t == "HEROPOWER" then
        if sender ~= gs_peerName or p[2] ~= gs_sessionId then return end
        addon:GE_ApplyPeer("HEROPOWER", tonumber(p[4]))
        RecordPeer("HEROPOWER", tonumber(p[4]))
        addon:Board_Update()
        PeerAlive()

    elseif t == "END_TURN" then
        if sender ~= gs_peerName or p[2] ~= gs_sessionId then return end
        local peerHash = tonumber(p[4])     -- fehlt bei älteren Clients → dann kein Vergleich
        addon:GE_ApplyPeer("END_TURN")
        RecordPeer("END_TURN")
        local myHash = addon:GE_StateHash()
        if peerHash and peerHash ~= myHash then
            ReportCheat("X", gs_peerName, "Spielzustand weicht am Zugende ab (" ..
                        peerHash .. " statt " .. myHash .. ")")
        end
        PeerAlive()

    elseif t == "MULLIGAN_CHOICES" then
        if sender ~= gs_peerName or p[2] ~= gs_sessionId then return end
        local indices = {}
        for i in (p[4] or ""):gmatch("[^,]+") do indices[tonumber(i)] = true end
        addon:GE_ApplyPeer("MULLIGAN_CHOICES", indices)
        RecordPeer("MULLIGAN_CHOICES", p[4] or "")
        PeerAlive()

    elseif t == "MULLIGAN_DONE" then
        if sender ~= gs_peerName or p[2] ~= gs_sessionId then return end
        addon:GE_ApplyPeer("MULLIGAN_DONE")
        RecordPeer("MULLIGAN_DONE")
        PeerAlive()

    elseif t == "TRACKING_CHOOSE" then
        if sender ~= gs_peerName or p[2] ~= gs_sessionId then return end
        addon:GE_ApplyPeer("TRACKING_CHOOSE", p[4])
        RecordPeer("TRACKING_CHOOSE", p[4])
        PeerAlive()

    elseif t == "GAME_END" then
        if sender ~= gs_peerName or p[2] ~= gs_sessionId then return end
        gs_peerName = nil  -- verhindert Echo in GE_OnGameEnd
        StopGameTimers()
        addon:GE_EndGame(p[3])

    elseif t == "PING" and gs_peerName then
        if sender ~= gs_peerName or p[2] ~= gs_sessionId then return end
        addon:SendComm("PONG|" .. gs_sessionId, gs_peerName)
        -- Auch der PING des Gegners ist ein Lebenszeichen: wenn die EIGENEN
        -- Pings gedrosselt hängen, kam sonst nie ein PONG zurück → Fehl-Draw
        PeerAlive()

    elseif t == "PONG" and gs_peerName then
        if sender ~= gs_peerName or p[2] ~= gs_sessionId then return end
        PeerAlive()
    end
end

-- ── Game-End send ─────────────────────────────────────────────────────────────

function addon:SendGameEnd(winner)
    if not gs_peerName or not gs_sessionId then return end
    -- ALERT wie SendInGame: gleiche Prio = gleiche Queue = GAME_END überholt
    -- den tödlichen Zug nicht (Reihenfolge aus S41-Nachtrag 6 bleibt gewahrt)
    addon:SendComm(string.format("GAME_END|%s|%s", gs_sessionId, winner), gs_peerName, "ALERT")
    gs_peerName = nil; gs_sessionId = nil; gs_myActionNo = 0
    StopGameTimers()
end

-- ── GE callbacks (overrides stubs in GameEngine.lua) ─────────────────────────

function addon:GE_TurnStart(pIdx)
    local state = addon:GE_State()
    if not state then return end
    -- Zuschauer: kein Zug-Timer / keine "Dein Zug"-Meldung / kein Auto-EndTurn
    if addon.IsSpectating and addon:IsSpectating() then return end
    if gs_turnTimer then gs_turnTimer:Cancel(); gs_turnTimer = nil end
    if addon.Sandbox_IsActive and addon:Sandbox_IsActive() and pIdx ~= state.myPlayerIdx then
        local targetName = addon.Sandbox_Name and addon:Sandbox_Name() or "Trainingsziel"
        local msg = targetName .. " ist dran."
        if self.GameLog then
            self:GameLog("|cffaaaaaa" .. msg .. "|r")
        else
            print("|cff00ff00[Arkana]|r " .. msg)
        end
        if addon.Sandbox_OnTurnStart then addon:Sandbox_OnTurnStart(pIdx) end
        return
    end
    if pIdx == state.myPlayerIdx then
        if addon.GE_IsSandbox and addon:GE_IsSandbox() and addon.GE_SandboxFillMana then
            addon:GE_SandboxFillMana()
            state = addon:GE_State() or state
        end
        local p = state.players[pIdx]
        local msg = string.format("Dein Zug! Mana: %d/%d", p.mana.currentPermanent, p.mana.maxPermanent)
        if self.GameLog then
            self:GameLog("|cff00ff00" .. msg .. "|r")
        else
            print("|cff00ff00[Arkana]|r " .. msg)
        end
        -- In der Karten-Sandbox gibt es keinen Zeitdruck. Reguläre Partien
        -- behalten weiterhin das automatische Zugende nach 90 Sekunden.
        if not (addon.GE_IsSandbox and addon:GE_IsSandbox()) then
            gs_turnTimer = C_Timer.NewTimer(90, function()
                if addon:GE_Active() then addon:Net_EndTurn() end
            end)
        end
    else
        local msg = "Gegner ist dran."
        if self.GameLog then
            self:GameLog("|cffaaaaaa" .. msg .. "|r")
        else
            print("|cff00ff00[Arkana]|r " .. msg)
        end
    end
end

function addon:GE_OnGameEnd(winner)
    -- Einen Frame verzögert: GE_EndGame feuert MITTEN in GE_DoAction, also BEVOR
    -- Net_PlayCard/Net_Attack/... die Aktion per SendInGame verschickt haben.
    -- Sofortiges SendGameEnd nillte gs_peerName → der tödliche Zug ging nie raus,
    -- der Verlierer bekam nur GAME_END (keine Animation, kein Log-Eintrag).
    -- Gleiches für Zuschauer: Spec_OnGameEnd nillte host vor RecordOwn → letzte
    -- SPECACT fehlte. Echo-Schutz bleibt: nach empfangenem GAME_END ist
    -- gs_peerName bereits nil, SendGameEnd wird dann zum No-op.
    C_Timer.After(0, function()
        if addon.Sandbox_IsActive and addon:Sandbox_IsActive() then
            if addon.Sandbox_OnGameEnd then addon:Sandbox_OnGameEnd(winner) end
            return
        end
        addon:SendGameEnd(winner)
        if addon.Spec_OnGameEnd then addon:Spec_OnGameEnd(winner) end
    end)
end

-- ── Public send API (für Phase 8 UI) ─────────────────────────────────────────

function addon:Net_PlayCard(handIdx, targetEntityId, boardPos, choiceId)
    if not addon:GE_DoAction("PLAY", handIdx, targetEntityId, boardPos or 0, choiceId) then return end
    SendInGame("PLAY", handIdx, 0, targetEntityId or 0, boardPos or 0, choiceId or "")
    RecordOwn("PLAY", handIdx, targetEntityId or 0, boardPos or 0, choiceId or "")
end

function addon:Net_TrackingChoose(chosenId)
    if not addon:GE_DoAction("TRACKING_CHOOSE", chosenId) then return end
    SendInGame("TRACKING_CHOOSE", chosenId)
    RecordOwn("TRACKING_CHOOSE", chosenId)
end

function addon:Net_GetPeerName()
    if addon.Sandbox_IsActive and addon:Sandbox_IsActive() then
        return addon.Sandbox_Name and addon:Sandbox_Name() or "Trainingsziel"
    end
    return gs_peerName
end

function addon:Net_IsBusy()
    return cs.peer ~= nil or gs_peerName ~= nil or (addon.GE_Active and addon:GE_Active())
end

function addon:Net_Attack(attackerEId, defenderEId)
    if not addon:GE_DoAction("ATTACK", attackerEId, defenderEId) then return end
    SendInGame("ATTACK", attackerEId, defenderEId)
    RecordOwn("ATTACK", attackerEId, defenderEId)
end

function addon:Net_HeroPower(targetEntityId)
    if not addon:GE_DoAction("HEROPOWER", targetEntityId) then return end
    SendInGame("HEROPOWER", targetEntityId or 0)
    RecordOwn("HEROPOWER", targetEntityId or 0)
end

function addon:Net_EndTurn()
    if not addon:GE_DoAction("END_TURN") then return end
    -- Zustands-Prüfsumme am Zugende mitschicken: der Gegner rechnet dieselbe Simulation
    -- und vergleicht. Weicht sie ab, rechnet einer der beiden mit manipulierten Regeln
    -- oder Kartendaten. Zugende ist der natürliche Prüfpunkt (deckt alle Aktionen des
    -- Zuges ab) und die Nachricht hat keine optionalen Felder → Anhängen ist gefahrlos
    -- (bei "PLAY" würde ein leeres Feld die Indizes verschieben, S45-Lektion).
    SendInGame("END_TURN", addon:GE_StateHash())
    RecordOwn("END_TURN")
end

function addon:Net_MulliganDone(returnIndices)
    returnIndices = returnIndices or {}
    addon:GE_DoAction("MULLIGAN_CHOICES", returnIndices)
    addon:GE_DoAction("MULLIGAN_DONE")
    -- Lokale Sandbox-Sitzungen haben keinen Peer und erzeugen weder Resends noch
    -- Zuschauer-Aktionsprotokolle.
    if addon.Sandbox_IsActive and addon:Sandbox_IsActive() then return end
    local idxList = {}
    for k in pairs(returnIndices) do idxList[#idxList+1] = k end
    table.sort(idxList)
    local payload = table.concat(idxList, ",")
    SendInGame("MULLIGAN_CHOICES", payload)
    SendInGame("MULLIGAN_DONE")
    RecordOwn("MULLIGAN_CHOICES", payload)
    RecordOwn("MULLIGAN_DONE")
    -- Geht eine der beiden Whisper verloren, starren beide Spieler für immer
    -- auf den Mulligan-Schleier (kein Retry im Comm-Layer). Deshalb: solange
    -- die Mulligan-Phase läuft, alle 5s erneut senden (max. 2 Min). Empfänger
    -- ist idempotent (MULLIGAN_DONE-Guard in GE_ApplyAs), RecordOwn bewusst
    -- nicht wiederholt (Zuschauer-Log bleibt sauber).
    local sid = gs_sessionId
    C_Timer.NewTicker(5, function(t)
        local st = addon.GE_State and addon:GE_State()
        if not st or gs_sessionId ~= sid or st.phase ~= "mulligan" then
            t:Cancel()
            return
        end
        SendInGame("MULLIGAN_CHOICES", payload)
        SendInGame("MULLIGAN_DONE")
    end, 24)
end
