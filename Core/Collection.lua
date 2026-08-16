local addon = Arkana
local ECONOMY_VERSION = 2
local DISTRIBUTOR_BOOSTER_LIMIT = 3
local ADMIN_BOOSTER_LIMIT = 9
local RECIPIENT_BOOSTER_LIMIT = 9
local BOOSTER_TYPES = {
    C = { key = "C", name = "Classic", payload = "CLASSIC" },
    X = { key = "X", name = "Custom", payload = "CUSTOM" },
    L = { key = "L", name = "Legendär", payload = "LEGENDARY" },
}

local function BoosterType(packType)
    local ptype = tostring(packType or "C"):upper()
    return BOOSTER_TYPES[ptype] and ptype or nil
end

function addon:COL_BoosterInfo(packType)
    return BOOSTER_TYPES[BoosterType(packType) or "C"]
end

local function Now()
    return (GetServerTime and GetServerTime()) or time()
end

-- Charaktergebundene Kartensammlung. Neue Charaktere starten ohne Karten.
-- Das Basispaket wird nicht als frei editierbare Kartenliste gespeichert, sondern
-- als signierter Berechtigungsnachweis. FREE-Karten sind nur mit einer gültigen,
-- an diesen Charakter gebundenen Spielleitungs-Freigabe verfügbar.

local function MyName()
    if addon.SEC_LocalIdentity then return addon:SEC_LocalIdentity() end
    return tostring(UnitName("player") or ""):lower()
end

local function CharacterName(name)
    if addon.SEC_CharacterIdentity then return addon:SEC_CharacterIdentity(name) end
    return tostring(name or ""):lower()
end

local function IsFreeCollectible(card)
    return type(card) == "table" and card.collectible == true and card.rarity == "FREE"
end

