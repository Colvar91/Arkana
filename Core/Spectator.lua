local addon = Arkana
local PREFIX         = "ARKANA"
local SPEC_CHANNEL   = "ARKANA"
local HEARTBEAT_SEC  = 10     -- zurückhaltende Lobby-Aktualisierung
local LOBBY_TTL      = 35     -- Sekunden ohne Heartbeat, bis ein Lobby-Eintrag verfällt

-- ── Zustand ─────────────────────────────────────────────────────────────────────
-- Deterministisches Replay: Nur wenn beide Duellanten in den Einstellungen
-- zugestimmt haben, kündigt der Host das Spiel im ARKANA-Kanal an. Decklisten,
-- Kosmetik und Aktionen gehen danach ausschließlich per Whisper an die Zuschauer.

local WATCHER_TTL    = 12     -- Sekunden ohne Ping, bis ein Zuschauer aus der Liste fällt

local host    = nil   -- { sessionId, seed, firstDeck, secondDeck, firstClass, secondClass, log={}, seq, hb }
local watch   = nil   -- { sessionId, hostName, appliedSeq, buffer={}, catchingUp, pingTicker }
local lobby   = {}    -- [sessionId] = { hostName, oppName, hostClass, oppClass, turnNum, seq, lastSeen }
local specBoardUp = false  -- Zuschauer-Board ist sichtbar (bleibt true auch nachdem
                           -- das beobachtete Spiel endete, damit der Verlassen-Button wirkt)
local specLastNames = { p1 = "?", p2 = "?" }  -- gemerkte Spielernamen (für den Endstand)

-- Wer ist Spieler 1/2? Braucht Network.lua, um beim ZUSCHAUEN einen Regelverstoß dem
-- richtigen Namen zuzuordnen (im Duell liefert gs_peerName den Gegner).
function addon:Spec_NameFor(pIdx)
    return (pIdx == 1) and specLastNames.p1 or specLastNames.p2
end

-- Zuschauerliste (für die "Nx Zuschauer"-Anzeige beim Spielen)
local myGame        = nil   -- { sessionId, isHost } — läuft, während ich selbst spiele
local hostSpectators = {}   -- (nur Host) [zuschauerName] = lastSeen(GetTime)
local watcherView   = { count = 0, names = {} }  -- (Nicht-Host) zuletzt empfangene Liste

-- ── Kanal-Helfer ────────────────────────────────────────────────────────────────
-- Der ARKANA-Kanal trägt nur auffindbare Lobby-Metadaten und freiwillige Rangdaten.
-- JoinTemporaryChannel ist asynchron. Nach einer bewussten Aktion wird der Beitritt
-- deshalb begrenzt wiederholt; bis dahin liegen ausgehende Metadaten in einer kleinen Queue.

local function ChanId()
    local id = GetChannelName(SPEC_CHANNEL)
    return (id and id > 0) and id or nil
end

local joinRetries = 0
local pendingBroadcasts = {}
local EnsureChannel

local function FlushBroadcasts()
    local cid = ChanId()
    if not cid then return end
    local queued = pendingBroadcasts
    pendingBroadcasts = {}
    for _, item in ipairs(queued) do
        addon:SendCommMessage(PREFIX, item.msg, "CHANNEL", cid, item.prio)
    end
end

EnsureChannel = function()
    if ChanId() then
        joinRetries = 0
        FlushBroadcasts()
        return true
    end
    -- Beitritt nur durch eine sichtbare Nutzeraktion (Zuschauer-/Ranglistenfenster)
    -- oder ein von beiden Spielern freigegebenes Duell.
    JoinTemporaryChannel(SPEC_CHANNEL)
    -- Beitritt ist async → erneut prüfen und ggf. nachfassen (bis ~30s)
    if joinRetries < 15 then
        joinRetries = joinRetries + 1
        C_Timer.After(2, EnsureChannel)
    end
    return false
end

