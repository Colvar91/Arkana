local addon = Arkana

-- Lokale Karten-Sandbox. Die BOT_* Aliase bleiben bestehen, damit ältere
-- Netzwerk- und UI-Pfade den lokalen Gegner weiterhin korrekt erkennen.
local SANDBOX_NAME = "Trainingsziel"
local SANDBOX_CLASS = "WARRIOR"
local PASS_DELAY = 0.55
local activeSandbox

local function PrintError(message)
    print("|cffff0000[Arkana]|r " .. tostring(message))
end

local function ActiveDeck()
    local idx = ARKANA_CharData and ARKANA_CharData.activeDeckIndex
    local deck = idx and ARKANA_Decks and ARKANA_Decks[idx] or nil
    if not deck or #(deck.cards or {}) ~= 30 or not deck.class or deck.class == "CLASSLESS" then
        return nil
    end

    local used = {}
    for _, cardId in ipairs(deck.cards) do
        local card = ARKANA_CardData and ARKANA_CardData[cardId]
        if not card or (card.class ~= "NEUTRAL" and card.class ~= deck.class) then return nil end
        used[cardId] = (used[cardId] or 0) + 1
        local maxCopies = card.rarity == "LEGENDARY" and 1 or 2
        if used[cardId] > maxCopies then return nil end
        if addon.COL_Count and used[cardId] > addon:COL_Count(cardId) then return nil end
    end
    return deck
end

local function BuildFallbackDeck()
    local candidates = {}
    for cardId, card in pairs(ARKANA_CardData or {}) do
        if card.collectible == true and card.type == "MINION" and card.class == "NEUTRAL" then
            candidates[#candidates + 1] = {
                id = cardId,
                cost = tonumber(card.cost) or 0,
                name = tostring(card.name or cardId),
            }
        end
    end
    table.sort(candidates, function(a, b)
        if a.cost ~= b.cost then return a.cost < b.cost end
        if a.name ~= b.name then return a.name < b.name end
        return a.id < b.id
    end)

    local cards = {}
    for i = 1, math.min(15, #candidates) do
        cards[#cards + 1] = candidates[i].id
        cards[#cards + 1] = candidates[i].id
    end
    if #cards ~= 30 then return nil end
    return cards
end

local function ChooseRole(preference)
    preference = preference and string.lower(tostring(preference)) or nil
    if preference == "second" or preference == "zweiter" then return "second" end
    return "first"
end

local function RefreshBoard()
    if addon.Board_Update then addon:Board_Update() end
end

local function EndPassiveTurn(sandbox, turnToken)
    C_Timer.After(PASS_DELAY, function()
        if activeSandbox ~= sandbox or sandbox.turnToken ~= turnToken then return end
        local state = addon.GE_State and addon:GE_State()
        if not state or state.phase ~= "play" or state.activePlayer ~= sandbox.playerIdx then return end
        addon:GE_ApplyAs(sandbox.playerIdx, "END_TURN")
        RefreshBoard()
    end)
end

function addon:Sandbox_Name() return SANDBOX_NAME end
function addon:Sandbox_IsActive() return activeSandbox ~= nil end

function addon:Sandbox_OnTurnStart(playerIdx)
    local sandbox = activeSandbox
    if not sandbox or playerIdx ~= sandbox.playerIdx then return end
    sandbox.turnToken = (sandbox.turnToken or 0) + 1
    EndPassiveTurn(sandbox, sandbox.turnToken)
end

function addon:Sandbox_OnGameEnd()
    activeSandbox = nil
end

function addon:Sandbox_End()
    if not activeSandbox or not (addon.GE_IsSandbox and addon:GE_IsSandbox()) then return false end
    addon:GE_EndGame("SANDBOX_END")
    return true
end

function addon:Sandbox_Start(preference)
    if not (addon.SEC_CanUseSandbox and addon:SEC_CanUseSandbox()) then
        PrintError("Die Karten-Sandbox ist nur für Annila-Schattenhain freigegeben.")
        return false
    end
    if activeSandbox or (addon.Net_IsBusy and addon:Net_IsBusy()) then
        PrintError("Es läuft bereits eine Partie oder Herausforderung.")
        return false
    end
    if addon.IsSpectating and addon:IsSpectating() then
        PrintError("Beende zuerst den Zuschauermodus.")
        return false
    end

    local deck = ActiveDeck()
    local myCards, myClass, deckName
    if deck then
        myCards, myClass, deckName = deck.cards, deck.class, deck.name
    else
        myCards = BuildFallbackDeck()
        myClass, deckName = SANDBOX_CLASS, "Sandbox-Testdeck"
        if not myCards then
            PrintError("Für die Sandbox konnte kein Startdeck erstellt werden.")
            return false
        end
    end

    local targetCards = BuildFallbackDeck()
    if not targetCards then
        PrintError("Für das Trainingsziel konnte kein Deck erstellt werden.")
        return false
    end

    local role = ChooseRole(preference)
    local myIdx = role == "first" and 1 or 2
    local targetIdx = myIdx == 1 and 2 or 1
    local now = GetServerTime and GetServerTime() or time()
    local sessionId = "SANDBOX-" .. tostring(now) .. "-" .. tostring(math.random(1000, 9999))
    local sandbox = { sessionId = sessionId, playerIdx = targetIdx, turnToken = 0 }
    activeSandbox = sandbox
    addon.RK_LastDelta = nil

    addon:GE_StartGame(sessionId, now + math.random(1, 100000), role,
        myCards, targetCards, myClass, SANDBOX_CLASS, { practice = true, sandbox = true })

    local state = addon:GE_State()
    if not state then
        activeSandbox = nil
        PrintError("Die Sandbox konnte nicht gestartet werden.")
        return false
    end
    state.myDeckName = deckName
    state.players[targetIdx].hero.health = 9999

    -- Keine Mulligan-Unterbrechung: Das Startdeck ist nur der Ausgangspunkt,
    -- weitere Karten werden direkt über die Testfläche auf die Hand gelegt.
    addon:GE_ApplyAs(myIdx, "MULLIGAN_CHOICES", {})
    addon:GE_ApplyAs(targetIdx, "MULLIGAN_CHOICES", {})
    addon:GE_ApplyAs(targetIdx, "MULLIGAN_DONE")
    addon:GE_ApplyAs(myIdx, "MULLIGAN_DONE")
    -- Die Sandbox beginnt bewusst ohne zufällige Starthand. Testkarten werden
    -- anschließend ausschließlich gezielt über die angedockte Testfläche gewählt.
    addon:GE_SandboxClearHand()
    addon:GE_SandboxFillMana()

    if addon.MM_Hide then addon:MM_Hide() end
    print("|cff00ff00[Arkana]|r Karten-Sandbox gestartet: leere Hand, 10/10 Mana und ein Trainingsziel mit 9999 Leben.")
    return true
end

-- Kompatibilität für bestehende Aufrufe in Network.lua und ältere Slash-Befehle.
function addon:BOT_Name() return addon:Sandbox_Name() end
function addon:BOT_IsActive() return addon:Sandbox_IsActive() end
function addon:BOT_OnTurnStart(playerIdx) return addon:Sandbox_OnTurnStart(playerIdx) end
function addon:BOT_OnGameEnd() return addon:Sandbox_OnGameEnd() end
function addon:BOT_Start(preference) return addon:Sandbox_Start(preference) end