local function BasePackageCards()
    local cards = {}
    for id, card in pairs(ARKANA_CardData or {}) do
        if IsFreeCollectible(card) then cards[#cards + 1] = id end
    end
    table.sort(cards)
    return cards
end

local function Data()
    ARKANA_CharData = ARKANA_CharData or {}
    -- Einmaliger sauberer Start für das neue Besitzmodell. Frühere Builds gaben
    -- den kompletten Katalog frei bzw. verwendeten andere Sammlungs-/Packformate;
    -- diese Werte dürfen nicht versehentlich als neuer Kartenbesitz weiterleben.
    if ARKANA_CharData.cardEconomyVersion ~= ECONOMY_VERSION then
        ARKANA_CharData.collection = {}
        ARKANA_CharData.entitlements = {}
        ARKANA_CharData.boosters = {}
        ARKANA_CharData.appliedGrants = {}
        ARKANA_CharData.cardEconomyVersion = ECONOMY_VERSION
    end
    ARKANA_CharData.collection = ARKANA_CharData.collection or {}
    ARKANA_CharData.entitlements = ARKANA_CharData.entitlements or {}
    ARKANA_CharData.boosters = ARKANA_CharData.boosters or {}
    return ARKANA_CharData
end

local function HasBasePackage()
    local grant = Data().entitlements.base
    if type(grant) ~= "table" or grant.v ~= 1 or not addon.SEC_IsSigningAuthority or
       not addon:SEC_IsSigningAuthority(grant.issuer) then return false end
    return addon.SEC_ValidateGrantSignature and addon:SEC_ValidateGrantSignature(
        "BASE", MyName(), grant.nonce, "FREE-V1", grant.signature)
end

local function HasDistributorAccess()
    local grant = Data().entitlements.distributor
    if type(grant) ~= "table" or grant.v ~= 1 or not addon.SEC_IsSigningAuthority or
       not addon:SEC_IsSigningAuthority(grant.issuer) then return false end
    return addon.SEC_ValidateDistributorCredential and addon:SEC_ValidateDistributorCredential(
        MyName(), grant.nonce, grant.signature)
end

local function GetDistributorCredential()
    if not HasDistributorAccess() then return nil end
    local grant = Data().entitlements.distributor
    return {
        v = 1,
        issuer = addon.SEC_SigningAuthority and addon:SEC_SigningAuthority() or "annila-schattenhain",
        nonce = grant.nonce,
        signature = grant.signature,
    }
end

function addon:COL_HasBasePackage()
    return HasBasePackage()
end

-- Explizite Paketliste für UI/Diagnose: ausschließlich sammelbare FREE-Karten.
-- Die Besitzmenge ist keine veränderbare Zahl, sondern fest auf 2 gesetzt.
function addon:COL_BasePackageCards()
    return BasePackageCards()
end

local function ApplyBaseGrant(nonce, signature)
    if not addon.SEC_ValidateGrantSignature or
       not addon:SEC_ValidateGrantSignature("BASE", MyName(), nonce, "FREE-V1", signature) then
        return false, "Basispaket-Freigabe ist ungültig."
    end
    local data = Data()
    if HasBasePackage() then return true, "Basispaket war bereits freigeschaltet." end
    -- Alte/fehlerhafte FREE-Einträge werden nicht als normale Sammlung geführt.
    -- Ihr Besitz kommt ausschließlich aus der signierten Basispaket-Freigabe.
    for id in pairs(data.collection) do
        if IsFreeCollectible(ARKANA_CardData and ARKANA_CardData[id]) then
            data.collection[id] = nil
        end
    end
    data.entitlements.base = {
        v = 1,
        issuer = addon.SEC_SigningAuthority and addon:SEC_SigningAuthority() or "annila-schattenhain",
        nonce = tostring(nonce),
        signature = tostring(signature):upper(),
        grantedAt = time(),
    }
    if addon.DB_RefreshIfShown then addon:DB_RefreshIfShown() end
    return true, "Basispaket freigeschaltet: " .. #BasePackageCards() .. " kostenlose Karten, jeweils 2x."
end

local function ApplyDistributorGrant(nonce, signature)
    if not addon.SEC_ValidateDistributorCredential or
       not addon:SEC_ValidateDistributorCredential(MyName(), nonce, signature) then
        return false, "Verteiler-Freigabe ist ungültig."
    end
    local data = Data()
    data.appliedGrants = data.appliedGrants or {}
    local grantKey = "distributor:" .. tostring(nonce or "")
    if data.appliedGrants[grantKey] then
        local active = HasDistributorAccess()
        return active, active and
            "Booster-Verteiler war bereits freigeschaltet." or
            "Diese Verteiler-Freigabe wurde bereits widerrufen."
    end
    if HasDistributorAccess() then
        data.appliedGrants[grantKey] = true
        return true, "Booster-Verteiler war bereits freigeschaltet."
    end
    data.entitlements.distributor = {
        v = 1,
        issuer = addon.SEC_SigningAuthority and addon:SEC_SigningAuthority() or "annila-schattenhain",
        nonce = tostring(nonce),
        signature = tostring(signature):upper(),
        grantedAt = time(),
    }
    data.appliedGrants[grantKey] = true
    if addon.MM_RefreshAccess then addon:MM_RefreshAccess() end
    return true, "Booster-Verteilung freigeschaltet. Du kannst nun Booster an Ziele vergeben."
end

local function ApplyDistributorRevocation(nonce, signature)
    if not addon.SEC_ValidateGrantSignature or
       not addon:SEC_ValidateGrantSignature(
            "DISTRIBUTOR_REVOKE", MyName(), nonce, "BOOSTER-V1", signature) then
        return false, "Verteiler-Entfernung ist ungültig."
    end
    local data = Data()
    data.appliedGrants = data.appliedGrants or {}
    local revokeKey = "distributor-revoke:" .. tostring(nonce or "")
    if data.appliedGrants[revokeKey] then
        return true, "Verteiler-Entfernung wurde bereits angewendet."
    end
    local oldGrant = data.entitlements.distributor
    if type(oldGrant) == "table" and oldGrant.nonce then
        data.appliedGrants["distributor:" .. tostring(oldGrant.nonce)] = true
    end
    data.entitlements.distributor = nil
    data.appliedGrants[revokeKey] = true
    if addon.MM_RefreshAccess then addon:MM_RefreshAccess() end
    if addon.ADM_CloseIfUnauthorized then addon:ADM_CloseIfUnauthorized() end
    return true, "Booster-Verteiler entfernt."
end

function addon:COL_Count(cardId)
    local card = ARKANA_CardData and ARKANA_CardData[cardId]
    if not card or card.collectible ~= true then return 0 end
    if IsFreeCollectible(card) then return HasBasePackage() and 2 or 0 end
    return math.max(0, math.floor(tonumber(Data().collection[cardId]) or 0))
end

local function AddCard(cardId, amount, suppressRefresh)
    local card = ARKANA_CardData and ARKANA_CardData[cardId]
    amount = math.floor(tonumber(amount) or 0)
    if not card or card.collectible ~= true then return 0 end
    -- FREE-Karten bleiben immer exakt 2x vorhanden und können weder erhöht noch
    -- verringert werden. Auch interne Aufrufer erhalten den echten Besitzwert.
    if IsFreeCollectible(card) then return HasBasePackage() and 2 or 0 end
    if amount == 0 then return addon:COL_Count(cardId) end
    local data = Data()
    local before = math.max(0, math.floor(tonumber(data.collection[cardId]) or 0))
    local after = math.max(0, before + amount)
    data.collection[cardId] = after > 0 and after or nil
    if after > before then
        data.newCards = data.newCards or {}
        data.newCards[cardId] = true
    end
    if not suppressRefresh and addon.DB_RefreshIfShown then addon:DB_RefreshIfShown() end
    return after
end

local function ValidBooster(item)
    if not addon.SEC_ValidateBoosterItem then return false end
    return addon:SEC_ValidateBoosterItem(item)
end

local function SanitizedBoosters()
    local data, clean, seen = Data(), {}, {}
    for _, item in ipairs(data.boosters) do
        local valid = ValidBooster(item)
        if valid and not seen[item] then
            clean[#clean + 1] = item
            seen[item] = true
        end
    end
    data.boosters = clean
    return clean
end

function addon:BP_ValidItem(item)
    local valid = ValidBooster(item)
    return valid and true or false, valid and nil or "Ungültiger oder manipulierter Booster."
end

function addon:COL_BoosterCount(packType)
    local wanted = (packType == nil or packType == "") and "C" or tostring(packType):upper()
    local count = 0
    for _, item in ipairs(SanitizedBoosters()) do
        -- SanitizedBoosters hat Signatur und Dubletten bereits geprüft.
        if item:sub(1, 1) == wanted then count = count + 1 end
    end
    return count
end

local function GiveBoosters(serials)
    local data = Data()
    local seen = {}
    data.boosters = SanitizedBoosters()
    for _, existing in ipairs(data.boosters) do seen[existing] = true end

    -- Erst vollständig prüfen, dann verändern. So bleibt der Bestand unverändert,
    -- wenn eine Freigabe ein ungültiges oder doppeltes Booster-Item enthält.
    for _, item in ipairs(serials or {}) do
        local valid = ValidBooster(item)
        if not valid or seen[item] then return 0 end
        seen[item] = true
    end
    for _, item in ipairs(serials or {}) do
        data.boosters[#data.boosters + 1] = item
    end
    return #(serials or {})
end

local function TakeBoosters(amount, packType)
    amount = math.max(0, math.floor(tonumber(amount) or 0))
    local wanted = (packType == nil or packType == "") and "C" or tostring(packType):upper()
    if amount == 0 then return nil end
    local data, taken = Data(), {}
    data.boosters = SanitizedBoosters()
    local available = 0
    for _, item in ipairs(data.boosters) do
        if item:sub(1, 1) == wanted then available = available + 1 end
    end
    if available < amount then return nil end
    for i = #data.boosters, 1, -1 do
        if data.boosters[i]:sub(1, 1) == wanted and #taken < amount then
            taken[#taken + 1] = table.remove(data.boosters, i)
        end
    end
    return taken, available - amount
end

local function WeeklyBoosterReceived(issuer)
    local now = Now()
    local distributorCount, distributorNextAt = 0, nil
    local recipientCount, recipientNextAt = 0, nil
    local cutoff = now - (7 * 24 * 60 * 60)
    local wantedIssuer = CharacterName(issuer)
    for _, grant in pairs(Data().appliedGrants or {}) do
        local appliedAt = type(grant) == "table" and tonumber(grant.appliedAt) or nil
        local grantIssuer = type(grant) == "table" and CharacterName(grant.issuer) or ""
        if appliedAt and grant.kind == "BOOSTER" and appliedAt > cutoff and appliedAt <= now then
            local amount = math.max(0, math.floor(tonumber(grant.amount) or 0))
            local expiresAt = appliedAt + (7 * 24 * 60 * 60)
            recipientCount = recipientCount + amount
            if not recipientNextAt or expiresAt < recipientNextAt then recipientNextAt = expiresAt end
            if wantedIssuer ~= "" and grantIssuer == wantedIssuer then
                distributorCount = distributorCount + amount
                if not distributorNextAt or expiresAt < distributorNextAt then
                    distributorNextAt = expiresAt
                end
            end
        end
    end
    return distributorCount, distributorNextAt, recipientCount, recipientNextAt
end

function addon:COL_WeeklyBoosterStatus(issuer)
    local distributorCount, distributorNextAt, recipientCount, recipientNextAt =
        WeeklyBoosterReceived(issuer)
    local issuerLimit = addon.SEC_IsAdmin and addon:SEC_IsAdmin(issuer) and
        ADMIN_BOOSTER_LIMIT or DISTRIBUTOR_BOOSTER_LIMIT
    return recipientCount, RECIPIENT_BOOSTER_LIMIT, recipientNextAt,
        distributorCount, issuerLimit, distributorNextAt
end

local function ApplyBoosterGrant(amount, nonce, signature, issuer, credentialNonce, credentialSignature, packType)
    amount = math.floor(tonumber(amount) or 0)
    local ptype = BoosterType(packType)
    local issuerIsAdmin = addon.SEC_IsAdmin and addon:SEC_IsAdmin(issuer)
    local issuerLimit = issuerIsAdmin and ADMIN_BOOSTER_LIMIT or DISTRIBUTOR_BOOSTER_LIMIT
    if not ptype or amount < 1 or amount > issuerLimit then return false, "Ungültige Booster-Menge." end
    if not issuerIsAdmin and ptype ~= "C" then
        return false, "Verteiler dürfen nur Classic-Booster vergeben."
    end
    local info = BOOSTER_TYPES[ptype]
    local payload = info.payload .. ":" .. amount
    if not addon.SEC_ValidateBoosterGrantSignature or
       not addon:SEC_ValidateBoosterGrantSignature(issuer, MyName(), nonce, payload, signature,
            credentialNonce, credentialSignature) then
        return false, "Booster-Freigabe ist ungültig."
    end
    local data = Data()
    data.appliedGrants = data.appliedGrants or {}
    local grantKey = CharacterName(issuer) .. ":" .. tostring(nonce or "")
    if data.appliedGrants[grantKey] then return true, "Booster-Freigabe wurde bereits angewendet." end
    local distributorCount, distributorNextAt, recipientCount, recipientNextAt =
        WeeklyBoosterReceived(issuer)
    local distributorRemaining = math.max(0, issuerLimit - distributorCount)
    if amount > distributorRemaining then
        local cooldown = distributorNextAt and (" Nächste Freigabe ab " ..
            date("%d.%m. %H:%M", distributorNextAt) .. ".") or ""
        return false, "Verteiler-Limit erreicht: Noch " .. distributorRemaining .. " von " ..
            issuerLimit .. " Boostern verfügbar." .. cooldown
    end
    local recipientRemaining = math.max(0, RECIPIENT_BOOSTER_LIMIT - recipientCount)
    if amount > recipientRemaining then
        local cooldown = recipientNextAt and (" Nächster Empfang ab " ..
            date("%d.%m. %H:%M", recipientNextAt) .. ".") or ""
        return false, "Empfänger-Limit erreicht: Noch " .. recipientRemaining .. " von " ..
            RECIPIENT_BOOSTER_LIMIT .. " Boostern verfügbar." .. cooldown
    end
    local serials = addon.SEC_ItemsFromBoosterGrant and
        addon:SEC_ItemsFromBoosterGrant(issuer, MyName(), amount, nonce, signature,
            credentialNonce, credentialSignature, ptype)
    if not serials or #serials ~= amount then return false, "Booster konnten nicht erzeugt werden." end
    local added = GiveBoosters(serials)
    if added ~= amount then return false, "Booster konnten nicht vollständig hinzugefügt werden." end
    data.appliedGrants[grantKey] = {
        kind = "BOOSTER",
        amount = amount,
        issuer = tostring(issuer or ""),
        packType = ptype,
        appliedAt = Now(),
    }
    return true, amount .. " " .. info.name .. "-Booster erhalten (" .. (distributorCount + amount) .. "/" ..
        issuerLimit .. " von diesem Verteiler · " ..
        (recipientCount + amount) .. "/" .. RECIPIENT_BOOSTER_LIMIT .. " gesamt)."
end

-- Einmalige interne Übergabe an das direkt nachgeladene Verteilungsmodul. Danach
-- löscht Admin.lua die globale Abholfunktion wieder. So bleiben reine
-- Besitzmutationen nicht über /run oder ein gewöhnliches Makro erreichbar.
local adminAPIClaimed = false
function addon:COL_ConsumeAdminAPI()
    if adminAPIClaimed then return nil end
    adminAPIClaimed = true
    return {
        ApplyBaseGrant = ApplyBaseGrant,
        ApplyBoosterGrant = ApplyBoosterGrant,
        ApplyDistributorGrant = ApplyDistributorGrant,
        ApplyDistributorRevocation = ApplyDistributorRevocation,
        HasDistributorAccess = HasDistributorAccess,
        GetDistributorCredential = GetDistributorCredential,
    }
end


local function CardPools()
    local pools = { COMMON = {}, RARE = {}, EPIC = {}, LEGENDARY = {} }
    for _, card in pairs(ARKANA_CardData or {}) do
        if card.collectible == true and card.rarity ~= "FREE" and pools[card.rarity] then
            pools[card.rarity][#pools[card.rarity] + 1] = card.id
        end
    end
    return pools
end

local function RollClassicRarity(guaranteedRare)
    local roll = math.random(1, 1000)
    if guaranteedRare then
        if roll <= 50 then return "LEGENDARY" end
        if roll <= 200 then return "EPIC" end
        return "RARE"
    end
    if roll <= 20 then return "LEGENDARY" end
    if roll <= 80 then return "EPIC" end
    if roll <= 300 then return "RARE" end
    return "COMMON"
end

local function RollCustomRarity(guaranteedEpic)
    local roll = math.random(1, 1000)
    if guaranteedEpic then return roll <= 150 and "LEGENDARY" or "EPIC" end
    if roll <= 50 then return "LEGENDARY" end
    if roll <= 250 then return "EPIC" end
    return "RARE"
end

local function PackRarity(packType, index)
    if packType == "X" then return RollCustomRarity(index == 5) end
    if packType == "L" and index == 5 then return "LEGENDARY" end
    return RollClassicRarity(packType == "C" and index == 5)
end

function addon:COL_OpenBooster(packType)
    local ptype = BoosterType(packType)
    if not ptype then return nil, "Unbekannter Booster-Typ." end
    local info = BOOSTER_TYPES[ptype]
    local taken, remaining = TakeBoosters(1, ptype)
    if not taken then return nil, "Du besitzt keinen " .. info.name .. "-Booster." end
    local pools, cards = CardPools(), {}
    for i = 1, 5 do
        local rarity = PackRarity(ptype, i)
        local pool = pools[rarity]
        if not pool or #pool == 0 then
            GiveBoosters(taken)
            return nil, "Für " .. rarity .. " sind keine Karten im Katalog vorhanden."
        end
        local id = pool[math.random(1, #pool)]
        cards[#cards + 1] = id
    end
    -- Sammlung erst verändern, nachdem alle fünf Ziehungen erfolgreich ermittelt
    -- wurden. Bei einem Katalogfehler bleibt damit weder eine Teilbelohnung noch ein
    -- verbrauchter Booster zurück.
    for _, id in ipairs(cards) do AddCard(id, 1, true) end
    if addon.DB_RefreshIfShown then addon:DB_RefreshIfShown() end
    return cards, nil, remaining
end

-- Die Wunschliste bleibt als persönlicher Favoriten-/Merkzettel erhalten.
local function WData()
    ARKANA_CharData = ARKANA_CharData or {}
    ARKANA_CharData.wishlist = ARKANA_CharData.wishlist or {}
    return ARKANA_CharData.wishlist
end

function addon:WL_Has(cardId)
    return WData()[cardId] == true
end

function addon:WL_Toggle(cardId)
    local wishlist = WData()
    if wishlist[cardId] then wishlist[cardId] = nil else wishlist[cardId] = true end
    return wishlist[cardId] == true
end

function addon:WL_Count()
    local count = 0
    for _ in pairs(WData()) do count = count + 1 end
    return count
end