-- prio (optional): AceComm-Priorität "ALERT"/"NORMAL"/"BULK".
local function Broadcast(msg, prio)
    local cid = ChanId()
    if cid then
        addon:SendCommMessage(PREFIX, msg, "CHANNEL", cid, prio)
    else
        local key = msg:match("^([^|]+)") or msg
        for i, item in ipairs(pendingBroadcasts) do
            if item.key == key then
                pendingBroadcasts[i] = { key = key, msg = msg, prio = prio }
                EnsureChannel()
                return
            end
        end
        if #pendingBroadcasts >= 10 then table.remove(pendingBroadcasts, 1) end
        pendingBroadcasts[#pendingBroadcasts + 1] = { key = key, msg = msg, prio = prio }
        EnsureChannel()
    end
end

local function Whisper(msg, target, prio)
    addon:SendCommMessage(PREFIX, msg, "WHISPER", target, prio)
end

local function WhisperWatchers(msg, prio)
    for name in pairs(hostSpectators) do Whisper(msg, name, prio) end
end

local function WhisperWatcherState(msg)
    local peer = addon.Net_GetPeerName and addon:Net_GetPeerName()
    if peer and peer ~= "" then Whisper(msg, peer) end
    WhisperWatchers(msg)
end

-- Einmalige, eng begrenzte Übergabe an Ranked.lua. Dadurch gibt es im geladenen
-- Release keine allgemeine /run-erreichbare Broadcast-Funktion.
local rankChannelAPIClaimed = false
function addon:Spec_ConsumeRankChannelAPI()
    if rankChannelAPIClaimed then return nil end
    rankChannelAPIClaimed = true
    return {
        Announce = function(message)
            if type(message) == "string" and message:match("^RKINFO|") then Broadcast(message) end
        end,
        Request = function() Broadcast("RKPING") end,
    }
end

-- ── Aktions-(De)Serialisierung ──────────────────────────────────────────────────
-- Kompaktes eigenes Format (wir kontrollieren beide Enden): immer 4 Arg-Felder,
-- leere mit "" gepolstert. Feldtrenner ist "|", MULLIGAN-Indizes nutzen "," intern.

local function EncodeArgs(actionType, ...)
    local a = { ... }
    if actionType == "PLAY" then
        -- handIdx, target, boardPos, choiceId (choiceId kann string sein)
        return tostring(a[1] or 0), tostring(a[2] or 0), tostring(a[3] or 0), tostring(a[4] or "")
    elseif actionType == "ATTACK" then
        return tostring(a[1] or 0), tostring(a[2] or 0), "", ""
    elseif actionType == "HEROPOWER" then
        return tostring(a[1] or 0), "", "", ""
    elseif actionType == "TRACKING_CHOOSE" then
        return tostring(a[1] or ""), "", "", ""
    elseif actionType == "MULLIGAN_CHOICES" then
        -- a[1] ist entweder ein Set {[idx]=true} (eigene Aktion) oder ein fertiger CSV-String (Peer)
        local v = a[1]
        if type(v) == "table" then
            local list = {}
            for k in pairs(v) do list[#list+1] = k end
            table.sort(list)
            return table.concat(list, ","), "", "", ""
        end
        return tostring(v or ""), "", "", ""
    else -- END_TURN, MULLIGAN_DONE
        return "", "", "", ""
    end
end

-- Wendet eine dekodierte Aktion auf die (Zuschauer-)Engine an
local function ApplyDecoded(pIdx, actionType, a1, a2, a3, a4)
    if actionType == "PLAY" then
        addon:GE_ApplyAs(pIdx, "PLAY", tonumber(a1), tonumber(a2), tonumber(a3), (a4 ~= "" and a4) or nil)
    elseif actionType == "ATTACK" then
        addon:GE_ApplyAs(pIdx, "ATTACK", tonumber(a1), tonumber(a2))
    elseif actionType == "HEROPOWER" then
        addon:GE_ApplyAs(pIdx, "HEROPOWER", tonumber(a1))
    elseif actionType == "END_TURN" then
        addon:GE_ApplyAs(pIdx, "END_TURN")
    elseif actionType == "TRACKING_CHOOSE" then
        addon:GE_ApplyAs(pIdx, "TRACKING_CHOOSE", a1)
    elseif actionType == "MULLIGAN_CHOICES" then
        local set = {}
        for s in (a1 or ""):gmatch("[^,]+") do set[tonumber(s)] = true end
        addon:GE_ApplyAs(pIdx, "MULLIGAN_CHOICES", set)
    elseif actionType == "MULLIGAN_DONE" then
        addon:GE_ApplyAs(pIdx, "MULLIGAN_DONE")
    end
end

-- ── HOST-Seite ──────────────────────────────────────────────────────────────────

-- Von Network.lua bei GE_StartGame gerufen. Streaming startet nur nach beidseitiger
-- Freigabe aus dem Handshake; ohne Freigabe werden weder Lobbydaten noch Decks geteilt.
function addon:Spec_OnGameStart(isHost, sessionId, seed, firstDeck, secondDeck, firstClass, secondClass, ranked, sharingAllowed)
    host = nil
    myGame = nil
    hostSpectators = {}
    watcherView = { count = 0, names = {} }
    if addon.Spec_RefreshWatcherDisplay then addon:Spec_RefreshWatcherDisplay() end
    if not sharingAllowed then return end
    myGame = { sessionId = sessionId, isHost = isHost }
    if not isHost then return end
    EnsureChannel()
    host = {
        sessionId   = sessionId,
        seed        = seed,
        firstDeck   = firstDeck,
        secondDeck  = secondDeck,
        firstClass  = firstClass,
        secondClass = secondClass,
        ranked      = ranked and true or false,
        log         = {},
        seq         = 0,
    }
    host.hb = C_Timer.NewTicker(HEARTBEAT_SEC, function() addon:Spec_SendHeartbeat() end)
    addon:Spec_SendHeartbeat()
end

function addon:Spec_SendHeartbeat()
    if not host then return end
    local st = addon:GE_State()
    if not st then return end
    local p1, p2 = st.players[1], st.players[2]
    -- Namen in P1/P2-Reihenfolge: seit der Startspieler-Auslosung kann der Host
    -- (Herausforderer) auch P2 sein — Zuschauer zeigen P1 unten
    local meName, opName = UnitName("player") or "?", addon:Net_GetPeerName() or "?"
    local p1Name, p2Name = meName, opName
    if st.myPlayerIdx == 2 then p1Name, p2Name = opName, meName end
    -- Feld 9 = gewertetes Spiel (Tester-Wunsch: beim Zuschauen sichtbar machen);
    -- alte Zuschauer-Clients ignorieren das Extra-Feld
    -- Feld 10 = Build des Hosts: der Zuschauer rechnet die Partie mit seiner EIGENEN
    -- Engine nach (Lockstep) — bei abweichendem Stand driftet die Anzeige still.
    Broadcast(string.format("SPECGAME|%s|%s|%s|%s|%s|%d|%d|%s|%s",
        host.sessionId, p1Name, p2Name,
        p1.hero.class or "?", p2.hero.class or "?",
        st.turnNumber or 0, host.seq, host.ranked and "1" or "0", tostring(ARKANA_BUILD)))
    -- Zuschauerliste pflegen; Namen nur gezielt an Duellpartner und Zuschauer senden.
    local now = GetTime()
    local names = {}
    for name, last in pairs(hostSpectators) do
        if now - last > WATCHER_TTL then hostSpectators[name] = nil
        else names[#names+1] = name end
    end
    table.sort(names)
    WhisperWatcherState(string.format("SPECWATCH|%s|%d|%s", host.sessionId, #names, table.concat(names, ",")))
    if addon.Spec_RefreshWatcherDisplay then addon:Spec_RefreshWatcherDisplay() end
end

-- Von Network.lua nach jeder angewandten Aktion gerufen. Der Host hält das Log für
-- spätere Beitritte vor und sendet live nur an bereits beigetretene Zuschauer.
function addon:Spec_RecordAction(pIdx, actionType, ...)
    if not host then return end
    host.seq = host.seq + 1
    local a1, a2, a3, a4 = EncodeArgs(actionType, ...)
    local entry = { seq = host.seq, pIdx = pIdx, t = actionType, a1 = a1, a2 = a2, a3 = a3, a4 = a4 }
    host.log[host.seq] = entry
    WhisperWatchers(string.format("SPECACT|%s|%d|%d|%s|%s|%s|%s|%s",
        host.sessionId, entry.seq, pIdx, actionType, a1, a2, a3, a4), "BULK")
end

function addon:Spec_OnGameEnd(winner)
    if host then
        WhisperWatcherState(string.format("SPECEND|%s|%s", host.sessionId, winner or "DRAW"))
        if host.hb then host.hb:Cancel() end
        host = nil
    end
    -- Zuschauerliste/Anzeige zurücksetzen (eigenes Spiel vorbei)
    myGame = nil
    hostSpectators = {}
    watcherView = { count = 0, names = {} }
    if addon.Spec_RefreshWatcherDisplay then addon:Spec_RefreshWatcherDisplay() end
    -- Zuschauer: wenn das beobachtete Spiel endet
    if watch then
        addon:Spec_ShowEnded(winner)
    end
end

-- Info für die "Nx Zuschauer"-Anzeige.
-- Host: eigene authoritative Liste. Nicht-Host-Spieler UND Zuschauer: die zuletzt
-- vom Host empfangene Liste (SPECWATCH).
function addon:Spec_WatcherInfo()
    if myGame and myGame.isHost then
        local names = {}
        for name in pairs(hostSpectators) do names[#names+1] = name end
        table.sort(names)
        return #names, names
    end
    return watcherView.count or 0, watcherView.names or {}
end

-- Host beantwortet eine Beitrittsanfrage: Startdaten + komplettes Log per Whisper
local function HostHandleJoin(specName, sessionId)
    if not host or host.sessionId ~= sessionId then return end
    hostSpectators[specName] = GetTime()   -- Zuschauer in die Liste aufnehmen
    if addon.Spec_RefreshWatcherDisplay then addon:Spec_RefreshWatcherDisplay() end
    Whisper(string.format("SPECINIT|%s|%d|%s|%s|%s|%s|%d",
        host.sessionId, host.seed, host.firstClass, host.secondClass,
        table.concat(host.firstDeck, ","), table.concat(host.secondDeck, ","),
        host.seq), specName)
    -- Aufhol-Log GEBÜNDELT (Tester: "Zuschauen dauert ewig"). Eine Whisper-Nachricht
    -- je Aktion kostete pro Eintrag den vollen Chat-Drossel-Overhead — bei langen
    -- Partien Minuten. Format: SPECLOGB|<sid>|<startSeq>|pIdx~t~a1~a2~a3~a4;…
    local chunk, chunkStart = {}, nil
    local function FlushChunk()
        if not chunkStart then return end
        Whisper(string.format("SPECLOGB|%s|%d|%s", host.sessionId, chunkStart,
            table.concat(chunk, ";")), specName)
        chunk, chunkStart = {}, nil
    end
    local chunkLen = 0
    for i = 1, host.seq do
        local e = host.log[i]
        if e then
            if chunkStart and e.seq ~= chunkStart + #chunk then FlushChunk() end   -- Lücke im Log
            local s = string.format("%d~%s~%s~%s~%s~%s", e.pIdx, e.t, e.a1, e.a2, e.a3, e.a4)
            if not chunkStart then chunkStart, chunkLen = e.seq, 0 end
            chunk[#chunk + 1] = s
            chunkLen = chunkLen + #s + 1
            if chunkLen > 180 then FlushChunk() end
        end
    end
    FlushChunk()
    Whisper(string.format("SPECDONE|%s|%d", host.sessionId, host.seq), specName)
    -- Kartenrücken/Karten-Skins beider Spieler an den neuen Zuschauer (signiert)
    if addon.CB_SpecCosmMsg then
        Whisper(addon:CB_SpecCosmMsg(host.sessionId), specName)
    end
end

-- Von CardBacks.lua gerufen, wenn sich Kosmetik-Daten ändern: Host verteilt an alle Zuschauer
function addon:Spec_CosmChanged()
    if host and addon.CB_SpecCosmMsg then
        WhisperWatchers(addon:CB_SpecCosmMsg(host.sessionId))
    end
end

-- ── ZUSCHAUER-Seite ─────────────────────────────────────────────────────────────

-- true solange ein Zuschauer-Board sichtbar ist (auch nach Spielende, bis verlassen) —
-- hält das Board read-only und den Verlassen-Button/Banner erhalten
function addon:IsSpectating() return watch ~= nil or specBoardUp end
function addon:Spec_IsCatchup() return watch ~= nil and watch.catchingUp end
-- Kanal beitreten, damit ein passiver Client die SPECGAME-Heartbeats empfängt
function addon:Spec_EnsureChannel() EnsureChannel() end

-- Diagnose: Kanal-Status + Anzahl gefundener Spiele (für /arkana spectate status)
function addon:Spec_Status()
    local cid = ChanId()
    local now = GetTime()
    local nRaw, nFresh, oldest = 0, 0, nil
    for _, g in pairs(lobby) do
        nRaw = nRaw + 1
        local age = now - g.lastSeen
        if age <= LOBBY_TTL then nFresh = nFresh + 1 end
        if not oldest or age > oldest then oldest = age end
    end
    print("|cff00ff00[Arkana-Spectate]|r Kanal '" .. SPEC_CHANNEL .. "': " ..
        (cid and ("beigetreten (#" .. cid .. ")") or "|cffff0000NICHT beigetreten|r") ..
        "  ·  Spiele aktiv/gesamt: " .. nFresh .. "/" .. nRaw ..
        (oldest and string.format("  ·  letzter Heartbeat vor %.0fs", oldest) or "") ..
        (host and ("  ·  du hostest gerade (seq " .. host.seq .. ")") or "") ..
        (watch and "  ·  du schaust gerade zu" or ""))
    if not cid then
        print("|cffffcc00[Arkana]|r Der Kanal wird erst beim Öffnen von Zuschauen/Rangliste oder für ein beidseitig freigegebenes Duell betreten. Benutzerdefinierte Kanäle sind fraktionsgebunden.")
    end
end
-- Namen der beiden Spieler (P1/Host unten, P2/Gegner oben) für die Board-Anzeige.
-- Aus watch, mit Fallback auf gemerkte Werte (bleiben nach Spielende erhalten,
-- wenn watch bereits nil ist, das Board aber noch als Endstand steht).
function addon:Spec_PlayerNames()
    if watch then return watch.hostName or "?", watch.oppName or "?" end
    return specLastNames.p1, specLastNames.p2
end

-- Gewertetes Spiel? (Zuschauer-Banner; nil solange nichts beobachtet wird)
function addon:Spec_IsRankedGame() return watch and watch.ranked or false end

-- Lobby: verfallene Einträge ausräumen und Liste zurückgeben
function addon:Spec_GetLobby()
    local now = GetTime()
    local list = {}
    for sid, g in pairs(lobby) do
        if now - g.lastSeen > LOBBY_TTL then
            lobby[sid] = nil
        else
            list[#list+1] = { sessionId = sid, hostName = g.hostName, oppName = g.oppName,
                              relayName = g.relayName,
                              hostClass = g.hostClass, oppClass = g.oppClass, turnNum = g.turnNum,
                              ranked = g.ranked, build = g.build,
                              versionOk = (g.build == tostring(ARKANA_BUILD)) }
        end
    end
    table.sort(list, function(a, b) return a.hostName < b.hostName end)
    return list
end

function addon:Spec_Watch(sessionId)
    if watch or specBoardUp then addon:Spec_Leave() end  -- altes (auch beendetes) Zuschauen abräumen
    if addon.GE_Active and addon:GE_Active() then
        print("|cffff0000[Arkana]|r Beende erst dein eigenes Spiel, bevor du zuschaust.")
        return
    end
    local g = lobby[sessionId]
    if not g then
        print("|cffff0000[Arkana]|r Spiel nicht in der Lobby (evtl. beendet).")
        return
    end
    -- Zuschauen ist Lockstep: die Aktionen des Hosts laufen durch die EIGENE Engine.
    -- Bei abweichendem Stand liefe die Nachrechnung still auseinander (falsches Brett
    -- statt Fehlermeldung) → gar nicht erst beitreten. Gleiche Regel wie beim Duell.
    if g.build ~= tostring(ARKANA_BUILD) then
        print("|cffff0000[Arkana]|r Zuschauen nicht möglich: " .. (g.hostName or "der Host") ..
              " hat eine andere Addon-Version (Host: " .. tostring(g.build or "unbekannt") ..
              ", du: " .. tostring(ARKANA_BUILD) .. ") — bitte die aktuelle Version installieren.")
        return
    end
    watch = { sessionId = sessionId, hostName = g.hostName, oppName = g.oppName,
              relayName = g.relayName or g.hostName,
              ranked = g.ranked, appliedSeq = 0, buffer = {}, catchingUp = true,
              lastRecv = GetTime() }
    specLastNames.p1, specLastNames.p2 = g.hostName or "?", g.oppName or "?"
    watcherView = { count = 0, names = {} }  -- Zuschauerliste dieses Spiels (kommt per SPECWATCH)
    if addon.CB_SpecReset then addon:CB_SpecReset() end  -- alte Kosmetik-Daten verwerfen
    local myName = UnitName("player") or "?"
    Whisper(string.format("SPECJOIN|%s|%s", sessionId, myName), watch.relayName, "ALERT")
    -- Ticker (3s): solange der Catch-up noch NICHT da ist → Beitritt erneut anfragen
    -- (die SPECJOIN- oder Antwort-Nachricht kann verloren gehen); danach nur noch
    -- "ich schaue noch zu"-Ping, damit der Host uns nicht verfallen lässt.
    watch.lastJoinReq = GetTime()
    watch.pingTicker = C_Timer.NewTicker(3, function()
        if not watch then return end
        if specBoardUp then
            Whisper(string.format("SPECPING|%s|%s", watch.sessionId, myName), watch.relayName)
            -- Stall-Selbstheilung (Tester: "Zuschauer hängt, nur Neu-Join hilft"):
            -- geht eine SPECACT verloren, staut der Lücken-Puffer für immer bzw.
            -- der Host-seq (Lobby-Heartbeat) läuft davon. 3 Ticks (~9s) Rückstand
            -- ohne Fortschritt → Beitritt neu anfragen; SPECINIT setzt die
            -- Zuschauer-Sim komplett zurück (identisch zum manuellen Neu-Join).
            local g = lobby[watch.sessionId]
            local behind = next(watch.buffer) ~= nil
                or (g and (g.seq or 0) > watch.appliedSeq)
            if behind and watch.appliedSeq == watch.lastAppliedSeen then
                watch.stallTicks = (watch.stallTicks or 0) + 1
                if watch.stallTicks >= 3 then
                    watch.stallTicks = 0
                    addon:Info("|cffffcc00[Arkana]|r Zuschauer-Stream hängt – synchronisiere neu …")
                    Whisper(string.format("SPECJOIN|%s|%s", watch.sessionId, myName), watch.relayName, "ALERT")
                end
            else
                watch.stallTicks = 0
            end
            watch.lastAppliedSeen = watch.appliedSeq
        else
            -- Beitritts-Phase: NICHT stur alle 3s neu anfragen. Jede Anfrage lässt den
            -- Host das KOMPLETTE Log erneut schicken — bei langen Partien kroch das
            -- durch die Chat-Drossel, die Nachfrage-Lawine machte es noch langsamer
            -- und am Ende brach der Timeout ab ("Keine Antwort vom Host"). Erst nach
            -- 15s Funkstille nachfassen, nach 60s ohne JEDE Antwort aufgeben.
            local now = GetTime()
            if now - (watch.lastRecv or 0) > 60 then
                print("|cffff0000[Arkana]|r Keine Antwort vom Host – Zuschauen abgebrochen.")
                addon:Spec_Leave()
                return
            end
            if now - (watch.lastRecv or 0) > 15 and now - (watch.lastJoinReq or 0) > 15 then
                watch.lastJoinReq = now
                Whisper(string.format("SPECJOIN|%s|%s", watch.sessionId, myName), watch.relayName, "ALERT")
            end
        end
    end)
    addon:Info("|cff00ff00[Arkana]|r Beitritt zu " .. g.hostName .. " angefragt …")
end

local function TeardownWatch()
    if watch then
        if watch.pingTicker then watch.pingTicker:Cancel() end
        Whisper(string.format("SPECLEAVE|%s|%s", watch.sessionId, UnitName("player") or "?"), watch.relayName)
    end
    watch = nil
    specBoardUp = false
    watcherView = { count = 0, names = {} }
    if addon.CB_SpecReset then addon:CB_SpecReset() end
    if addon.GE_Reset then addon:GE_Reset() end
    if addon.Spec_HideBoard then addon:Spec_HideBoard() end
end

function addon:Spec_Leave()
    -- Funktioniert auch wenn das Spiel bereits endete (watch=nil, aber Board noch da)
    if not watch and not specBoardUp then return end
    TeardownWatch()
    addon:Info("|cff00ff00[Arkana]|r Zuschauen beendet.")
end

function addon:Spec_ShowEnded(winner)
    if not watch and not specBoardUp then return end
    -- Aufgeben/Spielende läuft NICHT über den Aktions-Stream → die Zuschauer-Engine
    -- erreicht kein GE_EndGame. Board als eingefrorenen Endstand stehen lassen und
    -- nur keine Live-Aktionen mehr annehmen; der Verlassen-Button bleibt aktiv
    -- (specBoardUp bleibt true). Kein Auto-Reset, damit man den Endstand noch sieht.
    watch = nil
    addon:Info("|cff00ff00[Arkana]|r Beobachtetes Spiel beendet (" .. tostring(winner) .. "). '/arkana spectate leave' oder Button zum Schließen.")
    if addon.Spec_MarkEnded then addon:Spec_MarkEnded(winner) end
end

-- Wendet eine (Katchup- oder Live-)Aktion an, dedupliziert per seq, puffert Lücken
local function SpecApplyEntry(seq, pIdx, t, a1, a2, a3, a4)
    if not watch then return end
    if seq <= watch.appliedSeq then return end            -- schon angewandt
    if seq > watch.appliedSeq + 1 then
        watch.buffer[seq] = { pIdx, t, a1, a2, a3, a4 }    -- Lücke → puffern
        return
    end
    ApplyDecoded(pIdx, t, a1, a2, a3, a4)
    watch.appliedSeq = seq
    -- gepufferte Folgeaktionen nachziehen
    while watch.buffer[watch.appliedSeq + 1] do
        local n = watch.buffer[watch.appliedSeq + 1]
        watch.buffer[watch.appliedSeq + 1] = nil
        ApplyDecoded(n[1], n[2], n[3], n[4], n[5], n[6])
        watch.appliedSeq = watch.appliedSeq + 1
    end
    if not watch.catchingUp and addon.Board_Update then
        addon:Board_Update()
    end
end

-- ── Nachrichten-Dispatch (von Network.lua OnCommReceived delegiert) ──────────────
-- Rückgabe true = Nachricht wurde behandelt (Network soll nicht weiterverarbeiten).

function addon:Spec_OnComm(t, p, sender, dist)
    if t == "SPECGAME" then
        if dist ~= "CHANNEL" then return true end
        local sid = p[2]
        if not sid then return true end
        lobby[sid] = {
            hostName = p[3], oppName = p[4], relayName = sender,
            hostClass = p[5], oppClass = p[6],
            turnNum = tonumber(p[7]) or 0, seq = tonumber(p[8]) or 0,
            ranked = (p[9] == "1"), build = p[10], lastSeen = GetTime(),
        }
        return true

    elseif t == "SPECJOIN" then
        if dist ~= "WHISPER" then return true end
        HostHandleJoin(sender, p[2])
        return true

    elseif t == "SPECPING" then
        if dist ~= "WHISPER" then return true end
        -- Zuschauer meldet sich (Host aktualisiert seine lastSeen-Zeit)
        if host and host.sessionId == p[2] and sender then
            hostSpectators[sender] = GetTime()
        end
        return true

    elseif t == "SPECLEAVE" then
        if dist ~= "WHISPER" then return true end
        if host and host.sessionId == p[2] and sender then
            hostSpectators[sender] = nil
            if addon.Spec_RefreshWatcherDisplay then addon:Spec_RefreshWatcherDisplay() end
        end
        return true

    elseif t == "SPECWATCH" then
        if dist ~= "WHISPER" then return true end
        -- Zuschauerliste vom Host — relevant für den Nicht-Host-Spieler UND für Zuschauer
        local relevant = (myGame and not myGame.isHost and myGame.sessionId == p[2])
                      or (watch and watch.sessionId == p[2])
        if relevant then
            local names = {}
            for n in (p[4] or ""):gmatch("[^,]+") do names[#names+1] = n end
            watcherView = { count = tonumber(p[3]) or #names, names = names }
            if addon.Spec_RefreshWatcherDisplay then addon:Spec_RefreshWatcherDisplay() end
        end
        return true

    elseif t == "SPECINIT" then
        if dist ~= "WHISPER" then return true end
        if not watch or watch.sessionId ~= p[2] then return true end
        watch.lastRecv = GetTime()
        local seed = tonumber(p[3])
        local firstClass, secondClass = p[4], p[5]
        local firstDeck, secondDeck = {}, {}
        for id in (p[6] or ""):gmatch("[^,]+") do firstDeck[#firstDeck+1] = id end
        for id in (p[7] or ""):gmatch("[^,]+") do secondDeck[#secondDeck+1] = id end
        watch.appliedSeq = 0
        watch.buffer = {}
        watch.catchingUp = true
        if addon.Spec_PrepareBoard then addon:Spec_PrepareBoard() end
        -- Identische Simulation wie der Host: Rolle "first" → P1 = Herausforderer
        addon:GE_StartGame(p[2], seed, "first", firstDeck, secondDeck, firstClass, secondClass)
        return true

    elseif t == "SPECLOG" then
        if dist ~= "WHISPER" then return true end
        if not watch or watch.sessionId ~= p[2] then return true end
        watch.lastRecv = GetTime()
        SpecApplyEntry(tonumber(p[3]), tonumber(p[4]), p[5], p[6], p[7], p[8], p[9])
        return true

    elseif t == "SPECLOGB" then
        if dist ~= "WHISPER" then return true end
        -- gebündeltes Aufhol-Log (siehe HostHandleJoin)
        if not watch or watch.sessionId ~= p[2] then return true end
        watch.lastRecv = GetTime()
        local seq = tonumber(p[3]) or 0
        for entry in (p[4] or ""):gmatch("[^;]+") do
            local pIdx, at, a1, a2, a3, a4 = entry:match("^(%d+)~([^~]*)~([^~]*)~([^~]*)~([^~]*)~([^~]*)$")
            if pIdx then SpecApplyEntry(seq, tonumber(pIdx), at, a1, a2, a3, a4) end
            seq = seq + 1
        end
        return true

    elseif t == "SPECDONE" then
        if dist ~= "WHISPER" then return true end
        if not watch or watch.sessionId ~= p[2] then return true end
        watch.lastRecv = GetTime()
        watch.catchingUp = false
        specBoardUp = true
        -- Falls beim Aufsetzen der Sim doch eine Mulligan-Auswahl aufging (Tester:
        -- "gelegentlich"), spätestens hier zu. Vorher verschwand sie erst beim
        -- nächsten Zugbeginn — also unter Umständen einen ganzen Zug lang klickbar.
        if addon.Mulligan_Hide then addon:Mulligan_Hide() end
        if addon.Spec_ShowBoard then addon:Spec_ShowBoard() end
        if addon.Board_Update then addon:Board_Update() end
        addon:Info("|cff00ff00[Arkana]|r Zuschauen aktiv – aufgeholt bis Aktion " .. tostring(watch.appliedSeq) .. ".")
        return true

    elseif t == "SPECACT" then
        if dist ~= "WHISPER" then return true end
        if not watch or watch.sessionId ~= p[2] then return true end
        watch.lastRecv = GetTime()
        SpecApplyEntry(tonumber(p[3]), tonumber(p[4]), p[5], p[6], p[7], p[8], p[9])
        return true

    elseif t == "SPECCOSM" then
        if dist ~= "WHISPER" then return true end
        -- Kartenrücken/Karten-Skins beider Spieler (nur relevant, wenn wir DIESES Spiel schauen)
        if watch and watch.sessionId == p[2] and addon.CB_OnSpecCosm then
            addon:CB_OnSpecCosm(p)
        end
        return true

    elseif t == "SPECEND" then
        if dist ~= "WHISPER" then return true end
        if watch and watch.sessionId == p[2] then
            addon:Spec_ShowEnded(p[3])
        end
        lobby[p[2]] = nil
        return true

    elseif t == "RKINFO" then
        if dist ~= "CHANNEL" then return true end
        -- Rang-Ansage eines Spielers (Ladder-Anzeige, unverifiziert)
        if addon.RK_OnInfo then addon:RK_OnInfo(p, sender) end
        return true

    elseif t == "RKPING" then
        if dist ~= "CHANNEL" then return true end
        -- Jemand hat die Rangliste geöffnet → eigene Ansage (gedrosselt)
        if addon.RK_Announce then addon:RK_Announce(true) end
        return true

    end
    return false
end
