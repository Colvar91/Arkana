local addon = Arkana
local PREFIX = "ARKANA"
local pending = {}
local collectionAPI = addon.COL_ConsumeAdminAPI and addon:COL_ConsumeAdminAPI()
addon.COL_ConsumeAdminAPI = nil
local BOOSTER_TYPES = {
    C = { name = "Classic", payload = "CLASSIC" },
    X = { name = "Custom", payload = "CUSTOM" },
    L = { name = "Legendär", payload = "LEGENDARY" },
}

local function BoosterType(packType)
    local value = tostring(packType or "C"):lower()
    local aliases = {
        c = "C", classic = "C",
        x = "X", custom = "X",
        l = "L", legendary = "L", ["legendär"] = "L", legendaer = "L",
    }
    return aliases[value]
end

local function CharacterName(name)
    if addon.SEC_CharacterIdentity then return addon:SEC_CharacterIdentity(name) end
    return tostring(name or ""):lower()
end

local function MyName()
    if addon.SEC_LocalIdentity then return addon:SEC_LocalIdentity() end
    return CharacterName(UnitName("player"))
end

local function Nonce()
    return string.format("%08X%04X", time() % 4294967296, math.random(0, 65535))
end

local function Whisper(target, message)
    addon:SendCommMessage(PREFIX, message, "WHISPER", target, "ALERT")
end

