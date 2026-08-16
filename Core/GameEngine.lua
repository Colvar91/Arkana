local addon = Arkana

-- Hash vor allen Runtime-Injektionen: enthält nur ClassicCardData (stabil auf allen Clients)
ARKANA_CATALOG_HASH = ARKANA_ComputeCatalogHash()

-- Freeze-on-hit Patch für Wasserelementar (CS2_033) — nach Hash, kein CATALOG_HASH-Einfluss
do
    local c = ARKANA_CardData and ARKANA_CardData["CS2_033"]
    if c and not c._freezePatched then
        c.tags = c.tags or {}
        c.tags[#c.tags+1] = {type="FREEZE_ON_HIT"}
        c._freezePatched = true
    end
end

-- ── PRNG (Numerical Recipes LCG, 16-bit split) ───────────────────────────────

local function PrngNext(state)
    local lo = state % 65536
    local hi = math.floor(state / 65536)
    return ((1664525 * lo) + ((1664525 * hi * 65536) % 4294967296) + 1013904223) % 4294967296
end

-- ── Active game state ─────────────────────────────────────────────────────────

local gs = nil
local FireTriggers   -- forward declaration (DealDmgToEntity/HealEntity sind vor FireTriggers definiert)
local RecalcAuras    -- forward declaration (SilenceMinion ist vor RecalcAuras definiert)
local CheckSecrets   -- forward declaration (RunDeathPipeline ist vor CheckSecrets definiert)
local DealDmgToEntity -- forward declaration (DrawCard/Fatigue ist vor DealDmgToEntity definiert)

local function P(idx) return gs.players[idx] end
local function OtherIdx(idx) return idx == 1 and 2 or 1 end

-- ── Tag / stat helpers ────────────────────────────────────────────────────────

local function HasTag(tags, tagType)
    for _, t in ipairs(tags or {}) do
        if t.type == tagType then return true end
    end
    return false
end

local function GetTag(tags, tagType)
    for _, t in ipairs(tags or {}) do
        if t.type == tagType then return t end
    end
end

local function FindOnBoard(entityId)
    for pIdx = 1, 2 do
        for bIdx, m in ipairs(P(pIdx).board) do
            if m.entityId == entityId then return m, pIdx, bIdx end
        end
    end
end

local function EntityName(entityId)
    if entityId == 1 or entityId == 2 then
        return entityId == (gs and gs.myPlayerIdx) and "eigener Held" or "gegnerischer Held"
    end
    local m = FindOnBoard(entityId)
    return m and ((ARKANA_CardData[m.id] or {}).name or m.id) or "?"
end

-- Kartenname aus einer Karten-ID (fürs Spiellog; Fallback = ID selbst)
local function CardName(id)
    return (ARKANA_CardData[id] or {}).name or id
end

local function MinionEffAtk(m)
    local a = m.baseAttack + (m.auraAttack or 0)
    for _, e in ipairs(m.enchantments) do a = a + (e.attack or 0) end
    if m.damageTaken > 0 then
        local enr = GetTag(m.tags, "ENRAGE")
        if enr then a = a + (enr.attack or 0) end
    end
    return math.max(0, a)
end

local function MinionEffMaxHp(m)
    local h = m.baseHealth + (m.auraHealth or 0)
    for _, e in ipairs(m.enchantments) do h = h + (e.health or 0) end
    return h
end

local function MinionCurHp(m) return MinionEffMaxHp(m) - m.damageTaken end

local function SilenceMinion(m)
    local curHp = MinionCurHp(m)
    local hadAtkEqualsHp = HasTag(m.tags, "ATK_EQUALS_HP")
    m.enchantments = {}; m.tags = {}; m.triggers = {}
    m.secondaryEffect = nil; m.divineShield = false; m.stealthed = false
    m.auraAttack = 0; m.auraHealth = 0; m.silenced = true
    if hadAtkEqualsHp then m.baseAttack = (ARKANA_CardData[m.id] and ARKANA_CardData[m.id].attack) or 0 end
    local newMax = MinionEffMaxHp(m)
    m.damageTaken = newMax - math.min(curHp, newMax)
    RecalcAuras()
end

local function SpellDmgBonus(pIdx)
    local b = 0
    for _, m in ipairs(P(pIdx).board) do
        local sd = GetTag(m.tags, "SPELL_DAMAGE")
        if sd then b = b + (sd.value or 0) end
    end
    return b
end

-- Prophet Velen verdoppelt NUR die Heilung (Betreiber-Entscheidung, weicht vom
-- Original ab — dort zählt auch Zauberschaden). Der Kartentext sagt dasselbe.
local function HealMult(pIdx)
    for _, m in ipairs(P(pIdx).board) do
        if m.id == "EX1_350" then return 2 end
    end
    return 1
end

local function FirstMinionDiscount(pIdx)
    for _, m in ipairs(P(pIdx).board) do
        if m.id == "EX1_076" then return 1 end
    end
    return 0
end

local function WeaponEffAtk(pIdx)
    local wep = P(pIdx).weapon
    if not wep then return 0 end
    local atk = wep.attack or 0
    for _, m in ipairs(P(pIdx).board) do
        if m.damageTaken > 0 then
            local enr = GetTag(m.tags, "ENRAGE")
            if enr and enr.weaponAttack then atk = atk + enr.weaponAttack end
        end
    end
    return atk
end

-- ── canAttack ─────────────────────────────────────────────────────────────────

local function MaxAttacks(m)
    if HasTag(m.tags, "WINDFURY") then return 2 end
    if m.damageTaken > 0 then
        local enr = GetTag(m.tags, "ENRAGE")
        if enr and enr.windfury then return 2 end
    end
    return 1
end

local function UpdateCanAttack(m)
    local chargeFromAura = false
    if (ARKANA_CardData[m.id] or {}).race == "BEAST" then
        for _, bm in ipairs(P(m.controller).board) do
            if GetTag(bm.tags, "CHARGE_BEAST") then chargeFromAura = true; break end
        end
    end
    -- Südmeerdeckmatrose: Ansturm wenn Waffe angelegt
    if m.id == "CS2_146" and P(m.controller).weapon then chargeFromAura = true end
    m.canAttackThisTurn = (not m.summonedThisTurn or chargeFromAura or HasTag(m.tags, "CHARGE"))
        and not m.frozen
        and not HasTag(m.tags, "CANT_ATTACK")
        and m.attacksThisTurn < MaxAttacks(m)
        and MinionEffAtk(m) > 0
end

-- ── Aura recalculation ────────────────────────────────────────────────────────

RecalcAuras = function()
    for pIdx = 1, 2 do
        for _, m in ipairs(P(pIdx).board) do m.auraAttack = 0; m.auraHealth = 0 end
    end
    for pIdx = 1, 2 do
        local board = P(pIdx).board
        for i, src in ipairs(board) do
            local aura = GetTag(src.tags, "AURA")
            if aura then
                for j, tgt in ipairs(board) do
                    if tgt ~= src then
                        local inRange = aura.range == "ALL_FRIENDLY"
                            or (aura.range == "ADJACENT" and math.abs(i - j) == 1)
                            or (aura.range == "ALL_FRIENDLY_BEASTS"  and (ARKANA_CardData[tgt.id] or {}).race == "BEAST")
                            or (aura.range == "ALL_FRIENDLY_PIRATES" and (ARKANA_CardData[tgt.id] or {}).race == "PIRATE")
                            or (aura.range == "ALL_FRIENDLY_MURLOCS" and (ARKANA_CardData[tgt.id] or {}).race == "MURLOC")
                        if inRange then
                            tgt.auraAttack = tgt.auraAttack + (aura.attack or 0)
                            tgt.auraHealth = tgt.auraHealth + (aura.health or 0)
                        end
                    end
                end
            end
        end
    end
    -- SELF_PER_MURLOC aura (Trübauge der Alte: +1 ATK pro anderem Murloc auf dem Feld)
    for pIdx = 1, 2 do
        for _, m in ipairs(P(pIdx).board) do
            local aura = GetTag(m.tags, "AURA")
            if aura and aura.range == "SELF_PER_MURLOC" then
                local count = 0
                for pi = 1, 2 do
                    for _, bm in ipairs(P(pi).board) do
                        if bm ~= m and (ARKANA_CardData[bm.id] or {}).race == "MURLOC" then
                            count = count + 1
                        end
                    end
                end
                m.auraAttack = m.auraAttack + count * (aura.attack or 1)
            end
        end
    end
    -- AURA_OWN_MINION_COST_INCREASE / COST_REDUCE
    for pIdx = 1, 2 do
        local inc, red, spellRed = 0, 0, 0
        for _, m in ipairs(P(pIdx).board) do
            local ti = GetTag(m.tags, "AURA_OWN_MINION_COST_INCREASE")
            if ti then inc = inc + (ti.value or 0) end
            local tr = GetTag(m.tags, "AURA_OWN_MINION_COST_REDUCE")
            if tr then red = red + (tr.value or 0) end
            local ts = GetTag(m.tags, "AURA_OWN_SPELL_COST_REDUCE")
            if ts then spellRed = spellRed + (ts.value or 0) end
        end
        P(pIdx).minionCostIncrease = inc
        P(pIdx).minionCostReduction = red
        P(pIdx).auraSpellCostReduction = spellRed
    end
    -- AURA_ALL_MINION_COST_INCREASE (Managespenst: alle Diener beider Spieler kosten mehr)
    local allInc = 0
    for pi = 1, 2 do
        for _, m in ipairs(P(pi).board) do
            local tag = GetTag(m.tags, "AURA_ALL_MINION_COST_INCREASE")
            if tag then allInc = allInc + (tag.value or 0) end
        end
    end
    if allInc > 0 then
        for pi = 1, 2 do P(pi).minionCostIncrease = (P(pi).minionCostIncrease or 0) + allInc end
    end
    -- ATK_EQUALS_HP (Lichtbrut: Angriff = aktuelle Leben)
    for pIdx = 1, 2 do
        for _, m in ipairs(P(pIdx).board) do
            if HasTag(m.tags, "ATK_EQUALS_HP") then
                m.baseAttack = math.max(0, MinionCurHp(m))
                m.auraAttack = 0
            end
        end
    end
    -- canAttackThisTurn nach Aura-/Enchantment-Änderungen neu berechnen
    for pIdx = 1, 2 do
        for _, m in ipairs(P(pIdx).board) do UpdateCanAttack(m) end
    end
end

-- ── Build minion from CardData ────────────────────────────────────────────────

local function NewMinion(cardId, controller)
    local card = ARKANA_CardData[cardId]
    if not card then return nil end
    local m = {
        entityId        = nil,
        id              = cardId,
        controller      = controller,
        baseAttack      = card.attack  or 0,
        baseHealth      = card.health  or 1,
        damageTaken     = 0,
        enchantments    = {},
        auraAttack      = 0,
        auraHealth      = 0,
        tags            = {},
        triggers        = {},
        secondaryEffect = card.secondaryEffect,
        frozen          = false,
        divineShield    = HasTag(card.tags, "DIVINE_SHIELD"),
        stealthed       = HasTag(card.tags, "STEALTH"),
        canAttackThisTurn = false,
        attacksThisTurn = 0,
        summonedThisTurn = true,
    }
    for _, t in ipairs(card.tags or {}) do m.tags[#m.tags+1] = t end
    for _, t in ipairs(card.triggers or {}) do m.triggers[#m.triggers+1] = t end
    UpdateCanAttack(m)
    return m
end

-- Erstellt unabhängige Kopien der kleinen Tag-/Trigger-/Verzauberungstabellen.
-- Ohne Tiefenkopie würden Ablauf oder Schweigen einer Kopie auch das Original
-- verändern, weil beide Diener dieselben Tabellen referenzieren.
local function CopyValue(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local copy = {}
    seen[value] = copy
    for key, child in pairs(value) do
        copy[CopyValue(key, seen)] = CopyValue(child, seen)
    end
    return copy
end

local function CopyMinionState(source, controller)
    local clone = NewMinion(source.id, controller)
    if not clone then return nil end

    -- Gedruckte beziehungsweise dauerhaft veränderte Werte und aktueller
    -- Schaden gehören zur Kopie. Aurawerte werden absichtlich nicht kopiert:
    -- RecalcAuras bestimmt sie anschließend anhand der neuen Spielfeldseite.
    clone.baseAttack = source.baseAttack
    clone.baseHealth = source.baseHealth
    clone.damageTaken = source.damageTaken or 0
    clone.enchantments = CopyValue(source.enchantments or {})
    clone.tags = CopyValue(source.tags or {})
    clone.triggers = CopyValue(source.triggers or {})
    clone.secondaryEffect = CopyValue(source.secondaryEffect)

    clone.displayId = source.displayId
    clone.silenced = source.silenced or false
    clone.divineShield = source.divineShield or false
    clone.stealthed = source.stealthed or false
    clone.frozen = source.frozen or false
    clone.immuneThisTurn = source.immuneThisTurn or false
    clone.minHealthThisTurn = source.minHealthThisTurn
    clone.dieAtStartOfTurn = source.dieAtStartOfTurn
    clone.dieEndOfTurn = source.dieEndOfTurn
    clone.ancestralSpirit = source.ancestralSpirit
    clone.extraDeathrattle = source.extraDeathrattle
    clone.drawOnAttack = source.drawOnAttack

    -- Der Manipulator ist eine neue Instanz unter Kontrolle des Ausspielers.
    -- Angriffszähler und temporäre Kontrollrückgabe dürfen daher nicht vom
    -- Ziel übernommen werden. Zeitlich begrenzte Verstohlenheit wird dagegen
    -- auf den neuen Besitzer abgebildet.
    clone.controller = controller
    clone.auraAttack = 0
    clone.auraHealth = 0
    clone.summonedThisTurn = true
    clone.attacksThisTurn = 0
    clone.returnToPlayer = nil
    clone.stealthedByVerhullen = source.stealthedByVerhullen and controller or nil
    return clone
end

-- ── Mana ─────────────────────────────────────────────────────────────────────

local function AvailMana(pIdx)
    local mn = P(pIdx).mana
    return mn.currentPermanent + mn.temporary
end

local function SpendMana(pIdx, amount)
    local mn = P(pIdx).mana
    local temp = math.min(mn.temporary, amount)
    mn.temporary = mn.temporary - temp
    mn.currentPermanent = mn.currentPermanent - (amount - temp)
end

-- ── Draw / fatigue ────────────────────────────────────────────────────────────

local function DrawCard(pIdx)
    local p = P(pIdx)
    if #p.deck == 0 then
        p.fatigue = p.fatigue + 1
        local dmg = p.fatigue
        -- Über DealDmgToEntity statt dupliziertem Inline-Schaden: das deckt
        -- Immunität (Eisblock-Folgezug) ab, die der alte Inline-Code komplett
        -- ausgelassen hat (das Spiel endete bei tödlichem Fatigue nie).
        -- Eisblock darf Fatigue am EIGENEN Zug (z.B. eigenes Tiefenlichtorakel
        -- bei leerem Deck) NICHT retten — nur wenn der Gegner das Ziehen
        -- erzwingt (gs.activePlayer ~= pIdx), sonst würde Eisblock "verschwendet"
        -- statt den gesamten Gegnerzug abzudecken (User-Entscheidung).
        local allowSecretSave = (gs.activePlayer ~= pIdx)
        DealDmgToEntity(pIdx, pIdx, dmg, allowSecretSave)
        addon:GE_Log(pIdx, "Fatigue: " .. dmg .. " Schaden")
        -- DealDmgToEntity() feuert GE_OnDamage() bereits selbst (Fließtext-
        -- Zahl) — hier nur noch der Fatigue-spezifische Impact-Animations-Hook
        addon:GE_OnFatigueDamage(pIdx, dmg)
        return
    end
    local id = table.remove(p.deck, 1)
    if #p.hand >= 10 then
        addon:GE_Log(pIdx, "Karte verbrannt: " .. CardName(id))
        return
    end
    local eid = gs.entityCounter; gs.entityCounter = gs.entityCounter + 1
    local cost = (ARKANA_CardData[id] and ARKANA_CardData[id].cost) or 0
    p.hand[#p.hand+1] = { entityId = eid, id = id, cost = cost }
end

-- ── Deck shuffle ─────────────────────────────────────────────────────────────

local function ShuffleDeck(deck)
    for i = #deck, 2, -1 do
        gs.prngState = PrngNext(gs.prngState)
        local j = (gs.prngState % i) + 1
        deck[i], deck[j] = deck[j], deck[i]
    end
end

-- ── Victory ───────────────────────────────────────────────────────────────────

local function CheckVictory()
    if gs.phase == "ended" then return true end
    -- Die lokale Sandbox hat absichtlich kein Sieg-/Niederlage-Ziel. Helden,
    -- die durch einen Kartentest auf 0 fallen, bleiben deshalb mit 1 Leben im
    -- Spiel, bis der Tester die Sandbox selbst neutral beendet.
    if gs.sandbox then
        if P(1).hero.health <= 0 then P(1).hero.health = 1 end
        if P(2).hero.health <= 0 then P(2).hero.health = 1 end
        return false
    end
    local d1 = P(1).hero.health <= 0
    local d2 = P(2).hero.health <= 0
    if d1 or d2 then
        local winner = (d1 and d2) and "DRAW" or (d1 and "second" or "first")
        addon:GE_EndGame(winner)
        return true
    end
    return false
end

-- ── Effects ───────────────────────────────────────────────────────────────────

-- allowSecretSave (default true): Eisblock/HERO_WOULD_DIE nur greifen lassen,
-- wenn der Schaden das erlaubt — DrawCard() reicht hier false durch für Fatigue
-- am eigenen Zug (siehe dort), damit Eisblock nicht durch selbstverursachtes
-- Fatigue "verschwendet" wird.
DealDmgToEntity = function(pIdx, targetEntityId, amount, allowSecretSave)
    if allowSecretSave == nil then allowSecretSave = true end
    if amount <= 0 then return end
    if targetEntityId == 1 or targetEntityId == 2 then
        local hero = P(targetEntityId).hero
        if hero.immuneThisTurn then return end
        if hero.armor >= amount then
            hero.armor = hero.armor - amount
        else
            hero.health = hero.health - (amount - hero.armor)
            hero.armor  = 0
        end
        FireTriggers("TRIGGER_ON_FRIENDLY_DAMAGE", { pIdx = targetEntityId })
        if allowSecretSave and hero.health <= 0 then
            -- Eisblock u.ä.: VOR CheckVictory() prüfen, sonst wird das Spiel schon
            -- hier beendet, bevor der Rettungs-Secret überhaupt eine Chance hat
            local iceData = {}
            if CheckSecrets(targetEntityId, "HERO_WOULD_DIE", iceData) then
                hero.health = 1
                hero.immuneThisTurn = true
            end
        end
        CheckVictory()
    else
        local m = FindOnBoard(targetEntityId)
        if not m then return end
        if m.immuneThisTurn then return end
        if m.divineShield then m.divineShield = false; return end
        m.damageTaken = m.damageTaken + amount
        if m.minHealthThisTurn then
            -- Befehlsruf: Leben darf diesen Zug nicht unter minHealthThisTurn fallen —
            -- damageTaken direkt deckeln (nicht nur die Anzeige), sonst "stirbt" der Diener
            -- rückwirkend sobald der Flag am Zugende zurückgesetzt wird.
            local cap = MinionEffMaxHp(m) - m.minHealthThisTurn
            if m.damageTaken > cap then m.damageTaken = cap end
        end
        UpdateCanAttack(m)  -- Enrage kann Windzorn freischalten, muss sofort wirken
        FireTriggers("TRIGGER_ON_DAMAGE", { m = m })
        FireTriggers("TRIGGER_ON_FRIENDLY_DAMAGE", { pIdx = m.controller })
    end
    addon:GE_OnDamage(targetEntityId, amount)
end

local function HealEntity(targetEntityId, amount, casterPIdx)
    -- Auchenaiseelenpriesterin: Heilung → Schaden
    if casterPIdx then
        for _, bm in ipairs(P(casterPIdx).board) do
            if bm.id == "EX1_591" then
                DealDmgToEntity(casterPIdx, targetEntityId, amount)
                return
            end
        end
    end
    if targetEntityId == 1 or targetEntityId == 2 then
        local hero = P(targetEntityId).hero
        if hero.health < 30 then
            hero.health = math.min(30, hero.health + amount)
            FireTriggers("TRIGGER_ON_HEAL", { pIdx = targetEntityId })
        end
        addon:GE_OnHeal(targetEntityId, amount)
    else
        local m = FindOnBoard(targetEntityId)
        if m then
            if m.damageTaken > 0 then
                m.damageTaken = math.max(0, m.damageTaken - amount)
                FireTriggers("TRIGGER_ON_HEAL", { pIdx = m.controller, isMinion = true })
            end
            addon:GE_OnHeal(targetEntityId, amount)
        end
    end
end

-- Schwert der Gerechtigkeit (EX1_366): nach jedem beschworenen Diener +1/+1, Waffe verliert 1 Haltbarkeit
local function CheckSwordOfJustice(pIdx, m)
    local wep = P(pIdx).weapon
    if wep and wep.id == "EX1_366" and m then
        m.enchantments[#m.enchantments+1] = {attack=1, health=1, expiresEndOfTurn=false, source=0}
        wep.durability = wep.durability - 1
        if wep.durability <= 0 then P(pIdx).weapon = nil end
        RecalcAuras()
    end
end

local function SummonToken(pIdx, cardId)
    local board = P(pIdx).board
    if #board >= 7 then return end
    local eid = gs.entityCounter; gs.entityCounter = gs.entityCounter + 1
    local m = NewMinion(cardId, pIdx)
    if not m then return end
    m.entityId = eid
    board[#board+1] = m
    RecalcAuras()
    -- Messerjongleur & Co. reagieren auf JEDE Beschwörung, auch auf Token
    -- (vorher feuerte nur ExecPlay/SummonMinionAt → kein zweites Messer).
    FireTriggers("TRIGGER_ON_SUMMON", { m = m, pIdx = pIdx })
    CheckSwordOfJustice(pIdx, m)
end

-- ── Triggers ─────────────────────────────────────────────────────────────────

local SummonMinionAt  -- forward declaration, defined after BATTLECRY table

FireTriggers = function(triggerType, data)
    local order = { gs.activePlayer, OtherIdx(gs.activePlayer) }
    for _, pIdx in ipairs(order) do
        local snapshot = {}; for _, m in ipairs(P(pIdx).board) do snapshot[#snapshot+1] = m end
        for _, m in ipairs(snapshot) do
            for _, trig in ipairs(m.triggers) do
                if trig.type == triggerType then
                    local fires = false
                    if triggerType == "TRIGGER_ON_FRIENDLY_DEATH" then
                        if trig.anyDeath then
                            fires = data.m ~= m
                        else
                            fires = data.pIdx == pIdx and data.m ~= m
                        end
                        if fires and trig.onlyIfBeast then
                            local card = ARKANA_CardData[data.m.id]
                            fires = card and card.race == "BEAST"
                        end
                    elseif triggerType == "TRIGGER_END_TURN" then
                        fires = gs.activePlayer == pIdx
                        if fires and trig.onlyIfSecret then fires = #P(pIdx).secrets > 0 end
                    elseif triggerType == "TRIGGER_START_TURN" then
                        fires = gs.activePlayer == pIdx
                    elseif triggerType == "TRIGGER_ON_SPELL" or triggerType == "TRIGGER_AFTER_SPELL" then
                        fires = trig.anyPlayer or data.pIdx == pIdx
                        -- Diener, die der Zauber erst herübergeholt hat, reagieren nicht mit
                        if fires and data.castBoard and pIdx == data.pIdx then
                            fires = data.castBoard[m.entityId] == true
                        end
                    elseif triggerType == "TRIGGER_ON_DAMAGE" then
                        if trig.anyMinion then
                            fires = not trig.friendlyOnly or data.m.controller == pIdx
                        else
                            fires = data.m == m
                        end
                    elseif triggerType == "TRIGGER_ON_HEAL" then
                        -- anyPlayer: Heilungen auf beiden Spielfeldseiten zählen.
                        -- Die Klerikerin von Nordhain reagiert auf jeden tatsächlich
                        -- geheilten Diener, unabhängig von dessen Besitzer.
                        fires = trig.anyPlayer or data.pIdx == pIdx
                        -- Klerikerin von Nordhain: nur Diener-Heilung, nicht der Held
                        if fires and trig.minionOnly then fires = data.isMinion == true end
                    elseif triggerType == "TRIGGER_ON_SUMMON" then
                        fires = data.m ~= m
                        if not trig.onlyIfMurloc then fires = fires and data.pIdx == pIdx end
                        if fires and trig.onlyIfBeast then
                            local card = ARKANA_CardData[data.m.id]
                            fires = card and card.race == "BEAST"
                        end
                        if fires and trig.onlyIfMurloc then
                            local card = ARKANA_CardData[data.m.id]
                            fires = card and card.race == "MURLOC"
                        end
                        if fires and trig.maxAtk then
                            local atk = (data.m.baseAttack or 0) + (data.m.auraAttack or 0)
                            fires = atk <= trig.maxAtk
                        end
                    elseif triggerType == "TRIGGER_ON_FRIENDLY_DAMAGE" then
                        fires = data.pIdx == pIdx
                    elseif triggerType == "TRIGGER_ON_CARD_PLAYED" then
                        fires = (trig.anyPlayer or data.pIdx == pIdx)
                            and m.entityId ~= (data.playedEntityId or -1)
                        -- castBoard enthält nur das Brett des Zaubernden. Bei
                        -- anyPlayer-Triggern (Geheimnisbewahrerin) darf es die
                        -- bereits liegende Karte des Gegners nicht herausfiltern.
                        if fires and data.castBoard and pIdx == data.pIdx then
                            fires = data.castBoard[m.entityId] == true
                        end
                        if fires and trig.onlyIfSecret then
                            fires = HasTag((ARKANA_CardData[data.cardId] or {}).tags, "SECRET")
                        end
                        if fires and trig.onlyIfOverload then
                            fires = HasTag((ARKANA_CardData[data.cardId] or {}).tags, "OVERLOAD")
                        end
                    end
                    if fires then
                        local eff = trig.effect
                        local val = trig.value
                        if eff == "DEAL_DAMAGE" then
                            DealDmgToEntity(pIdx, trig.target or OtherIdx(pIdx), val)
                        elseif eff == "DRAW_CARDS" then
                            if trig.chance50 then gs.prngState = PrngNext(gs.prngState) end
                            if not trig.chance50 or (gs.prngState % 2 == 1) then
                                for _ = 1, (val or 1) do DrawCard(pIdx) end
                            end
                        elseif eff == "GIVE_SELF_ATTACK" then
                            -- thisTurn: Manasüchtige verliert den Bonus am Zugende (EndTurn räumt auf)
                            m.enchantments[#m.enchantments+1] = { attack = val, expiresEndOfTurn = trig.thisTurn or false }
                            UpdateCanAttack(m)
                        elseif eff == "GIVE_SELF_BUFF" then
                            m.enchantments[#m.enchantments+1] = { attack = (trig.attack or 0), health = (trig.health or 0), expiresEndOfTurn = false, source = 0 }
                            RecalcAuras()
                        elseif eff == "HEAL_ALL_FRIENDLY_MINIONS" then
                            for _, fm in ipairs(P(pIdx).board) do
                                if fm.damageTaken > 0 then
                                    fm.damageTaken = math.max(0, fm.damageTaken - val)
                                end
                            end
                        elseif eff == "GIVE_ARMOR" then
                            P(pIdx).hero.armor = P(pIdx).hero.armor + val
                        elseif eff == "DEAL_SELF_DAMAGE" then
                            DealDmgToEntity(pIdx, m.entityId, val)
                        elseif eff == "DAMAGE_ALL_MINIONS" then
                            local snap = {}
                            for pi = 1, 2 do
                                for _, bm in ipairs(P(pi).board) do snap[#snap+1] = bm.entityId end
                            end
                            for _, eid in ipairs(snap) do DealDmgToEntity(pIdx, eid, val) end
                        elseif eff == "DEAL_DAMAGE_ALL_OTHERS" then
                            local op = OtherIdx(pIdx)
                            local tgts = {pIdx, op}
                            for _, bm in ipairs(P(pIdx).board) do if bm ~= m then tgts[#tgts+1] = bm.entityId end end
                            for _, bm in ipairs(P(op).board)   do tgts[#tgts+1] = bm.entityId end
                            for _, tid in ipairs(tgts) do DealDmgToEntity(pIdx, tid, val) end
                        elseif eff == "DEAL_DAMAGE_RANDOM_ENEMY" then
                            local op = OtherIdx(pIdx)
                            local tgts = {op}
                            for _, bm in ipairs(P(op).board) do tgts[#tgts+1] = bm.entityId end
                            gs.prngState = PrngNext(gs.prngState)
                            local hit = tgts[(gs.prngState % #tgts) + 1]
                            addon:GE_Log(pIdx, (ARKANA_CardData[m.id] or {}).name .. ": " .. val .. " Schaden → " .. EntityName(hit))
                            DealDmgToEntity(pIdx, hit, val)
                        elseif eff == "GIVE_ALL_FRIENDLY_HEALTH" then
                            for _, fm in ipairs(P(pIdx).board) do
                                fm.enchantments[#fm.enchantments+1] = {attack=0, health=val, expiresEndOfTurn=false, source=0}
                            end
                            RecalcAuras()
                        elseif eff == "GIVE_RANDOM_FRIENDLY_BUFF" then
                            local cands = {}
                            for _, fm in ipairs(P(pIdx).board) do if fm ~= m then cands[#cands+1] = fm end end
                            if #cands > 0 then
                                gs.prngState = PrngNext(gs.prngState)
                                local pick = cands[(gs.prngState % #cands) + 1]
                                pick.enchantments[#pick.enchantments+1] = {attack=(trig.attack or 0), health=(trig.health or 0), expiresEndOfTurn=false, source=0}
                                RecalcAuras()
                            end
                        elseif eff == "GRANT_CHARGE_TO_SUMMONED" then
                            data.m.canAttackThisTurn = true
                            if not HasTag(data.m, "CHARGE") then
                                data.m.tags[#data.m.tags+1] = {type="CHARGE"}
                            end
                        elseif eff == "DESTROY_ALL_MINIONS" then
                            for pi = 1, 2 do
                                for _, bm in ipairs(P(pi).board) do bm.damageTaken = bm.damageTaken + 9999 end
                            end
                            -- RunDeathPipeline NICHT hier aufrufen – wird nach FireTriggers in StartTurn erledigt
                        elseif eff == "HEAL_ALL_FRIENDLY" then
                            for _, fm in ipairs(P(pIdx).board) do HealEntity(fm.entityId, val, pIdx) end
                        elseif eff == "HEAL_RANDOM_DAMAGED_FRIENDLY" then
                            local cands = {}
                            if P(pIdx).hero.health < 30 then cands[#cands+1] = pIdx end
                            for _, fm in ipairs(P(pIdx).board) do
                                if fm.damageTaken > 0 then cands[#cands+1] = fm.entityId end
                            end
                            if #cands > 0 then
                                gs.prngState = PrngNext(gs.prngState)
                                HealEntity(cands[(gs.prngState % #cands) + 1], val, pIdx)
                            end
                        elseif eff == "SUMMON_TOKEN" then
                            SummonMinionAt(pIdx, trig.tokenId, #P(pIdx).board + 1)
                        elseif eff == "ADD_TO_HAND" then
                            if #P(pIdx).hand < 10 then
                                local base = ARKANA_CardData[trig.cardId]
                                P(pIdx).hand[#P(pIdx).hand+1] = {entityId=gs.entityCounter, id=trig.cardId, cost=(base and base.cost or 0)}
                                gs.entityCounter = gs.entityCounter + 1
                            end
                        elseif eff == "ADD_RANDOM_TO_HAND" then
                            if #P(pIdx).hand < 10 and trig.cardIds and #trig.cardIds > 0 then
                                gs.prngState = PrngNext(gs.prngState)
                                local pick = trig.cardIds[(gs.prngState % #trig.cardIds) + 1]
                                local base = ARKANA_CardData[pick]
                                P(pIdx).hand[#P(pIdx).hand+1] = {entityId=gs.entityCounter, id=pick, cost=(base and base.cost or 0)}
                                gs.entityCounter = gs.entityCounter + 1
                            end
                        elseif eff == "GIVE_SPELL_COPY_TO_OPPONENT" then
                            local spellId = data.spellId
                            if spellId then
                                local recipient = OtherIdx(data.pIdx)
                                if #P(recipient).hand < 10 then
                                    local base = ARKANA_CardData[spellId]
                                    gs.entityCounter = gs.entityCounter + 1
                                    P(recipient).hand[#P(recipient).hand+1] = {entityId=gs.entityCounter, id=spellId, cost=(base and base.cost or 0)}
                                end
                            end
                        elseif eff == "DESTROY_SELF" then
                            DealDmgToEntity(pIdx, m.entityId, 999)
                        elseif eff == "SWAP_SELF_WITH_RANDOM_HAND_MINION" then
                            local hand = P(pIdx).hand
                            local cands = {}
                            for i, hc in ipairs(hand) do
                                local hcard = ARKANA_CardData[hc.id]
                                if hcard and hcard.type == "MINION" then cands[#cands+1] = i end
                            end
                            if #cands > 0 then
                                gs.prngState = PrngNext(gs.prngState)
                                local handIdx = cands[(gs.prngState % #cands) + 1]
                                local handCard = hand[handIdx]
                                local board = P(pIdx).board
                                local boardIdx
                                for bi, bm in ipairs(board) do if bm == m then boardIdx = bi; break end end
                                if boardIdx then
                                    table.remove(hand, handIdx)
                                    table.remove(board, boardIdx)
                                    local newM = NewMinion(handCard.id, pIdx)
                                    newM.entityId = gs.entityCounter; gs.entityCounter = gs.entityCounter + 1
                                    table.insert(board, boardIdx, newM)
                                    local backCard = ARKANA_CardData[m.id]
                                    hand[#hand+1] = {entityId=gs.entityCounter, id=m.id, cost=(backCard and backCard.cost) or 0}
                                    gs.entityCounter = gs.entityCounter + 1
                                    RecalcAuras()
                                end
                            end
                        elseif eff == "TRANSFORM_RANDOM_MINION" then
                            local op = OtherIdx(pIdx)
                            local cands = {}
                            for bi, bm in ipairs(P(pIdx).board) do if bm ~= m then cands[#cands+1] = {p=pIdx, i=bi} end end
                            for bi, bm in ipairs(P(op).board)   do cands[#cands+1] = {p=op,   i=bi} end
                            if #cands > 0 then
                                gs.prngState = PrngNext(gs.prngState)
                                local pick = cands[(gs.prngState % #cands) + 1]
                                local newM = NewMinion(trig.tokenId or "TRANSFORM_SHEEP", pick.p)
                                if newM then
                                    newM.entityId = gs.entityCounter; gs.entityCounter = gs.entityCounter + 1
                                    newM.transformedFrom = P(pick.p).board[pick.i].entityId
                                    P(pick.p).board[pick.i] = newM; RecalcAuras()
                                end
                            end
                        elseif eff == "HEAL_RANDOM_CHAR" then
                            local op = OtherIdx(pIdx)
                            local cands = {}
                            if P(pIdx).hero.health < 30 then cands[#cands+1] = pIdx end
                            if P(op).hero.health < 30    then cands[#cands+1] = op   end
                            for _, fm in ipairs(P(pIdx).board) do if fm.damageTaken > 0 then cands[#cands+1] = fm.entityId end end
                            for _, fm in ipairs(P(op).board)   do if fm.damageTaken > 0 then cands[#cands+1] = fm.entityId end end
                            if #cands > 0 then
                                gs.prngState = PrngNext(gs.prngState)
                                HealEntity(cands[(gs.prngState % #cands) + 1], val, pIdx)
                            end
                        end
                    end
                end
            end
        end
    end
end

-- ── Death pipeline ────────────────────────────────────────────────────────────

local DEATHRATTLE = {}  -- forward declaration, filled after BATTLECRY table

local function RunDeathPipeline()
    while true do
        local dead = {}
        local order = { gs.activePlayer, OtherIdx(gs.activePlayer) }
        for _, pIdx in ipairs(order) do
            for _, m in ipairs(P(pIdx).board) do
                if MinionCurHp(m) <= 0 then dead[#dead+1] = { m = m, pIdx = pIdx } end
            end
        end
        if #dead == 0 then break end
        for _, e in ipairs(dead) do
            local board = P(e.pIdx).board
            for i = #board, 1, -1 do
                if board[i] == e.m then table.remove(board, i); break end
            end
            addon:GE_Log(e.pIdx, CardName(e.m.id) .. " gestorben")
        end
        RecalcAuras()
        for _, e in ipairs(dead) do
            FireTriggers("TRIGGER_ON_FRIENDLY_DEATH", { m = e.m, pIdx = e.pIdx })
            CheckSecrets(e.pIdx, "FRIENDLY_MINION_DIES", { m = e.m })
            if not e.m.silenced then
                local dr = DEATHRATTLE[e.m.id]
                if dr then
                    addon:GE_Log(e.pIdx, "[DR] " .. CardName(e.m.id))
                    local ok, err = pcall(dr, e.pIdx, e.m)
                    if not ok then addon:GE_Log(e.pIdx, "[DR-ERR] " .. tostring(err)) end
                end
                if e.m.extraDeathrattle and #P(e.pIdx).board < 7 then
                    SummonMinionAt(e.pIdx, e.m.extraDeathrattle, #P(e.pIdx).board + 1)
                end
                if e.m.ancestralSpirit and #P(e.pIdx).board < 7 then
                    SummonMinionAt(e.pIdx, e.m.id, #P(e.pIdx).board + 1)
                end
            end
        end
        if CheckVictory() then return end
    end
end

-- ── Hero power definitions ────────────────────────────────────────────────────

local HeroPower = {
    WARRIOR  = function(pIdx, _)   P(pIdx).hero.armor = P(pIdx).hero.armor + 2 end,
    PALADIN  = function(pIdx, _)   SummonToken(pIdx, "CS2_101t") end,
    HUNTER   = function(pIdx, _)   DealDmgToEntity(pIdx, OtherIdx(pIdx), 2) end,
    DRUID    = function(pIdx, _)
        local hero = P(pIdx).hero
        hero.armor = hero.armor + 1
        hero.enchantments[#hero.enchantments+1] = {attack=1, health=0, expiresEndOfTurn=true, source=0}
        hero.attack = hero.attack + 1
    end,
    SHAMAN   = function(pIdx, _)
        local totems = {"CS2_050","CS2_051","CS2_052","NEW1_009"}  -- Verbrennungstotem, Steinklauentotem, Sturmzorntotem, Heiltotem
        local avail = {}
        for _, tid in ipairs(totems) do
            local found = false
            for _, m in ipairs(P(pIdx).board) do if m.id == tid then found = true; break end end
            if not found then avail[#avail+1] = tid end
        end
        if #avail == 0 then return end
        gs.prngState = PrngNext(gs.prngState)
        SummonToken(pIdx, avail[(gs.prngState % #avail) + 1])
    end,
    MAGE     = function(pIdx, tgt) DealDmgToEntity(pIdx, tgt, 1) end,
    PRIEST   = function(pIdx, tgt) HealEntity(tgt, 2 * HealMult(pIdx), pIdx) end,
    ROGUE    = function(pIdx, _)
        -- 1/2 dagger: Waffe gibt Angriff (hero.attack bleibt unberührt)
        local p = P(pIdx)
        if p.weapon then p.weapon = nil end
        p.weapon = { entityId = gs.entityCounter, id = "ROGUE_DAGGER", attack = 1, durability = 2, tags = {} }
        gs.entityCounter = gs.entityCounter + 1
    end,
    WARLOCK  = function(pIdx, _)
        DealDmgToEntity(pIdx, pIdx, 2)
        DrawCard(pIdx)
    end,
    JARAXXUS  = function(pIdx, _)
        if #P(pIdx).board < 7 then SummonMinionAt(pIdx, "EX1_323t2", #P(pIdx).board + 1) end
    end,
    NEUTRAL       = function(_, _) end,
    CLASSLESS     = function(pIdx, _) DrawCard(pIdx) end,  -- Neugier: Ziehe 1 Karte
    SHADOW_PRIEST = function(pIdx, tgt)
        DealDmgToEntity(pIdx, tgt, 2)
        addon:GE_Log(pIdx, "Dunkle Pulse: 2 Schaden!")
        RunDeathPipeline()
    end,
    SHADOW_PRIEST_UPGRADED = function(pIdx, tgt)
        DealDmgToEntity(pIdx, tgt, 3)
        addon:GE_Log(pIdx, "Gedankenschinden: 3 Schaden!")
        RunDeathPipeline()
    end,
}

-- ── Turn sequences ────────────────────────────────────────────────────────────

local function StartTurn(pIdx)
    gs.activePlayer = pIdx
    local p = P(pIdx)
    p.cardPlayedThisTurn = false
    p.cardsPlayedThisTurn = 0
    p.firstMinionCostUsedThisTurn = false
    p.mana.temporary = 0
    p.mana.maxPermanent  = math.min(10, p.mana.maxPermanent + 1)
    p.mana.currentPermanent = math.max(0, p.mana.maxPermanent - p.mana.locked)
    p.mana.locked = 0
    p.hero.heroPowerUsedThisTurn = false
    p.hero.attacksThisTurn = 0
    p.hero.immuneThisTurn = false  -- Eisblock: Immunität endet mit Beginn des eigenen nächsten Zuges
    for _, m in ipairs(p.board) do
        m.attacksThisTurn = 0
        m.summonedThisTurn = false
        if m.stealthedByVerhullen == pIdx then
            m.stealthed = false
            m.stealthedByVerhullen = nil
            for i, t in ipairs(m.tags) do if t.type == "STEALTH" then table.remove(m.tags, i); break end end
        end
        UpdateCanAttack(m)
    end
    -- CS2_063 Verderbnis: markierte Diener sterben zu Beginn dieses Zuges
    for pi = 1, 2 do
        for _, m in ipairs(P(pi).board) do
            if m.dieAtStartOfTurn == pIdx then m.damageTaken = m.damageTaken + 9999 end
        end
    end
    RunDeathPipeline()
    FireTriggers("TRIGGER_START_TURN", {})
    RunDeathPipeline()
    -- EX1_137 Schädelbruch (Combo): kehrt jetzt zurück, vor dem Ziehen (wie im echten HS)
    while (p.headcrackReturn or 0) > 0 do
        p.headcrackReturn = p.headcrackReturn - 1
        if #p.hand < 10 then
            gs.entityCounter = gs.entityCounter + 1
            local cd = ARKANA_CardData["EX1_137"]
            p.hand[#p.hand+1] = {entityId=gs.entityCounter, id="EX1_137", cost=(cd and cd.cost or 3)}
            addon:GE_Log(pIdx, "Schädelbruch kehrt auf die Hand zurück! (Combo)")
        end
    end
    DrawCard(pIdx)
    if CheckVictory() then return end
    gs.turnNumber = gs.turnNumber + 1
    addon:GE_TurnStart(pIdx)
end

local function EndTurn(pIdx)
    if gs.activePlayer ~= pIdx or gs.phase ~= "play" then return end
    FireTriggers("TRIGGER_END_TURN", {})
    -- Überwältigende Macht: Diener mit dieEndOfTurn sterben jetzt
    for _, m in ipairs(P(pIdx).board) do
        if m.dieEndOfTurn then m.damageTaken = m.damageTaken + 9999 end
    end
    RunDeathPipeline()
    -- EX1_334 Dunkler Wahnsinn: am Zugende gestohlene Diener zurückgeben
    do
        local toReturn = {}
        for i, m in ipairs(P(pIdx).board) do
            if m.returnToPlayer then toReturn[#toReturn+1] = {m=m, idx=i} end
        end
        for j = #toReturn, 1, -1 do
            local e = toReturn[j]
            table.remove(P(pIdx).board, e.idx)
            e.m.controller = e.m.returnToPlayer; e.m.returnToPlayer = nil
            if #P(e.m.controller).board < 7 then P(e.m.controller).board[#P(e.m.controller).board+1] = e.m end
        end
        if #toReturn > 0 then RecalcAuras() end
    end
    -- Expire hero enchantments
    local hero = P(pIdx).hero
    local kept = {}
    for _, e in ipairs(hero.enchantments) do
        if not e.expiresEndOfTurn then kept[#kept+1] = e end
    end
    hero.enchantments = kept
    -- Recalc hero attack (Waffe wird separat über P(pIdx).weapon.attack geprüft)
    local atk = 0
    for _, e in ipairs(hero.enchantments) do atk = atk + (e.attack or 0) end
    hero.attack = atk
    -- Expire minion enchantments
    for _, m in ipairs(P(pIdx).board) do
        local mKept = {}
        for _, e in ipairs(m.enchantments) do
            if not e.expiresEndOfTurn then mKept[#mKept+1] = e end
        end
        m.enchantments = mKept
    end
    RecalcAuras()
    P(pIdx).mana.temporary = 0
    P(pIdx).spellCostReduction = 0
    -- Eigene eingefrorene Charaktere auftauen — erst jetzt, damit sie diesen Zug nicht angreifen konnten
    P(pIdx).hero.frozen = false
    for _, m in ipairs(P(pIdx).board) do m.frozen = false; m.immuneThisTurn = false; m.minHealthThisTurn = nil end
    P(pIdx).allCostZeroThisTurn = false
    StartTurn(OtherIdx(pIdx))
end

-- ── Mulligan ─────────────────────────────────────────────────────────────────

local function DoMulligan(pIdx, returnSet)
    -- returnSet: table with 0-based indices to return, e.g. {[0]=true, [2]=true}
    local p   = P(pIdx)
    local returned = {}
    local kept     = {}
    for i, card in ipairs(p.hand) do
        if returnSet[i - 1] then
            returned[#returned+1] = card.id
        else
            kept[#kept+1] = card
        end
    end
    p.hand = kept
    for _, id in ipairs(returned) do p.deck[#p.deck+1] = id end
    ShuffleDeck(p.deck)
    for _ = 1, #returned do DrawCard(pIdx) end
end

local function TryStartPlay()
    if gs.mulliganDone[1] and gs.mulliganDone[2] then
        gs.phase = "play"
        StartTurn(1)
    end
end

-- ── Spell execution ───────────────────────────────────────────────────────────

local function ExecSpellTags(pIdx, tags, targetEntityId)
    for _, tag in ipairs(tags or {}) do
        local t = tag.type
        if t == "DEAL_DAMAGE" then
            DealDmgToEntity(pIdx, targetEntityId, tag.value + SpellDmgBonus(pIdx))
        elseif t == "GIVE_TEMP_MANA" then
            P(pIdx).mana.temporary = P(pIdx).mana.temporary + (tag.value or 1)
        elseif t == "DRAW_CARDS" then
            for _ = 1, (tag.value or 1) do DrawCard(pIdx) end
        elseif t == "HEAL" then
            HealEntity(targetEntityId, tag.value * HealMult(pIdx), pIdx)
        elseif t == "FREEZE" then
            if targetEntityId == 1 or targetEntityId == 2 then
                P(targetEntityId).hero.frozen = true
            else
                local m = FindOnBoard(targetEntityId)
                if m then m.frozen = true; UpdateCanAttack(m) end
            end
        elseif t == "SILENCE" then
            local m = FindOnBoard(targetEntityId)
            if m then SilenceMinion(m) end
        elseif t == "GIVE_BUFF" then
            local m = FindOnBoard(targetEntityId)
            if m then
                m.enchantments[#m.enchantments+1] = {attack=(tag.attack or 0), health=(tag.health or 0), expiresEndOfTurn=false, source=0}
                RecalcAuras()
            end
        elseif t == "GIVE_ARMOR" then
            P(pIdx).hero.armor = P(pIdx).hero.armor + (tag.value or 0)
        elseif t == "TAKE_CONTROL" then
            local m, mPIdx, mBIdx = FindOnBoard(targetEntityId)
            if m and mPIdx ~= pIdx and #P(pIdx).board < 7 then
                table.remove(P(mPIdx).board, mBIdx)
                m.controller = pIdx
                table.insert(P(pIdx).board, m)
                RecalcAuras()
            end
        end
    end
end

-- ── Battlecry-Helfer ──────────────────────────────────────────────────────────

local function AddTagToMinion(m, tagType)
    for _, t in ipairs(m.tags) do if t.type == tagType then return end end
    m.tags[#m.tags+1] = {type=tagType}
end

SummonMinionAt = function(pIdx, cardId, boardPos)
    if #P(pIdx).board >= 7 then return end
    local m = NewMinion(cardId, pIdx)
    if not m then return end
    m.entityId = gs.entityCounter; gs.entityCounter = gs.entityCounter + 1
    table.insert(P(pIdx).board, math.min(boardPos, #P(pIdx).board + 1), m)
    RecalcAuras()
    FireTriggers("TRIGGER_ON_SUMMON", { m = m, pIdx = pIdx })
    CheckSwordOfJustice(pIdx, m)
    return m
end

local BATTLECRY = {
    ["EX1_165"] = function(pIdx, tgt, mPos, comboCount, choiceId)  -- Druide der Klaue: Ansturm ODER +2 HP/Spott
        local m = P(pIdx).board[mPos]
        if not m then return end
        if choiceId == "EX1_165b" then
            m.enchantments[#m.enchantments+1] = {attack=0, health=2, expiresEndOfTurn=false, source=0}
            AddTagToMinion(m, "TAUNT")
            m.displayId = "EX1_165b"
        else
            AddTagToMinion(m, "CHARGE")
            m.displayId = "EX1_165a"
        end
        RecalcAuras()
    end,
    ["EX1_178"] = function(pIdx, tgt, mPos, comboCount, choiceId)  -- Urtum des Krieges: +5 Angriff ODER +5 HP/Spott
        local m = P(pIdx).board[mPos]
        if not m then return end
        if choiceId == "EX1_178b" then
            m.enchantments[#m.enchantments+1] = {attack=5, health=0, expiresEndOfTurn=false, source=0}
        else
            m.enchantments[#m.enchantments+1] = {attack=0, health=5, expiresEndOfTurn=false, source=0}
            AddTagToMinion(m, "TAUNT")
        end
        RecalcAuras()
    end,
    ["NEW1_008"] = function(pIdx, tgt, mPos, comboCount, choiceId)  -- Urtum der Lehren: 2 Karten ziehen ODER 5 HP heilen
        if choiceId == "NEW1_008b" then
            HealEntity(pIdx, 5, pIdx)
        else
            DrawCard(pIdx); DrawCard(pIdx)
        end
    end,
    ["EX1_573"] = function(pIdx, tgt, mPos, comboCount, choiceId)  -- Cenarius: +2/+2 andere Diener ODER 2 Treants (Spott)
        if choiceId == "EX1_573b" then
            for i = 1, 2 do
                local t = SummonMinionAt(pIdx, "EX1_tk9", mPos + 1)
                if t then AddTagToMinion(t, "TAUNT") end
            end
        else
            local self = P(pIdx).board[mPos]
            for _, bm in ipairs(P(pIdx).board) do
                if bm ~= self then
                    bm.enchantments[#bm.enchantments+1] = {attack=2, health=2, expiresEndOfTurn=false, source=0}
                end
            end
            RecalcAuras()
        end
    end,
    ["EX1_166"] = function(pIdx, tgt, mPos, comboCount, choiceId)  -- Hüter des Hains: 2 Schaden ODER Diener schweigen
        if choiceId == "EX1_166b" then
            local m = FindOnBoard(tgt)
            if m then SilenceMinion(m) end
        else
            DealDmgToEntity(pIdx, tgt, 2)
        end
    end,
    ["EX1_506"] = function(pIdx, tgt, mPos)  -- Murlocgezeitenjäger → Murlocspäher
        SummonMinionAt(pIdx, "EX1_506a", mPos + 1)
    end,
    ["EX1_085"] = function(pIdx, tgt, mPos)  -- Gedankenkontrolleur → stehlen wenn ≥4
        local op = OtherIdx(pIdx)
        if #P(op).board >= 4 then
            gs.prngState = PrngNext(gs.prngState)
            local stolen = table.remove(P(op).board, (gs.prngState % #P(op).board) + 1)
            if #P(pIdx).board < 7 then
                stolen.controller = pIdx
                table.insert(P(pIdx).board, stolen)
            end
            RecalcAuras()
        end
    end,
    ["CS2_189"] = function(pIdx, tgt, mPos)  DealDmgToEntity(pIdx, tgt, 1) end,
    ["CS2_188"] = function(pIdx, tgt, mPos)  -- Ruchloser Unteroffizier → +2 Angriff diesen Zug
        local m = FindOnBoard(tgt)
        if m then m.enchantments[#m.enchantments+1] = {attack=2, health=0, expiresEndOfTurn=true, source=0}; RecalcAuras() end
    end,
    ["EX1_011"] = function(pIdx, tgt, mPos)  HealEntity(tgt, 2, pIdx) end,
    ["EX1_015"] = function(pIdx, tgt, mPos)  DrawCard(pIdx) end,
    ["EX1_066"] = function(pIdx, tgt, mPos)  P(OtherIdx(pIdx)).weapon = nil end,
    ["NEW1_025"] = function(pIdx, tgt, mPos) -- Blutsegelkorsar → Waffe -1 Haltbarkeit
        local w = P(OtherIdx(pIdx)).weapon
        if w then w.durability = w.durability - 1; if w.durability <= 0 then P(OtherIdx(pIdx)).weapon = nil end end
    end,
    ["EX1_306"] = function(pIdx, tgt, mPos) -- Teufelspirscher → zufällige Karte ablegen
        local hand = P(pIdx).hand
        if #hand > 0 then gs.prngState = PrngNext(gs.prngState); table.remove(hand, (gs.prngState % #hand) + 1) end
    end,
    ["EX1_082"] = function(pIdx, tgt, mPos) -- Verrückter Bomber → 3 zufälligen Schaden (beide Helden + alle Diener außer sich selbst)
        local op = OtherIdx(pIdx)
        for _ = 1, 3 do
            local pool = {P(pIdx).hero.entityId, P(op).hero.entityId}
            -- Tote überspringen (s. EX1_277): der Todes-Pipeline läuft erst am Ende
            for i, m in ipairs(P(pIdx).board) do
                if i ~= mPos and MinionCurHp(m) > 0 then pool[#pool+1] = m.entityId end
            end
            for _, m in ipairs(P(op).board) do
                if MinionCurHp(m) > 0 then pool[#pool+1] = m.entityId end
            end
            gs.prngState = PrngNext(gs.prngState)
            local hit = pool[(gs.prngState % #pool) + 1]
            addon:GE_Log(pIdx, "Bomber: 1 Schaden → " .. EntityName(hit))
            DealDmgToEntity(pIdx, hit, 1)
        end
    end,
    ["EX1_362"] = function(pIdx, tgt, mPos) -- Argentumbeschützer → Gottesschild
        local m = FindOnBoard(tgt)
        if m and m.controller == pIdx then m.divineShield = true end
    end,
    ["EX1_603"] = function(pIdx, tgt, mPos) -- Fieser Zuchtmeister → 1 Schaden + +2 Angriff
        DealDmgToEntity(pIdx, tgt, 1)
        local m = FindOnBoard(tgt)
        if m then m.enchantments[#m.enchantments+1] = {attack=2, health=0, expiresEndOfTurn=false, source=0}; RecalcAuras() end
    end,
    ["CS2_117"] = function(pIdx, tgt, mPos) -- Seher des Irdenen Rings → 3 Leben heilen
        HealEntity(tgt, 3, pIdx)
    end,
    ["CS2_141"] = function(pIdx, tgt, mPos) -- Schütze von Eisenschmiede → 1 Schaden
        DealDmgToEntity(pIdx, tgt, 1)
    end,
    ["CS2_203"] = function(pIdx, tgt, mPos) -- Eisenschnabeleule → Schweigen
        local m = FindOnBoard(tgt)
        if m then SilenceMinion(m) end
    end,
    ["EX1_059"] = function(pIdx, tgt, mPos) -- Verrückter Alchemist → aktuelle HP↔ATK tauschen
        local m = FindOnBoard(tgt)
        if m then
            local newAtk = MinionCurHp(m)
            local newHp  = MinionEffAtk(m)
            m.baseAttack = newAtk; m.baseHealth = newHp
            m.enchantments = {}; m.damageTaken = 0
            RecalcAuras()
        end
    end,
    ["EX1_049"] = function(pIdx, tgt, mPos) -- Junger Braumeister → freundlichen Diener zurück
        local m, mPIdx, mBIdx = FindOnBoard(tgt)
        if m and mPIdx == pIdx then
            table.remove(P(pIdx).board, mBIdx)
            local hand = P(pIdx).hand
            if #hand < 10 then
                local base = ARKANA_CardData[m.id]
                hand[#hand+1] = {entityId=gs.entityCounter, id=m.id, cost=(base and base.cost or 0)}
                gs.entityCounter = gs.entityCounter + 1
            end
            RecalcAuras()
        end
    end,
    ["EX1_058"] = function(pIdx, tgt, mPos) -- Sonnenzornbeschützerin → Nachbarn Spott
        local board = P(pIdx).board
        if mPos > 1       then AddTagToMinion(board[mPos-1], "TAUNT") end
        if mPos < #board  then AddTagToMinion(board[mPos+1], "TAUNT") end
    end,
    ["NEW1_017"] = function(pIdx, tgt, mPos) -- Hungrige Krabbe → Murloc zerstören, +2/+2
        local m, mPIdx, mBIdx = FindOnBoard(tgt)
        local data = m and ARKANA_CardData[m.id]
        if m and data and data.race == "MURLOC" then
            local kr = P(pIdx).board[mPos]  -- vor table.remove, sonst Index-Shift wenn Murloc < mPos
            table.remove(P(mPIdx).board, mBIdx)
            if kr then kr.enchantments[#kr.enchantments+1] = {attack=2, health=2, expiresEndOfTurn=false, source=0} end
            RecalcAuras()
        end
    end,
    ["EX1_025"] = function(pIdx, tgt, mPos) -- Drachlingmechanikerin → Mech-Drachling (2/1)
        SummonMinionAt(pIdx, "EX1_025t", mPos + 1)
    end,
    ["EX1_116"] = function(pIdx, tgt, mPos) -- Leeroy Jenkins → 2 Welplinge (1/1) für Gegner
        local op = OtherIdx(pIdx)
        SummonMinionAt(op, "EX1_116t", #P(op).board + 1)
        SummonMinionAt(op, "EX1_116t", #P(op).board + 1)
    end,
    ["EX1_562"] = function(pIdx, tgt, mPos) -- Onyxia → Spielfeld mit Welplingen füllen
        -- Bewusst begrenzt statt while: liefert SummonMinionAt still nichts
        -- (Kartendaten fehlen), wäre while eine Endlosschleife = Client-Hard-Freeze
        for _ = #P(pIdx).board + 1, 7 do
            SummonMinionAt(pIdx, "EX1_116t", #P(pIdx).board + 1)
        end
    end,
    ["CS2_088"] = function(pIdx, tgt, mPos) HealEntity(pIdx, 6, pIdx) end,  -- Wächter der Könige
    ["EX1_050"] = function(pIdx, tgt, mPos)  -- Tiefenlichtorakel → beide Spieler ziehen 2 Karten
        for _ = 1, 2 do DrawCard(pIdx) end
        for _ = 1, 2 do DrawCard(OtherIdx(pIdx)) end
    end,
    ["EX1_103"] = function(pIdx, tgt, mPos)  -- Tiefenlichtseher → alle eigenen Murlocs +2 HP
        local self = P(pIdx).board[mPos]
        for _, bm in ipairs(P(pIdx).board) do
            if bm ~= self then
                local bd = ARKANA_CardData[bm.id]
                if bd and bd.race == "MURLOC" then
                    bm.enchantments[#bm.enchantments+1] = {attack=0, health=2, expiresEndOfTurn=false, source=0}
                end
            end
        end
        RecalcAuras()
    end,
    ["CS2_226"] = function(pIdx, tgt, mPos) -- Frostwolfkriegsfürst → +1/+1 pro freundl. Diener
        local count = #P(pIdx).board - 1
        if count > 0 then
            local self = P(pIdx).board[mPos]
            if self then
                self.enchantments[#self.enchantments+1] = {attack=count, health=count, expiresEndOfTurn=false, source=0}
                RecalcAuras()
            end
        end
    end,
    ["EX1_019"] = function(pIdx, tgt, mPos) -- Blutelfenklerikerin → +1/+1 auf freundl. Diener
        local m = FindOnBoard(tgt)
        if m then m.enchantments[#m.enchantments+1] = {attack=1, health=1, expiresEndOfTurn=false, source=0}; RecalcAuras() end
    end,
    ["CS2_196"] = function(pIdx, tgt, mPos) -- Jägerin der Klingenhauer → Eber (1/1)
        SummonMinionAt(pIdx, "CS2_196a", mPos + 1)
    end,
    ["CS2_181"] = function(pIdx, tgt, mPos) -- Verletzter Klingenmeister → 4 Schaden an sich selbst
        local m = P(pIdx).board[mPos]
        if m then DealDmgToEntity(pIdx, m.entityId, 4) end
    end,
    ["EX1_005"] = function(pIdx, tgt, mPos) -- Großwildjäger → Diener mit ≥7 ATK vernichten
        local m = FindOnBoard(tgt)
        if m and MinionEffAtk(m) >= 7 then m.damageTaken = 9999 end
    end,
    ["EX1_057"] = function(pIdx, tgt, mPos) -- Uralter Braumeister → freundl. Diener auf Hand
        local m, mPIdx, mBIdx = FindOnBoard(tgt)
        if m and mPIdx == pIdx and #P(pIdx).hand < 10 then
            table.remove(P(pIdx).board, mBIdx)
            local base = ARKANA_CardData[m.id]
            P(pIdx).hand[#P(pIdx).hand+1] = {entityId=gs.entityCounter, id=m.id, cost=(base and base.cost or 0)}
            gs.entityCounter = gs.entityCounter + 1; RecalcAuras()
        end
    end,
    ["EX1_093"] = function(pIdx, tgt, mPos) -- Verteidiger von Argus → Nachbarn +1/+1 + Spott
        local board = P(pIdx).board
        local function buffNeighbor(bm)
            bm.enchantments[#bm.enchantments+1] = {attack=1, health=1, expiresEndOfTurn=false, source=0}
            AddTagToMinion(bm, "TAUNT")
        end
        if mPos > 1      then buffNeighbor(board[mPos-1]) end
        if mPos < #board then buffNeighbor(board[mPos+1]) end
        RecalcAuras()
    end,
    ["CS2_150"] = function(pIdx, tgt, mPos) DealDmgToEntity(pIdx, tgt, 2) end,  -- Sturmlanzenkommando
    ["EX1_593"] = function(pIdx, tgt, mPos) DealDmgToEntity(pIdx, OtherIdx(pIdx), 3) end,  -- Nachtklinge → feindl. Held
    ["EX1_313"] = function(pIdx, tgt, mPos) DealDmgToEntity(pIdx, pIdx, 5) end,  -- Grubenlord → eigener Held
    ["EX1_046"] = function(pIdx, tgt, mPos)  -- Dunkeleisenzwerg → Diener +2 ATK diesen Zug
        local m = FindOnBoard(tgt)
        if m then m.enchantments[#m.enchantments+1] = {attack=2, health=0, expiresEndOfTurn=true, source=0}; RecalcAuras() end
    end,
    ["EX1_623"] = function(pIdx, tgt, mPos)  -- Vollstrecker des Tempels → freundl. Diener +3 Leben
        local m = FindOnBoard(tgt)
        if m then m.enchantments[#m.enchantments+1] = {attack=0, health=3, expiresEndOfTurn=false, source=0}; RecalcAuras() end
    end,
    ["DS1_055"] = function(pIdx, tgt, mPos)  -- Dunkelschuppenheilerin → alle freundl. Charaktere +2 Leben
        HealEntity(pIdx, 2, pIdx)
        for _, bm in ipairs(P(pIdx).board) do HealEntity(bm.entityId, 2, pIdx) end
    end,
    ["CS2_151"] = function(pIdx, tgt, mPos)  -- Ritter der Silbernen Hand → Knappe (2/2)
        SummonMinionAt(pIdx, "CS2_152", mPos + 1)
    end,
    ["EX1_301"] = function(pIdx, tgt, mPos)  -- Teufelswache → EIGENER Manakristall wird vernichtet (Drawback)
        local p = P(pIdx)
        if p.mana.maxPermanent > 0 then
            p.mana.maxPermanent = p.mana.maxPermanent - 1
            p.mana.currentPermanent = math.min(p.mana.currentPermanent, p.mana.maxPermanent)
            addon:GameLog("[Teufelswache] Eigener Manakristall vernichtet → " .. p.mana.maxPermanent .. " verbleibend")
        end
    end,
    ["EX1_002"] = function(pIdx, tgt, mPos)  -- Der Schwarze Ritter → gewählten Spott-Diener vernichten
        local m = FindOnBoard(tgt)
        addon:GameLog("[SchwarzerRitter] tgt=" .. tostring(tgt) .. " found=" .. tostring(m ~= nil) .. (m and " hasTaunt=" .. tostring(HasTag(m.tags, "TAUNT")) or ""))
        if m and HasTag(m.tags, "TAUNT") then
            m.damageTaken = m.damageTaken + 9999
        else
            for _, bm in ipairs(P(OtherIdx(pIdx)).board) do
                if HasTag(bm.tags, "TAUNT") then bm.damageTaken = bm.damageTaken + 9999; break end
            end
        end
    end,
    ["DS1_070"] = function(pIdx, tgt, mPos)  -- Hundemeister → freundl. Wildtier +2/+2 + Spott
        local m = FindOnBoard(tgt)
        if m then
            local card = ARKANA_CardData[m.id]
            if card and card.race == "BEAST" then
                m.enchantments[#m.enchantments+1] = {attack=2, health=2, expiresEndOfTurn=false, source=0}
                AddTagToMinion(m, "TAUNT"); RecalcAuras()
            end
        end
    end,
    ["EX1_561"] = function(pIdx, tgt, mPos)  -- Alexstrasza → Held-Leben auf 15 (tgt nur wenn Hero-Entity, sonst feindl. Held)
        local target = (tgt == 1 or tgt == 2) and tgt or OtherIdx(pIdx)
        P(target).hero.health = 15
    end,
    ["EX1_284"] = function(pIdx, tgt, mPos) DrawCard(pIdx) end,  -- Azurblauer Drache
    ["EX1_583"] = function(pIdx, tgt, mPos) HealEntity(pIdx, 4, pIdx) end,  -- Priesterin von Elune → eigener Held
    ["EX1_319"] = function(pIdx, tgt, mPos) DealDmgToEntity(pIdx, pIdx, 3) end,  -- Flammenwichtel → eigener Held
    ["CS2_042"] = function(pIdx, tgt, mPos) DealDmgToEntity(pIdx, tgt, 3) end,  -- Feuerelementar
    ["EX1_043"] = function(pIdx, tgt, mPos)  -- Zwielichtdrache → +1 Leben pro Handkarte
        local n = #P(pIdx).hand
        local kr = P(pIdx).board[mPos]
        if kr and n > 0 then kr.enchantments[#kr.enchantments+1] = {attack=0, health=n, expiresEndOfTurn=false, source=0}; RecalcAuras() end
    end,
    ["EX1_089"] = function(pIdx, tgt, mPos)  -- Arkangolem → Gegner +1 Manakristall
        local op = P(OtherIdx(pIdx))
        if op.mana.maxPermanent < 10 then op.mana.maxPermanent = op.mana.maxPermanent + 1 end
    end,
    ["EX1_048"] = function(pIdx, tgt, mPos)  -- Zauberbrecher → Diener schweigen
        local m = FindOnBoard(tgt)
        if m then SilenceMinion(m) end
    end,
    ["EX1_587"] = function(pIdx, tgt, mPos)  -- Windsprecher → freundl. Diener Windzorn
        local m = FindOnBoard(tgt)
        if m and m.controller == pIdx then AddTagToMinion(m, "WINDFURY"); UpdateCanAttack(m) end
    end,
    ["NEW1_014"] = function(pIdx, tgt, mPos)  -- Meisterin der Tarnung → freundl. Diener Verstohlenheit
        local m = FindOnBoard(tgt)
        if m and m.controller == pIdx then m.stealthed = true end
    end,
    ["NEW1_041"] = function(pIdx, tgt, mPos)  -- Panischer Kodo → zufälligen feindl. Diener ≤2 ATK vernichten
        local cands = {}
        for _, bm in ipairs(P(OtherIdx(pIdx)).board) do
            if MinionEffAtk(bm) <= 2 then cands[#cands+1] = bm end
        end
        if #cands > 0 then gs.prngState = PrngNext(gs.prngState); cands[(gs.prngState % #cands) + 1].damageTaken = 9999 end
    end,
    ["CS2_064"] = function(pIdx, tgt, mPos)  -- Schreckenshöllenbestie → 1 Schaden an alle außer sich
        local selfId = P(pIdx).board[mPos] and P(pIdx).board[mPos].entityId
        local tgts = {pIdx, OtherIdx(pIdx)}
        for p = 1, 2 do for _, bm in ipairs(P(p).board) do if bm.entityId ~= selfId then tgts[#tgts+1] = bm.entityId end end end
        for _, tid in ipairs(tgts) do DealDmgToEntity(pIdx, tid, 1) end
    end,
    ["EX1_310"] = function(pIdx, tgt, mPos)  -- Verdammniswache → 2 Handkarten zufällig abwerfen
        for i = 1, 2 do
            local h = P(pIdx).hand
            if #h > 0 then gs.prngState = PrngNext(gs.prngState); table.remove(h, (gs.prngState % #h) + 1) end
        end
    end,
    ["EX1_283"] = function(pIdx, tgt, mPos)  -- Frostelementar → Charakter einfrieren
        if tgt == 1 or tgt == 2 then P(tgt).hero.frozen = true
        else local m = FindOnBoard(tgt); if m then m.frozen = true; UpdateCanAttack(m) end end
    end,
    ["EX1_382"] = function(pIdx, tgt, mPos)  -- Friedensbewahrer → feindl. Diener ATK auf 1
        local m = FindOnBoard(tgt)
        if m and m.controller ~= pIdx then
            local eff = MinionEffAtk(m)
            if eff ~= 1 then m.enchantments[#m.enchantments+1] = {attack=1-eff, health=0, expiresEndOfTurn=false, source=0}; RecalcAuras() end
        end
    end,
    ["EX1_590"] = function(pIdx, tgt, mPos)  -- Blutritter → Gottesschilde entfernen, +3/+3 pro Schild
        local shields = 0
        for p = 1, 2 do for _, bm in ipairs(P(p).board) do if bm.divineShield then bm.divineShield=false; shields=shields+1 end end end
        local kr = P(pIdx).board[mPos]
        if kr and shields > 0 then kr.enchantments[#kr.enchantments+1] = {attack=shields*3, health=shields*3, expiresEndOfTurn=false, source=0}; RecalcAuras() end
    end,
    ["NEW1_030"] = function(pIdx, tgt, mPos)  -- Todesschwinge → alle anderen Diener vernichten + Hand abwerfen
        local selfId = P(pIdx).board[mPos] and P(pIdx).board[mPos].entityId
        for p = 1, 2 do for _, bm in ipairs(P(p).board) do if bm.entityId ~= selfId then bm.damageTaken = bm.damageTaken + 9999 end end end
        P(pIdx).hand = {}
    end,
    ["EX1_091"] = function(pIdx, tgt, mPos)  -- Kabaleschattenpriesterin → feindl. Diener ≤2 ATK stehlen
        local op = OtherIdx(pIdx)
        local m, _, bIdx = FindOnBoard(tgt)
        if m and m.controller == op and MinionEffAtk(m) <= 2 and #P(pIdx).board < 7 then
            table.remove(P(op).board, bIdx)
            m.controller = pIdx
            table.insert(P(pIdx).board, m)
            RecalcAuras()
        end
    end,
    ["EX1_304"] = function(pIdx, tgt, mPos)  -- Schrecken der Leere → Nachbarn vernichten + deren Stats erhalten
        local board = P(pIdx).board
        local totalAtk, totalHp = 0, 0
        local left, right = board[mPos-1], board[mPos+1]
        if left  then totalAtk = totalAtk + MinionEffAtk(left);  totalHp = totalHp + MinionEffMaxHp(left);  left.damageTaken  = left.damageTaken  + 9999 end
        if right then totalAtk = totalAtk + MinionEffAtk(right); totalHp = totalHp + MinionEffMaxHp(right); right.damageTaken = right.damageTaken + 9999 end
        if (totalAtk > 0 or totalHp > 0) and board[mPos] then
            board[mPos].enchantments[#board[mPos].enchantments+1] = {attack=totalAtk, health=totalHp, expiresEndOfTurn=false, source=0}
            RecalcAuras()
        end
    end,
    ["EX1_564"] = function(pIdx, tgt, mPos)  -- Gesichtsloser Manipulator → Kopie eines Ziels werden
        local m = FindOnBoard(tgt)
        local kr = P(pIdx).board[mPos]
        if not m or not kr then return end
        local clone = CopyMinionState(m, pIdx)
        if not clone then return end
        clone.entityId = kr.entityId; clone.summonedThisTurn = true; clone.attacksThisTurn = 0
        clone.transformedFrom = kr.id
        P(pIdx).board[mPos] = clone
        RecalcAuras()
        UpdateCanAttack(clone)
    end,
    ["EX1_014"] = function(pIdx, tgt, mPos)  -- König Mukla → Gegner bekommt 2 Bananen
        local op = OtherIdx(pIdx)
        for i = 1, 2 do if #P(op).hand < 10 then P(op).hand[#P(op).hand+1] = {id="EX1_014t"} end end
    end,
    ["EX1_584"] = function(pIdx, tgt, mPos)  -- Uralter Magier → Nachbarn +1 SpellDamage
        local board = P(pIdx).board
        local function addSpellDmg(bm)
            if not bm then return end
            local sd = GetTag(bm.tags, "SPELL_DAMAGE")
            if sd then sd.value = (sd.value or 0) + 1 else bm.tags[#bm.tags+1] = {type="SPELL_DAMAGE", value=1} end
        end
        addSpellDmg(board[mPos-1]); addSpellDmg(board[mPos+1])
    end,
    ["EX1_083"] = function(pIdx, tgt, mPos)  -- Tüftlermeister Oberfunks → zufällig Teufelssaurier (5/5) oder Eichhörnchen (1/1)
        local cands = {}
        for p = 1, 2 do for _, bm in ipairs(P(p).board) do if bm.entityId ~= (P(pIdx).board[mPos] and P(pIdx).board[mPos].entityId) then cands[#cands+1] = {m=bm,pIdx=p} end end end
        if #cands == 0 then return end
        gs.prngState = PrngNext(gs.prngState)
        local pick = cands[(gs.prngState % #cands) + 1]
        local board = P(pick.pIdx).board
        local bIdx; for i, bm in ipairs(board) do if bm == pick.m then bIdx=i; break end end
        if not bIdx then return end
        gs.prngState = PrngNext(gs.prngState)
        local newId = (gs.prngState % 2 == 0) and "EX1_083t" or "EX1_083t2"
        local newM = NewMinion(newId, pick.m.controller)
        if not newM then return end
        newM.entityId = pick.m.entityId
        board[bIdx] = newM
        RecalcAuras()
    end,
    ["EX1_398"] = function(pIdx, tgt, mPos)  -- Arathiwaffenschmiedin: 2/2 Waffe anlegen
        P(pIdx).weapon = {entityId=gs.entityCounter, id="EX1_398a", attack=2, durability=2, tags={}}
        gs.entityCounter = gs.entityCounter + 1
    end,
    ["EX1_558"] = function(pIdx, tgt, mPos)  -- Harrison Jones: feindl. Waffe zerstören + Karten ziehen
        local w = P(OtherIdx(pIdx)).weapon
        if w then
            local dur = w.durability or 0
            P(OtherIdx(pIdx)).weapon = nil
            for _ = 1, dur do DrawCard(pIdx) end
        end
    end,
    ["CS2_147"] = function(pIdx, tgt, mPos) DrawCard(pIdx) end,  -- Gnomische Erfinderin: Karte ziehen
    ["NEW1_024"] = function(pIdx, tgt, mPos)  -- Kapitän Grünhaut: Waffe +1/+1
        local w = P(pIdx).weapon
        if w then w.attack = w.attack + 1; w.durability = w.durability + 1 end
    end,
    ["NEW1_018"] = function(pIdx, tgt, mPos)  -- Blutsgelräuberin: Diener +ATK der Waffe (permanent)
        local w = P(pIdx).weapon
        if w then
            local m = P(pIdx).board[mPos]
            if m then
                m.enchantments[#m.enchantments+1] = {attack=w.attack, health=0, expiresEndOfTurn=false, source=0}
                RecalcAuras()
            end
        end
    end,
    ["NEW1_016"] = function(pIdx, tgt, mPos)  -- Papagei des Kapitäns: Pirat aus Deck ziehen
        local deck = P(pIdx).deck
        for i, id in ipairs(deck) do
            local cd = ARKANA_CardData[id]
            if cd and cd.race == "PIRATE" then
                table.remove(deck, i)
                if #P(pIdx).hand < 10 then
                    gs.entityCounter = gs.entityCounter + 1
                    P(pIdx).hand[#P(pIdx).hand+1] = {entityId=gs.entityCounter, id=id, cost=cd.cost or 0}
                end
                return
            end
        end
        addon:GE_Log(pIdx, "Kein Pirat im Deck")
    end,
    ["NEW1_029"] = function(pIdx, tgt, mPos)  -- Millhaus Manasturm: Gegner Karten kosten 0 diesen Zug
        P(OtherIdx(pIdx)).allCostZeroThisTurn = true
    end,
    ["EX1_612"] = function(pIdx, tgt, mPos)  -- Magierin der Kirin Tor: nächstes Geheimnis kostet (0)
        P(pIdx).nextSecretFree = true
    end,
    ["EX1_112"] = function(pIdx, tgt, mPos)  -- Gelbin Mekkadrill: zuf. Erfindung auf eigenes Brett
        if #P(pIdx).board >= 7 then return end
        local inventions = {"EX1_112t1", "EX1_112t2", "EX1_112t3", "EX1_112t4"}
        gs.prngState = PrngNext(gs.prngState)
        SummonMinionAt(pIdx, inventions[(gs.prngState % 4) + 1], #P(pIdx).board + 1)
    end,
    ["PRO_001"] = function(pIdx, tgt, mPos)  -- Elite Tauren Chieftain: beide Spieler zuf. Powerakkord
        local chords = {"PRO_001a", "PRO_001b", "PRO_001c"}
        for _, p in ipairs({pIdx, OtherIdx(pIdx)}) do
            if #P(p).hand < 10 then
                gs.prngState = PrngNext(gs.prngState)
                local pick = chords[(gs.prngState % 3) + 1]
                local base = ARKANA_CardData[pick]
                P(p).hand[#P(p).hand+1] = {entityId=gs.entityCounter, id=pick, cost=(base and base.cost or 0)}
                gs.entityCounter = gs.entityCounter + 1
            end
        end
    end,
    ["EX1_323"] = function(pIdx, tgt, mPos)  -- Lord Jaraxxus: Held wird Jaraxxus (HP=15, Klasse=JARAXXUS, Waffe 3/8)
        local h = P(pIdx).hero
        h.health = 15
        h.class = "JARAXXUS"
        P(pIdx).weapon = {entityId=gs.entityCounter, id="EX1_323w", attack=3, durability=8, tags={}}
        gs.entityCounter = gs.entityCounter + 1
        -- Jaraxxus verlässt das Brett und wird zum Held (kein Minion-Slot)
        if mPos and P(pIdx).board[mPos] and P(pIdx).board[mPos].id == "EX1_323" then
            table.remove(P(pIdx).board, mPos)
        end
        RecalcAuras()
        addon:GE_Log(pIdx, "Ihr seid nun Lord Jaraxxus!")
    end,
    ["EX1_319"] = function(pIdx, tgt, mPos, comboCount)  -- Flammenwichtel: 3 Schaden an eigenen Helden
        DealDmgToEntity(pIdx, pIdx, 3)
    end,
    ["EX1_613"] = function(pIdx, tgt, mPos, comboCount)  -- Edwin van Cleef: Combo +2/+2 pro vorher gespielter Karte
        if comboCount > 0 then
            local m = P(pIdx).board[mPos]
            if m then
                m.enchantments[#m.enchantments+1] = {attack=comboCount*2, health=comboCount*2, expiresEndOfTurn=false, source=0}
                RecalcAuras()
            end
        end
    end,
    ["EX1_133"] = function(pIdx, tgt, mPos, comboCount)  -- Klinge des Verderbens: 1 Schaden; Combo: 2 Schaden
        DealDmgToEntity(pIdx, tgt, comboCount > 0 and 2 or 1)
    end,
    ["EX1_134"] = function(pIdx, tgt, mPos, comboCount)  -- SI:7-Agent: Combo → 2 Schaden
        if comboCount > 0 and tgt then DealDmgToEntity(pIdx, tgt, 2) end
    end,
    ["EX1_131"] = function(pIdx, tgt, mPos, comboCount)  -- Rädelsführer der Defias: Combo → Defias 2/1
        if comboCount > 0 then SummonMinionAt(pIdx, "EX1_131t", #P(pIdx).board + 1) end
    end,
    ["NEW1_005"] = function(pIdx, tgt, mPos, comboCount)  -- Entführer: Combo → Diener auf Hand zurück
        if comboCount > 0 and tgt then
            local m = FindOnBoard(tgt)
            if m then
                local owner = m.controller
                local card = ARKANA_CardData[m.id]
                for i, bm in ipairs(P(owner).board) do
                    if bm.entityId == tgt then table.remove(P(owner).board, i); break end
                end
                P(owner).hand[#P(owner).hand+1] = {entityId=gs.entityCounter, id=m.id, cost=card and card.cost or 0}
                gs.entityCounter = gs.entityCounter + 1
                RecalcAuras()
            end
        end
    end,
}

local SPELL_OVERRIDES = {
    ["EX1_251"] = function(pIdx, tgt)  -- Gabelblitzschlag → 2 zufällige feindliche Diener je 2 Schaden
        local bonus = SpellDmgBonus(pIdx)
        local cands = {}
        for _, bm in ipairs(P(OtherIdx(pIdx)).board) do cands[#cands+1] = bm.entityId end
        local hits = math.min(2, #cands)
        for _ = 1, hits do
            gs.prngState = PrngNext(gs.prngState)
            local idx = (gs.prngState % #cands) + 1
            local eid = table.remove(cands, idx)
            DealDmgToEntity(pIdx, eid, 2 + bonus)
        end
    end,
    ["CS2_031"] = function(pIdx, tgt)  -- Eislanze → friert ein; 4 Schaden statt Freeze, wenn Ziel bereits eingefroren ist
        local alreadyFrozen
        if tgt == 1 or tgt == 2 then
            alreadyFrozen = P(tgt).hero.frozen
        else
            local m = FindOnBoard(tgt)
            alreadyFrozen = m and m.frozen
        end
        if alreadyFrozen then
            DealDmgToEntity(pIdx, tgt, 4 + SpellDmgBonus(pIdx))
        elseif tgt == 1 or tgt == 2 then
            P(tgt).hero.frozen = true
        else
            local m = FindOnBoard(tgt)
            if m then m.frozen = true; UpdateCanAttack(m) end
        end
    end,
    ["CS2_062"] = function(pIdx, tgt)  -- Höllenfeuer → 3 Schaden an ALLE Charaktere
        local dmg = 3 + SpellDmgBonus(pIdx)
        local op = OtherIdx(pIdx)
        local snap = {}
        for _, m in ipairs(P(pIdx).board) do snap[#snap+1] = m.entityId end
        for _, m in ipairs(P(op).board)   do snap[#snap+1] = m.entityId end
        DealDmgToEntity(pIdx, pIdx, dmg)
        DealDmgToEntity(pIdx, op,   dmg)
        for _, eid in ipairs(snap) do DealDmgToEntity(pIdx, eid, dmg) end
        RunDeathPipeline()
    end,
    ["CS2_031"] = function(pIdx, tgt)  -- Eislanze: wenn Ziel eingefroren → 4 Schaden; sonst einfrieren
        if tgt == 1 or tgt == 2 then
            local h = P(tgt).hero
            if h.frozen then DealDmgToEntity(pIdx, tgt, 4)
            else h.frozen = true end
        else
            local m = FindOnBoard(tgt)
            if m then
                if m.frozen then DealDmgToEntity(pIdx, tgt, 4)
                else m.frozen = true; UpdateCanAttack(m) end
            end
        end
    end,
    ["CS2_009"] = function(pIdx, tgt)  -- Mal der Wildnis → +2/+3 + Spott
        local m = FindOnBoard(tgt)
        if m then
            m.enchantments[#m.enchantments+1] = {attack=2, health=3, expiresEndOfTurn=false, source=0}
            AddTagToMinion(m, "TAUNT"); RecalcAuras()
        end
    end,
    ["CS1_113"] = function(pIdx, tgt) -- Gedankenkontrolle → feindlichen Diener stehlen
        local m, mPIdx, mBIdx = FindOnBoard(tgt)
        if m and mPIdx ~= pIdx and #P(pIdx).board < 7 then
            table.remove(P(mPIdx).board, mBIdx)
            m.controller = pIdx
            table.insert(P(pIdx).board, m); RecalcAuras()
        end
    end,
    ["CS2_084"] = function(pIdx, tgt) -- Mal des Jägers → Leben auf 1 setzen
        local m = FindOnBoard(tgt)
        if m then
            local maxHp = m.baseHealth + (m.auraHealth or 0)
            for _, e in ipairs(m.enchantments) do maxHp = maxHp + (e.health or 0) end
            m.damageTaken = math.max(0, maxHp - 1)
        end
    end,
    ["CS1_129"] = function(pIdx, tgt) -- Inneres Feuer → Angriff = aktuelles Leben
        local m = FindOnBoard(tgt)
        if m then
            local maxHp = m.baseHealth + (m.auraHealth or 0)
            for _, e in ipairs(m.enchantments) do maxHp = maxHp + (e.health or 0) end
            local curHp = maxHp - m.damageTaken
            local curAtk = m.baseAttack + (m.auraAttack or 0)
            for _, e in ipairs(m.enchantments) do curAtk = curAtk + (e.attack or 0) end
            m.enchantments[#m.enchantments+1] = {attack = curHp - curAtk, health = 0, expiresEndOfTurn = false, source = 0}
            RecalcAuras()
        end
    end,
    ["CS2_041"] = function(pIdx, tgt) -- Heilung der Ahnen → volles Leben + Spott
        local m = FindOnBoard(tgt)
        if m and m.controller == pIdx then
            m.damageTaken = 0
            AddTagToMinion(m, "TAUNT")
            RecalcAuras()
        end
    end,
    ["EX1_607"] = function(pIdx, tgt) -- Innere Wut → 1 Schaden + +2 Angriff
        DealDmgToEntity(pIdx, tgt, 1)
        local m = FindOnBoard(tgt)
        if m then
            m.enchantments[#m.enchantments+1] = {attack=2, health=0, expiresEndOfTurn=false, source=0}
            RecalcAuras()
        end
    end,
    ["EX1_308"] = function(pIdx, tgt) -- Seelenfeuer → 4 Schaden + zufällige Karte abwerfen
        DealDmgToEntity(pIdx, tgt, 4)
        local hand = P(pIdx).hand
        if #hand > 0 then
            gs.prngState = PrngNext(gs.prngState)
            table.remove(hand, (gs.prngState % #hand) + 1)
        end
    end,
    ["EX1_621"] = function(pIdx, tgt) -- Kreis der Heilung → ALLE Diener +4 Leben
        -- Über den zentralen Heilpfad ausführen: Nur so reagieren Klerikerin,
        -- Lichtwächterin und Auchenaiseelenpriesterin regelgerecht. Helden sind
        -- laut Kartentext ausdrücklich nicht betroffen.
        local targets = {}
        for pi = 1, 2 do
            for _, m in ipairs(P(pi).board) do targets[#targets+1] = m.entityId end
        end
        for _, entityId in ipairs(targets) do HealEntity(entityId, 4, pIdx) end
    end,
    ["CS2_003"] = function(pIdx, tgt) -- Gedankensicht → zufällige Handkarte des Gegners kopieren
        local op = OtherIdx(pIdx)
        local hand = P(op).hand
        if #hand > 0 and #P(pIdx).hand < 10 then
            gs.prngState = PrngNext(gs.prngState)
            local card = hand[(gs.prngState % #hand) + 1]
            local base = ARKANA_CardData[card.id]
            P(pIdx).hand[#P(pIdx).hand+1] = {entityId=gs.entityCounter, id=card.id, cost=(base and base.cost or 0)}
            gs.entityCounter = gs.entityCounter + 1
        end
    end,
    ["EX1_145"] = function(pIdx, tgt) -- Vorbereitung → nächster Zauber kostet 3 weniger
        P(pIdx).spellCostReduction = (P(pIdx).spellCostReduction or 0) + 3
    end,
    ["CS2_073"] = function(pIdx, tgt, comboActive) -- Kaltblütigkeit → +2 ATK (Combo: +4 ATK)
        local m = FindOnBoard(tgt)
        if m then
            local bonus = comboActive and 4 or 2
            m.enchantments[#m.enchantments+1] = {attack=bonus, health=0, expiresEndOfTurn=false, source=0}
            RecalcAuras()
        end
    end,
    ["DS1_233"] = function(pIdx, tgt) -- Gedankenschlag → 5 Schaden am feindl. Helden
        DealDmgToEntity(pIdx, OtherIdx(pIdx), 5)
    end,
    ["EX1_345"] = function(pIdx, tgt) -- Gedankenspiele → zufälligen Diener aus Gegner-Deck beschwören
        local op = OtherIdx(pIdx)
        local minions = {}
        for _, id in ipairs(P(op).deck) do
            local c = ARKANA_CardData[id]
            if c and c.type == "MINION" then minions[#minions+1] = id end
        end
        if #minions > 0 and #P(pIdx).board < 7 then
            gs.prngState = PrngNext(gs.prngState)
            SummonMinionAt(pIdx, minions[(gs.prngState % #minions) + 1], #P(pIdx).board + 1)
        elseif #P(pIdx).board < 7 then
            SummonMinionAt(pIdx, "EX1_345t", #P(pIdx).board + 1)
        end
    end,
    ["CS2_087"] = function(pIdx, tgt)  -- Segen der Macht → Diener +3 ATK
        local m = FindOnBoard(tgt)
        if m then m.enchantments[#m.enchantments+1] = {attack=3, health=0, expiresEndOfTurn=false, source=0}; RecalcAuras() end
    end,
    ["CS2_013"] = function(pIdx, tgt)  -- Wildwuchs → +1 Manakristall (leerer Kristall, füllt bei StartTurn)
        local p = P(pIdx)
        if p.mana.maxPermanent < 10 then
            p.mana.maxPermanent = p.mana.maxPermanent + 1
            -- currentPermanent bleibt unverändert — neuer Kristall leer
            addon:GameLog("[Wildwuchs] Manakristalle: " .. p.mana.maxPermanent)
        elseif #p.hand < 10 then
            -- Bei 10 Kristallen gibt es stattdessen "Überschüssiges Mana" auf die Hand
            p.hand[#p.hand+1] = {entityId=gs.entityCounter, id="CS2_013t", cost=0}
            gs.entityCounter = gs.entityCounter + 1
            addon:GameLog("[Wildwuchs] Bereits 10 Kristalle → Überschüssiges Mana")
        end
    end,
    ["CS2_013t"] = function(pIdx, tgt)  -- Überschüssiges Mana → 1 Karte ziehen
        DrawCard(pIdx)
    end,
    ["CS2_072"] = function(pIdx, tgt)  -- Meucheln → 2 Schaden, aber NUR an unverletzte Diener
        local m = FindOnBoard(tgt)
        if m and m.damageTaken == 0 then
            DealDmgToEntity(pIdx, tgt, 2 + SpellDmgBonus(pIdx))
        end
    end,
    ["CS2_108"] = function(pIdx, tgt)  -- Hinrichten → verletzten feindl. Diener vernichten
        local m = FindOnBoard(tgt)
        if m and m.controller ~= pIdx and m.damageTaken > 0 then m.damageTaken = m.damageTaken + 9999 end
    end,
    ["CS2_234"] = function(pIdx, tgt)  -- Schattenwort: Schmerz → beliebiger Diener ≤3 ATK vernichten
        local m = FindOnBoard(tgt)
        if m then
            local atk = m.baseAttack + m.auraAttack
            for _, e in ipairs(m.enchantments) do atk = atk + (e.attack or 0) end
            if atk <= 3 then m.damageTaken = m.damageTaken + 9999 end
        end
    end,
    ["EX1_622"] = function(pIdx, tgt)  -- Schattenwort: Tod → beliebiger Diener ≥5 ATK vernichten
        local m = FindOnBoard(tgt)
        if m then
            local atk = m.baseAttack + m.auraAttack
            for _, e in ipairs(m.enchantments) do atk = atk + (e.attack or 0) end
            if atk >= 5 then m.damageTaken = m.damageTaken + 9999 end
        end
    end,
    ["CS2_092"] = function(pIdx, tgt)  -- Segen der Könige → Diener +4/+4
        local m = FindOnBoard(tgt)
        if m then m.enchantments[#m.enchantments+1] = {attack=4, health=4, expiresEndOfTurn=false, source=0}; RecalcAuras() end
    end,
    ["CS2_039"] = function(pIdx, tgt)  -- Windzorn → Diener Windzorn
        local m = FindOnBoard(tgt)
        if m then AddTagToMinion(m, "WINDFURY"); UpdateCanAttack(m) end
    end,
    ["CS2_103"] = function(pIdx, tgt)  -- Sturmangriff → freundl. Diener +2 ATK + Ansturm
        local m = FindOnBoard(tgt)
        if m and m.controller == pIdx then
            m.enchantments[#m.enchantments+1] = {attack=2, health=0, expiresEndOfTurn=false, source=0}
            AddTagToMinion(m, "CHARGE"); UpdateCanAttack(m); RecalcAuras()
        end
    end,
    ["CS2_046"] = function(pIdx, tgt)  -- Kampfrausch (Bloodlust) → alle freundl. Diener +3 ATK diesen Zug
        for _, bm in ipairs(P(pIdx).board) do
            bm.enchantments[#bm.enchantments+1] = {attack=3, health=0, expiresEndOfTurn=true, source=0}
        end
        RecalcAuras()
    end,
    ["CS2_105"] = function(pIdx, tgt)  -- Heldenhafter Stoß → Held +4 ATK diesen Zug
        local hero = P(pIdx).hero
        hero.enchantments[#hero.enchantments+1] = {attack=4, health=0, expiresEndOfTurn=true, source=0}
        hero.attack = hero.attack + 4
    end,
    ["CS2_005"] = function(pIdx, tgt)  -- Klaue → Held +2 ATK diesen Zug + 2 Rüstung
        local hero = P(pIdx).hero
        hero.enchantments[#hero.enchantments+1] = {attack=2, health=0, expiresEndOfTurn=true, source=0}
        hero.attack = hero.attack + 2
        hero.armor = hero.armor + 2
    end,
    ["CS2_011"] = function(pIdx, tgt)  -- Wildes Brüllen → alle freundl. Charaktere +2 ATK diesen Zug
        for _, bm in ipairs(P(pIdx).board) do
            bm.enchantments[#bm.enchantments+1] = {attack=2, health=0, expiresEndOfTurn=true, source=0}
        end
        local hero = P(pIdx).hero
        hero.enchantments[#hero.enchantments+1] = {attack=2, health=0, expiresEndOfTurn=true, source=0}
        hero.attack = hero.attack + 2
        RecalcAuras()
    end,
    ["EX1_360"] = function(pIdx, tgt)  -- Demut → Diener ATK auf 1
        local m = FindOnBoard(tgt)
        if m then
            local eff = MinionEffAtk(m)
            if eff ~= 1 then m.enchantments[#m.enchantments+1] = {attack=1-eff, health=0, expiresEndOfTurn=false, source=0}; RecalcAuras() end
        end
    end,
    ["EX1_355"] = function(pIdx, tgt)  -- Gesegneter Champion → Diener ATK verdoppeln
        local m = FindOnBoard(tgt)
        if m then
            local eff = MinionEffAtk(m)
            if eff > 0 then m.enchantments[#m.enchantments+1] = {attack=eff, health=0, expiresEndOfTurn=false, source=0}; RecalcAuras() end
        end
    end,
    ["EX1_371"] = function(pIdx, tgt)  -- Hand des Schutzes → Diener Gottesschild
        local m = FindOnBoard(tgt)
        if m and m.controller == pIdx then m.divineShield = true end
    end,
    ["EX1_312"] = function(pIdx, tgt)  -- Wirbelnder Nether → alle Diener vernichten
        for p = 1, 2 do for _, bm in ipairs(P(p).board) do bm.damageTaken = bm.damageTaken + 9999 end end
    end,
    ["CS2_075"] = function(pIdx, tgt)  -- Finsterer Stoß → 3 Schaden an feindl. Helden
        DealDmgToEntity(pIdx, OtherIdx(pIdx), 3 + SpellDmgBonus(pIdx))
    end,
    ["CS2_076"] = function(pIdx, tgt)  -- Attentat → feindl. Diener vernichten
        local m = FindOnBoard(tgt)
        if m and m.controller ~= pIdx then m.damageTaken = m.damageTaken + 9999 end
    end,
    ["EX1_617"] = function(pIdx, tgt)  -- Tödlicher Schuss → zufälligen feindl. Diener vernichten
        local board = P(OtherIdx(pIdx)).board
        if #board > 0 then gs.prngState = PrngNext(gs.prngState); board[(gs.prngState % #board) + 1].damageTaken = 9999 end
    end,
    ["EX1_619"] = function(pIdx, tgt)  -- Gleichheit → alle Diener HP auf 1
        for p = 1, 2 do
            for _, bm in ipairs(P(p).board) do
                local maxHp = MinionEffMaxHp(bm)
                if maxHp > 1 then bm.damageTaken = maxHp - 1 end
            end
        end
    end,
    ["EX1_246"] = function(pIdx, tgt)  -- Verhexung → Frosch (0/1 Spott)
        local m, mPIdx, mBIdx = FindOnBoard(tgt)
        if m then
            local frog = NewMinion("TRANSFORM_FROG", mPIdx)
            if frog then frog.entityId = gs.entityCounter; gs.entityCounter = gs.entityCounter + 1; frog.transformedFrom = m.entityId; P(mPIdx).board[mBIdx] = frog; RecalcAuras() end
        end
    end,
    ["CS2_022"] = function(pIdx, tgt)  -- Verwandlung → Schaf (1/1)
        local m, mPIdx, mBIdx = FindOnBoard(tgt)
        if m then
            local sheep = NewMinion("TRANSFORM_SHEEP", mPIdx)
            if sheep then sheep.entityId = gs.entityCounter; gs.entityCounter = gs.entityCounter + 1; sheep.transformedFrom = m.entityId; P(mPIdx).board[mBIdx] = sheep; RecalcAuras() end
        end
    end,
    ["EX1_538"] = function(pIdx, tgt)  -- Lasst die Hunde los! → 1 Hund pro feindl. Diener
        local count = #P(OtherIdx(pIdx)).board
        for i = 1, count do SummonMinionAt(pIdx, "EX1_538t", #P(pIdx).board + 1) end
    end,
    ["EX1_539"] = function(pIdx, tgt)  -- Fass! → 3 Schaden (5 wenn eigenes Wildtier auf Feld), +SpellDmgBonus
        local hasBeast = false
        for _, bm in ipairs(P(pIdx).board) do
            if (ARKANA_CardData[bm.id] or {}).race == "BEAST" then hasBeast = true; break end
        end
        DealDmgToEntity(pIdx, tgt, (hasBeast and 5 or 3) + SpellDmgBonus(pIdx))
    end,
    ["EX1_544"] = function(pIdx, tgt)  -- Leuchtfeuer: Verstohlenheit entfernen + Geheimnisse zerstören + Karte ziehen
        local op = OtherIdx(pIdx)
        for pi = 1, 2 do
            for _, m in ipairs(P(pi).board) do
                m.stealthed = false
                for i, t in ipairs(m.tags) do
                    if t.type == "STEALTH" then table.remove(m.tags, i); break end
                end
            end
        end
        P(op).secrets = {}
        DrawCard(pIdx)
    end,
    ["CS2_027"] = function(pIdx, tgt)  -- Spiegelbild → 2× Spiegelbild (0/2 Spott)
        SummonMinionAt(pIdx, "CS2_mirror", #P(pIdx).board + 1)
        SummonMinionAt(pIdx, "CS2_mirror", #P(pIdx).board + 1)
    end,
    ["CS2_032"] = function(pIdx, tgt)  -- Flammenstoß → 4 Schaden alle feindl. Diener
        local board = P(OtherIdx(pIdx)).board
        local bonus = SpellDmgBonus(pIdx)
        for i = #board, 1, -1 do DealDmgToEntity(pIdx, board[i].entityId, 4 + bonus) end
    end,
    ["CS2_026"] = function(pIdx, tgt)  -- Frostnova → alle feindl. Diener einfrieren
        for _, bm in ipairs(P(OtherIdx(pIdx)).board) do bm.frozen = true; UpdateCanAttack(bm) end
    end,
    ["EX1_400"] = function(pIdx, tgt)  -- Wirbelwind → 1 Schaden ALLE Charaktere (beide Helden + alle Diener)
        local op = OtherIdx(pIdx)
        local snap = {pIdx, op}
        for _, bm in ipairs(P(pIdx).board) do snap[#snap+1] = bm.entityId end
        for _, bm in ipairs(P(op).board)   do snap[#snap+1] = bm.entityId end
        for _, eid in ipairs(snap) do DealDmgToEntity(pIdx, eid, 1) end
    end,
    ["CS2_093"] = function(pIdx, tgt)  -- Weihe → 2 Schaden alle Feinde
        local op = OtherIdx(pIdx)
        local bonus = SpellDmgBonus(pIdx)
        local board = P(op).board
        for i = #board, 1, -1 do DealDmgToEntity(pIdx, board[i].entityId, 2 + bonus) end
        DealDmgToEntity(pIdx, op, 2 + bonus)
    end,
    ["EX1_626"] = function(pIdx, tgt)  -- Massenbannung → alle feindl. Diener schweigen + 1 Karte
        for _, bm in ipairs(P(OtherIdx(pIdx)).board) do SilenceMinion(bm) end
        DrawCard(pIdx)
    end,
    ["EX1_128"] = function(pIdx, tgt)  -- Verhüllen → Verstohlenheit bis nächsten eigenen Zug
        for _, bm in ipairs(P(pIdx).board) do
            bm.stealthed = true
            bm.stealthedByVerhullen = pIdx
            if not HasTag(bm.tags, "STEALTH") then bm.tags[#bm.tags+1] = {type="STEALTH"} end
        end
    end,
    ["EX1_144"] = function(pIdx, tgt)  -- Schattenschritt → freundl. Diener zurück, kostet 2 weniger
        local m = FindOnBoard(tgt)
        if not m or m.controller ~= pIdx then return end
        local card = ARKANA_CardData[m.id]
        for i, bm in ipairs(P(pIdx).board) do
            if bm.entityId == tgt then table.remove(P(pIdx).board, i); break end
        end
        -- Der Auktionator zieht jetzt regelgerecht vor dem Zaubertext. Füllt
        -- diese Karte den letzten Handplatz, darf Schattenschritt nicht als
        -- elfte Karte zurückkehren; der zurückgenommene Diener verfällt dann.
        if #P(pIdx).hand < 10 then
            P(pIdx).hand[#P(pIdx).hand+1] = {entityId=gs.entityCounter, id=m.id, cost=math.max(0, (card and card.cost or 0) - 2)}
            gs.entityCounter = gs.entityCounter + 1
        else
            addon:GE_Log(pIdx, "Schattenschritt: " .. CardName(m.id) .. " verfällt wegen voller Hand")
        end
        RecalcAuras()
    end,
    ["EX1_581"] = function(pIdx, tgt)  -- Kopfnuss → feindl. Diener zurück auf Gegner-Hand
        local op = OtherIdx(pIdx)
        local m = FindOnBoard(tgt)
        if not m or m.controller ~= op then return end
        local card = ARKANA_CardData[m.id]
        for i, bm in ipairs(P(op).board) do
            if bm.entityId == tgt then table.remove(P(op).board, i); break end
        end
        P(op).hand[#P(op).hand+1] = {entityId=gs.entityCounter, id=m.id, cost=card and card.cost or 0}
        gs.entityCounter = gs.entityCounter + 1
        RecalcAuras()
    end,
    ["EX1_126"] = function(pIdx, tgt)  -- Verrat → feindl. Diener fügt Nachbarn seinen Schaden zu
        local op = OtherIdx(pIdx)
        local m = FindOnBoard(tgt)
        if not m then return end
        local atk = MinionEffAtk(m)
        if atk <= 0 then return end
        local pos = nil
        for i, bm in ipairs(P(op).board) do if bm.entityId == tgt then pos = i; break end end
        if not pos then return end
        local lm = P(op).board[pos - 1]; local rm = P(op).board[pos + 1]
        if lm then DealDmgToEntity(pIdx, lm.entityId, atk) end
        if rm then DealDmgToEntity(pIdx, rm.entityId, atk) end
    end,
    ["EX1_570"] = function(pIdx, tgt)  -- Biss → Held +4 ATK + 4 Rüstung diesen Zug
        local hero = P(pIdx).hero
        hero.enchantments[#hero.enchantments+1] = {attack=4, health=0, expiresEndOfTurn=true, source=0}
        hero.attack = hero.attack + 4; hero.armor = hero.armor + 4
    end,
    ["CS2_104"] = function(pIdx, tgt)  -- Toben → verletzten freundl. Diener +3/+3
        local m = FindOnBoard(tgt)
        if m and m.controller == pIdx and m.damageTaken > 0 then
            m.enchantments[#m.enchantments+1] = {attack=3, health=3, expiresEndOfTurn=false, source=0}; RecalcAuras()
        end
    end,
    ["EX1_248"] = function(pIdx, tgt)  -- Wildgeist → 2× Geisterwolf (2/3 Spott); OVERLOAD:2 via ExecPlay
        SummonMinionAt(pIdx, "EX1_248t", #P(pIdx).board + 1)
        SummonMinionAt(pIdx, "EX1_248t", #P(pIdx).board + 1)
    end,
    ["EX1_407"] = function(pIdx, tgt)  -- Scharmützel → alle Diener vernichten außer 1 zufälligen
        local all = {}
        for p = 1, 2 do for _, bm in ipairs(P(p).board) do all[#all+1] = bm end end
        if #all < 2 then return end
        gs.prngState = PrngNext(gs.prngState)
        local survivor = all[(gs.prngState % #all) + 1]
        for _, bm in ipairs(all) do if bm.entityId ~= survivor.entityId then bm.damageTaken = bm.damageTaken + 9999 end end
    end,
    ["EX1_349"] = function(pIdx, tgt)  -- Göttliche Gunst → Karten ziehen bis Hand = Gegner-Handgröße
        local myCount = #P(pIdx).hand
        local opCount = #P(OtherIdx(pIdx)).hand
        for _ = myCount + 1, opCount do DrawCard(pIdx) end
    end,
    ["EX1_316"] = function(pIdx, tgt)  -- Überwältigende Macht → Diener +4/+4, stirbt Zugende
        local m = FindOnBoard(tgt)
        if m and m.controller == pIdx then
            m.enchantments[#m.enchantments+1] = {attack=4, health=4, expiresEndOfTurn=false, source=0}
            m.dieEndOfTurn = true; RecalcAuras()
        end
    end,
    ["EX1_571"] = function(pIdx, tgt)  -- Naturgewalt → 3× Baumläufer (2/2), sterben Zugende
        for _ = 1, 3 do
            if #P(pIdx).board < 7 then
                SummonMinionAt(pIdx, "EX1_571t", #P(pIdx).board + 1)
                local newest = P(pIdx).board[#P(pIdx).board]
                if newest then newest.dieEndOfTurn = true; AddTagToMinion(newest, "CHARGE"); UpdateCanAttack(newest) end
            end
        end
    end,
    ["NEW1_004"] = function(pIdx, tgt)  -- Verschwinden → alle Diener auf Eigentümerhand zurück
        for p = 1, 2 do
            local snapshot = {}; for _, bm in ipairs(P(p).board) do snapshot[#snapshot+1] = bm end
            for _, bm in ipairs(snapshot) do
                if #P(p).hand < 10 then
                    local base = ARKANA_CardData[bm.id]
                    P(p).hand[#P(p).hand+1] = {entityId=gs.entityCounter, id=bm.id, cost=(base and base.cost or 0)}
                    gs.entityCounter = gs.entityCounter + 1
                end
            end
            P(p).board = {}
        end
        RecalcAuras()
    end,
    ["CS2_038"] = function(pIdx, tgt)  -- Geist der Ahnen → Diener wird nach Tod erneut beschworen
        local m = FindOnBoard(tgt)
        if m then m.ancestralSpirit = true end
    end,
    ["EX1_572t"] = function(pIdx, tgt)  -- Traumform → Diener zurück auf Eigentümerhand
        local m, mPIdx, bIdx = FindOnBoard(tgt)
        if m and bIdx then
            table.remove(P(mPIdx).board, bIdx)
            local base = ARKANA_CardData[m.id]
            P(mPIdx).hand[#P(mPIdx).hand+1] = {entityId=gs.entityCounter, id=m.id, cost=(base and base.cost or 0)}
            gs.entityCounter = gs.entityCounter + 1
            RecalcAuras()
        end
    end,
    ["EX1_572t2"] = function(pIdx, tgt)  -- Alptraum → Diener +5/+5, stirbt Zugende
        local m = FindOnBoard(tgt)
        if m then
            m.enchantments[#m.enchantments+1] = {attack=5, health=5, expiresEndOfTurn=false, source=0}
            m.dieEndOfTurn = true
            RecalcAuras()
        end
    end,
    ["EX1_572t4"] = function(pIdx, tgt)  -- Ysera Erwacht → 5 Schaden an alle Charaktere
        for p = 1, 2 do
            DealDmgToEntity(pIdx, p, 5)
            local snap = {}; for _, bm in ipairs(P(p).board) do snap[#snap+1] = bm.entityId end
            for _, eid in ipairs(snap) do DealDmgToEntity(pIdx, eid, 5) end
        end
    end,
    ["CS2_045"] = function(pIdx, tgt)  -- Waffe des Felsbeißers: befreundeter Charakter +3 ATK diesen Zug
        if tgt == 1 or tgt == 2 then
            local hero = P(tgt).hero
            hero.enchantments[#hero.enchantments+1] = {attack=3, health=0, expiresEndOfTurn=true, source=0}
            hero.attack = hero.attack + 3
        else
            local m = FindOnBoard(tgt)
            if m then m.enchantments[#m.enchantments+1] = {attack=3, health=0, expiresEndOfTurn=true, source=0}; RecalcAuras() end
        end
    end,
    ["CS2_074"] = function(pIdx, tgt)  -- Tödliches Gift: eigene Waffe +2 ATK
        local w = P(pIdx).weapon
        if w then w.attack = w.attack + 2 end
    end,
    ["CS2_063"] = function(pIdx, tgt)  -- Verderbnis: feindl. Diener stirbt am Anfang nächsten Zuges
        local m = FindOnBoard(tgt)
        if m and m.controller ~= pIdx then m.dieAtStartOfTurn = pIdx end
    end,
    ["CS2_236"] = function(pIdx, tgt)  -- Göttlicher Wille: Diener HP verdoppeln
        local m = FindOnBoard(tgt)
        if m then
            m.enchantments[#m.enchantments+1] = {attack=0, health=MinionEffMaxHp(m), expiresEndOfTurn=false, source=0}
            RecalcAuras()
        end
    end,
    ["EX1_334"] = function(pIdx, tgt)  -- Dunkler Wahnsinn: feindl. Diener ≤3 ATK bis Zugende stehlen
        local op = OtherIdx(pIdx)
        local m, mPIdx, bIdx = FindOnBoard(tgt)
        if not m or m.controller ~= op or MinionEffAtk(m) > 3 then return end
        table.remove(P(op).board, bIdx)
        m.controller = pIdx; m.returnToPlayer = op
        -- Erschöpfung löschen → Diener kann sofort angreifen (Shadow Madness-Regel)
        m.summonedThisTurn = nil; m.attacksThisTurn = 0
        if #P(pIdx).board < 7 then P(pIdx).board[#P(pIdx).board+1] = m end
        RecalcAuras()
        UpdateCanAttack(m)
    end,
    ["CS2_061"] = function(pIdx, tgt)  -- Blutsauger: 2 Schaden an Ziel + eigener Held heilt 2
        DealDmgToEntity(pIdx, tgt, 2)
        HealEntity(pIdx, 2 * HealMult(pIdx), pIdx)
    end,
    ["EX1_596"] = function(pIdx, tgt)  -- Dämonenfeuer: freundl. Dämon → +2/+2, sonst 2 Schaden
        local m = FindOnBoard(tgt)
        if m and m.controller == pIdx and (ARKANA_CardData[m.id] or {}).race == "DEMON" then
            m.enchantments[#m.enchantments+1] = {attack=2, health=2, expiresEndOfTurn=false, source=0}
            RecalcAuras()
        else
            DealDmgToEntity(pIdx, tgt, 2)
        end
    end,
    ["EX1_303"] = function(pIdx, tgt)  -- Schattenflamme: eigener Diener sterben → ATK-Schaden an alle feindl. Diener (nicht Held)
        local m = FindOnBoard(tgt)
        if not m or m.controller ~= pIdx then return end
        local atk = MinionEffAtk(m)
        m.damageTaken = m.damageTaken + 9999
        if atk > 0 then
            local op = OtherIdx(pIdx)
            local snap = {}; for _, bm in ipairs(P(op).board) do snap[#snap+1] = bm.entityId end
            for _, eid in ipairs(snap) do DealDmgToEntity(pIdx, eid, atk) end
        end
    end,
    ["EX1_365"] = function(pIdx, tgt)  -- Heiliger Zorn: Karte ziehen + Schaden = Kosten
        local hBefore = #P(pIdx).hand
        DrawCard(pIdx)
        if #P(pIdx).hand > hBefore then
            local cost = P(pIdx).hand[#P(pIdx).hand].cost or 0
            if cost > 0 then DealDmgToEntity(pIdx, tgt, cost) end
        end
    end,
    ["CS2_025"] = function(pIdx, tgt)  -- Arkane Explosion: 1 Schaden an alle feindl. Diener
        local op = OtherIdx(pIdx)
        local snap = {}
        for _, bm in ipairs(P(op).board) do snap[#snap+1] = bm.entityId end
        for _, eid in ipairs(snap) do DealDmgToEntity(pIdx, eid, 1 + SpellDmgBonus(pIdx)) end
    end,
    ["EX1_384"] = function(pIdx, tgt)  -- Zornige Vergeltung: 8 Schaden zufällig auf Feinde verteilt (Zauberschaden = mehr Geschosse, nicht mehr Schaden)
        local op = OtherIdx(pIdx)
        for _ = 1, 8 + SpellDmgBonus(pIdx) do
            local pool = {op}
            for _, bm in ipairs(P(op).board) do
                if MinionCurHp(bm) > 0 then pool[#pool+1] = bm.entityId end
            end
            gs.prngState = PrngNext(gs.prngState)
            DealDmgToEntity(pIdx, pool[(gs.prngState % #pool) + 1], 1)
        end
    end,
    ["EX1_244"] = function(pIdx, tgt)  -- Macht der Totems: alle freundl. Totems +2 HP
        local count = 0
        for _, bm in ipairs(P(pIdx).board) do
            if (ARKANA_CardData[bm.id] or {}).race == "TOTEM" then
                bm.enchantments[#bm.enchantments+1] = {attack=0, health=2, expiresEndOfTurn=false, source=0}
                count = count + 1
            end
        end
        if count == 0 then addon:GE_Log(pIdx, "Keine Totems vorhanden") end
        RecalcAuras()
    end,
    ["CS2_004"] = function(pIdx, tgt)  -- Machtwort: Schild: Diener +2 Leben + Karte ziehen
        local m = FindOnBoard(tgt)
        if m then
            m.enchantments[#m.enchantments+1] = {attack=0, health=2, expiresEndOfTurn=false, source=0}
            RecalcAuras()
        end
        DrawCard(pIdx)
    end,
    ["EX1_606"] = function(pIdx, tgt)  -- Schildblock: 5 Rüstung + Karte ziehen
        P(pIdx).hero.armor = P(pIdx).hero.armor + 5
        DrawCard(pIdx)
    end,
    ["EX1_129"] = function(pIdx, tgt)  -- Dolchfächer: 1 Schaden alle feindl. Diener + Karte ziehen
        local board = P(OtherIdx(pIdx)).board
        local bonus = SpellDmgBonus(pIdx)
        for i = #board, 1, -1 do DealDmgToEntity(pIdx, board[i].entityId, 1 + bonus) end
        DrawCard(pIdx)
    end,
    ["DS1_183"] = function(pIdx, tgt)  -- Mehrfachschuss: 3 Schaden an 2 zufällige feindl. Diener
        local op = OtherIdx(pIdx)
        local bonus = SpellDmgBonus(pIdx)
        for _ = 1, 2 do
            local alive = {}
            for _, bm in ipairs(P(op).board) do
                if MinionCurHp(bm) > 0 then alive[#alive+1] = bm.entityId end
            end
            if #alive == 0 then break end
            gs.prngState = PrngNext(gs.prngState)
            DealDmgToEntity(pIdx, alive[(gs.prngState % #alive) + 1], 3 + bonus)
        end
    end,
    ["EX1_409"] = function(pIdx, tgt)  -- Aufwertung!: Waffe +1/+1 oder neue 1/3 Waffe
        local w = P(pIdx).weapon
        if w then
            w.attack = w.attack + 1; w.durability = w.durability + 1
        else
            P(pIdx).weapon = {entityId=gs.entityCounter, id="EX1_409a", attack=1, durability=3, tags={}}
            gs.entityCounter = gs.entityCounter + 1
        end
    end,
    ["DS1_184"] = function(pIdx, tgt)  -- Fährtenlesen: Top-3 anzeigen, 1 wählen, Rest abwerfen
        local deck = P(pIdx).deck
        local count = math.min(3, #deck)
        if count == 0 then return end
        local choices = {}
        for i = 1, count do choices[i] = deck[#deck - i + 1] end
        P(pIdx).trackingChoices = choices
        if addon.GE_OnTracking then addon:GE_OnTracking(pIdx, choices) end
    end,
    ["EX1_363"] = function(pIdx, tgt)  -- Segen der Weisheit: Karte ziehen wenn Diener angreift
        local m = FindOnBoard(tgt)
        if m then m.drawOnAttack = true end
    end,
    ["EX1_158"] = function(pIdx, tgt)  -- Seele des Waldes: alle freundl. Diener Todesröcheln:Treant
        for _, m in ipairs(P(pIdx).board) do m.extraDeathrattle = "EX1_tk9" end
    end,
    ["EX1_320"] = function(pIdx, tgt)  -- Omen der Verdammnis: 3 Schaden + falls stirbt → Wichtel
        local bonus = SpellDmgBonus(pIdx)
        local target = FindOnBoard(tgt)
        DealDmgToEntity(pIdx, tgt, 3 + bonus)
        if target and MinionCurHp(target) <= 0 and #P(pIdx).board < 7 then
            SummonMinionAt(pIdx, "EX1_598", #P(pIdx).board + 1)
        end
        RunDeathPipeline()
    end,
    ["EX1_154"] = function(pIdx, tgt, _, choiceId)  -- Zorn: Wahl A=3 Schaden, B=1 Schaden + Karte
        if choiceId == "EX1_154b" then
            DealDmgToEntity(pIdx, tgt, 1 + SpellDmgBonus(pIdx)); DrawCard(pIdx)
        else
            DealDmgToEntity(pIdx, tgt, 3 + SpellDmgBonus(pIdx))
        end
    end,
    ["EX1_155"] = function(pIdx, tgt, _, choiceId)  -- Mal der Natur: Wahl A=+4 ATK, B=+4 HP+Spott
        local m = FindOnBoard(tgt)
        if m then
            if choiceId == "EX1_155b" then
                m.enchantments[#m.enchantments+1] = {attack=0, health=4, expiresEndOfTurn=false, source=0}
                m.tags = m.tags or {}
                local hasTaunt = false
                for _, t in ipairs(m.tags) do if t.type == "TAUNT" then hasTaunt = true; break end end
                if not hasTaunt then m.tags[#m.tags+1] = {type="TAUNT"} end
            else
                m.enchantments[#m.enchantments+1] = {attack=4, health=0, expiresEndOfTurn=false, source=0}
            end
            RecalcAuras()
        end
    end,
    ["EX1_160"] = function(pIdx, tgt, _, choiceId)  -- Macht der Wildnis: Wahl A=Panther, B=+1/+1 alle
        if choiceId == "EX1_160a" then
            SummonMinionAt(pIdx, "EX1_160_token", #P(pIdx).board + 1)
        else
            for _, m in ipairs(P(pIdx).board) do
                m.enchantments[#m.enchantments+1] = {attack=1, health=1, expiresEndOfTurn=false, source=0}
            end
            RecalcAuras()
        end
    end,
    ["EX1_164"] = function(pIdx, tgt, _, choiceId)  -- Pflege: Wahl A=+2 permanente Kristalle, B=3 Karten ziehen
        if choiceId == "EX1_164a" then
            local p = P(pIdx)
            p.mana.maxPermanent = math.min(10, p.mana.maxPermanent + 2)
        else
            DrawCard(pIdx); DrawCard(pIdx); DrawCard(pIdx)
        end
    end,
    ["NEW1_007"] = function(pIdx, tgt, _, choiceId)  -- Sternenregen: Wahl A=2 AoE, B=5 Ziel
        local op = OtherIdx(pIdx)
        if choiceId == "NEW1_007a" then
            local snap = {}; for _, bm in ipairs(P(op).board) do snap[#snap+1] = bm.entityId end
            for _, eid in ipairs(snap) do DealDmgToEntity(pIdx, eid, 2 + SpellDmgBonus(pIdx)) end
            RunDeathPipeline()
        else
            DealDmgToEntity(pIdx, tgt, 5 + SpellDmgBonus(pIdx))
        end
    end,
    ["CS2_012"] = function(pIdx, tgt)  -- Prankenhieb: 4 an Ziel + 1 alle anderen Feinde
        local op = OtherIdx(pIdx)
        local bonus = SpellDmgBonus(pIdx)
        DealDmgToEntity(pIdx, tgt, 4 + bonus)
        if tgt ~= op then DealDmgToEntity(pIdx, op, 1 + bonus) end
        local snap = {}; for _, bm in ipairs(P(op).board) do snap[#snap+1] = bm.entityId end
        for _, eid in ipairs(snap) do if eid ~= tgt then DealDmgToEntity(pIdx, eid, 1 + bonus) end end
    end,
    ["CS2_114"] = function(pIdx, tgt)  -- Spalten: 2 Schaden an 2 zufällige feindl. Diener
        local op = OtherIdx(pIdx)
        local bonus = SpellDmgBonus(pIdx)
        for _ = 1, 2 do
            local alive = {}
            for _, bm in ipairs(P(op).board) do
                if MinionCurHp(bm) > 0 then alive[#alive+1] = bm.entityId end
            end
            if #alive == 0 then break end
            gs.prngState = PrngNext(gs.prngState)
            DealDmgToEntity(pIdx, alive[(gs.prngState % #alive) + 1], 2 + bonus)
        end
    end,
    ["CS2_053"] = function(pIdx, tgt)  -- Fernsicht: Karte ziehen, Kosten -3
        local hand = P(pIdx).hand
        local before = #hand
        DrawCard(pIdx)
        if #hand > before then
            local card = hand[#hand]
            card.cost = math.max(0, card.cost - 3)
        end
    end,
    ["EX1_317"] = function(pIdx, tgt)  -- Dämonen wahrnehmen: 2 Dämonen aus Deck ziehen
        local deck = P(pIdx).deck
        local drawn = 0
        local i = 1
        while i <= #deck and drawn < 2 do
            local id = deck[i]
            local cd = ARKANA_CardData[id]
            if cd and cd.race == "DEMON" then
                table.remove(deck, i)
                if #P(pIdx).hand < 10 then
                    gs.entityCounter = gs.entityCounter + 1
                    P(pIdx).hand[#P(pIdx).hand+1] = {entityId=gs.entityCounter, id=id, cost=cd.cost or 0}
                end
                drawn = drawn + 1
            else
                i = i + 1
            end
        end
        if drawn == 0 then addon:GE_Log(pIdx, "Kein Dämon im Deck") end
    end,
    ["EX1_161"] = function(pIdx, tgt)  -- Kreislauf der Natur: Diener vernichten + Gegner zieht 2
        local m = FindOnBoard(tgt)
        if m then m.damageTaken = m.damageTaken + 9999; RunDeathPipeline() end
        DrawCard(OtherIdx(pIdx))
        DrawCard(OtherIdx(pIdx))
    end,
    ["CS2_233"] = function(pIdx, tgt)  -- Klingenwirbel: Waffe zerstören + ATK Schaden an alle Feinde
        local w = P(pIdx).weapon
        if not w then addon:GE_Log(pIdx, "Keine Waffe angelegt"); return end
        local atk = w.attack
        P(pIdx).weapon = nil
        local op = OtherIdx(pIdx)
        DealDmgToEntity(pIdx, op, atk)
        local snap = {}; for _, bm in ipairs(P(op).board) do snap[#snap+1] = bm.entityId end
        for _, eid in ipairs(snap) do DealDmgToEntity(pIdx, eid, atk) end
    end,
    ["EX1_549"] = function(pIdx, tgt)  -- Zorn der Wildtiers: Wildtier +2 ATK + Immunität diesen Zug
        local m = FindOnBoard(tgt)
        if not m or m.controller ~= pIdx then return end
        local cd = ARKANA_CardData[m.id]
        if not cd or cd.race ~= "BEAST" then addon:GE_Log(pIdx, "Kein Wildtier"); return end
        m.enchantments[#m.enchantments+1] = {attack=2, health=0, expiresEndOfTurn=true, source=0}
        m.immuneThisTurn = true
        RecalcAuras()
    end,
    ["EX1_339"] = function(pIdx, tgt)  -- Gedankenraub: 2 zufällige Karten aus Gegner-Deck kopieren
        local opDeck = P(OtherIdx(pIdx)).deck
        if #opDeck == 0 then return end
        local hand = P(pIdx).hand
        for _ = 1, 2 do
            if #opDeck == 0 then break end
            gs.prngState = PrngNext(gs.prngState)
            local id = opDeck[(gs.prngState % #opDeck) + 1]
            local cd = ARKANA_CardData[id]
            if #hand < 10 then
                gs.entityCounter = gs.entityCounter + 1
                hand[#hand+1] = {entityId=gs.entityCounter, id=id, cost=cd and cd.cost or 0}
            end
        end
    end,
    ["EX1_578"] = function(pIdx, tgt)  -- Unbändigkeit: Schaden = Held-ATK an Diener
        local atk = (P(pIdx).hero.attack or 0)
        if atk > 0 then DealDmgToEntity(pIdx, tgt, atk) end
    end,
    ["NEW1_031"] = function(pIdx, tgt)  -- Tierbegleiter: zufälligen Wildtierbegleiter beschwören
        if #P(pIdx).board >= 7 then
            addon:GE_Log(pIdx, "Brett voll – kein Begleiter beschworen")
            return
        end
        local companions = {"NEW1_031a", "NEW1_031b", "NEW1_031c"}
        gs.prngState = PrngNext(gs.prngState)
        SummonMinionAt(pIdx, companions[(gs.prngState % 3) + 1], #P(pIdx).board + 1)
    end,
    ["PRO_001a"] = function(pIdx, tgt)  -- Ich bin ein Murloc: 1/1 Murloc für jede Handkarte
        local count = #P(pIdx).hand
        for _ = 1, count do
            if #P(pIdx).board >= 7 then break end
            SummonMinionAt(pIdx, "PRO_001a_t", #P(pIdx).board + 1)
        end
    end,
    ["PRO_001b"] = function(pIdx, tgt)  -- Schurken machen es...: 4 Schaden zuf. Feind + Karte ziehen
        local op = OtherIdx(pIdx)
        local tgts = {op}
        for _, bm in ipairs(P(op).board) do tgts[#tgts+1] = bm.entityId end
        gs.prngState = PrngNext(gs.prngState)
        DealDmgToEntity(pIdx, tgts[(gs.prngState % #tgts) + 1], 4)
        DrawCard(pIdx)
    end,
    ["PRO_001c"] = function(pIdx, tgt)  -- Macht der Horde: zuf. Horde-Krieger beschwören
        if #P(pIdx).board >= 7 then return end
        local warriors = {"NEW1_011", "EX1_084", "EX1_604"}
        gs.prngState = PrngNext(gs.prngState)
        SummonMinionAt(pIdx, warriors[(gs.prngState % #warriors) + 1], #P(pIdx).board + 1)
    end,
    ["EX1_277"] = function(pIdx, tgt)  -- Arkane Geschosse: 3× 1 Schaden an zufällige Feinde (Zauberschaden = mehr Geschosse, nicht mehr Schaden)
        local op = OtherIdx(pIdx)
        for _ = 1, 3 + SpellDmgBonus(pIdx) do
            local pool = {op}
            -- RunDeathPipeline läuft erst am ENDE von ExecPlay: ein vom vorherigen
            -- Geschoss getöteter Diener steht noch auf dem Brett und würde die
            -- Folgegeschosse schlucken (Schaden verpufft, Animation findet keinen
            -- Frame mehr). Tote hier überspringen — wie bei EX1_384.
            for _, bm in ipairs(P(op).board) do
                if MinionCurHp(bm) > 0 then pool[#pool+1] = bm.entityId end
            end
            gs.prngState = PrngNext(gs.prngState)
            DealDmgToEntity(pIdx, pool[(gs.prngState % #pool) + 1], 1)
        end
    end,
    ["CS2_028"] = function(pIdx, tgt)  -- Blizzard: 2 Schaden + Einfrieren alle feindl. Diener
        local op = OtherIdx(pIdx)
        local bonus = SpellDmgBonus(pIdx)
        local snap = {}
        for _, bm in ipairs(P(op).board) do snap[#snap+1] = bm.entityId end
        for _, eid in ipairs(snap) do
            DealDmgToEntity(pIdx, eid, 2 + bonus)
            local bm = FindOnBoard(eid)
            if bm then bm.frozen = true; UpdateCanAttack(bm) end
        end
    end,
    ["EX1_624"] = function(pIdx, tgt)  -- Heiliges Feuer: 5 Schaden auf Ziel, 5 Heilung auf eigenen Helden
        DealDmgToEntity(pIdx, tgt, 5 + SpellDmgBonus(pIdx))
        HealEntity(pIdx, 5 * HealMult(pIdx), pIdx)
    end,
    ["CS1_112"] = function(pIdx, tgt)  -- Heilige Nova: 2 Schaden alle Feinde + 2 Heilen alle Freunde
        local op = OtherIdx(pIdx)
        local bonus = SpellDmgBonus(pIdx)
        local snap = {}
        for _, bm in ipairs(P(op).board) do snap[#snap+1] = bm.entityId end
        snap[#snap+1] = op
        for _, eid in ipairs(snap) do DealDmgToEntity(pIdx, eid, 2 + bonus) end
        for _, bm in ipairs(P(pIdx).board) do HealEntity(bm.entityId, 2, pIdx) end
        HealEntity(pIdx, 2, pIdx)
    end,
    ["EX1_275"] = function(pIdx, tgt)  -- Kältekegel: 1 Schaden + Einfrieren an Ziel + Nachbarn
        local m, mPIdx, mBIdx = FindOnBoard(tgt)
        if not m then return end
        local board = P(mPIdx).board
        local bonus = SpellDmgBonus(pIdx)
        local hits = {}
        for _, idx in ipairs({mBIdx - 1, mBIdx, mBIdx + 1}) do
            if board[idx] then hits[#hits+1] = board[idx].entityId end
        end
        for _, eid in ipairs(hits) do
            local bm = FindOnBoard(eid)
            if bm then DealDmgToEntity(pIdx, eid, 1 + bonus); bm.frozen = true; UpdateCanAttack(bm) end
        end
    end,
    ["EX1_537"] = function(pIdx, tgt)  -- Explosivschuss: 5 Schaden Ziel + 2 Schaden Nachbarn
        local m, mPIdx, mBIdx = FindOnBoard(tgt)
        if not m then return end
        local board = P(mPIdx).board
        local bonus = SpellDmgBonus(pIdx)
        DealDmgToEntity(pIdx, tgt, 5 + bonus)
        for _, idx in ipairs({mBIdx - 1, mBIdx + 1}) do
            if board[idx] then DealDmgToEntity(pIdx, board[idx].entityId, 2 + bonus) end
        end
    end,
    ["EX1_309"] = function(pIdx, tgt)  -- Seele entziehen: Diener vernichten + 3 Leben heilen
        local m = FindOnBoard(tgt)
        if m then m.damageTaken = m.damageTaken + 9999 end
        HealEntity(pIdx, 3, pIdx)
    end,
    ["NEW1_003"] = function(pIdx, tgt)  -- Opferpakt: eigenen Dämon vernichten + 5 Leben heilen (nur Dämonen)
        local m = FindOnBoard(tgt)
        if m and m.controller == pIdx then
            local cd = ARKANA_CardData[m.id]
            if cd and cd.race == "DEMON" then
                m.damageTaken = m.damageTaken + 9999
                HealEntity(pIdx, 5, pIdx)
            end
        end
    end,
    ["EX1_124"] = function(pIdx, tgt, combo)  -- Ausweiden: 2 Schaden (Combo: 4)
        DealDmgToEntity(pIdx, tgt, (combo and 4 or 2) + SpellDmgBonus(pIdx))
    end,
    ["EX1_137"] = function(pIdx, tgt, combo)  -- Schädelbruch: 2 Schaden feindl. Held (Combo: kehrt auf Hand zurück)
        DealDmgToEntity(pIdx, OtherIdx(pIdx), 2 + SpellDmgBonus(pIdx))
        if combo then
            -- Rückkehr erst zu BEGINN des nächsten eigenen Zuges (StartTurn) — sofort
            -- zurücklegen ließ die Karte im selben Zug beliebig oft spielen.
            P(pIdx).headcrackReturn = (P(pIdx).headcrackReturn or 0) + 1
            addon:GE_Log(pIdx, "Schädelbruch kehrt zu Beginn deines nächsten Zuges zurück! (Combo)")
        end
    end,
    ["EX1_625"] = function(pIdx, tgt)  -- Schattengestalt: Heldenfähigkeit → 2/3 Schaden
        local p = P(pIdx)
        if p.hero.heroPowerOverride == "SHADOW_PRIEST" or p.hero.heroPowerOverride == "SHADOW_PRIEST_UPGRADED" then
            p.hero.heroPowerOverride = "SHADOW_PRIEST_UPGRADED"
            addon:GE_Log(pIdx, "Schattengestalt: Heldenfähigkeit zu 'Gedankenschinden' geändert!")
        else
            p.hero.heroPowerOverride = "SHADOW_PRIEST"
            addon:GE_Log(pIdx, "Schattengestalt: Heldenfähigkeit zu 'Dunkle Pulse' geändert!")
        end
    end,
    ["EX1_391"] = function(pIdx, tgt)  -- Zerschmettern: 2 Schaden; wenn überlebt → Karte ziehen
        local m = FindOnBoard(tgt)
        if not m then return end
        local maxHp = m.baseHealth
        for _, e in ipairs(m.enchantments) do maxHp = maxHp + (e.health or 0) end
        DealDmgToEntity(pIdx, tgt, 2 + SpellDmgBonus(pIdx))
        if m.damageTaken < maxHp then DrawCard(pIdx) end
    end,
    ["EX1_302"] = function(pIdx, tgt)  -- Weltliche Ängste: 1 Schaden; wenn stirbt → Karte ziehen
        local m = FindOnBoard(tgt)
        if not m then return end
        local maxHp = m.baseHealth
        for _, e in ipairs(m.enchantments) do maxHp = maxHp + (e.health or 0) end
        DealDmgToEntity(pIdx, tgt, 1 + SpellDmgBonus(pIdx))
        if m.damageTaken >= maxHp then DrawCard(pIdx) end
    end,
    ["EX1_410"] = function(pIdx, tgt)  -- Schildschlag: Schaden = eigene Rüstung
        local dmg = P(pIdx).hero.armor or 0
        if dmg > 0 then DealDmgToEntity(pIdx, tgt, dmg + SpellDmgBonus(pIdx)) end
    end,
    ["EX1_392"] = function(pIdx, tgt)  -- Kampfeswut: 1 Karte pro verletztem eigenen Diener (Held zählt nicht)
        local count = 0
        for _, bm in ipairs(P(pIdx).board) do
            if (bm.damageTaken or 0) > 0 then count = count + 1 end
        end
        for _ = 1, count do DrawCard(pIdx) end
    end,
    ["NEW1_036"] = function(pIdx, tgt)  -- Befehlsruf: eigene Diener HP-Untergrenze 1 diesen Zug + Karte ziehen
        for _, bm in ipairs(P(pIdx).board) do bm.minHealthThisTurn = 1 end
        DrawCard(pIdx)
    end,
    ["EX1_408"] = function(pIdx, tgt)  -- Tödlicher Stoß: 4 Schaden, 6 wenn eigener Held max. 12 Leben hat
        local dmg = (P(pIdx).hero.health or 30) <= 12 and 6 or 4
        DealDmgToEntity(pIdx, tgt, dmg + SpellDmgBonus(pIdx))
    end,
    ["EX1_259"] = function(pIdx, tgt)  -- Gewittersturm: 2-3 Schaden (zufällig, pro Diener) an alle feindl. Diener
        local bonus = SpellDmgBonus(pIdx)
        local board = P(OtherIdx(pIdx)).board
        for i = #board, 1, -1 do
            gs.prngState = PrngNext(gs.prngState)
            local dmg = 2 + (gs.prngState % 2)
            DealDmgToEntity(pIdx, board[i].entityId, dmg + bonus)
        end
    end,
}

-- Laufzeit-Tags/-Trigger (fehlend in ClassicCardData)
if ARKANA_CardData["NEW1_020"] then  -- Wilder Pyromant: 1 Schaden an ALLE Diener NACH eigenem Zauber
    ARKANA_CardData["NEW1_020"].triggers = {{type="TRIGGER_AFTER_SPELL", effect="DAMAGE_ALL_MINIONS", value=1}}
end
if ARKANA_CardData["EX1_258"] then  -- Entfesselter Elementar: +1/+1 bei jeder gespielten Überladungs-Karte
    ARKANA_CardData["EX1_258"].triggers = {{type="TRIGGER_ON_CARD_PLAYED", effect="GIVE_SELF_BUFF", attack=1, health=1, onlyIfOverload=true}}
end
if ARKANA_CardData["EX1_080"] then  -- Geheimnisbewahrerin: +1/+1 bei jedem Geheimnis, unabhängig vom Besitzer
    ARKANA_CardData["EX1_080"].triggers = {{
        type="TRIGGER_ON_CARD_PLAYED", effect="GIVE_SELF_BUFF",
        attack=1, health=1, onlyIfSecret=true, anyPlayer=true,
    }}
end
if ARKANA_CardData["EX1_006"] then  -- Alarm-o-Bot: Zugbeginn → Tausch mit zufälligem Diener auf der Hand
    ARKANA_CardData["EX1_006"].triggers = {{type="TRIGGER_START_TURN", effect="SWAP_SELF_WITH_RANDOM_HAND_MINION"}}
end
if ARKANA_CardData["EX1_608"] then  -- Zauberlehrling: eigene Zauber kosten (1) weniger
    ARKANA_CardData["EX1_608"].tags = ARKANA_CardData["EX1_608"].tags or {}
    if not HasTag(ARKANA_CardData["EX1_608"].tags, "AURA_OWN_SPELL_COST_REDUCE") then
        ARKANA_CardData["EX1_608"].tags[#ARKANA_CardData["EX1_608"].tags+1] = {type="AURA_OWN_SPELL_COST_REDUCE", value=1}
    end
end
if ARKANA_CardData["EX1_274"] then  -- Astraler Arkanist: +2/+2 wenn am Zugende ein Geheimnis kontrolliert wird
    ARKANA_CardData["EX1_274"].triggers = {{type="TRIGGER_END_TURN", effect="GIVE_SELF_BUFF", attack=2, health=2, onlyIfSecret=true}}
end
if ARKANA_CardData["CS2_221"] then  -- Hasserfüllte Schmiedin: ENRAGE Waffe +2 ATK
    ARKANA_CardData["CS2_221"].tags = ARKANA_CardData["CS2_221"].tags or {}
    local has = false
    for _, t in ipairs(ARKANA_CardData["CS2_221"].tags) do if t.type == "ENRAGE" then has = true end end
    if not has then ARKANA_CardData["CS2_221"].tags[#ARKANA_CardData["CS2_221"].tags+1] = {type="ENRAGE", weaponAttack=2} end
end
if ARKANA_CardData["EX1_412"] then  -- Tobender Worgen: ENRAGE Windzorn +1 ATK
    ARKANA_CardData["EX1_412"].tags = ARKANA_CardData["EX1_412"].tags or {}
    local has = false
    for _, t in ipairs(ARKANA_CardData["EX1_412"].tags) do if t.type == "ENRAGE" then has = true end end
    if not has then ARKANA_CardData["EX1_412"].tags[#ARKANA_CardData["EX1_412"].tags+1] = {type="ENRAGE", attack=1, windfury=true} end
end
if ARKANA_CardData["EX1_390"] then  -- Taurenkrieger: ENRAGE +3 ATK
    local has = false
    for _, t in ipairs(ARKANA_CardData["EX1_390"].tags) do if t.type == "ENRAGE" then has = true end end
    if not has then ARKANA_CardData["EX1_390"].tags[#ARKANA_CardData["EX1_390"].tags+1] = {type="ENRAGE", attack=3} end
end
if ARKANA_CardData["EX1_393"] then  -- Amaniberserker: ENRAGE +3 ATK
    ARKANA_CardData["EX1_393"].tags = ARKANA_CardData["EX1_393"].tags or {}
    local has = false
    for _, t in ipairs(ARKANA_CardData["EX1_393"].tags) do if t.type == "ENRAGE" then has = true end end
    if not has then ARKANA_CardData["EX1_393"].tags[#ARKANA_CardData["EX1_393"].tags+1] = {type="ENRAGE", attack=3} end
end
if ARKANA_CardData["EX1_001"] and not ARKANA_CardData["EX1_001"].triggers then  -- Lichtwächterin: +2 ATK wenn irgendein Charakter geheilt wird
    ARKANA_CardData["EX1_001"].triggers = {{type="TRIGGER_ON_HEAL", effect="GIVE_SELF_ATTACK", value=2, anyPlayer=true}}
end
if ARKANA_CardData["CS2_122"] then  -- Schlachtzugsleiter: AURA +1 ATK alle Freundliche
    local has = false
    for _, t in ipairs(ARKANA_CardData["CS2_122"].tags or {}) do if t.type == "AURA" then has = true end end
    if not has then
        ARKANA_CardData["CS2_122"].tags = ARKANA_CardData["CS2_122"].tags or {}
        ARKANA_CardData["CS2_122"].tags[#ARKANA_CardData["CS2_122"].tags+1] = {type="AURA", range="ALL_FRIENDLY", attack=1}
    end
end
if ARKANA_CardData["DS1_175"] then  -- Waldwolf: andere Wildtiere +1 ATK
    local has = false
    for _, t in ipairs(ARKANA_CardData["DS1_175"].tags or {}) do if t.type == "AURA" then has = true end end
    if not has then
        ARKANA_CardData["DS1_175"].tags = ARKANA_CardData["DS1_175"].tags or {}
        ARKANA_CardData["DS1_175"].tags[#ARKANA_CardData["DS1_175"].tags+1] = {type="AURA", range="ALL_FRIENDLY_BEASTS", attack=1}
    end
end
if ARKANA_CardData["CS2_222"] then  -- Champion von Sturmwind: andere freundl. Diener +1/+1
    local has = false
    for _, t in ipairs(ARKANA_CardData["CS2_222"].tags or {}) do if t.type == "AURA" then has = true end end
    if not has then
        ARKANA_CardData["CS2_222"].tags = ARKANA_CardData["CS2_222"].tags or {}
        ARKANA_CardData["CS2_222"].tags[#ARKANA_CardData["CS2_222"].tags+1] = {type="AURA", range="ALL_FRIENDLY", attack=1, health=1}
    end
end
if ARKANA_CardData["EX1_162"] then  -- Terrorwolfalpha: benachbarte Diener +1 ATK
    local has = false
    for _, t in ipairs(ARKANA_CardData["EX1_162"].tags or {}) do if t.type == "AURA" then has = true end end
    if not has then
        ARKANA_CardData["EX1_162"].tags = ARKANA_CardData["EX1_162"].tags or {}
        ARKANA_CardData["EX1_162"].tags[#ARKANA_CardData["EX1_162"].tags+1] = {type="AURA", range="ADJACENT", attack=1}
    end
end
if ARKANA_CardData["EX1_565"] then  -- Flammenzungentotem: benachbarte Diener +2 ATK
    local has = false
    for _, t in ipairs(ARKANA_CardData["EX1_565"].tags or {}) do if t.type == "AURA" then has = true end end
    if not has then
        ARKANA_CardData["EX1_565"].tags = ARKANA_CardData["EX1_565"].tags or {}
        ARKANA_CardData["EX1_565"].tags[#ARKANA_CardData["EX1_565"].tags+1] = {type="AURA", range="ADJACENT", attack=2}
    end
end
if ARKANA_CardData["NEW1_027"] then  -- Südmeerkapitän: andere Piraten +1/+1
    local has = false
    for _, t in ipairs(ARKANA_CardData["NEW1_027"].tags or {}) do if t.type == "AURA" then has = true end end
    if not has then
        ARKANA_CardData["NEW1_027"].tags = ARKANA_CardData["NEW1_027"].tags or {}
        ARKANA_CardData["NEW1_027"].tags[#ARKANA_CardData["NEW1_027"].tags+1] = {type="AURA", range="ALL_FRIENDLY_PIRATES", attack=1, health=1}
    end
end
if ARKANA_CardData["EX1_507"] then  -- Murlocanführer: andere Murlocs +2/+1
    local has = false
    for _, t in ipairs(ARKANA_CardData["EX1_507"].tags or {}) do if t.type == "AURA" then has = true end end
    if not has then
        ARKANA_CardData["EX1_507"].tags = ARKANA_CardData["EX1_507"].tags or {}
        ARKANA_CardData["EX1_507"].tags[#ARKANA_CardData["EX1_507"].tags+1] = {type="AURA", range="ALL_FRIENDLY_MURLOCS", attack=2, health=1}
    end
end
if ARKANA_CardData["EX1_508"] then  -- Grimmschuppenorakel: andere Murlocs +1 ATK
    local has = false
    for _, t in ipairs(ARKANA_CardData["EX1_508"].tags or {}) do if t.type == "AURA" then has = true end end
    if not has then
        ARKANA_CardData["EX1_508"].tags = ARKANA_CardData["EX1_508"].tags or {}
        ARKANA_CardData["EX1_508"].tags[#ARKANA_CardData["EX1_508"].tags+1] = {type="AURA", range="ALL_FRIENDLY_MURLOCS", attack=1}
    end
end
if ARKANA_CardData["CS2_237"] and not ARKANA_CardData["CS2_237"].triggers then  -- Verhungernder Bussard
    ARKANA_CardData["CS2_237"].triggers = {{type="TRIGGER_ON_SUMMON", effect="DRAW_CARDS", value=1, onlyIfBeast=true}}
end
if ARKANA_CardData["NEW1_019"] and not ARKANA_CardData["NEW1_019"].triggers then  -- Messerjongleur: zufälligem Feind 1 Schaden bei Diener-Beschwörung
    ARKANA_CardData["NEW1_019"].triggers = {{type="TRIGGER_ON_SUMMON", effect="DEAL_DAMAGE_RANDOM_ENEMY", value=1}}
end
if ARKANA_CardData["EX1_084"] and not ARKANA_CardData["EX1_084"].triggers then  -- Kriegshymnenanführerin: Ansturm für ≤3 ATK Diener
    ARKANA_CardData["EX1_084"].triggers = {{type="TRIGGER_ON_SUMMON", effect="GRANT_CHARGE_TO_SUMMONED", maxAtk=3}}
end
if ARKANA_CardData["EX1_044"] and not ARKANA_CardData["EX1_044"].triggers then  -- Rastloser Abenteurer
    ARKANA_CardData["EX1_044"].triggers = {{type="TRIGGER_ON_CARD_PLAYED", effect="GIVE_SELF_BUFF", attack=1, health=1}}
end
if ARKANA_CardData["EX1_509"] then  -- Murlocgezeitenrufer: +1 ATK bei jedem Murloc-Ruf (Freund + Feind)
    ARKANA_CardData["EX1_509"].triggers = {{type="TRIGGER_ON_SUMMON", effect="GIVE_SELF_ATTACK", value=1, onlyIfMurloc=true}}
end
-- TRIGGER_ON_FRIENDLY_DEATH
if ARKANA_CardData["EX1_595"] then  -- Kultmeisterin: Karte ziehen wenn freundl. Diener stirbt
    ARKANA_CardData["EX1_595"].triggers = {{type="TRIGGER_ON_FRIENDLY_DEATH", effect="DRAW_CARDS", value=1}}
end
if ARKANA_CardData["EX1_531"] then  -- Aasfressende Hyäne: +2/+1 wenn freundl. Wildtier stirbt
    ARKANA_CardData["EX1_531"].triggers = {{type="TRIGGER_ON_FRIENDLY_DEATH", effect="GIVE_SELF_BUFF", attack=2, health=1, onlyIfBeast=true}}
end
if ARKANA_CardData["tt_004"] then  -- Fleischfressender Ghul: +1 ATK wenn irgendjemand stirbt
    ARKANA_CardData["tt_004"].triggers = {{type="TRIGGER_ON_FRIENDLY_DEATH", effect="GIVE_SELF_ATTACK", value=1, anyDeath=true}}
end
-- TRIGGER_ON_DAMAGE (self)
if ARKANA_CardData["EX1_399"] then  -- Gurubashiberserker: +3 ATK wenn er Schaden nimmt
    ARKANA_CardData["EX1_399"].triggers = {{type="TRIGGER_ON_DAMAGE", effect="GIVE_SELF_ATTACK", value=3}}
end
if ARKANA_CardData["EX1_007"] then  -- Akolyth des Schmerzes: Karte ziehen wenn er Schaden nimmt
    ARKANA_CardData["EX1_007"].triggers = {{type="TRIGGER_ON_DAMAGE", effect="DRAW_CARDS", value=1}}
end
if ARKANA_CardData["EX1_604"] then  -- Wütender Berserker: +1 ATK wenn er Schaden nimmt
    ARKANA_CardData["EX1_604"].triggers = {{type="TRIGGER_ON_DAMAGE", effect="GIVE_SELF_ATTACK", value=1, anyMinion=true}}
end
if ARKANA_CardData["EX1_402"] then  -- Rüstungsschmiedin: +1 Rüstung wenn ein befreundeter Diener Schaden nimmt
    ARKANA_CardData["EX1_402"].triggers = {{type="TRIGGER_ON_DAMAGE", effect="GIVE_ARMOR", value=1, anyMinion=true, friendlyOnly=true}}
end
-- TRIGGER_END_TURN
if ARKANA_CardData["EX1_298"] then  -- Ragnaros: 8 Schaden auf zufälligen Feind
    ARKANA_CardData["EX1_298"].triggers = {{type="TRIGGER_END_TURN", effect="DEAL_DAMAGE_RANDOM_ENEMY", value=8}}
end
if ARKANA_CardData["EX1_249"] then  -- Baron Geddon: 2 Schaden auf alle anderen Charaktere
    ARKANA_CardData["EX1_249"].triggers = {{type="TRIGGER_END_TURN", effect="DEAL_DAMAGE_ALL_OTHERS", value=2}}
end
if ARKANA_CardData["NEW1_038"] then  -- Gruul: +1/+1 am Ende jedes Zuges
    ARKANA_CardData["NEW1_038"].triggers = {{type="TRIGGER_END_TURN", effect="GIVE_SELF_BUFF", attack=1, health=1}}
end
if ARKANA_CardData["CS2_059"] then  -- Blutwichtel: EINEM anderen freundl. Diener +1 HP am Zugende
    ARKANA_CardData["CS2_059"].triggers = {{type="TRIGGER_END_TURN", effect="GIVE_RANDOM_FRIENDLY_BUFF", attack=0, health=1}}
end
if ARKANA_CardData["EX1_597"] then  -- Wichtelmeisterin: 1 Schaden an sich + Imp beschwören
    ARKANA_CardData["EX1_597"].triggers = {
        {type="TRIGGER_END_TURN", effect="DEAL_SELF_DAMAGE", value=1},
        {type="TRIGGER_END_TURN", effect="SUMMON_TOKEN", tokenId="EX1_597t"},
    }
end
if ARKANA_CardData["EX1_575"] then  -- Manafluttotem: Karte ziehen am Zugend
    ARKANA_CardData["EX1_575"].triggers = {{type="TRIGGER_END_TURN", effect="DRAW_CARDS", value=1}}
end
if ARKANA_CardData["EX1_004"] then  -- Junge Priesterin: zufälligem freundl. Diener +1 Leben
    ARKANA_CardData["EX1_004"].triggers = {{type="TRIGGER_END_TURN", effect="GIVE_RANDOM_FRIENDLY_BUFF", attack=0, health=1}}
end
if ARKANA_CardData["NEW1_037"] then  -- Meisterschwertschmied: zufälligem freundl. Diener +1 ATK
    ARKANA_CardData["NEW1_037"].triggers = {{type="TRIGGER_END_TURN", effect="GIVE_RANDOM_FRIENDLY_BUFF", attack=1, health=0}}
end
-- TRIGGER_ON_SPELL
if ARKANA_CardData["EX1_559"] then  -- Erzmagier Antonidas: Feuerball auf Hand wenn Zauber gewirkt
    ARKANA_CardData["EX1_559"].triggers = {{type="TRIGGER_ON_SPELL", effect="ADD_TO_HAND", cardId="CS2_029"}}
end
if ARKANA_CardData["NEW1_026"] then  -- Violette Ausbilderin: Violetten Lehrling beschwören
    ARKANA_CardData["NEW1_026"].triggers = {{type="TRIGGER_ON_SPELL", effect="SUMMON_TOKEN", tokenId="NEW1_026t"}}
end
if ARKANA_CardData["EX1_055"] then  -- Manasüchtige: +2 Angriff NUR in diesem Zug (ClassicCardData vergisst das Ablaufen)
    ARKANA_CardData["EX1_055"].triggers = {{type="TRIGGER_ON_SPELL", effect="GIVE_SELF_ATTACK", value=2, thisTurn=true}}
end
if ARKANA_CardData["EX1_100"] and not ARKANA_CardData["EX1_100"].triggers then  -- Lehrensucher Cho: Zauberkopie für anderen Spieler
    ARKANA_CardData["EX1_100"].triggers = {{type="TRIGGER_ON_SPELL", effect="GIVE_SPELL_COPY_TO_OPPONENT", anyPlayer=true}}
end
if ARKANA_CardData["EX1_557"] and not ARKANA_CardData["EX1_557"].triggers then  -- Nat Pagle: 50% Karte ziehen zu Zugbeginn
    ARKANA_CardData["EX1_557"].triggers = {{type="TRIGGER_START_TURN", effect="DRAW_CARDS", value=1, chance50=true}}
end
-- TRIGGER_ON_HEAL
if ARKANA_CardData["CS2_235"] then  -- Klerikerin von Nordhain: Karte ziehen wenn irgendein DIENER geheilt wird
    ARKANA_CardData["CS2_235"].triggers = {{
        type="TRIGGER_ON_HEAL", effect="DRAW_CARDS", value=1,
        minionOnly=true, anyPlayer=true,
    }}
end
-- EX1_306: Blizzard hat die Karte später in "Teufelspirscher" umbenannt — hier bleibt
-- bewusst der alte Name "Sukkubus" (User-Entscheidung, das Bild zeigt ihn auch).
-- altNames: wer nach dem neueren Namen sucht, findet die Karte trotzdem.
if ARKANA_CardData["EX1_306"] then
    ARKANA_CardData["EX1_306"].altNames = { "Teufelspirscher" }
end

-- Flüchtig: kein Ziel für Zauber/Heldenfähigkeiten (Kartentext "Flüchtig", stand nur im Glossar)
for _, elusiveId in ipairs({"NEW1_023", "DREAM_01"}) do
    local ecd = ARKANA_CardData[elusiveId]
    if ecd and not HasTag(ecd.tags, "ELUSIVE") then
        ecd.tags = ecd.tags or {}
        ecd.tags[#ecd.tags+1] = {type="ELUSIVE"}
    end
end
if ARKANA_CardData["DS1_178"] then  -- Tundranashorn: Wildtiere haben Ansturm
    local has = false
    for _, t in ipairs(ARKANA_CardData["DS1_178"].tags or {}) do if t.type == "CHARGE_BEAST" then has = true end end
    if not has then
        ARKANA_CardData["DS1_178"].tags = ARKANA_CardData["DS1_178"].tags or {}
        ARKANA_CardData["DS1_178"].tags[#ARKANA_CardData["DS1_178"].tags+1] = {type="CHARGE_BEAST"}
    end
end
if ARKANA_CardData["EX1_572"] and not ARKANA_CardData["EX1_572"].triggers then  -- Ysera: Ende Zug Traumkarte
    ARKANA_CardData["EX1_572"].triggers = {{type="TRIGGER_END_TURN", effect="ADD_RANDOM_TO_HAND",
        cardIds={"EX1_572t","EX1_572t2","EX1_572t3","EX1_572t4","EX1_572t5"}}}
end

-- Grommash Höllschrei: ENRAGE +6 ATK
if ARKANA_CardData["EX1_414"] then
    ARKANA_CardData["EX1_414"].tags = ARKANA_CardData["EX1_414"].tags or {}
    local has = false
    for _, t in ipairs(ARKANA_CardData["EX1_414"].tags) do if t.type == "ENRAGE" then has = true end end
    if not has then ARKANA_CardData["EX1_414"].tags[#ARKANA_CardData["EX1_414"].tags+1] = {type="ENRAGE", attack=6} end
end
-- Malygos: SPELL_DAMAGE +5 (ClassicCardData-Bug: value=1, korrekt wäre 5)
if ARKANA_CardData["EX1_563"] then
    ARKANA_CardData["EX1_563"].tags = {{type="SPELL_DAMAGE", value=5}}
end
-- Trübauge der Alte: SELF_PER_MURLOC Aura (+1 ATK pro anderem Murloc)
if ARKANA_CardData["EX1_062"] then
    ARKANA_CardData["EX1_062"].tags = ARKANA_CardData["EX1_062"].tags or {}
    local has = false
    for _, t in ipairs(ARKANA_CardData["EX1_062"].tags) do if t.type == "AURA" then has = true end end
    if not has then ARKANA_CardData["EX1_062"].tags[#ARKANA_CardData["EX1_062"].tags+1] = {type="AURA", range="SELF_PER_MURLOC", attack=1} end
end
-- Lichtbrunnen: Start Zug → heilt zufälligen verletzten befreundeten Charakter um 3
if ARKANA_CardData["EX1_341"] then
    ARKANA_CardData["EX1_341"].triggers = {{type="TRIGGER_START_TURN", effect="HEAL_RANDOM_DAMAGED_FRIENDLY", value=3}}
end
-- Heiltotem: Ende Zug → heilt alle befreundeten Charaktere um 1
if ARKANA_CardData["NEW1_009"] then
    ARKANA_CardData["NEW1_009"].triggers = {{type="TRIGGER_END_TURN", effect="HEAL_ALL_FRIENDLY", value=1}}
end
-- Hogger: Ende Zug → Gnoll (2/2 Spott)
if ARKANA_CardData["NEW1_040"] and not ARKANA_CardData["NEW1_040"].triggers then
    ARKANA_CardData["NEW1_040"].triggers = {{type="TRIGGER_END_TURN", effect="SUMMON_TOKEN", tokenId="NEW1_040t"}}
end
if ARKANA_CardData["EX1_614"] and not ARKANA_CardData["EX1_614"].triggers then
    ARKANA_CardData["EX1_614"].triggers = {{type="TRIGGER_ON_CARD_PLAYED", effect="SUMMON_TOKEN", tokenId="EX1_614t"}}
end
if ARKANA_CardData["VAN_EX1_614"] and not ARKANA_CardData["VAN_EX1_614"].triggers then
    ARKANA_CardData["VAN_EX1_614"].triggers = {{type="TRIGGER_ON_CARD_PLAYED", effect="SUMMON_TOKEN", tokenId="VAN_EX1_614t"}}
end

-- Beschwörungsportal (EX1_315): eigene Diener kosten -2 (min 1)
if ARKANA_CardData["EX1_315"] then
    ARKANA_CardData["EX1_315"].tags = ARKANA_CardData["EX1_315"].tags or {}
    ARKANA_CardData["EX1_315"].tags[#ARKANA_CardData["EX1_315"].tags+1] = {type="AURA_OWN_MINION_COST_REDUCE", value=2}
end
-- Managespenst (EX1_616): ALLE Diener (beide Spieler) kosten +1
if ARKANA_CardData["EX1_616"] then
    ARKANA_CardData["EX1_616"].tags = ARKANA_CardData["EX1_616"].tags or {}
    ARKANA_CardData["EX1_616"].tags[#ARKANA_CardData["EX1_616"].tags+1] = {type="AURA_ALL_MINION_COST_INCREASE", value=1}
end
-- Söldner der Venture Co (CS2_227): eigene Diener kosten +3
if ARKANA_CardData["CS2_227"] then
    local has = false
    for _, t in ipairs(ARKANA_CardData["CS2_227"].tags or {}) do if t.type == "AURA_OWN_MINION_COST_INCREASE" then has = true end end
    if not has then
        ARKANA_CardData["CS2_227"].tags = ARKANA_CardData["CS2_227"].tags or {}
        ARKANA_CardData["CS2_227"].tags[#ARKANA_CardData["CS2_227"].tags+1] = {type="AURA_OWN_MINION_COST_INCREASE", value=3}
    end
end
-- Lichtbrut (EX1_335): Angriff = aktuelle Leben (ATK_EQUALS_HP)
if ARKANA_CardData["EX1_335"] then
    local has = false
    for _, t in ipairs(ARKANA_CardData["EX1_335"].tags or {}) do if t.type == "ATK_EQUALS_HP" then has = true end end
    if not has then
        ARKANA_CardData["EX1_335"].tags = ARKANA_CardData["EX1_335"].tags or {}
        ARKANA_CardData["EX1_335"].tags[#ARKANA_CardData["EX1_335"].tags+1] = {type="ATK_EQUALS_HP"}
    end
end
-- Untergangsverkünder (NEW1_021): Zu Beginn des Zuges alle Diener vernichten
if ARKANA_CardData["NEW1_021"] and not ARKANA_CardData["NEW1_021"].triggers then
    ARKANA_CardData["NEW1_021"].triggers = {{type="TRIGGER_START_TURN", effect="DESTROY_ALL_MINIONS"}}
end
-- Verwüster (EX1_102): Zu Beginn des Zuges 2 Schaden an zufälligen Feind
if ARKANA_CardData["EX1_102"] and not ARKANA_CardData["EX1_102"].triggers then
    ARKANA_CardData["EX1_102"].triggers = {{type="TRIGGER_START_TURN", effect="DEAL_DAMAGE_RANDOM_ENEMY", value=2}}
end
-- Waffen-Token: die Engine legt sie an (Arathiwaffenschmiedin, Aufwertung!, Tirion),
-- in den Kartendaten standen sie nicht → der Helden-Tooltip zeigte "Waffe: Waffe".
-- Bewusst HIER und nicht in ClassicCardData.lua: die Datei ist generiert (nächster
-- Generator-Lauf würde es überschreiben) und fließt in ARKANA_CATALOG_HASH ein — ein
-- geänderter Hash sperrt jedes Duell zwischen altem und neuem Client. Werte kommen
-- ohnehin aus der Engine; hier zählen nur Name und Bild (vom Ursprungsdiener geliehen).
if not ARKANA_CardData["EX1_398a"] then
    ARKANA_CardData["EX1_398a"] = {
        id="EX1_398a", name="Kampfaxt", cost=0, type="WEAPON", class="WARRIOR",
        collectible=false, attack=2, durability=2, rarity="COMMON",
        text="Von der Arathiwaffenschmiedin angelegt.",
        targetType="NONE", targetCondition="NONE",
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\EX1_398.tga",
    }
end
if not ARKANA_CardData["EX1_409a"] then
    ARKANA_CardData["EX1_409a"] = {
        id="EX1_409a", name="Schwere Axt", cost=0, type="WEAPON", class="WARRIOR",
        collectible=false, attack=1, durability=3, rarity="COMMON",
        text="Durch Aufwertung! angelegt.",
        targetType="NONE", targetCondition="NONE",
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\EX1_409.tga",
    }
end
if not ARKANA_CardData["EX1_383t"] then
    ARKANA_CardData["EX1_383t"] = {
        id="EX1_383t", name="Aschenbringer", cost=0, type="WEAPON", class="PALADIN",
        collectible=false, attack=5, durability=3, rarity="LEGENDARY",
        text="Tirion Fordrings Waffe.",
        targetType="NONE", targetCondition="NONE",
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\EX1_383.tga",
    }
end

-- Laufzeit-Tokens (nicht in ClassicCardData)
if not ARKANA_CardData["CS2_013t"] then   -- Überschüssiges Mana (Wildwuchs bei 10 Kristallen); Bild vom Wildwuchs geliehen
    local wg = ARKANA_CardData["CS2_013"] or {}
    ARKANA_CardData["CS2_013t"] = {
        id="CS2_013t", name="Überschüssiges Mana", cost=0, type="SPELL", class="DRUID",
        collectible=false, rarity="COMMON", text="Zieht eine Karte.",
        targetType="NONE", targetCondition="NONE",
        artTexture=wg.artTexture, frameTexture=wg.frameTexture,
    }
end
if not ARKANA_CardData["NEW1_040t"] then
    ARKANA_CardData["NEW1_040t"] = {
        id="NEW1_040t", name="Gnoll", cost=2, type="MINION", class="NEUTRAL",
        collectible=false, attack=2, health=2, rarity="COMMON",
        targetType="NONE", targetCondition="NONE",
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\NEW1_040t.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga",
        tags={{type="TAUNT"}},
    }
end
if not ARKANA_CardData["EX1_614t"] then
    ARKANA_CardData["EX1_614t"] = {
        id="EX1_614t", name="Flamme von Azzinoth", cost=1, type="MINION", class="NEUTRAL",
        collectible=false, attack=2, health=1, rarity="COMMON",
        targetType="NONE", targetCondition="NONE",
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\EX1_614t.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga",
        tags={},
    }
end
if not ARKANA_CardData["VAN_EX1_614t"] then
    ARKANA_CardData["VAN_EX1_614t"] = {
        id="VAN_EX1_614t", name="Flamme von Azzinoth", cost=1, type="MINION", class="NEUTRAL",
        collectible=false, attack=2, health=1, rarity="COMMON",
        targetType="NONE", targetCondition="NONE",
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\VAN_EX1_614t.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga",
        tags={},
    }
end
-- SI:7-Agent: BATTLECRY-Tag
if not HasTag(ARKANA_CardData["EX1_134"].tags or {}, "BATTLECRY") then
    ARKANA_CardData["EX1_134"].tags = ARKANA_CardData["EX1_134"].tags or {}
    ARKANA_CardData["EX1_134"].tags[#ARKANA_CardData["EX1_134"].tags+1] = {type="BATTLECRY"}
end
-- Rädelsführer der Defias: BATTLECRY-Tag + Token
if not ARKANA_CardData["EX1_131"].tags or not HasTag(ARKANA_CardData["EX1_131"].tags, "BATTLECRY") then
    ARKANA_CardData["EX1_131"].tags = ARKANA_CardData["EX1_131"].tags or {}
    ARKANA_CardData["EX1_131"].tags[#ARKANA_CardData["EX1_131"].tags+1] = {type="BATTLECRY"}
end
if not ARKANA_CardData["EX1_131t"] then
    ARKANA_CardData["EX1_131t"] = {id="EX1_131t", name="Banditen der Defias", cost=2, type="MINION", class="NEUTRAL",
        collectible=false, attack=2, health=1, race="PIRATE", tags={}, triggers={}, enchantments={},
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\EX1_131t.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga"}
end
-- Entführer: BATTLECRY-Tag
if not ARKANA_CardData["NEW1_005"].tags or not HasTag(ARKANA_CardData["NEW1_005"].tags, "BATTLECRY") then
    ARKANA_CardData["NEW1_005"].tags = ARKANA_CardData["NEW1_005"].tags or {}
    ARKANA_CardData["NEW1_005"].tags[#ARKANA_CardData["NEW1_005"].tags+1] = {type="BATTLECRY"}
end
-- Geduldiger Attentäter: POISONOUS-Tag
if not HasTag(ARKANA_CardData["EX1_522"].tags, "POISONOUS") then
    ARKANA_CardData["EX1_522"].tags = ARKANA_CardData["EX1_522"].tags or {}
    ARKANA_CardData["EX1_522"].tags[#ARKANA_CardData["EX1_522"].tags+1] = {type="POISONOUS"}
end
-- Kaiserkobra: POISONOUS-Tag (wie Geduldiger Attentäter)
if not HasTag(ARKANA_CardData["EX1_170"].tags, "POISONOUS") then
    ARKANA_CardData["EX1_170"].tags = ARKANA_CardData["EX1_170"].tags or {}
    ARKANA_CardData["EX1_170"].tags[#ARKANA_CardData["EX1_170"].tags+1] = {type="POISONOUS"}
end
-- Uralter Wächter: CANT_ATTACK-Tag
if not HasTag(ARKANA_CardData["EX1_045"].tags, "CANT_ATTACK") then
    ARKANA_CardData["EX1_045"].tags = ARKANA_CardData["EX1_045"].tags or {}
    ARKANA_CardData["EX1_045"].tags[#ARKANA_CardData["EX1_045"].tags+1] = {type="CANT_ATTACK"}
end

if not ARKANA_CardData["EX1_538t"] then
    ARKANA_CardData["EX1_538t"] = {
        id="EX1_538t", name="Jagdhund", cost=1, type="MINION", class="NEUTRAL",
        collectible=false, attack=1, health=1, race="BEAST", rarity="COMMON",
        targetType="NONE", targetCondition="NONE",
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\EX1_538t.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga",
        tags={{type="CHARGE"}},
    }
end
if not ARKANA_CardData["EX1_534t"] then
    ARKANA_CardData["EX1_534t"] = {
        id="EX1_534t", name="Hyäne", cost=2, type="MINION", class="NEUTRAL",
        collectible=false, attack=2, health=2, race="BEAST", rarity="COMMON",
        targetType="NONE", targetCondition="NONE",
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\EX1_534t.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga",
    }
end
if not ARKANA_CardData["EX1_116t"] then
    ARKANA_CardData["EX1_116t"] = {
        id="EX1_116t", name="Welplin", cost=1, type="MINION", class="NEUTRAL",
        collectible=false, attack=1, health=1, race="DRAGON", rarity="COMMON",
        targetType="NONE", targetCondition="NONE",
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\EX1_116t.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga",
    }
end
if not ARKANA_CardData["EX1_025t"] then
    ARKANA_CardData["EX1_025t"] = {
        id="EX1_025t", name="Mech-Drachling", cost=2, type="MINION", class="NEUTRAL",
        collectible=false, attack=2, health=1, race="MECHANICAL", rarity="COMMON",
        targetType="NONE", targetCondition="NONE",
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\EX1_025t.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga",
    }
end

if not ARKANA_CardData["CS2_196a"] then
    ARKANA_CardData["CS2_196a"] = {id="CS2_196a", name="Eber", cost=0, type="MINION", class="NEUTRAL",
        collectible=false, attack=1, health=1, race="BEAST", tags={}, triggers={},
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\CS2_196a.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga"}
end
if not ARKANA_CardData["EX1_597t"] then
    ARKANA_CardData["EX1_597t"] = {id="EX1_597t", name="Teufelchen", cost=0, type="MINION", class="NEUTRAL",
        collectible=false, attack=1, health=1, race="DEMON", tags={}, triggers={},
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\EX1_597t.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga"}
end
if not ARKANA_CardData["CS2_101"] then
    ARKANA_CardData["CS2_101"] = {id="CS2_101", name="Knappe der Silbernen Hand", cost=0, type="MINION", class="PALADIN",
        collectible=false, attack=1, health=1, tags={}, triggers={},
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\CS2_101.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga"}
end
if not ARKANA_CardData["NEW1_026t"] then
    ARKANA_CardData["NEW1_026t"] = {id="NEW1_026t", name="Violetter Lehrling", cost=0, type="MINION", class="NEUTRAL",
        collectible=false, attack=1, health=1, tags={}, triggers={},
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\NEW1_026t.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga"}
end
if not ARKANA_CardData["CS2_mirror"] then
    ARKANA_CardData["CS2_mirror"] = {id="CS2_mirror", name="Spiegelbild", cost=0, type="MINION", class="MAGE",
        collectible=false, attack=0, health=2, tags={{type="TAUNT"}}, triggers={},
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\CS2_mirror.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga"}
end
if not ARKANA_CardData["EX1_248t"] then
    ARKANA_CardData["EX1_248t"] = {id="EX1_248t", name="Geisterwolf", cost=0, type="MINION", class="NEUTRAL",
        collectible=false, attack=2, health=3, tags={{type="TAUNT"}}, triggers={},
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\EX1_248t.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga"}
end
if not ARKANA_CardData["EX1_014t"] then
    ARKANA_CardData["EX1_014t"] = {id="EX1_014t", name="Banane", cost=1, type="SPELL", class="NEUTRAL",
        collectible=false, text="Verleiht einem Diener +1/+1.", tags={{type="GIVE_BUFF", attack=1, health=1}},
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\EX1_014t.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-spell-neutral.tga"}
end
if not ARKANA_CardData["CS2_022t"] then
    ARKANA_CardData["CS2_022t"] = {id="CS2_022t", name="Schaf", cost=0, type="MINION", class="NEUTRAL",
        collectible=false, attack=1, health=1, tags={}, triggers={}, enchantments={},
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\CS2_022t.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga"}
end
if not ARKANA_CardData["EX1_571t"] then
    ARKANA_CardData["EX1_571t"] = {id="EX1_571t", name="Baumläufer", cost=0, type="MINION", class="DRUID",
        collectible=false, attack=2, health=2, tags={{type="CHARGE"}}, triggers={}, enchantments={},
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\EX1_571t.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga"}
end
if not ARKANA_CardData["EX1_083t"] then
    ARKANA_CardData["EX1_083t"] = {id="EX1_083t", name="Teufelssaurier", cost=5, type="MINION", class="NEUTRAL",
        collectible=false, attack=5, health=5, race="BEAST", tags={}, triggers={}, enchantments={},
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\EX1_083t.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga"}
end
if not ARKANA_CardData["EX1_083t2"] then
    ARKANA_CardData["EX1_083t2"] = {id="EX1_083t2", name="Eichhörnchen", cost=1, type="MINION", class="NEUTRAL",
        collectible=false, attack=1, health=1, tags={}, triggers={}, enchantments={},
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\EX1_083t2.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga"}
end
if not ARKANA_CardData["EX1_572t"] then
    ARKANA_CardData["EX1_572t"] = {id="EX1_572t", name="Traumform", cost=0, type="SPELL", class="NEUTRAL",
        collectible=false, text="Kehrt einen Diener auf die Hand seines Besitzers zurück.", targetType="ANY_MINION",
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\EX1_572t.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-spell-neutral.tga"}
end
if not ARKANA_CardData["EX1_572t2"] then
    ARKANA_CardData["EX1_572t2"] = {id="EX1_572t2", name="Alptraum", cost=0, type="SPELL", class="NEUTRAL",
        collectible=false, text="Gibt einem Diener +5/+5. Am Ende des Zuges stirbt er.", targetType="ANY_MINION",
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\EX1_572t2.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-spell-neutral.tga"}
end
if not ARKANA_CardData["EX1_572t3"] then
    ARKANA_CardData["EX1_572t3"] = {id="EX1_572t3", name="Lachende Schwester", cost=0, type="MINION", class="NEUTRAL",
        collectible=false, attack=3, health=5, race="DRAGON", tags={}, triggers={}, enchantments={},
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\EX1_572t3.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga"}
end
if not ARKANA_CardData["EX1_572t4"] then
    ARKANA_CardData["EX1_572t4"] = {id="EX1_572t4", name="Ysera Erwacht", cost=2, type="SPELL", class="NEUTRAL",
        collectible=false, text="Fügt allen Charakteren 5 Schaden zu.", targetType="NONE",
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\EX1_572t4.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-spell-neutral.tga"}
end
if not ARKANA_CardData["EX1_572t5"] then
    ARKANA_CardData["EX1_572t5"] = {id="EX1_572t5", name="Smaragddrache", cost=0, type="MINION", class="NEUTRAL",
        collectible=false, attack=7, health=6, race="DRAGON", tags={}, triggers={}, enchantments={},
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\EX1_572t5.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga"}
end
if not ARKANA_CardData["NEW1_031a"] then
    ARKANA_CardData["NEW1_031a"] = {id="NEW1_031a", name="Huffer", cost=0, type="MINION", class="NEUTRAL",
        collectible=false, attack=4, health=2, race="BEAST",
        tags={{type="CHARGE"}}, triggers={}, enchantments={},
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\NEW1_031a.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga"}
end
if not ARKANA_CardData["NEW1_031b"] then
    ARKANA_CardData["NEW1_031b"] = {id="NEW1_031b", name="Misha", cost=0, type="MINION", class="NEUTRAL",
        collectible=false, attack=4, health=4, race="BEAST",
        tags={{type="TAUNT"}}, triggers={}, enchantments={},
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\NEW1_031b.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga"}
end
if not ARKANA_CardData["NEW1_031c"] then
    ARKANA_CardData["NEW1_031c"] = {id="NEW1_031c", name="Leokk", cost=0, type="MINION", class="NEUTRAL",
        collectible=false, attack=2, health=4, race="BEAST",
        tags={{type="AURA", range="ALL_FRIENDLY", attack=1}}, triggers={}, enchantments={},
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\NEW1_031c.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga"}
end
-- Gelbin Mekkadrill Erfindungen (landen auf Gegner-Brett, triggern zu Zugbeginn des Besitzers)
if not ARKANA_CardData["EX1_112t1"] then
    ARKANA_CardData["EX1_112t1"] = {id="EX1_112t1", name="Das Zielsuchende Huhn", cost=0, type="MINION",
        class="NEUTRAL", collectible=false, attack=0, health=1, rarity="COMMON",
        text="Zu Beginn Eures Zuges: Zieht 3 Karten. Dann wird dieses Gerät zerstört.",
        targetType="NONE", targetCondition="NONE", tags={}, enchantments={},
        triggers={{type="TRIGGER_START_TURN", effect="DRAW_CARDS", value=3},
                  {type="TRIGGER_START_TURN", effect="DESTROY_SELF"}},
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\EX1_112t1.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga"}
end
if not ARKANA_CardData["EX1_112t2"] then
    ARKANA_CardData["EX1_112t2"] = {id="EX1_112t2", name="Kraftverstärker 3000", cost=0, type="MINION",
        class="NEUTRAL", collectible=false, attack=0, health=1, rarity="COMMON",
        text="Zu Beginn Eures Zuges: Verleiht einem zufälligen Diener +1/+1.",
        targetType="NONE", targetCondition="NONE", tags={}, enchantments={},
        triggers={{type="TRIGGER_START_TURN", effect="GIVE_RANDOM_FRIENDLY_BUFF", attack=1, health=1}},
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\EX1_112t2.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga"}
end
if not ARKANA_CardData["EX1_112t3"] then
    ARKANA_CardData["EX1_112t3"] = {id="EX1_112t3", name="Reparaturbot", cost=0, type="MINION",
        class="NEUTRAL", collectible=false, attack=0, health=2, rarity="COMMON",
        text="Zu Beginn Eures Zuges: Stellt einem zufälligen beschädigten Charakter 6 Leben wieder her.",
        targetType="NONE", targetCondition="NONE", tags={}, enchantments={},
        triggers={{type="TRIGGER_START_TURN", effect="HEAL_RANDOM_CHAR", value=6}},
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\EX1_112t3.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga"}
end
if not ARKANA_CardData["EX1_112t4"] then
    ARKANA_CardData["EX1_112t4"] = {id="EX1_112t4", name="Geflügelisierer", cost=0, type="MINION",
        class="NEUTRAL", collectible=false, attack=0, health=1, rarity="COMMON",
        text="Zu Beginn Eures Zuges: Verwandelt einen zufälligen Diener in ein 1/1 Huhn.",
        targetType="NONE", targetCondition="NONE", tags={}, enchantments={},
        triggers={{type="TRIGGER_START_TURN", effect="TRANSFORM_RANDOM_MINION", tokenId="TRANSFORM_CHICKEN"}},
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\EX1_112t4.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga"}
end
-- PRO_001 Powerakkord-Tokens
if not ARKANA_CardData["PRO_001a"] then
    ARKANA_CardData["PRO_001a"] = {id="PRO_001a", name="Ich bin ein Murloc", cost=2, type="SPELL",
        class="NEUTRAL", collectible=false, rarity="COMMON",
        text="Ruft für jede Karte in Eurer Hand einen 1/1-Murloc herbei.",
        targetType="NONE", targetCondition="NONE",
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\PRO_001a.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-spell-neutral.tga"}
end
if not ARKANA_CardData["PRO_001b"] then
    ARKANA_CardData["PRO_001b"] = {id="PRO_001b", name="Schurken machen es...", cost=2, type="SPELL",
        class="NEUTRAL", collectible=false, rarity="COMMON",
        text="Fügt einem zufälligen Feind 4 Schaden zu. Zieht eine Karte.",
        targetType="NONE", targetCondition="NONE",
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\PRO_001b.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-spell-neutral.tga"}
end
if not ARKANA_CardData["PRO_001a_t"] then
    ARKANA_CardData["PRO_001a_t"] = {id="PRO_001a_t", name="Murloc", cost=0, type="MINION",
        class="NEUTRAL", collectible=false, attack=1, health=1, race="MURLOC", rarity="COMMON",
        targetType="NONE", targetCondition="NONE", tags={}, triggers={}, enchantments={},
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\PRO_001a_t.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga"}
end
-- Lord Jaraxxus Tokens
if not ARKANA_CardData["EX1_323t2"] then
    ARKANA_CardData["EX1_323t2"] = {id="EX1_323t2", name="Infernaler", cost=0, type="MINION",
        class="NEUTRAL", collectible=false, attack=6, health=6, race="DEMON", rarity="COMMON",
        targetType="NONE", targetCondition="NONE", tags={}, triggers={}, enchantments={},
        artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\EX1_323t2.tga",
        frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga"}
end
-- Deathrattle-Einträge werden in GE_StartGame gesetzt (sicherer als top-level)

local function ExecBattlecry(pIdx, cardId, targetId, mPos, comboCount, choiceId)
    if addon.GE_OnBattlecry then
        addon:GE_OnBattlecry(pIdx, cardId, targetId, mPos)
    end
    local fn = BATTLECRY[cardId]
    if fn then
        fn(pIdx, targetId, mPos, comboCount or 0, choiceId)
    end
end

-- ── SECRETS ──────────────────────────────────────────────────────────────────

local SECRET_EFFECTS = {
    -- HERO_ATTACKED: secret owner's hero is being attacked (fires before damage)
    ["EX1_289"] = { event="HERO_ATTACKED", fn=function(ownerIdx, data)
        P(ownerIdx).hero.armor = P(ownerIdx).hero.armor + 8
        addon:GE_Log(ownerIdx, "[Eisbarriere] +8 Rüstung!")
    end},
    ["EX1_610"] = { event="HERO_ATTACKED", fn=function(ownerIdx, data)
        local op = OtherIdx(ownerIdx)
        local snap = {}
        for _, bm in ipairs(P(op).board) do snap[#snap+1] = bm.entityId end
        for _, eid in ipairs(snap) do DealDmgToEntity(ownerIdx, eid, 2) end
        DealDmgToEntity(ownerIdx, op, 2)
        RunDeathPipeline()
        addon:GE_Log(ownerIdx, "[Sprengfalle] 2 Schaden an alle Feinde!")
    end},
    ["EX1_130"] = { event="ENEMY_ATTACKS", fn=function(ownerIdx, data)
        if #P(ownerIdx).board < 7 then
            local def = SummonMinionAt(ownerIdx, "EX1_130a", #P(ownerIdx).board + 1)
            if def then data.redirectTarget = def.entityId end
        end
        data.cancel = true
        addon:GE_Log(ownerIdx, "[Heldenopfer] Verteidiger (2/1) beschworen, Angriff umgeleitet!")
    end},
    ["EX1_132"] = { event="HERO_ATTACKED", fn=function(ownerIdx, data)
        -- Auge um Auge: tatsächlicher Schaden (nach Rüstung) an feindlichen Helden
        local dmg = math.max(0, (data.atkVal or 0) - (P(ownerIdx).hero.armor or 0))
        if dmg > 0 then
            DealDmgToEntity(ownerIdx, OtherIdx(ownerIdx), dmg)
            addon:GE_Log(ownerIdx, "[Auge um Auge] " .. dmg .. " Schaden zurück!")
        end
    end},

    -- HERO_WOULD_DIE: hero HP ≤ 0 after damage
    ["EX1_295"] = { event="HERO_WOULD_DIE", fn=function(ownerIdx, data)
        data.saved = true
        addon:GE_Log(ownerIdx, "[Eisblock] Held gerettet! Immun diesen Zug.")
    end},

    -- MINION_ATTACKS_HERO: a minion attacks the secret owner's hero (can cancel)
    ["EX1_594"] = { event="MINION_ATTACKS_HERO", fn=function(ownerIdx, data)
        local m = FindOnBoard(data.attackerEId)
        if m then m.damageTaken = m.damageTaken + 9999 end
        data.cancel = true
        RunDeathPipeline()
        addon:GE_Log(ownerIdx, "[Zerstäuben] Angreifer vernichtet!")
    end},
    ["EX1_611"] = { event="ENEMY_MINION_ATTACKS", fn=function(ownerIdx, data)
        local op = OtherIdx(ownerIdx)
        local m = FindOnBoard(data.attackerEId)
        if m then
            local baseCost = (ARKANA_CardData[m.id] and ARKANA_CardData[m.id].cost or 0)
            for i, bm in ipairs(P(op).board) do
                if bm.entityId == data.attackerEId then table.remove(P(op).board, i); break end
            end
            P(op).hand[#P(op).hand+1] = {entityId=gs.entityCounter, id=m.id, cost=math.min(10, baseCost+2)}
            gs.entityCounter = gs.entityCounter + 1
            RecalcAuras()
        end
        data.cancel = true
        addon:GE_Log(ownerIdx, "[Eiskältefalle] Angreifer zurückgegeben (+2 Kosten)!")
    end},
    ["EX1_533"] = { event="MINION_ATTACKS_HERO", fn=function(ownerIdx, data)
        local op = OtherIdx(ownerIdx)
        local targets = {}
        -- Alle eigenen Diener des Secret-Besitzers
        for _, bm in ipairs(P(ownerIdx).board) do targets[#targets+1] = bm.entityId end
        -- Alle Diener des Angreifers (außer dem Angreifer selbst)
        for _, bm in ipairs(P(op).board) do
            if bm.entityId ~= data.attackerEId then targets[#targets+1] = bm.entityId end
        end
        -- Held des Angreifers (NICHT der Secret-Besitzer-Held = das wäre kein redirect)
        targets[#targets+1] = op
        if #targets > 0 then
            gs.prngState = PrngNext(gs.prngState)
            local newTarget = targets[(gs.prngState % #targets) + 1]
            data.redirectTarget = newTarget
        end
        data.cancel = true
        addon:GE_Log(ownerIdx, "[Irreführung] Angriff umgeleitet!")
    end},

    -- SPELL_CAST: opponent casts a spell (data.countered = true cancels it)
    ["EX1_287"] = { event="SPELL_CAST", fn=function(ownerIdx, data)
        data.countered = true
        if addon.GE_OnSpellCountered then
            addon:GE_OnSpellCountered()
        end
        addon:GE_Log(ownerIdx, "[Gegenzauber] Zauber wurde konteriert!")
    end},

    -- SPELL_TARGETS_MINION: opponent casts a spell targeting a minion (nur dann geprüft)
    ["tt_010"] = { event="SPELL_TARGETS_MINION", fn=function(ownerIdx, data)
        if #P(ownerIdx).board < 7 then
            local def = SummonMinionAt(ownerIdx, "tt_010a", #P(ownerIdx).board + 1)
            if def then data.redirectTarget = def.entityId end
        end
        addon:GE_Log(ownerIdx, "[Zauberformerin] Diener (1/3) wird neues Ziel!")
    end},

    -- MINION_PLAYED: opponent plays a minion
    ["EX1_294"] = { event="MINION_PLAYED", fn=function(ownerIdx, data)
        if data.m and #P(ownerIdx).board < 7 then
            SummonMinionAt(ownerIdx, data.m.id, #P(ownerIdx).board + 1)
        end
        addon:GE_Log(ownerIdx, "[Spiegelgestalt] Kopie beschworen!")
    end},
    ["EX1_609"] = { event="MINION_PLAYED", fn=function(ownerIdx, data)
        if data.m then
            DealDmgToEntity(ownerIdx, data.m.entityId, 4)
            RunDeathPipeline()
        end
        addon:GE_Log(ownerIdx, "[Scharfschießen] 4 Schaden!")
    end},
    ["EX1_379"] = { event="MINION_PLAYED", fn=function(ownerIdx, data)
        if data.m then
            local maxHp = data.m.baseHealth
            for _, e in ipairs(data.m.enchantments) do maxHp = maxHp + (e.health or 0) end
            data.m.damageTaken = math.max(0, maxHp - 1)
            RecalcAuras()
        end
        addon:GE_Log(ownerIdx, "[Buße] Leben auf 1 gesetzt!")
    end},

    -- FRIENDLY_MINION_ATTACKED: a friendly minion is being attacked
    ["EX1_554"] = { event="FRIENDLY_MINION_ATTACKED", fn=function(ownerIdx, data)
        data.summonedEntityIds = {}
        for _ = 1, 3 do
            if #P(ownerIdx).board < 7 then
                local m = SummonMinionAt(ownerIdx, "EX1_554t", #P(ownerIdx).board + 1)
                if m then data.summonedEntityIds[#data.summonedEntityIds+1] = m.entityId end
            end
        end
        addon:GE_Log(ownerIdx, "[Schlangenfalle] 3 Schlangen beschworen!")
    end},

    -- FRIENDLY_MINION_DIES: a friendly minion died
    ["EX1_136"] = { event="FRIENDLY_MINION_DIES", fn=function(ownerIdx, data)
        if data.m and #P(ownerIdx).board < 7 then
            local revived = NewMinion(data.m.id, ownerIdx)
            revived.entityId = gs.entityCounter; gs.entityCounter = gs.entityCounter + 1
            local maxHp = revived.baseHealth
            revived.damageTaken = math.max(0, maxHp - 1)
            P(ownerIdx).board[#P(ownerIdx).board+1] = revived
            RecalcAuras()
            data.revivedEntityId = revived.entityId
        end
        addon:GE_Log(ownerIdx, "[Erlösung] Diener mit 1 Leben wiederbelebt!")
    end},
}

CheckSecrets = function(ownerIdx, eventType, data)
    local secrets = P(ownerIdx).secrets
    if not secrets or #secrets == 0 then return false end
    for i, secretId in ipairs(secrets) do
        local s = SECRET_EFFECTS[secretId]
        if s and s.event == eventType then
            table.remove(secrets, i)
            if addon.GE_OnSecretTrigger then
                addon:GE_OnSecretTrigger(ownerIdx, secretId, data)
            end
            s.fn(ownerIdx, data)
            if addon.GE_OnSecretEffect then
                addon:GE_OnSecretEffect(ownerIdx, secretId, data)
            end
            for pi = 1, 2 do
                local w = P(pi).weapon
                if w and w.id == "EX1_536" then
                    w.durability = w.durability + 1
                    addon:GE_Log(pi, "[Adlerhornbogen] +1 Haltbarkeit!")
                end
            end
            return true
        end
    end
    return false
end

-- ── PLAY ─────────────────────────────────────────────────────────────────────

local function CardHasTag(card, tagType)
    if not card.tags then return false end
    for _, t in ipairs(card.tags) do if t.type == tagType then return true end end
    return false
end

local function EffCost(pIdx, cardId, slotCostExtra)
    local card = ARKANA_CardData[cardId]
    if not card then return 99 end
    local c = (card.cost or 0) + (slotCostExtra or 0)
    if card.type == "SPELL" then
        c = math.max(0, c - (P(pIdx).spellCostReduction or 0) - (P(pIdx).auraSpellCostReduction or 0))
    end
    if card.type == "MINION" then
        c = c + (P(pIdx).minionCostIncrease or 0)
        local red = P(pIdx).minionCostReduction or 0
        if red > 0 then c = math.max(1, c - red) end
        if not P(pIdx).firstMinionCostUsedThisTurn then
            c = math.max(0, c - FirstMinionDiscount(pIdx))
        end
        -- Dynamische Riesen-Kosten
        if cardId == "EX1_620" then
            c = math.max(0, c - math.max(0, 30 - P(pIdx).hero.health))
        elseif cardId == "EX1_586" then
            local cnt = 0; for pi = 1, 2 do cnt = cnt + #P(pi).board end
            c = math.max(0, c - cnt)
        elseif cardId == "EX1_105" then
            c = math.max(0, c - math.max(0, #P(pIdx).hand - 1))
        elseif cardId == "NEW1_022" then  -- Schreckenskorsar: (1) weniger je Angriffspunkt der Waffe
            c = math.max(0, c - WeaponEffAtk(pIdx))
        end
    end
    if P(pIdx).allCostZeroThisTurn and card.type == "SPELL" then c = 0 end
    if P(pIdx).nextSecretFree and CardHasTag(card, "SECRET") then c = 0 end
    return math.max(0, c)
end

-- Differenz zwischen den Kosten IM HANDSLOT und dem Basispreis der Karte.
-- Darf NEGATIV sein (Schattenschritt: -2) — früher auf 0 geklemmt, dadurch
-- verpuffte jede Rabatt-Karte. Positiv z.B. bei Eiskältefalle (+2).
local function SlotExtra(slot)
    if not slot then return 0 end
    local card = ARKANA_CardData[slot.id]
    return (slot.cost or 0) - (card and card.cost or 0)
end

-- "kein Ziel" heißt IMMER 0. Die UI übergibt nil (Net_PlayCard), die Leitung macht
-- daraus `targetEntityId or 0` — beide Seiten müssen denselben Wert prüfen UND
-- ausführen, sonst fällt die eigene Aktion beim Gegner durch (S48).
local function ValidatePlay(pIdx, handIdx, targetEntityId)
    targetEntityId = targetEntityId or 0
    if gs.phase ~= "play" then return false, "Nicht in Spielphase" end
    if gs.activePlayer ~= pIdx then return false, "Nicht dein Zug" end
    local slot = P(pIdx).hand[handIdx + 1]
    if not slot then return false, "Ungültige Hand-Position" end
    local card = ARKANA_CardData[slot.id]
    if not card then return false, "Unbekannte Karte" end
    if AvailMana(pIdx) < EffCost(pIdx, slot.id, SlotExtra(slot)) then return false, "Nicht genug Mana" end
    if card.type == "MINION" and #P(pIdx).board >= 7 then return false, "Brett voll" end
    if slot.id == "CS2_074" and not P(pIdx).weapon then return false, "Keine Waffe ausgerüstet" end
    if card.type == "SPELL" and CardHasTag(card, "SECRET") then
        for _, sid in ipairs(P(pIdx).secrets) do
            if sid == slot.id then return false, "Dieses Geheimnis ist bereits aktiv" end
        end
    end
    -- KEINE "Ziel erforderlich"-Prüfung: targetType heißt "darf zielen", nicht "muss".
    -- Gezielte Kampfschreie ohne gültiges Ziel (Board_ClickSlot ohne chosenTarget),
    -- Choose-One-Hälften ohne Ziel und die CARD_TARGET_OVERRIDE-Liste der UI kommen
    -- alle legitim mit Ziel 0 an. Zielprüfung macht weiter die UI (bewusste Lücke).
    -- Verstohlenheit schützt auch gegen gezielte Zauber/Kampfschreie des Gegners
    -- (bisher nur beim Angriff geprüft → Verhexung traf getarnte Diener).
    if targetEntityId and targetEntityId ~= 0 then
        local tm = FindOnBoard(targetEntityId)
        if tm and tm.controller ~= pIdx and tm.stealthed then
            return false, "Ziel in Stealth"
        end
    end
    -- Flüchtig (Feendrache): kein Ziel für ZAUBER. Kampfschreie dürfen weiterhin
    -- anvisieren — genau wie im Original.
    if card.type == "SPELL" and targetEntityId and targetEntityId ~= 0 then
        local tm = FindOnBoard(targetEntityId)
        if tm and HasTag(tm.tags, "ELUSIVE") then return false, "Ziel ist flüchtig" end
    end
    if slot.id == "NEW1_003" and targetEntityId ~= 0 then
        local tm = FindOnBoard(targetEntityId)
        if not tm or tm.controller ~= pIdx then return false, "Nur eigene Diener" end
        local tcd = ARKANA_CardData[tm.id]
        if not tcd or tcd.race ~= "DEMON" then return false, "Nur Dämonen" end
    end
    return true
end

local function ExecPlay(pIdx, handIdx, targetEntityId, boardPos, choiceId)
    targetEntityId = targetEntityId or 0   -- wie ValidatePlay: nil und 0 sind dasselbe
    local slot = P(pIdx).hand[handIdx + 1]
    if addon.GE_OnCardPlay then
        addon:GE_OnCardPlay(pIdx, slot.id, handIdx, boardPos, targetEntityId, choiceId)
    end
    local card = ARKANA_CardData[slot.id]
    local cost = EffCost(pIdx, slot.id, SlotExtra(slot))
    table.remove(P(pIdx).hand, handIdx + 1)
    SpendMana(pIdx, cost)
    local comboCount  = P(pIdx).cardsPlayedThisTurn
    local comboActive = P(pIdx).cardPlayedThisTurn
    P(pIdx).cardsPlayedThisTurn = P(pIdx).cardsPlayedThisTurn + 1
    P(pIdx).cardPlayedThisTurn = true
    -- Overload
    local ol = GetTag(card.tags, "OVERLOAD")
    if ol then P(pIdx).mana.locked = P(pIdx).mana.locked + (ol.value or 0) end

    if card.type == "MINION" then
        P(pIdx).firstMinionCostUsedThisTurn = true
        local eid = gs.entityCounter; gs.entityCounter = gs.entityCounter + 1
        local m = NewMinion(slot.id, pIdx)
        m.entityId = eid
        local board = P(pIdx).board
        local pos = (boardPos >= 0 and boardPos <= #board) and (boardPos + 1) or (#board + 1)
        table.insert(board, pos, m)
        RecalcAuras()
        FireTriggers("TRIGGER_ON_SUMMON", { m = m, pIdx = pIdx })
        CheckSwordOfJustice(pIdx, m)
        FireTriggers("TRIGGER_ON_CARD_PLAYED", { pIdx = pIdx, playedEntityId = m.entityId, cardId = slot.id })
        CheckSecrets(OtherIdx(pIdx), "MINION_PLAYED", { m = m })
        ExecBattlecry(pIdx, slot.id, targetEntityId, pos, comboCount, choiceId)
        addon:GE_Log(pIdx, "Spielt " .. (card.name or slot.id))
    elseif card.type == "SPELL" then
        P(pIdx).spellCostReduction = 0
        -- Wer beim WIRKEN schon dem Zauberer gehörte, darf auf den Zauber reagieren.
        -- Sonst beschwört eine per Gedankenkontrolle geklaute Violette Ausbilderin
        -- sofort einen Lehrling für den neuen Besitzer (Tester-Report).
        local castBoard = {}
        for _, bm in ipairs(P(pIdx).board) do castBoard[bm.entityId] = true end
        if P(pIdx).nextSecretFree and CardHasTag(card, "SECRET") then
            P(pIdx).nextSecretFree = false
        end
        -- Gegenzauber prüfen (auch Geheimnisse können konteriert werden)
        local spellData = { countered = false }
        CheckSecrets(OtherIdx(pIdx), "SPELL_CAST", spellData)
        -- Zauberformerin: nur wenn Zauber einen Diener als Ziel hat
        if not spellData.countered and targetEntityId and targetEntityId ~= 0 and targetEntityId ~= 1 and targetEntityId ~= 2 then
            local benderData = { redirectTarget = nil }
            CheckSecrets(OtherIdx(pIdx), "SPELL_TARGETS_MINION", benderData)
            if benderData.redirectTarget then targetEntityId = benderData.redirectTarget end
        end
        if not spellData.countered then
            -- "Immer wenn Ihr einen Zauber wirkt" gehört in die Wirkphase VOR
            -- den Zaubertext. Dadurch zieht der Goblinauktionator auch dann noch,
            -- wenn Schattenschritt oder Verschwinden ihn anschließend zurücknehmen.
            -- castBoard verhindert weiterhin, dass ein erst durch diesen Zauber
            -- übernommener Diener rückwirkend auf denselben Zauber reagiert.
            FireTriggers("TRIGGER_ON_SPELL", { pIdx = pIdx, spellId = slot.id, castBoard = castBoard })
            if CardHasTag(card, "SECRET") then
                P(pIdx).secrets[#P(pIdx).secrets+1] = slot.id
                -- Namen NUR dem tatsächlichen Besitzer zeigen. Zuschauer (IsSpectating)
                -- dürfen KEINE Geheimnis-Namen sehen — für beide Spieler verdeckt.
                local isSpec = addon.IsSpectating and addon:IsSpectating()
                if pIdx == gs.myPlayerIdx and not isSpec then
                    addon:GE_Log(pIdx, "Geheimnis aktiv: " .. (card.name or slot.id))
                else
                    addon:GE_Log(pIdx, "Ein Geheimnis gelegt")
                end
            else
                if SPELL_OVERRIDES[slot.id] then
                    SPELL_OVERRIDES[slot.id](pIdx, targetEntityId, comboActive, choiceId)
                else
                    ExecSpellTags(pIdx, card.tags, targetEntityId)
                end
            end
            -- Echte "Nachdem Ihr einen Zauber gewirkt habt"-Effekte bleiben
            -- hinter dem Zaubertext (aktuell: Wilder Pyromant).
            FireTriggers("TRIGGER_AFTER_SPELL", { pIdx = pIdx, spellId = slot.id, castBoard = castBoard })
            FireTriggers("TRIGGER_ON_CARD_PLAYED", { pIdx = pIdx, cardId = slot.id, castBoard = castBoard })
        end
        if not CardHasTag(card, "SECRET") then
            addon:GE_Log(pIdx, "Zaubert " .. (card.name or slot.id))
        end
    elseif card.type == "WEAPON" then
        -- ClassicCardData legt Haltbarkeit im Feld 'health' ab (Python-Mapping), nicht 'durability'
        P(pIdx).weapon = {
            entityId   = gs.entityCounter,
            id         = slot.id,
            attack     = card.attack or 0,
            durability = card.health or 1,
            tags       = card.tags or {},
        }
        gs.entityCounter = gs.entityCounter + 1
        ExecBattlecry(pIdx, slot.id, targetEntityId, 0, comboCount)
        FireTriggers("TRIGGER_ON_CARD_PLAYED", { pIdx = pIdx, cardId = slot.id })
        addon:GE_Log(pIdx, "Rüstet aus " .. (card.name or slot.id))
    end
    RunDeathPipeline()
    RecalcAuras()
end

-- ── ATTACK ────────────────────────────────────────────────────────────────────

-- Verstohlenheit hebt Spott auf, solange der Diener getarnt ist. Sonst sperrt ein
-- Diener mit BEIDEM das ganze Brett: anvisieren geht nicht (Stealth-Prüfung unten),
-- etwas anderes angreifen auch nicht (Spott-Zwang) — der Gegner konnte gar nichts
-- mehr tun (Tester-Report). Enttarnt (Angriff/Zauber des Besitzers) zählt er wieder.
local function TauntActive(m) return HasTag(m.tags, "TAUNT") and not m.stealthed end

local function HasTauntOnBoard(pIdx)
    for _, m in ipairs(P(pIdx).board) do
        if TauntActive(m) then return true end
    end
end

local function ValidateAttack(pIdx, attackerEId, defenderEId)
    if gs.phase ~= "play" then return false, "Nicht in Spielphase" end
    if gs.activePlayer ~= pIdx then return false, "Nicht dein Zug" end
    local enemyIdx = OtherIdx(pIdx)
    -- Attacker
    if attackerEId == pIdx then
        local hero = P(pIdx).hero
        local wep = P(pIdx).weapon
        local atk = (hero.attack or 0) + WeaponEffAtk(pIdx)
        if atk <= 0 then return false, "Held hat keinen Angriff" end
        if hero.frozen then return false, "Held eingefroren" end
        local maxAtks = (wep and HasTag(wep.tags or {}, "WINDFURY")) and 2 or 1
        if (hero.attacksThisTurn or 0) >= maxAtks then return false, "Held hat bereits angegriffen" end
    else
        local m = FindOnBoard(attackerEId)
        if not m then
            return false, "Ungültiger Angreifer"
        end
        if m.controller ~= pIdx then
            return false, "Ungültiger Angreifer"
        end
        -- Harte Invariante zusätzlich zum abgeleiteten canAttackThisTurn-Flag:
        -- selbst wenn dieses durch eine Aura-/UI-Aktualisierung versehentlich
        -- veraltet wäre, darf dieselbe Entität ihr Angriffslimit nicht überschreiten.
        if (m.attacksThisTurn or 0) >= MaxAttacks(m) then
            return false, "Diener hat bereits angegriffen"
        end
        if not m.canAttackThisTurn then return false, "Diener kann nicht angreifen" end
    end
    -- Taunt check
    if HasTauntOnBoard(enemyIdx) then
        local def = FindOnBoard(defenderEId)
        if defenderEId == enemyIdx or not (def and TauntActive(def)) then
            return false, "Muss Diener mit Spott angreifen"
        end
    end
    -- Defender valid
    if defenderEId ~= enemyIdx then
        local def = FindOnBoard(defenderEId)
        if not def or def.controller ~= enemyIdx then return false, "Ungültiges Ziel" end
        if def.stealthed then return false, "Ziel in Stealth" end
    end
    return true
end

local function ELabel(eid)
    if eid == 1 or eid == 2 then return "Held" end
    local m = FindOnBoard(eid)
    if not m then return "?" end
    local cardData = ARKANA_CardData and ARKANA_CardData[m.id]
    return cardData and cardData.name or m.id
end

local function ExecAttack(pIdx, attackerEId, defenderEId)
    local enemyIdx = OtherIdx(pIdx)
    local logA = ELabel(attackerEId)
    local logD = ELabel(defenderEId)
    -- Attacker stats
    local atkVal = 0
    local heroImmuneThisAttack = false
    local truesilverHeal = false
    if attackerEId == pIdx then
        local hero = P(pIdx).hero
        local wep = P(pIdx).weapon
        atkVal = (hero.attack or 0) + WeaponEffAtk(pIdx)
        hero.attacksThisTurn = (hero.attacksThisTurn or 0) + 1
        heroImmuneThisAttack = wep and wep.id == "DS1_188"
        truesilverHeal = wep and wep.id == "CS2_097"
        if wep then
            if wep.id == "EX1_411" and defenderEId ~= enemyIdx then
                -- Blutschrei: Angriff auf Diener kostet 1 Angriff statt 1 Haltbarkeit
                wep.attack = math.max(0, wep.attack - 1)
            else
                wep.durability = wep.durability - 1
                if wep.durability <= 0 then P(pIdx).weapon = nil end
            end
        end
    else
        local m = FindOnBoard(attackerEId)
        if not m then return end
        atkVal = MinionEffAtk(m)
        m.attacksThisTurn = m.attacksThisTurn + 1
        UpdateCanAttack(m)
        if m.drawOnAttack then DrawCard(pIdx) end
        if m.stealthed or HasTag(m.tags, "STEALTH") then
            m.stealthed = false
            for i, t in ipairs(m.tags) do
                if t.type == "STEALTH" then table.remove(m.tags, i); break end
            end
        end
    end
    -- Defender counter-attack value
    local defVal = 0
    if defenderEId == enemyIdx then
        -- hitting enemy hero
    else
        local def = FindOnBoard(defenderEId)
        if def then defVal = MinionEffAtk(def) end
    end
    -- Check secrets before damage
    local secretData = { cancel = false, attackerEId = attackerEId, atkVal = atkVal }
    -- Heldenopfer: JEDER Feind (Held oder Diener) greift irgendein Ziel an
    CheckSecrets(enemyIdx, "ENEMY_ATTACKS", secretData)
    -- Eiskältefalle: feindl. Diener greift irgendein Ziel an
    if not secretData.cancel and attackerEId ~= pIdx then
        CheckSecrets(enemyIdx, "ENEMY_MINION_ATTACKS", secretData)
    end
    if not secretData.cancel then
        if defenderEId == enemyIdx then
            if attackerEId ~= pIdx then  -- Minion greift Helden an
                CheckSecrets(enemyIdx, "MINION_ATTACKS_HERO", secretData)
            end
            if not secretData.cancel then
                CheckSecrets(enemyIdx, "HERO_ATTACKED", secretData)
            end
        else
            CheckSecrets(enemyIdx, "FRIENDLY_MINION_ATTACKED", secretData)
        end
    end

    -- Animation erst NACH der Secret-Auflösung feuern, damit Redirect-Secrets
    -- (Heldenopfer, Irreführung) das tatsächliche (umgeleitete) Ziel bekommen
    -- statt des ursprünglich anvisierten
    if addon.GE_OnAttack then
        local visualDefenderEId = defenderEId
        if secretData.cancel and secretData.redirectTarget then
            visualDefenderEId = secretData.redirectTarget
        end
        addon:GE_OnAttack(attackerEId, visualDefenderEId, defenderEId)
    end

    if secretData.cancel then
        if secretData.redirectTarget then
            -- Irreführung: Angriff auf neues Ziel umleiten
            DealDmgToEntity(pIdx, secretData.redirectTarget, atkVal)
            if secretData.redirectTarget ~= pIdx then
                local newDef = FindOnBoard(secretData.redirectTarget)
                if newDef then
                    local newDefAtk = MinionEffAtk(newDef)
                    if newDefAtk > 0 then DealDmgToEntity(enemyIdx, attackerEId, newDefAtk) end
                end
            end
        end
        CheckVictory(); RunDeathPipeline(); RecalcAuras(); return
    end

    -- Apply damage to defender
    DealDmgToEntity(pIdx, defenderEId, atkVal)
    if truesilverHeal then HealEntity(pIdx, 2, pIdx) end  -- Echtsilberchampion: 2 HP bei Helden-Angriff

    -- POISONOUS: Angreifer-Diener mit POISONOUS tötet jeden verletzten Diener
    if atkVal > 0 and attackerEId ~= pIdx then
        local atm = FindOnBoard(attackerEId)
        if atm and HasTag(atm.tags, "POISONOUS") and defenderEId ~= enemyIdx then
            local defM = FindOnBoard(defenderEId)
            if defM then defM.damageTaken = defM.damageTaken + 9999 end
        end
    end
    -- Verteidiger-Diener mit POISONOUS
    if defenderEId ~= enemyIdx then
        local defM = FindOnBoard(defenderEId)
        if defM and HasTag(defM.tags, "POISONOUS") and atkVal > 0 and attackerEId ~= pIdx then
            local atm = FindOnBoard(attackerEId)
            if atm then atm.damageTaken = atm.damageTaken + 9999 end
        end
    end

    -- Freeze-on-hit (z.B. Wasserelementar CS2_033)
    if attackerEId ~= pIdx then
        local atm = FindOnBoard(attackerEId)
        if atm and HasTag(atm.tags, "FREEZE_ON_HIT") then
            if defenderEId == enemyIdx then P(enemyIdx).hero.frozen = true
            else local def = FindOnBoard(defenderEId); if def then def.frozen = true; UpdateCanAttack(def) end end
        end
    end

    -- Eisblock: läuft jetzt direkt in DealDmgToEntity() (vor dessen CheckVictory()),
    -- damit das Spiel nicht schon endet bevor der Rettungs-Secret greifen kann

    -- Apply counter-damage to attacker (Langbogen: Held immun während Angriff)
    if defVal > 0 and not (attackerEId == pIdx and heroImmuneThisAttack) then
        DealDmgToEntity(enemyIdx, attackerEId, defVal)
    end
    CheckVictory()
    RunDeathPipeline()
    RecalcAuras()
    local hpAfter
    if defenderEId == enemyIdx then
        local h = P(enemyIdx).hero
        hpAfter = h.health .. "/" .. 30 .. " HP"
    else
        local def = FindOnBoard(defenderEId)
        if def then hpAfter = MinionCurHp(def) .. "/" .. MinionEffMaxHp(def) .. " HP" end
    end
    local dmgStr = hpAfter and (" (-" .. atkVal .. ", " .. hpAfter .. ")") or (" (-" .. atkVal .. ")")
    addon:GE_Log(pIdx, logA .. " greift " .. logD .. " an" .. dmgStr)
end

-- ── HEROPOWER ────────────────────────────────────────────────────────────────

local function ValidateHeroPower(pIdx, targetEntityId)
    if gs.phase ~= "play" then return false, "Nicht in Spielphase" end
    if gs.activePlayer ~= pIdx then return false, "Nicht dein Zug" end
    if P(pIdx).hero.heroPowerUsedThisTurn then return false, "Heldenpower bereits benutzt" end
    if AvailMana(pIdx) < 2 then return false, "Nicht genug Mana" end
    if targetEntityId and targetEntityId ~= 0 then
        local tm = FindOnBoard(targetEntityId)
        if tm and HasTag(tm.tags, "ELUSIVE") then return false, "Ziel ist flüchtig" end
        if tm and tm.controller ~= pIdx and tm.stealthed then return false, "Ziel in Stealth" end
    end
    return true
end

local function ExecHeroPower(pIdx, targetEntityId)
    local class  = P(pIdx).hero.heroPowerOverride or P(pIdx).hero.class or "NEUTRAL"
    local fn = HeroPower[class] or HeroPower.NEUTRAL
    SpendMana(pIdx, 2)
    P(pIdx).hero.heroPowerUsedThisTurn = true
    if addon.GE_OnHeroPower then
        addon:GE_OnHeroPower(pIdx, class, targetEntityId)
    end
    fn(pIdx, targetEntityId)
    RunDeathPipeline()
    RecalcAuras()
    CheckVictory()
end

-- ── Mulligan processing ───────────────────────────────────────────────────────

-- Applied kanonisch P1 then P2 once both are done
local pendingMulligans = {}

local function ApplyMulligans()
    for pIdx = 1, 2 do
        DoMulligan(pIdx, pendingMulligans[pIdx] or {})
        pendingMulligans[pIdx] = nil
    end
    TryStartPlay()
end

-- ── State hash ────────────────────────────────────────────────────────────────

local function StateHash()
    local t = {}
    local function a(v) t[#t+1] = tostring(v) end
    a(gs.activePlayer); a(gs.turnNumber); a(gs.entityCounter)
    for pIdx = 1, 2 do
        local p = P(pIdx)
        local h = p.hero
        a(p.fatigue); a(p.cardPlayedThisTurn and 1 or 0); a(p.cardsPlayedThisTurn or 0); a(p.spellCostReduction)
        a(h.health); a(h.armor); a(h.attack or 0); a(h.frozen and 1 or 0); a(h.heroPowerUsedThisTurn and 1 or 0)
        local mn = p.mana
        a(mn.maxPermanent); a(mn.currentPermanent); a(mn.temporary); a(mn.locked)
        a(#p.deck)
        for _, id in ipairs(p.deck) do a(id) end
        a(#p.hand)
        for _, card in ipairs(p.hand) do a(card.entityId); a(card.id); a(card.cost) end
        for _, m in ipairs(p.board) do
            a(m.entityId); a(m.id); a(m.baseAttack); a(m.baseHealth); a(m.damageTaken)
            a(m.frozen and 1 or 0); a(m.divineShield and 1 or 0)
            a(m.canAttackThisTurn and 1 or 0); a(m.attacksThisTurn)
        end
        a("|"); a(p.lastActionNo)
    end
    return ARKANA_CRC32(table.concat(t, "|"))
end

-- ── Public engine API ─────────────────────────────────────────────────────────

function addon:GE_Active() return gs ~= nil end
function addon:GE_State()  return gs end
function addon:GE_Reset()  gs = nil end

function addon:GE_StartGame(sessionId, seed, myRole, myCards, peerCards, myClass, peerClass, options)
    -- Zweite Prüfung unterhalb von Menü, Slash-Befehl und Sandbox-Modul: Ein
    -- direkter Aufruf der Engine darf den eingeschränkten Modus nicht starten.
    if options and options.sandbox == true and
       not (addon.SEC_CanUseSandbox and addon:SEC_CanUseSandbox()) then
        return false
    end
    -- Fehlende Tokens (nicht in Python-generiertem ClassicCardData)
    if not ARKANA_CardData["EX1_116t"] then
        ARKANA_CardData["EX1_116t"] = {id="EX1_116t", name="Onyxia-Welplin", cost=0, type="MINION", attack=1, health=1, tags={}, triggers={}, artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\EX1_116t.tga", frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga"}
    end
    if not ARKANA_CardData["EX1_534t"] then
        ARKANA_CardData["EX1_534t"] = {id="EX1_534t", name="Hyäne", cost=0, type="MINION", attack=2, health=1, race="BEAST", tags={}, triggers={}, artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\EX1_534t.tga", frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga"}
    end
    if not ARKANA_CardData["ARKANA_SANDBOX_DUMMY"] then
        ARKANA_CardData["ARKANA_SANDBOX_DUMMY"] = {
            id="ARKANA_SANDBOX_DUMMY", name="Test-Dummy", cost=0,
            type="MINION", class="NEUTRAL", attack=0, health=30,
            collectible=false, tags={}, triggers={},
            -- Nur das Bild des Alarm-o-Bots. ID, Volk und Zugbeginn-Effekt
            -- werden bewusst nicht übernommen, damit der Dummy passiv bleibt.
            artTexture="Interface\\AddOns\\Arkana\\Textures\\Cards\\EX1_006.tga",
            frameTexture="Interface\\AddOns\\Arkana\\Textures\\Frames\\frame-minion-neutral.tga"
        }
    end
    -- Deathrattle-Effekte hier setzen (garantiert nach allen lokalen Funktionsdefinitionen)
    DEATHRATTLE["EX1_096"] = function(pIdx, _) DrawCard(pIdx) end
    DEATHRATTLE["EX1_012"] = function(pIdx, _) DrawCard(pIdx) end
    DEATHRATTLE["EX1_029"] = function(pIdx, _) DealDmgToEntity(pIdx, OtherIdx(pIdx), 2) end
    DEATHRATTLE["EX1_556"] = function(pIdx, _) SummonMinionAt(pIdx, "skele21", #P(pIdx).board + 1) end
    DEATHRATTLE["EX1_097"] = function(pIdx, _)
        local op = OtherIdx(pIdx)
        DealDmgToEntity(pIdx, pIdx, 2); DealDmgToEntity(pIdx, op, 2)
        for _, bm in ipairs(P(pIdx).board) do DealDmgToEntity(pIdx, bm.entityId, 2) end
        for _, bm in ipairs(P(op).board)   do DealDmgToEntity(pIdx, bm.entityId, 2) end
    end
    DEATHRATTLE["EX1_016"] = function(pIdx, _)
        local op = OtherIdx(pIdx); local board = P(op).board
        if #board > 0 and #P(pIdx).board < 7 then
            gs.prngState = PrngNext(gs.prngState)
            local stolen = table.remove(board, (gs.prngState % #board) + 1)
            stolen.controller = pIdx; table.insert(P(pIdx).board, stolen); RecalcAuras()
        end
    end
    DEATHRATTLE["EX1_110"] = function(pIdx, _) SummonMinionAt(pIdx, "EX1_110t", #P(pIdx).board + 1) end
    DEATHRATTLE["EX1_534"] = function(pIdx, _)
        SummonMinionAt(pIdx, "EX1_534t", #P(pIdx).board + 1)
        SummonMinionAt(pIdx, "EX1_534t", #P(pIdx).board + 1)
    end
    DEATHRATTLE["EX1_577"] = function(pIdx, _)
        local op = OtherIdx(pIdx); SummonMinionAt(op, "EX1_finkle", #P(op).board + 1)
    end
    DEATHRATTLE["EX1_383"] = function(pIdx, _)
        P(pIdx).weapon = { entityId=gs.entityCounter, id="EX1_383t", attack=5, durability=3, tags={} }
        gs.entityCounter = gs.entityCounter + 1
    end
    local myIdx   = (myRole == "first") and 1 or 2
    local peerIdx = OtherIdx(myIdx)
    pendingMulligans = {}
    gs = {
        sessionId    = sessionId,
        prngState    = seed,
        myRole       = myRole,
        myPlayerIdx  = myIdx,
        activePlayer = 1,
        turnNumber   = 0,
        entityCounter = 3,
        phase        = "mulligan",
        mulliganDone = { [1]=false, [2]=false },
        myActionNo   = 0,
        practice     = options and options.practice == true or false,
        sandbox      = options and options.sandbox == true or false,
        players = {
            [1] = {
                hero = { entityId=1, class=(myIdx==1 and myClass or peerClass),
                         health=30, armor=0, attack=0, heroPowerUsedThisTurn=false,
                         frozen=false, enchantments={}, attacksThisTurn=0 },
                weapon=nil,
                mana = { maxPermanent=0, currentPermanent=0, temporary=0, locked=0 },
                hand={}, deck={}, board={}, secrets={},
                fatigue=0, cardPlayedThisTurn=false, cardsPlayedThisTurn=0, spellCostReduction=0, lastActionNo=0,
            },
            [2] = {
                hero = { entityId=2, class=(myIdx==2 and myClass or peerClass),
                         health=30, armor=0, attack=0, heroPowerUsedThisTurn=false,
                         frozen=false, enchantments={}, attacksThisTurn=0 },
                weapon=nil,
                mana = { maxPermanent=0, currentPermanent=0, temporary=0, locked=0 },
                hand={}, deck={}, board={}, secrets={},
                fatigue=0, cardPlayedThisTurn=false, cardsPlayedThisTurn=0, spellCostReduction=0, lastActionNo=0,
            },
        },
    }
    -- Decks: P1 = first/challenger, P2 = second/challengee
    local p1Cards = (myIdx == 1) and myCards or peerCards
    local p2Cards = (myIdx == 2) and myCards or peerCards
    local d1, d2 = {}, {}
    for _, id in ipairs(p1Cards) do d1[#d1+1] = id end
    for _, id in ipairs(p2Cards) do d2[#d2+1] = id end
    table.sort(d1); table.sort(d2)
    P(1).deck = d1; P(2).deck = d2
    ShuffleDeck(P(1).deck); ShuffleDeck(P(2).deck)
    -- Initial draw: P1 gets 3 (entity 3-5), P2 gets 4 (6-9), Coin for P2 (10)
    for _ = 1, 3 do DrawCard(1) end
    for _ = 1, 4 do DrawCard(2) end
    local coinEid = gs.entityCounter; gs.entityCounter = gs.entityCounter + 1
    P(2).hand[#P(2).hand+1] = { entityId = coinEid, id = "GAME_005", cost = 0 }
    addon:GE_OnGameStart()
end

-- Own action: validate → apply → return success
function addon:GE_DoAction(actionType, ...)
    if not gs then return false end
    local myIdx = gs.myPlayerIdx
    local args  = { ... }
    local ok, err
    if actionType == "PLAY" then
        ok, err = ValidatePlay(myIdx, args[1], args[2])
        if ok then ExecPlay(myIdx, args[1], args[2], args[3] or 0, args[4]) end
    elseif actionType == "ATTACK" then
        ok, err = ValidateAttack(myIdx, args[1], args[2])
        if ok then ExecAttack(myIdx, args[1], args[2]) end
    elseif actionType == "HEROPOWER" then
        ok, err = ValidateHeroPower(myIdx, args[1])
        if ok then ExecHeroPower(myIdx, args[1]) end
    elseif actionType == "END_TURN" then
        if gs.activePlayer == myIdx and gs.phase == "play" then
            ok = true; EndTurn(myIdx)
        else err = "Nicht dein Zug" end
    elseif actionType == "MULLIGAN_CHOICES" then
        -- args[1] = set of 0-based indices
        pendingMulligans[myIdx] = args[1] or {}
        ok = true
    elseif actionType == "MULLIGAN_DONE" then
        gs.mulliganDone[myIdx] = true
        if gs.mulliganDone[1] and gs.mulliganDone[2] then ApplyMulligans() end
        ok = true
    elseif actionType == "TRACKING_CHOOSE" then
        addon:GE_TrackingChoose(myIdx, args[1])
        ok = true
    end
    if err then print("|cffff0000[Arkana]|r " .. err) end
    return ok == true
end

-- Wendet eine Aktion als EXPLIZITER Spielerindex an.
-- Basis für GE_ApplyPeer (Peer = OtherIdx(myPlayerIdx)) UND den Zuschauer-Modus,
-- der Aktionen von BEIDEN Spielern replayen muss und daher den pIdx explizit
-- kennen muss statt "immer als Peer" anzunehmen.
--
-- REGELPRÜFUNG FREMDER AKTIONEN: bis Juli 2026 liefen Aktionen hier UNGEPRÜFT direkt
-- in Exec* — nur eigene Aktionen (GE_DoAction) wurden validiert. Ein manipulierter
-- Gegner-Client konnte damit Karten ohne Mana spielen, zweimal mit demselben Diener
-- angreifen oder Karten spielen, die nicht auf seiner Hand liegen; der ehrliche Client
-- hat es brav ausgeführt. Beim Lockstep kennt jeder Client den vollen Zustand beider
-- Seiten, kann die Aktion also selbst prüfen. Zuschauer prüfen dadurch mit.
--
-- VERWERFEN, NICHT NUR MELDEN: Der Gegner hat dieselbe Prüfung (dieselbe Funktion!)
-- vor dem Senden schon durchlaufen, und der Build-Check aus S45 stellt sicher, dass
-- beide Seiten denselben Code fahren — eine ehrliche Aktion kann hier also nicht
-- durchfallen. Umgekehrt MUSS verworfen werden: eine strukturell unmögliche Aktion
-- (Handplatz, den es nicht gibt) würde in Exec* auf ein nil-Feld laufen und den
-- ehrlichen Client mit einem Lua-Fehler aus dem Spiel werfen — der Cheat wäre dann
-- eine Waffe. Sollte je eine gültige Aktion fälschlich verworfen werden, bleibt das
-- nicht still: der Zustandsvergleich am Zugende (Network.lua) meldet die Abweichung.
local PEER_ENFORCE = true
function addon:GE_ApplyAs(pIdx, actionType, ...)
    if not gs then return false end
    local args = { ... }
    do
        local ok, err
        if actionType == "PLAY" then
            ok, err = ValidatePlay(pIdx, args[1], args[2])
        elseif actionType == "ATTACK" then
            ok, err = ValidateAttack(pIdx, args[1], args[2])
        elseif actionType == "HEROPOWER" then
            ok, err = ValidateHeroPower(pIdx, args[1])
        elseif actionType == "END_TURN" then
            ok = (gs.activePlayer == pIdx and gs.phase == "play")
            err = "Zug beenden, ohne am Zug zu sein"
        else
            ok = true   -- Mulligan/Fährtenlesen prüfen sich in ihren Handlern selbst
        end
        if not ok then
            if addon.GE_OnRuleViolation then addon:GE_OnRuleViolation(pIdx, actionType, err or "?") end
            if PEER_ENFORCE then return false end
        end
    end
    if actionType == "PLAY" then
        ExecPlay(pIdx, args[1], args[2], args[3] or 0, args[4])
    elseif actionType == "ATTACK" then
        ExecAttack(pIdx, args[1], args[2])
    elseif actionType == "HEROPOWER" then
        ExecHeroPower(pIdx, args[1])
    elseif actionType == "END_TURN" then
        EndTurn(pIdx)
    elseif actionType == "MULLIGAN_CHOICES" then
        pendingMulligans[pIdx] = args[1] or {}
    elseif actionType == "MULLIGAN_DONE" then
        -- Idempotent: Netzwerk-Resends (Net_MulliganDone-Ticker) dürfen
        -- ApplyMulligans nie doppelt auslösen (würde neu mulliganen = Desync)
        if gs.mulliganDone[pIdx] then return true end
        gs.mulliganDone[pIdx] = true
        if gs.mulliganDone[1] and gs.mulliganDone[2] then ApplyMulligans() end
    elseif actionType == "TRACKING_CHOOSE" then
        addon:GE_TrackingChoose(pIdx, args[1])
    end
    return true
end

function addon:GE_ApplyPeer(actionType, ...)
    if not gs then return end
    addon:GE_ApplyAs(OtherIdx(gs.myPlayerIdx), actionType, ...)
end

function addon:GE_StateHash() return gs and StateHash() or 0 end
function addon:GE_EffCost(pIdx, cardId, slotExtra) return gs and EffCost(pIdx, cardId, slotExtra) or (ARKANA_CardData[cardId] and ARKANA_CardData[cardId].cost or 0) end
function addon:GE_WeaponEffAtk(pIdx) return gs and WeaponEffAtk(pIdx) or 0 end
function addon:GE_SpellDmgBonus(pIdx) return gs and SpellDmgBonus(pIdx) or 0 end
function addon:GE_CanPlay(pIdx, handIdx, targetEntityId)
    if not gs then return false end
    return ValidatePlay(pIdx, handIdx, targetEntityId)
end
function addon:GE_CanAttack(pIdx, attackerEntityId, defenderEntityId)
    if not gs then return false end
    return ValidateAttack(pIdx, attackerEntityId, defenderEntityId)
end
function addon:GE_CanHeroPower(pIdx, targetEntityId)
    if not gs then return false end
    return ValidateHeroPower(pIdx, targetEntityId)
end
function addon:GE_IsPractice() return gs and gs.practice == true or false end
function addon:GE_IsSandbox() return gs and gs.sandbox == true or false end

-- Lokale Testwerkzeuge. Diese APIs existieren nur innerhalb einer laufenden
-- Sandbox und erzeugen keinerlei Netzwerkaktion oder Sammlungsänderung.
function addon:GE_SandboxGiveCard(cardId)
    if not gs or not gs.sandbox or gs.phase ~= "play" then return false, "Keine Sandbox aktiv." end
    local card = ARKANA_CardData and ARKANA_CardData[cardId]
    if not card or (card.type ~= "MINION" and card.type ~= "SPELL" and card.type ~= "WEAPON") then
        return false, "Diese Karte kann nicht getestet werden."
    end
    local player = P(gs.myPlayerIdx)
    if #player.hand >= 10 then return false, "Die Hand ist voll." end
    player.hand[#player.hand + 1] = {
        entityId = gs.entityCounter,
        id = cardId,
        cost = tonumber(card.cost) or 0,
    }
    gs.entityCounter = gs.entityCounter + 1
    if addon.Board_Update then addon:Board_Update() end
    return true, tostring(card.name or cardId) .. " wurde auf die Hand gelegt."
end

function addon:GE_SandboxFillMana()
    if not gs or not gs.sandbox or gs.phase ~= "play" then return false, "Keine Sandbox aktiv." end
    local player = P(gs.myPlayerIdx)
    player.mana.maxPermanent = 10
    player.mana.currentPermanent = 10
    player.mana.temporary = 0
    player.mana.locked = 0
    if addon.Board_Update then addon:Board_Update() end
    return true, "Mana wurde aufgefüllt."
end

function addon:GE_SandboxClearHand()
    if not gs or not gs.sandbox or gs.phase ~= "play" then return false, "Keine Sandbox aktiv." end
    P(gs.myPlayerIdx).hand = {}
    if addon.Board_Update then addon:Board_Update() end
    return true, "Hand wurde geleert."
end

function addon:GE_SandboxAddDummy(enemySide, attack, health)
    if not gs or not gs.sandbox or gs.phase ~= "play" then return false, "Keine Sandbox aktiv." end
    local pIdx = enemySide == false and gs.myPlayerIdx or OtherIdx(gs.myPlayerIdx)
    if #P(pIdx).board >= 7 then return false, "Auf dieser Seite ist kein Platz." end
    local dummy = SummonMinionAt(pIdx, "ARKANA_SANDBOX_DUMMY", #P(pIdx).board + 1)
    if not dummy then return false, "Der Test-Dummy konnte nicht beschworen werden." end
    dummy.baseAttack = math.max(0, math.min(999, tonumber(attack) or 0))
    dummy.baseHealth = math.max(1, math.min(999, tonumber(health) or 30))
    dummy.damageTaken = 0
    RecalcAuras()
    UpdateCanAttack(dummy)
    if addon.Board_Update then addon:Board_Update() end
    return true, string.format("Test-Dummy wurde als %d/%d beschworen.", MinionEffAtk(dummy), MinionEffMaxHp(dummy))
end

function addon:GE_SandboxClearBoards()
    if not gs or not gs.sandbox or gs.phase ~= "play" then return false, "Keine Sandbox aktiv." end
    P(1).board = {}
    P(2).board = {}
    RecalcAuras()
    if addon.Board_Update then addon:Board_Update() end
    return true, "Beide Spielfelder wurden geleert."
end
-- Anzeige-Angriff eines Dieners: EINE Quelle für Brett und Tooltip. Die UI hatte
-- die Summe selbst nachgebaut und dabei die 0-Grenze vergessen (Lichtbrut mit
-- -3 Angriff durch einen Zauber) — MinionEffAtk klemmt sie und zählt Wut mit.
function addon:GE_MinionAtk(m) return m and MinionEffAtk(m) or 0 end

function addon:GE_TrackingChoose(pIdx, chosenId)
    if not gs then return end
    local choices = P(pIdx).trackingChoices
    if not choices then return end
    P(pIdx).trackingChoices = nil
    local deck = P(pIdx).deck
    -- Alle 3 angezeigten Karten vom Deck-Top entfernen
    local removed = {}
    for _, cid in ipairs(choices) do
        for i = #deck, 1, -1 do
            if deck[i] == cid and not removed[i] then
                removed[i] = true
                table.remove(deck, i)
                break
            end
        end
    end
    -- Gewählte Karte auf Hand
    local card = ARKANA_CardData[chosenId]
    P(pIdx).hand[#P(pIdx).hand+1] = {entityId=gs.entityCounter, id=chosenId, cost=card and card.cost or 0}
    gs.entityCounter = gs.entityCounter + 1
    addon:Board_Update()
end

function addon:GE_EndGame(winner)
    if not gs or gs.phase == "ended" then return end
    gs.phase = "ended"
    local myRole = gs.myRole
    local neutralSandboxEnd = winner == "SANDBOX_END"
    local result = winner == "DRAW" and "d" or (winner == myRole and "w" or "l")
    if not gs.practice and not neutralSandboxEnd then
        local g = ARKANA_Stats.global
        g[result] = g[result] + 1
        if gs.myDeckName and ARKANA_Stats.decks then
            if not ARKANA_Stats.decks[gs.myDeckName] then
                ARKANA_Stats.decks[gs.myDeckName] = {w=0,l=0,d=0}
            end
            ARKANA_Stats.decks[gs.myDeckName][result] = ARKANA_Stats.decks[gs.myDeckName][result] + 1
        end
        if addon.RK_OnGameEnd then addon:RK_OnGameEnd(result) end   -- Ranked (nur wenn gewertet)
    else
        addon.RK_LastDelta = nil
    end
    local msg = neutralSandboxEnd and "Sandbox beendet."
        or (winner == "DRAW" and "Unentschieden!" or (winner == myRole and "Du hast gewonnen!" or "Niederlage!"))
    if self.GameLog then
        self:GameLog("|cff00ff00" .. msg .. "|r")
    else
        print("|cff00ff00[Arkana]|r " .. msg)
    end
    addon:GE_OnGameEnd(winner)
    -- gs erst NACH dem aktuellen Call-Stack (ExecAttack/ExecPlay/FireTriggers/CheckSecrets ...) auf nil
    -- setzen, sonst crasht jeder Code, der nach dem tödlichen Treffer noch im selben Stack weiterläuft
    -- (z.B. RunDeathPipeline nach einem Secret, das den Angreifer tötet).
    C_Timer.After(0, function() gs = nil end)
end

-- ── Stub callbacks (overridden by UI / Network) ───────────────────────────────

function addon:GE_Log(pIdx, msg)
    local label
    if addon.IsSpectating and addon:IsSpectating() and addon.Spec_PlayerNames then
        -- Zuschauer: echte Namen (P1 = Host, P2 = Gegner)
        local p1, p2 = addon:Spec_PlayerNames()
        label = (pIdx == 1) and p1 or p2
    elseif gs and pIdx == gs.myPlayerIdx then
        label = UnitName("player")
    else
        label = (addon.Net_GetPeerName and addon:Net_GetPeerName())
    end
    label = label or "?"
    label = label:sub(1,1):upper() .. label:sub(2)
    if self.GameLog then
        self:GameLog("[" .. label .. "] " .. msg)
    else
        print("[ARKANA-GE P" .. pIdx .. "] " .. msg)
    end
end
function addon:GE_OnGameStart() end
function addon:GE_TurnStart(pIdx)
    if gs and pIdx == gs.myPlayerIdx then
        local p = P(pIdx)
        print(string.format("|cff00ff00[Arkana]|r Dein Zug! Mana: %d/%d  Hand: %d  Brett: %d",
            p.mana.currentPermanent, p.mana.maxPermanent, #p.hand, #p.board))
    else
        print("|cff00ff00[Arkana]|r Gegner ist dran.")
    end
end
function addon:GE_OnGameEnd(winner) end
function addon:GE_OnDamage(entityId, amount) end
function addon:GE_OnFatigueDamage(pIdx, amount) end
function addon:GE_OnHeal(entityId, amount) end
function addon:GE_OnSecretTrigger(ownerIdx, secretId, data) end
function addon:GE_OnSecretEffect(ownerIdx, secretId, data) end
function addon:GE_OnSpellCountered() end