local function Split(value)
    local parts = {}
    for part in tostring(value or ""):gmatch("[^|]+") do parts[#parts + 1] = part end
    return parts
end

local function SendGrant(target, fields)
    if not addon.SEC_SealGrant then return false end
    local envelope = addon:SEC_SealGrant(table.concat(fields, "|"))
    if not envelope then return false end
    Whisper(target, "ADMGRANT|" .. envelope)
    return true
end

local function CanAdmin()
    return addon.SEC_IsAdmin and addon:SEC_IsAdmin(MyName())
end

local function CanDistribute()
    return CanAdmin() or (collectionAPI and collectionAPI.HasDistributorAccess and
        collectionAPI.HasDistributorAccess())
end

local function DistributorRegistry()
    ARKANA_CharData = ARKANA_CharData or {}
    ARKANA_CharData.distributorRegistry = ARKANA_CharData.distributorRegistry or {}
    if ARKANA_CharData.distributorRegistryIdentityVersion ~= 2 then
        local migrated = {}
        for key, record in pairs(ARKANA_CharData.distributorRegistry) do
            local identity = CharacterName(key)
            if identity ~= "" then
                record = type(record) == "table" and record or {}
                record.name = identity
                migrated[identity] = record
            end
        end
        ARKANA_CharData.distributorRegistry = migrated
        ARKANA_CharData.distributorRegistryIdentityVersion = 2
    end
    return ARKANA_CharData.distributorRegistry
end

local function SetDistributorRegistration(target, enabled)
    if not CanAdmin() then return end
    local key = CharacterName(target)
    if key == "" or (addon.SEC_IsAdmin and addon:SEC_IsAdmin(key)) then return end
    local registry = DistributorRegistry()
    if enabled then
        registry[key] = { name = key, changedAt = (GetServerTime and GetServerTime()) or time() }
    else
        registry[key] = nil
    end
end

local function TrackGrant(nonce, target, kind)
    local record = { target = CharacterName(target), kind = tostring(kind or "Freigabe") }
    pending[nonce] = record
    C_Timer.After(8, function()
        if pending[nonce] ~= record then return end
        pending[nonce] = nil
        local message = "Keine Bestätigung von " .. target ..
            " erhalten. Ist das Ziel online und Arkana aktiv?"
        print("|cffff4040[Arkana-Verteilung]|r " .. message)
        if addon.ADM_UpdateStatus then addon:ADM_UpdateStatus(message, false) end
    end)
end

function addon:ADM_IsRootAdmin()
    return CanAdmin()
end

function addon:ADM_CanUse()
    return CanDistribute()
end

function addon:ADM_DistributorCount()
    if not CanAdmin() then return 0 end
    local count = 0
    for _ in pairs(DistributorRegistry()) do count = count + 1 end
    return count
end

function addon:ADM_IsDistributorRegistered(target)
    return CanAdmin() and DistributorRegistry()[CharacterName(target)] ~= nil
end

function addon:ADM_SendBasePackage(target)
    if not CanAdmin() then return false, "Nur die Arkana-Spielleitung darf das Basispaket vergeben." end
    local boundTarget = CharacterName(target)
    if boundTarget == "" then return false, "Kein gültiges Ziel ausgewählt." end
    local nonce = Nonce()
    local signature = addon:SEC_MakeGrantSignature("BASE", boundTarget, nonce, "FREE-V1")
    if not signature or not collectionAPI then return false, "Spielleitungs-Freigabe konnte nicht erzeugt werden." end
    if boundTarget == MyName() then
        return collectionAPI.ApplyBaseGrant(nonce, signature)
    end
    TrackGrant(nonce, boundTarget, "Basispaket")
    if not SendGrant(target, { "BASE", boundTarget, nonce, signature }) then
        pending[nonce] = nil
        return false, "Basispaket-Freigabe konnte nicht kodiert werden."
    end
    return true, "Basispaket an " .. boundTarget .. " gesendet."
end

function addon:ADM_SendDistributorAccess(target)
    if not CanAdmin() then return false, "Nur die Arkana-Spielleitung darf Booster-Verteiler eintragen." end
    local boundTarget = CharacterName(target)
    if boundTarget == "" then return false, "Kein gültiges Ziel ausgewählt." end
    if addon.SEC_IsAdmin and addon:SEC_IsAdmin(boundTarget) then
        return true, boundTarget .. " gehört bereits zur Arkana-Spielleitung."
    end
    local nonce = Nonce()
    local signature = addon:SEC_MakeGrantSignature("DISTRIBUTOR", boundTarget, nonce, "BOOSTER-V1")
    if not signature or not collectionAPI then return false, "Verteiler-Freigabe konnte nicht erzeugt werden." end
    if boundTarget == MyName() then
        return collectionAPI.ApplyDistributorGrant(nonce, signature)
    end
    TrackGrant(nonce, boundTarget, "DISTRIBUTOR")
    if not SendGrant(target, { "DISTRIBUTOR", boundTarget, nonce, signature }) then
        pending[nonce] = nil
        return false, "Verteiler-Freigabe konnte nicht kodiert werden."
    end
    return true, boundTarget .. " wurde als Booster-Verteiler eingetragen."
end

function addon:ADM_SendDistributorRemoval(target)
    if not CanAdmin() then return false, "Nur die Arkana-Spielleitung darf Booster-Verteiler entfernen." end
    local boundTarget = CharacterName(target)
    if boundTarget == "" then return false, "Kein gültiges Ziel ausgewählt." end
    if addon.SEC_IsAdmin and addon:SEC_IsAdmin(boundTarget) then
        return false, "Mitglieder der Arkana-Spielleitung können nicht als Verteiler entfernt werden."
    end
    local nonce = Nonce()
    local signature = addon:SEC_MakeGrantSignature(
        "DISTRIBUTOR_REVOKE", boundTarget, nonce, "BOOSTER-V1")
    if not signature or not collectionAPI then return false, "Entfernung konnte nicht erzeugt werden." end
    TrackGrant(nonce, boundTarget, "DISTRIBUTOR_REVOKE")
    if not SendGrant(target, { "DISTRIBUTOR_REVOKE", boundTarget, nonce, signature }) then
        pending[nonce] = nil
        return false, "Entfernung konnte nicht kodiert werden."
    end
    return true, "Entfernung an " .. boundTarget .. " gesendet."
end

function addon:ADM_SendBoosters(target, amount, packType)
    if not CanDistribute() then return false, "Keine Berechtigung zur Booster-Verteilung." end
    local boundTarget = CharacterName(target)
    amount = math.floor(tonumber(amount) or 0)
    local ptype = BoosterType(packType)
    local isAdmin = CanAdmin()
    if boundTarget == "" then return false, "Kein gültiges Ziel ausgewählt." end
    if not ptype then return false, "Unbekannter Booster-Typ." end
    if not isAdmin and ptype ~= "C" then
        return false, "Verteiler dürfen nur Classic-Booster vergeben."
    end
    local maxAmount = isAdmin and 9 or 3
    if amount < 1 or amount > maxAmount then
        return false, "Menge muss zwischen 1 und " .. maxAmount .. " liegen."
    end
    if not collectionAPI then return false, "Verteilungsdaten sind nicht verfügbar." end

    local nonce = Nonce()
    local info = BOOSTER_TYPES[ptype]
    local payload = info.payload .. ":" .. amount
    local credential = not isAdmin and collectionAPI.GetDistributorCredential() or nil
    local signature, issuer, credentialNonce, credentialSignature =
        addon:SEC_MakeBoosterGrantSignature(boundTarget, nonce, payload, credential)
    if not signature then return false, "Booster-Freigabe konnte nicht erzeugt werden." end
    if boundTarget == MyName() then
        return collectionAPI.ApplyBoosterGrant(amount, nonce, signature, issuer,
            credentialNonce, credentialSignature, ptype)
    end
    TrackGrant(nonce, boundTarget, "Booster")
    if not SendGrant(target, { "BOOSTER", boundTarget, amount, nonce, signature,
            issuer, credentialNonce, credentialSignature, ptype }) then
        pending[nonce] = nil
        return false, "Booster-Freigabe konnte nicht kodiert werden."
    end
    return true, amount .. " " .. info.name .. "-Booster an " .. boundTarget .. " gesendet."
end

function addon:ADM_SendClassicBoosters(target, amount)
    return addon:ADM_SendBoosters(target, amount, "C")
end

function addon:ADM_OnComm(messageType, fields, sender, dist)
    if dist ~= "WHISPER" then return true end
    if messageType == "ADMACK" then
        if not CanDistribute() then return true end
        local nonce, record = fields[2], pending[fields[2]]
        if not nonce or not record or record.target ~= CharacterName(sender) then return true end
        pending[nonce] = nil
        local ok = fields[3] == "1"
        local message = fields[4] or (ok and "Freigabe bestätigt." or "Freigabe abgelehnt.")
        if ok and CanAdmin() then
            if record.kind == "DISTRIBUTOR" then
                SetDistributorRegistration(record.target, true)
            elseif record.kind == "DISTRIBUTOR_REVOKE" then
                SetDistributorRegistration(record.target, false)
            end
            if addon.ADM_UpdateDistributorSummary then addon:ADM_UpdateDistributorSummary() end
        end
        print((ok and "|cff00ff00[Arkana-Verteilung]|r " or
            "|cffff4040[Arkana-Verteilung]|r ") .. message)
        if addon.ADM_UpdateStatus then addon:ADM_UpdateStatus(message, ok) end
        return true
    end
    if messageType ~= "ADMGRANT" then return false end

    local cleartext = addon.SEC_OpenGrant and addon:SEC_OpenGrant(fields[2])
    if not cleartext then return true end
    local grant = Split(cleartext)
    local kind, target = grant[1], CharacterName(grant[2])
    if target ~= MyName() then return true end

    local ok, message, nonce
    if kind == "BASE" then
        if not addon.SEC_IsAdmin or not addon:SEC_IsAdmin(sender) then return true end
        if not grant[3] or not grant[4] or not collectionAPI then return true end
        nonce = grant[3]
        ok, message = collectionAPI.ApplyBaseGrant(grant[3], grant[4])
    elseif kind == "DISTRIBUTOR" then
        if not addon.SEC_IsAdmin or not addon:SEC_IsAdmin(sender) then return true end
        if not grant[3] or not grant[4] or not collectionAPI then return true end
        nonce = grant[3]
        ok, message = collectionAPI.ApplyDistributorGrant(grant[3], grant[4])
    elseif kind == "DISTRIBUTOR_REVOKE" then
        if not addon.SEC_IsAdmin or not addon:SEC_IsAdmin(sender) then return true end
        if not grant[3] or not grant[4] or not collectionAPI then return true end
        nonce = grant[3]
        ok, message = collectionAPI.ApplyDistributorRevocation(grant[3], grant[4])
    elseif kind == "BOOSTER" then
        if not grant[3] or not grant[4] or not grant[5] or not grant[6] or
           not grant[7] or not grant[8] or not collectionAPI then return true end
        if CharacterName(sender) ~= CharacterName(grant[6]) then return true end
        nonce = grant[4]
        ok, message = collectionAPI.ApplyBoosterGrant(grant[3], grant[4], grant[5],
            grant[6], grant[7], grant[8], grant[9] or "C")
    else
        return true
    end

    Whisper(sender, table.concat({ "ADMACK", nonce, ok and "1" or "0", tostring(message or "") }, "|"))
    print((ok and "|cff00ff00[Arkana]|r " or "|cffff4040[Arkana]|r ") .. tostring(message))
    if addon.BO_RefreshIfShown then addon:BO_RefreshIfShown() end
    return true
end
