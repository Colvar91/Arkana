local addon = Arkana
local PREFIX = "ARKANA"

-- ═══════════════════════════════════════════════════════════════════════════════
-- Kartenrücken-Skins: Registry, Freischalt-Codes (signiert, an Charakter gebunden),
-- Peer-Anzeige mit Verifikation, Galerie-Fenster (Deck-Builder-Button).
--
-- Integritätsmodell:
-- - Texturen sind lokal; was ANDERE sehen, entscheidet die per Netzwerk gesendete
--   Skin-ID + Signatur. Empfänger verifizieren die Signatur gegen Absendername +
--   Skin-ID — gefälschte Ansagen fallen auf den Standard-Rücken zurück.
-- - Bestehende Freischalt-Codes sind an den Charakternamen gebunden.
-- - Grenze: Der Prüfwert liegt offen im Addon und ist kein Servergeheimnis. Die
--   Signaturen erkennen versehentliche Änderungen, ersetzen aber keine serverseitige
--   Rechteprüfung. Maßgeblich bleibt zusätzlich der echte WoW-Absender.
-- ═══════════════════════════════════════════════════════════════════════════════

local CARD_TEX_V = 388 / 512
local BACK_DIR   = "Interface\\AddOns\\Arkana\\Textures\\CardBacks\\CardBack"
local DEFAULT_BACK = "Interface\\AddOns\\Arkana\\Textures\\card_back.tga"

-- Skin-Liste: der Tester bestimmt, welche IDs hier stehen (Textur = CardBack<id>.tga).
-- Platzhalter-Einträge bis die finale Auswahl feststeht.
local SKINS = {
    { id = 1,  name = "Sonne" },
    { id = 2,  name = "Smaragd" },
    { id = 3,  name = "Wolke" },
    { id = 43, name = "Weihnachten 1" },
    { id = 5,  name = "Legendär" },
    { id = 9,  name = "Seefahrt" },
    { id = 10, name = "Helloween" },
    { id = 13, name = "Weiß flamme" },
    { id = 17, name = "Panda" },
    { id = 20, name = "Gold" },
    { id = 36, name = "Dschungel" },
    { id = 40, name = "Kuchen" },
    { id = 64, name = "Taverne" },
    { id = 118, name = "Schatz" },
    { id = 125, name = "Horde_ally" },
    { id = 148, name = "Muschel" },
    { id = 159, name = "Legy 2" },
    { id = 176, name = "Leoly Back" },
    { id = 193, name = "Meere"},
    { id = 195, name = "Drache Legy" },
    { id = 197, name = "Koi Karpfen" },
    { id = 200, name = "Schlangen" },
    { id = 204, name = "Backwaren" },
    { id = 211, name = "Herbst" },
    { id = 226, name = "Tauren" },
    { id = 231, name = "Blutelf" },
    { id = 239, name = "Mensch (allianz)" },
    { id = 304, name = "Geschenk" },
    { id = 348, name = "Space" },
    { id = 379, name = "Drache 2" },
    { id = 404, name = "Rot /Grün" },
    { id = 408, name = "Weihnachten 2" },
    { id = 424, name = "Blut" },
    { id = 429, name = "Forscher" },
    { id = 434, name = "Insel" },
    { id = 444, name = "WoW Zeichen" },
    { id = 445, name = "Draenei" },
    { id = 479, name = "Lava Gold" },
    { id = 481, name = "Champion von Kitar" },
}
local SKIN_BY_ID = {}
for _, s in ipairs(SKINS) do SKIN_BY_ID[s.id] = s end

-- ── Signatur für bestehende Freischalt-Codes und Peer-Anzeigen ──────────────────
-- FNV-1a 32-Bit, zweifach mit verschiedenen Seeds; 32-Bit-Multiplikation gesplittet
-- (Lua-Doubles verlieren oberhalb 2^53 Präzision). Der Namespace bleibt absichtlich
-- lesbar; er ist Kompatibilitätswert für bestehende Codes, kein Geheimnis.
local SIGNATURE_NAMESPACE = "HsWoW-Geheim-2026-Schattenhain"

local function mul32(a, m)
    local ah, al = math.floor(a / 65536), a % 65536
    return (((ah * m) % 65536) * 65536 + al * m) % 4294967296
end

local function fnv32(str, seed)
    local h = seed
    for i = 1, #str do
        h = bit.bxor(h, str:byte(i))
        h = mul32(h, 16777619)
    end
    return h
end

local function Sig(charName, skinId)
    local msg = SIGNATURE_NAMESPACE .. "|" .. charName:lower() .. "|" .. tostring(skinId)
    return string.format("%08X%08X", fnv32(msg, 2166136261), fnv32(msg:reverse(), 40389)):upper()
end

-- Signierte Berechtigungen für Arkana-Karten-/Booster-Freigaben.
-- Der Absender wird zusätzlich durch WoWs nicht fälschbaren Comm-Sender geprüft.
-- Die Signatur ist ein clientseitiger Integritätsmarker. Ohne echten Server kann ein
-- vollständig veränderter Client nie zuverlässig als Autorität dienen.
-- Neue Signaturen binden Charakter und Realm. Der frühere realmlose Anker wird
-- ausschließlich beim Lesen bereits ausgegebener lokaler Freigaben akzeptiert.
local SIGNING_AUTHORITY = "annila-schattenhain"
local LEGACY_SIGNING_AUTHORITY = "annila"
-- Realmgebundener Integritätsnachweis für die lokale Karten-Sandbox. Der feste
-- Prüfwert verhindert, dass nur der Klarname in der Berechtigungsliste geändert
-- wird. Wie alle clientseitigen Prüfungen ist er kein Ersatz für Serverrechte.
local SANDBOX_ACCESS_PROOF = "039491AFF8E5BD2F"
local ADMIN_CHARACTERS = {
    ["annila-schattenhain"] = true,
    ["artinea-schattenhain"] = true,
    ["romash-schattenhain"] = true,
}

local function BaseName(name)
    return ((tostring(name or "")):match("^[^-]+") or ""):lower()
end

local function RealmName(realm)
    return tostring(realm or ""):gsub("%s+", ""):lower()
end

local function LocalRealm()
    local realm = GetNormalizedRealmName and GetNormalizedRealmName() or nil
    if not realm or realm == "" then
        local _, unitRealm
        if UnitFullName then _, unitRealm = UnitFullName("player") end
        if (not unitRealm or unitRealm == "") and UnitName then
            _, unitRealm = UnitName("player")
        end
        realm = unitRealm
    end
    return RealmName(realm)
end

-- Sicherheitsrelevante Identitäten enthalten immer den normalisierten Realm.
-- Namen ohne Realm stammen bei WoW von Einheiten des eigenen Realms und werden
-- deshalb ausschließlich an den lokalen Realm gebunden.
local function CharacterIdentity(name)
    local value = tostring(name or "")
    local character, realm = value:match("^([^-]+)%-(.+)$")
    if not character then character = value end
    character = character:lower()
    realm = RealmName(realm)
    if realm == "" then realm = LocalRealm() end
    if character == "" then return "" end
    return realm ~= "" and (character .. "-" .. realm) or character
end

local function IsLocalIdentity(name)
    local identity = CharacterIdentity(name)
    local realm = identity:match("^[^-]+%-(.+)$")
    local localRealm = LocalRealm()
    return realm ~= nil and localRealm ~= "" and realm == localRealm
end

local function LocalIdentity()
    local name, realm
    if UnitFullName then name, realm = UnitFullName("player") end
    if not name or name == "" then name, realm = UnitName("player") end
    if realm and realm ~= "" then return CharacterIdentity(name .. "-" .. realm) end
    return CharacterIdentity(name)
end

function addon:SEC_CharacterIdentity(name)
    return CharacterIdentity(name)
end

function addon:SEC_LocalIdentity()
    return LocalIdentity()
end

function addon:SEC_SigningAuthority()
    return SIGNING_AUTHORITY
end

function addon:SEC_IsSigningAuthority(name)
    local identity = CharacterIdentity(name)
    return identity == SIGNING_AUTHORITY or tostring(name or ""):lower() == LEGACY_SIGNING_AUTHORITY
end

local function GrantSig(kind, target, nonce, payload)
    local key = table.concat({ "grant", SIGNING_AUTHORITY, tostring(kind or ""), CharacterIdentity(target),
        tostring(nonce or ""), tostring(payload or "") }, "|")
    return Sig(key, "ARKANA-GRANT-V1")
end

-- Bereits ausgegebene Freigaben bleiben lesbar. Neue Nachrichten verwenden nur
-- noch die realmgebundene Variante; die Absenderprüfung ist ebenfalls realmgenau.
local function LegacyGrantSig(kind, target, nonce, payload)
    local key = table.concat({ "grant", LEGACY_SIGNING_AUTHORITY, tostring(kind or ""), BaseName(target),
        tostring(nonce or ""), tostring(payload or "") }, "|")
    return Sig(key, "ARKANA-GRANT-V1")
end

function addon:SEC_IsAdmin(name)
    return ADMIN_CHARACTERS[CharacterIdentity(name)] == true
end

function addon:SEC_CanUseSandbox()
    local identity = LocalIdentity()
    if identity ~= SIGNING_AUTHORITY then return false end
    return Sig("sandbox-access|" .. identity, "ARKANA-SANDBOX-V1") == SANDBOX_ACCESS_PROOF
end

function addon:SEC_MakeGrantSignature(kind, target, nonce, payload)
    -- Signaturen dürfen im unveränderten Client ausschließlich von eingetragenen
    -- Charakteren der Arkana-Spielleitung erzeugt werden. Geprüft wird der echte eingeloggte Charakter.
    if not addon:SEC_IsAdmin(LocalIdentity()) then return nil end
    return GrantSig(kind, target, nonce, payload)
end

function addon:SEC_ValidateGrantSignature(kind, target, nonce, payload, signature)
    if type(signature) ~= "string" then return false end
    signature = signature:upper()
    return signature == GrantSig(kind, target, nonce, payload) or
        (IsLocalIdentity(target) and signature == LegacyGrantSig(kind, target, nonce, payload))
end

local function DistributorGrantSig(issuer, target, nonce, payload, credentialNonce, credentialSignature)
    local key = table.concat({ "distributor-grant", CharacterIdentity(issuer), CharacterIdentity(target),
        tostring(nonce or ""), tostring(payload or ""), tostring(credentialNonce or ""),
        tostring(credentialSignature or ""):upper() }, "|")
    return Sig(key, "ARKANA-DISTRIBUTOR-GRANT-V1")
end

local function LegacyDistributorGrantSig(issuer, target, nonce, payload, credentialNonce, credentialSignature)
    local key = table.concat({ "distributor-grant", BaseName(issuer), BaseName(target),
        tostring(nonce or ""), tostring(payload or ""), tostring(credentialNonce or ""),
        tostring(credentialSignature or ""):upper() }, "|")
    return Sig(key, "ARKANA-DISTRIBUTOR-GRANT-V1")
end

function addon:SEC_ValidateDistributorCredential(name, nonce, signature)
    if type(signature) ~= "string" then return false end
    local identity = CharacterIdentity(name)
    signature = signature:upper()
    return signature == GrantSig("DISTRIBUTOR", identity, nonce, "BOOSTER-V1") or
        (IsLocalIdentity(identity) and
            signature == LegacyGrantSig("DISTRIBUTOR", identity, nonce, "BOOSTER-V1"))
end

-- Die Arkana-Spielleitung kann direkt signieren. Eingetragene Verteiler müssen
-- zusätzlich ihren charaktergebundenen, von der Spielleitung signierten Nachweis vorlegen.
function addon:SEC_MakeBoosterGrantSignature(target, nonce, payload, credential)
    local issuer = LocalIdentity()
    if addon:SEC_IsAdmin(issuer) then
        return GrantSig("BOOSTER", target, nonce, payload), issuer, "-", "-"
    end
    -- Eingetragene Verteiler dürfen ausschließlich Classic-Booster signieren.
    -- Die Prüfung liegt bewusst unterhalb der UI, damit ein veränderter Client
    -- Custom-/Legendär-Grants nicht durch direkten Funktionsaufruf erzeugen kann.
    if not tostring(payload or ""):match("^CLASSIC:%d+$") then return nil end
    if type(credential) ~= "table" or credential.v ~= 1 or
       not addon:SEC_ValidateDistributorCredential(issuer, credential.nonce, credential.signature) then
        return nil
    end
    local credentialNonce = tostring(credential.nonce)
    local credentialSignature = tostring(credential.signature):upper()
    return DistributorGrantSig(issuer, target, nonce, payload, credentialNonce, credentialSignature),
        issuer, credentialNonce, credentialSignature
end

function addon:SEC_ValidateBoosterGrantSignature(issuer, target, nonce, payload, signature,
                                                  credentialNonce, credentialSignature)
    issuer = CharacterIdentity(issuer)
    if addon:SEC_IsAdmin(issuer) then
        return addon:SEC_ValidateGrantSignature("BOOSTER", target, nonce, payload, signature)
    end
    if not tostring(payload or ""):match("^CLASSIC:%d+$") then return false end
    if not addon:SEC_ValidateDistributorCredential(issuer, credentialNonce, credentialSignature) then
        return false
    end
    if type(signature) ~= "string" then return false end
    signature = signature:upper()
    return signature == DistributorGrantSig(
        issuer, target, nonce, payload, credentialNonce, credentialSignature) or
        (IsLocalIdentity(issuer) and signature == LegacyDistributorGrantSig(
            issuer, target, nonce, payload, credentialNonce, credentialSignature))
end

local function MakeBoosterItem(packType, serialId)
    local ptype = tostring(packType or "C"):upper()
    local serial = tostring(serialId or ""):upper():gsub("[^%x]", ""):sub(1, 12)
    if not ({ C = true, X = true, L = true })[ptype] or #serial ~= 12 then return nil end
    return ptype .. serial .. Sig("booster|" .. ptype .. "|" .. serial, "ARKANA-BOOSTER-V1")
end

local BOOSTER_PAYLOAD = { C = "CLASSIC", X = "CUSTOM", L = "LEGENDARY" }
local function BoosterType(packType)
    local ptype = tostring(packType or "C"):upper()
    return BOOSTER_PAYLOAD[ptype] and ptype or nil
end

-- Booster-Items werden nur aus einer bereits gültigen, charaktergebundenen
-- Spielleitungs-Freigabe abgeleitet. Es gibt bewusst keine öffentlich erreichbare
-- Funktion mehr, die beliebige Booster-Serials signiert.
function addon:SEC_ItemsFromBoosterGrant(issuer, target, amount, nonce, signature,
                                         credentialNonce, credentialSignature, packType)
    amount = math.floor(tonumber(amount) or 0)
    local ptype = BoosterType(packType)
    local maxAmount = addon:SEC_IsAdmin(issuer) and 9 or 3
    if not ptype or amount < 1 or amount > maxAmount then return nil end
    if not addon:SEC_IsAdmin(issuer) and ptype ~= "C" then return nil end
    local payload = BOOSTER_PAYLOAD[ptype] .. ":" .. amount
    if not addon:SEC_ValidateBoosterGrantSignature(issuer, target, nonce, payload, signature,
            credentialNonce, credentialSignature) then return nil end
    local items = {}
    for i = 1, amount do
        local serialSeed = table.concat({ "booster-grant", CharacterIdentity(issuer), CharacterIdentity(target),
            ptype, tostring(nonce), tostring(i) }, "|")
        local raw = string.format("%08X%04X", fnv32(serialSeed, 2166136261), i)
        local item = MakeBoosterItem(ptype, raw)
        if not item then return nil end
        items[#items + 1] = item
    end
    return items
end

function addon:SEC_ValidateBoosterItem(item)
    local ptype, serial, signature = tostring(item or ""):upper():match("^([CXL])(%x%x%x%x%x%x%x%x%x%x%x%x)(%x+)$")
    if not ptype or #signature ~= 16 then return false end
    return signature == Sig("booster|" .. ptype .. "|" .. serial, "ARKANA-BOOSTER-V1"), ptype
end

local function MyName()
    return (UnitName("player") or ""):match("^[^-]+")
end

-- ── Transparente Ablage der Charakterdaten ───────────────────────────────────────
-- Neue Spielstände bleiben als normale, lesbare SavedVariables-Tabelle erhalten.
-- Die folgenden Decoder existieren ausschließlich für die einmalige Übernahme des
-- bis Build -au verwendeten Legacy-Formats; gespeichert wird dieses Format nie mehr.
local storeBroken = false
-- read() ist gelaufen UND die Ablage liegt entpackt vor. Ohne das darf NICHTS den
-- Spielstand melden oder zurückschreiben: eine ungelesene Ablage sieht exakt aus wie
-- ein leerer Charakter (Sammlung 0, keine Warnung) — genau der Fall, den die Tester
-- als "Karten nach dem Ausloggen weg" gemeldet haben.
local storeReady = false

-- Legacy-Decoder. Nicht für neue Daten oder Netzwerkverkehr verwenden.
local function step(h) return (mul32(h, 1103515245) + 12345) % 4294967296 end
local function legacySeed() return fnv32(SIGNATURE_NAMESPACE .. "|cd|", 2166136261) end

local function LegacyFromStore(s)
    local h, out, n = legacySeed(), {}, 0
    for pair in s:gmatch("%x%x") do
        n = n + 1
        h = step(h)
        out[n] = string.char(bit.bxor(tonumber(pair, 16), math.floor(h / 65536) % 256))
    end
    if n * 2 ~= #s then return nil end   -- Fremdzeichen dazwischen → Versatz, nicht verwertbar
    return table.concat(out)
end

local function HexEncode(value)
    local out = {}
    for i = 1, #value do out[i] = string.format("%02X", value:byte(i)) end
    return table.concat(out)
end

local function HexDecode(value)
    if value == "" or #value % 2 ~= 0 or not value:match("^%x+$") then return nil end
    local out = {}
    for i = 1, #value, 2 do out[#out + 1] = string.char(tonumber(value:sub(i, i + 1), 16)) end
    return table.concat(out)
end

-- Freigaben werden wegen des Feldtrenners reversibel hex-kodiert und mit einem
-- Integritätsmarker versehen. Das ist ausdrücklich keine Verschlüsselung.
function addon:SEC_SealGrant(payload)
    payload = tostring(payload or "")
    if payload == "" then return nil end
    local encoded = HexEncode(payload)
    local signature = Sig("wire-plain|" .. encoded, "ARKANA-GRANT-WIRE-P1")
    return "P1" .. encoded .. signature
end

function addon:SEC_OpenGrant(envelope)
    envelope = tostring(envelope or ""):upper()
    if envelope:sub(1, 2) ~= "P1" or #envelope < 20 then return nil end
    local signature = envelope:sub(-16)
    local encoded = envelope:sub(3, -17)
    if signature ~= Sig("wire-plain|" .. encoded, "ARKANA-GRANT-WIRE-P1") then return nil end
    return HexDecode(encoded)
end

local function LegacyStoreSig(payload)
    local msg = SIGNATURE_NAMESPACE .. "|cdv|" .. payload
    return string.format("%08X%08X", fnv32(msg, 2166136261), fnv32(msg:reverse(), 40389)):upper()
end

addon._Store = {}

-- Sind die Charakterdaten benutzbar? Audit und Abmelden fragen das vorher.
function addon._Store.ready() return storeReady and not storeBroken end

function addon._Store.read()
    local t = ARKANA_CharData
    if type(t) ~= "table" or t.v ~= 1 or type(t.d) ~= "string" or type(t.s) ~= "string" then
        storeReady = true
        return
    end
    local ok, val = false, nil
    local payload = LegacyFromStore(t.d)
    if payload and t.s == LegacyStoreSig(payload) then
        ok, val = LibStub("AceSerializer-3.0"):Deserialize(payload)
    end
    if not ok or type(val) ~= "table" then
        -- NICHT zurücksetzen: die Ablage bleibt unangetastet auf der Platte, damit der
        -- Betreiber die Ablage prüfen und aus einer Dateisicherung reparieren kann.
        storeBroken = true
        print("|cffff0000[Arkana]|r Deine Charakterdaten konnten nicht gelesen werden. " ..
              "Bitte den Betreiber ansprechen — der Spielstand ist noch da und wird nicht überschrieben.")
        return
    end
    ARKANA_CharData = val
    storeReady = true
    print("|cff00ff00[Arkana]|r Charakterdaten wurden einmalig in das transparente SavedVariables-Format übernommen.")
end

function addon._Store.write()
    -- Nur zurückschreiben, was auch gelesen wurde. Lief read() nicht durch (Ladefehler
    -- eines früheren Moduls, abgebrochenes OnInitialize), steht hier ein FRISCH
    -- angelegter, leerer Spielstand — der würde den echten überschreiben.
    if storeBroken or not storeReady then return end
    local t = ARKANA_CharData
    if type(t) ~= "table" then return end
    -- Die kontoweiten Namen zeigen auf dieselben Tabellen (Alias aus Main.lua) und
    -- werden beim Anmelden ohnehin neu gesetzt — nicht zusätzlich duplizieren.
    ARKANA_Decks, ARKANA_Stats, ARKANA_ActionLog = nil, nil, nil
end

-- ── Besitz & Auswahl (per Charakter, ARKANA_CharData in .toc) ────────────────────

local function Data()
    ARKANA_CharData = ARKANA_CharData or {}
    ARKANA_CharData.cardBacks = ARKANA_CharData.cardBacks or { owned = {} }
    return ARKANA_CharData.cardBacks
end

local function Owns(skinId)
    local d = Data()
    local code = d.owned[skinId]
    -- Besitz wird bei jedem Zugriff gegen die Signatur geprüft — ein per
    -- SavedVariables-Edit eingetragener Skin ohne gültigen Code zählt nicht.
    return code ~= nil and code == Sig(MyName(), skinId)
end

local function Selected()
    local d = Data()
    if d.selected and Owns(d.selected) then return d.selected end
    return nil
end

-- ── Freischalt-Popup: großes Bild des erhaltenen Items + Schließen-Button ────────
-- Erscheint bei jedem erfolgreichen Einlösen, höchste Ebene.
local unlockPopup
function addon:ShowUnlockPopup(title, tex, u2, v2)
    if not unlockPopup then
        local f = CreateFrame("Frame", "ARKANA_UnlockPopup", UIParent, "BasicFrameTemplateWithInset")
        f:SetSize(300, 460)
        f:SetPoint("CENTER")
        f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        f:SetFrameStrata("TOOLTIP")     -- höchste Ebene: über allen Fenstern
        f:SetFrameLevel(9000)
        if addon.UI_RegisterScalableFrame then addon:UI_RegisterScalableFrame(f) end
        f.art = f:CreateTexture(nil, "ARTWORK")
        f.art:SetPoint("TOPLEFT", 20, -32)
        f.art:SetPoint("BOTTOMRIGHT", -20, 48)
        local close = CreateFrame("Button", nil, f, "GameMenuButtonTemplate")
        close:SetSize(120, 24)
        close:SetPoint("BOTTOM", 0, 14)
        close:SetText("Schließen")
        close:SetScript("OnClick", function() f:Hide() end)
        unlockPopup = f
    end
    unlockPopup.TitleText:SetText(title or "Freigeschaltet!")
    unlockPopup.art:SetTexture(tex)
    unlockPopup.art:SetTexCoord(0, u2 or 1, 0, v2 or 1)
    unlockPopup:Show()
end

-- Freischalt-Code einlösen — ein Format für beides:
--   Kartenrücken: "SKINID-XXXX-XXXX-XXXX-XXXX"   (numerischer Kopf)
--   Karten-Skin:  "CARDID_N-XXXX-XXXX-XXXX-XXXX" (Skin-Key als Kopf)
function addon:CB_Redeem(codeStr)
    codeStr = (codeStr or ""):upper():gsub("%s", "")
    local head, h1, h2, h3, h4 = codeStr:match("^(.+)%-(%x%x%x%x)%-(%x%x%x%x)%-(%x%x%x%x)%-(%x%x%x%x)$")
    if not head then return false, "Ungültiges Code-Format." end
    local hex = h1 .. h2 .. h3 .. h4
    -- Alte Booster-Codes werden bewusst nicht mehr angenommen.
    if head:match("^BP") then
        return false, "Diese alten Booster-Codes werden nicht mehr unterstützt."
    end
    local backId = tonumber(head)
    if backId then
        if not SKIN_BY_ID[backId] then return false, "Unbekannter Kartenrücken." end
        if hex ~= Sig(MyName(), backId) then
            return false, "Code ungültig (falscher Charakter oder Tippfehler?)."
        end
        Data().owned[backId] = hex
        addon:ShowUnlockPopup(SKIN_BY_ID[backId].name, addon:CB_Texture(backId), 1, CARD_TEX_V)
        return true, SKIN_BY_ID[backId].name .. " freigeschaltet!"
    end
    -- Helden-Skin? (Registry weiter unten; Keys case-insensitiv, Code kommt upper)
    if addon:HS_KeyByAny(head) then return addon:HS_RedeemKey(head, hex) end
    -- Karten-Skin (Registry + Redeem weiter unten in dieser Datei)
    return addon:CS_RedeemKey(head, hex)
end

-- Anfrage-Code für den Tester: Charaktername + Prüfziffer (gegen Tippfehler)
function addon:CB_RequestCode()
    local name = MyName()
    return name .. "-" .. string.format("%04X", fnv32("REQ|" .. name:lower(), 2166136261) % 65536)
end

-- ── Texturen für die Spiel-UI ───────────────────────────────────────────────────

local peerBackId  = nil   -- verifizierter Rücken des aktuellen Gegners (nil = Standard)
local peerBackSig = nil   -- dessen Signatur (für Zuschauer-Weiterleitung durch den Host)

-- Zuschauer-Sicht: vom Host verteilte, selbst nachverifizierte Kosmetik beider Spieler.
-- Seite 1 = P1/Host (unten im Zuschauer-Board), Seite 2 = P2.
local specCosm = nil      -- { backs = {id,id}, skins = { {cardId=key}, {cardId=key} } }

local function Spectating() return addon.IsSpectating and addon:IsSpectating() end

function addon:CB_Texture(skinId)
    if skinId and SKIN_BY_ID[skinId] then return BACK_DIR .. skinId .. ".tga" end
    return DEFAULT_BACK
end

function addon:CB_MyBackTexture()
    if Spectating() then return addon:CB_Texture(specCosm and specCosm.backs[1]) end
    return addon:CB_Texture(Selected())
end

function addon:CB_PeerBackTexture()
    if Spectating() then return addon:CB_Texture(specCosm and specCosm.backs[2]) end
    return addon:CB_Texture(peerBackId)
end

-- ═══ Karten-Skins ═══════════════════════════════════════════════════════════════
-- Alternative Karten-Arts. Gleiche Sicherheitslogik wie Kartenrücken; eigener
-- Sig-Namespace "skin:<key>" (kollidiert nie mit numerischen Rücken-IDs).
-- Textur-Konvention: Textures\CardSkins\<key>.tga, key = "<cardId>_<n>".
-- Tester kuratiert die Liste; Demo-Einträge zeigen auf vorhandene Karten-Arts.

local CARD_SKINS = {
	{ key = "Tarijan", cardId = "EX1_334", name = "Tarijan",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Tarijan" },
	{ key = "Tarijan_1", cardId = "EX1_334", name = "Tarijan Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Tarijan_1" },
	{ key = "Leoly", cardId = "EX1_559", name = "Königin Leoly",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Leoly" },
	{ key = "Leoly_1", cardId = "EX1_559", name = "Leoly Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Leoly_1" },
	{ key = "Artinea", cardId = "EX1_306", name = "Artinea",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Artinea" },
	{ key = "Artinea_1", cardId = "EX1_306", name = "Artinea Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Artinea_1" },
	{ key = "Weishan", cardId = "EX1_100", name = "Weishahn",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Weishan" },
	{ key = "Weishan_1", cardId = "EX1_100", name = "Weishan Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Weishan_1" },
	{ key = "Adrian", cardId = "EX1_557", name = "Adrian",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Adrian" },
	{ key = "Adrian_1", cardId = "EX1_557", name = "Adrian Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Adrian_1" },
	{ key = "Telnarion", cardId = "EX1_012", name = "Telnarion",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Telnarion" },
	{ key = "Telnarion_1", cardId = "EX1_012", name = "Telnarion Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Telnarion_1" },
	{ key = "Valesdra", cardId = "EX1_046", name = "Valesdra",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Valesdra" },
	{ key = "Valesdra_1", cardId = "EX1_046", name = "Valesdra Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Valesdra_1" },
	{ key = "Sanford", cardId = "EX1_095", name = "Sanford",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Sanford" },
	{ key = "Sanford_1", cardId = "EX1_095", name = "Sanford Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Sanford_1" },
	{ key = "Kelanis", cardId = "EX1_383", name = "Kelanis",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Kelanis" },
	{ key = "Kelanis_1", cardId = "EX1_383", name = "Kelanis Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Kelanis_1" },
	{ key = "Shino", cardId = "EX1_110", name = "Shino",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Shino" },
	{ key = "Shino_1", cardId = "EX1_110", name = "Shino Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Shino_1" },
	{ key = "Ishandriel", cardId = "CS2_189", name = "Ishandriel",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Ishandriel" },
	{ key = "Ishandriel_1", cardId = "CS2_189", name = "Ishandriel Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Ishandriel_1" },
	{ key = "Tharandir", cardId = "EX1_017", name = "Tharandir",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Tharandir" },
	{ key = "Tharandir_1", cardId = "EX1_017", name = "Tharandir Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Tharandir_1" },
	{ key = "Maran", cardId = "EX1_028", name = "Maran",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Maran" },
	{ key = "Maran_1", cardId = "EX1_028", name = "Maran Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Maran_1" },
	{ key = "Nyrella", cardId = "EX1_016", name = "Nyrella",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Nyrella" },
	{ key = "Nyrella_1", cardId = "EX1_016", name = "Nyrella Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Nyrella_1" }, 
	{ key = "Adare", cardId = "CS2_187", name = "Adare",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Adare" },
	{ key = "Adare_1", cardId = "CS2_187", name = "Adare Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Adare_1" }, 
	{ key = "Celina", cardId = "CS2_155", name = "Celina",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Celina" },
	{ key = "Celina_1", cardId = "CS2_155", name = "Celina Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Celina_1" }, 
	{ key = "Lincy", cardId = "CS2_027", name = "Lincy",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Lincy_Zauber" },
	{ key = "Lincy_1", cardId = "CS2_027", name = "Lincy Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Lincy_Zauber_1" },
	{ key = "Lincy_Token", cardId = "CS2_mirror", name = "Lincy_Token",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Lincy_Token" },
	{ key = "Lincy_Token_1", cardId = "CS2_mirror", name = "Lincy_Token Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Lincy_Token_1" },
	{ key = "Akheras", cardId = "DS1_070", name = "Akheras",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Akheras" },
	{ key = "Akheras_1", cardId = "DS1_070", name = "Akheras Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Akheras_1" },
	{ key = "Esther", cardId = "EX1_298", name = "Esther",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Esther" },
	{ key = "Esther_1", cardId = "EX1_298", name = "Esther Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Esther_1" },
	{ key = "Rizz", cardId = "EX1_082", name = "Rizz",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Rizz" },
	{ key = "Rizz_1", cardId = "EX1_082", name = "Rizz Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Rizz_1" },
	{ key = "Shari", cardId = "EX1_002", name = "Shari",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Shari" },
	{ key = "Shari_1", cardId = "EX1_002", name = "Shari Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Shari_1" },
	{ key = "Naylan", cardId = "EX1_613", name = "Naylan",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Naylan" },
	{ key = "Naylan_1", cardId = "EX1_613", name = "Naylan Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Naylan_1" },
    { key = "Vaylinn", cardId = "EX1_591", name = "Vaylinn",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Vaylinn" },
    { key = "Vaylinn_1", cardId = "EX1_591", name = "Vaylinn Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Vaylinn_1" },
    { key = "Zaazel", cardId = "EX1_043", name = "Zaazel",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Zaazel" },
    { key = "Zaazel_1", cardId = "EX1_043", name = "Zaazel Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Zaazel_1" },
    { key = "Arylissa", cardId = "EX1_093", name = "Arylissa",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Arylissa" },
    { key = "Arylissa_1", cardId = "EX1_093", name = "Arylissa Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Arylissa_1" },
    { key = "Ragnar", cardId = "EX1_116", name = "Ragnar",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Ragnar" },
    { key = "Ragnar_1", cardId = "EX1_116", name = "Ragnar Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Ragnar_1" },
    { key = "Narandor", cardId = "CS2_125", name = "Narandor",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Narandor" },
    { key = "Narandor_1", cardId = "CS2_125", name = "Narandor Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Narandor_1" },
    { key = "Velandra", cardId = "EX1_019", name = "Velandra",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Velandra" },
    { key = "Velandra_1", cardId = "EX1_019", name = "Velandra Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Velandra_1" },
    { key = "Bishop", cardId = "CS2_146", name = "Bishop",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Bishop" },
    { key = "Bishop_1", cardId = "CS2_146", name = "Bishop Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Bishop_1" },
    { key = "Korveliath", cardId = "EX1_350", name = "Korveliath",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Korveliath" },
    { key = "Korveliath_1", cardId = "EX1_350", name = "Korveliath Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Korveliath_1" },
    { key = "Theri", cardId = "NEW1_026", name = "Theri",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Theri" },
    { key = "Theri_1", cardId = "NEW1_026", name = "Theri Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Theri_1" },    
    { key = "Alani", cardId = "EX1_612", name = "Alani",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Alani" },
    { key = "Alani_1", cardId = "EX1_612", name = "Alani Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Alani_1" },
    { key = "Ewelina", cardId = "NEW1_021", name = "Ewelina",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Ewelina" },
    { key = "Ewelina_1", cardId = "NEW1_021", name = "Ewelina Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Ewelina_1" },
    { key = "Nereza", cardId = "CS2_141", name = "Nereza",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Nereza" },
    { key = "Nereza_1", cardId = "CS2_141", name = "Nereza Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Nereza_1" },
    { key = "Lodric", cardId = "EX1_059", name = "Lodric",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Lodric" },
    { key = "Lodric_1", cardId = "EX1_059", name = "Lodric Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Lodric_1" },
    { key = "Chiaki", cardId = "EX1_001", name = "Chiaki",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Chiaki" },
    { key = "Chiaki_1", cardId = "EX1_001", name = "Chiaki Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Chiaki_1" },
    { key = "Xalaren", cardId = "EX1_575", name = "Xalaren",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Xalaren" },
    { key = "Xalaren_1", cardId = "EX1_575", name = "Xalaren Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Xalaren_1" },
    { key = "Krazzix", cardId = "CS2_227", name = "Krazzix",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Krazzix" },
    { key = "Krazzix_1", cardId = "CS2_227", name = "Krazzix Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Krazzix_1" },
    { key = "Alani+Artinea", cardId = "NEW1_026t", name = "Alani + Artinea",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Alani+Artinea" },
    { key = "Alani+Artinea_1", cardId = "NEW1_026t", name = "Alani + Artinea Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Alani+Artinea_1" },
    { key = "Venisa", cardId = "EX1_249", name = "Venisa",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Venisa" },
    { key = "Venisa_1", cardId = "EX1_249", name = "Venisa Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Venisa_1" },
    { key = "Annila", cardId = "EX1_166", name = "Annila",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Annila" },
    { key = "Annila_1", cardId = "EX1_166", name = "Annila Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Annila_1" },
    { key = "Lumina", cardId = "CS2_235", name = "Lumina",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Lumina" },
    { key = "Lumina_1", cardId = "CS2_235", name = "Lumina Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Lumina_1" },
    { key = "Bria", cardId = "EX1_033", name = "Bria",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Bria" },
    { key = "Bria_1", cardId = "EX1_033", name = "Bria Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Bria_1" },
    { key = "Pepe", cardId = "EX1_572", name = "Pepe",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Pepe" },
    { key = "Pepe_1", cardId = "EX1_572", name = "Pepe Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Pepe_1" },
    { key = "Sammler", cardId = "EX1_561", name = "Sammler",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Sammler" },
    { key = "Sammler_1", cardId = "EX1_561", name = "Sammler Signatur",
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Sammler_1" },

    -- ── Turnier-Skins ───────────────────────────────────────────────────────────
    -- Eigene Kategorie für Turnierpreise. Immer ans ENDE der Registry anhängen —
    -- die Basis-/Signatur-Pools bleiben dadurch unverändert (ungeöffnete Packs
    -- würfeln weiter wie bisher).
    { key = "Turnier1_p1", cardId = "EX1_563", name = "#1 Artinea", tourney = true,
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Turnier1_p1" },
    { key = "Turnier1_p2", cardId = "EX1_563", name = "#2 Artinea", tourney = true,
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Turnier1_p2" },
    { key = "Turnier1_p3", cardId = "EX1_563", name = "#3 Artinea", tourney = true,
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Turnier1_p3" },
    { key = "Hanniball_T1_T", cardId = "CS2_171", name = "TeilnehmerSkin 1", tourney = true,
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Hanniball_T1_T" },
    { key = "Quieker_T2_T", cardId = "CS2_059", name = "TeilnehmerSkin 2", tourney = true,
      tex = "Interface\\AddOns\\Arkana\\Textures\\CustomCards\\Quieker_T2_T" },
}
local SKIN_BY_KEY = {}
for _, s in ipairs(CARD_SKINS) do SKIN_BY_KEY[s.key] = s end

local peerSkins = {}   -- [cardId] = key — verifizierte Skins des aktuellen Gegners

local function SkinTex(key)
    local s = SKIN_BY_KEY[key]
    if not s then return nil end
    return s.tex or ("Interface\\AddOns\\Arkana\\Textures\\CardSkins\\" .. key .. ".tga")
end

local function SData()
    ARKANA_CharData = ARKANA_CharData or {}
    local cs = ARKANA_CharData.cardSkins or {}
    ARKANA_CharData.cardSkins = cs
    cs.owned = cs.owned or {}
    cs.selected = cs.selected or {}   -- [cardId] = key (max. 1 Skin pro Karte)
    return cs
end

-- Key wird für die Signatur normalisiert (upper).
local function SkinSig(name, key) return Sig(name, "skin:" .. key:upper()) end

local function OwnsSkin(key)
    local d = SData()
    return d.owned[key] ~= nil and d.owned[key] == SkinSig(MyName(), key)
end

-- Auswahl pro Karte: LISTE von Skin-Keys (Mehrfach-Auswahl für Karten, die mehrere
-- Diener beschwören). Alt-Format (einzelner String aus früheren Builds) wird
-- transparent als 1-elementige Liste gelesen.
local function SelectedSkins(cardId)
    local sel = SData().selected[cardId]
    if type(sel) == "string" then return { sel } end
    return sel or {}
end

local function IsSkinSelected(cardId, key)
    for _, k in ipairs(SelectedSkins(cardId)) do
        if k == key then return true end
    end
    return false
end

-- Varianten-Wahl bei Mehrfach-Auswahl: deterministisch über die entityId — die ist
-- durch die Lockstep-Engine auf beiden Clients und bei Zuschauern IDENTISCH, alle
-- sehen also dieselbe Variante. Ohne entityId (Hand/Tooltip/Animation): Variante 1.
local function PickVariant(list, entityId)
    if type(list) == "string" then return list end   -- Alt-Format (Peer mit altem Build)
    if not list or #list == 0 then return nil end
    local i = entityId and (math.floor(entityId) % #list) + 1 or 1
    return list[i]
end

-- Von CB_Redeem gerufen (einheitliches Code-Format). Der Code kommt upper-case
-- an — Keys mit kleingeschriebenen Karten-IDs (z.B. tt_010_1) case-insensitiv finden.
function addon:CS_RedeemKey(key, hex)
    if not SKIN_BY_KEY[key] then
        for k in pairs(SKIN_BY_KEY) do
            if k:upper() == key then key = k; break end
        end
    end
    if not SKIN_BY_KEY[key] then return false, "Unbekannter Karten-Skin." end
    if hex ~= SkinSig(MyName(), key) then
        return false, "Code ungültig (falscher Charakter oder Tippfehler?)."
    end
    SData().owned[key] = hex
    addon:ShowUnlockPopup(SKIN_BY_KEY[key].name, SkinTex(key), 1, CARD_TEX_V)
    return true, SKIN_BY_KEY[key].name .. " freigeschaltet!"
end

-- Legende-Belohnung (aus Ranked.lua): Rücken lokal freischalten.
function addon:CB_GrantLegendBack(backId)
    if not SKIN_BY_ID[backId] or Owns(backId) then return end
    Data().owned[backId] = Sig(MyName(), backId)
    print("|cffffd700[Arkana-Ranked]|r Kartenrücken '" .. SKIN_BY_ID[backId].name ..
          "' freigeschaltet — Legende erreicht!")
    addon:ShowUnlockPopup(SKIN_BY_ID[backId].name, addon:CB_Texture(backId), 1, CARD_TEX_V)
end

function addon:CB_OwnsBack(backId)
    return Owns(backId)
end

function addon:CB_BackName(backId)
    local s = SKIN_BY_ID[tonumber(backId)]
    return s and s.name
end

function addon:CS_OwnsSkin(key)
    return OwnsSkin(key)
end

function addon:CS_Texture(key)
    return SkinTex(key)
end

-- Art-Override für die Spiel-UI: nil = Original-Art verwenden.
-- Zuschauer: isMine entspricht der P1-Seite (unten) des Zuschauer-Boards.
-- entityId (optional): wählt bei Mehrfach-Auswahl die Variante — deterministisch,
-- alle Clients sehen dieselbe (ohne entityId immer Variante 1).
function addon:CS_ArtFor(cardId, isMine, entityId)
    if Spectating() then
        local m = specCosm and specCosm.skins[isMine and 1 or 2]
        local key = PickVariant(m and m[cardId], entityId)
        return key and SkinTex(key) or nil
    end
    if isMine then
        local ownedSel = {}
        for _, k in ipairs(SelectedSkins(cardId)) do
            if OwnsSkin(k) then ownedSel[#ownedSel + 1] = k end
        end
        local key = PickVariant(ownedSel, entityId)
        if key then return SkinTex(key) end
    else
        local key = PickVariant(peerSkins[cardId], entityId)
        if key then return SkinTex(key) end
    end
    return nil
end

-- Für Animationen ohne Besitzer-Info: Gegner-Skin vor eigenem.
-- kollidiert nur, wenn beide Spieler DIESELBE Karte unterschiedlich
-- skinnen — dann gewinnt der Gegner-Skin. Besitzer-Durchreichung durch alle
-- Animationspfade erst, falls das je auffällt.
function addon:CS_AnyArt(cardId, entityId)
    return addon:CS_ArtFor(cardId, false, entityId) or addon:CS_ArtFor(cardId, true, entityId)
end

-- ── Netzwerk: eigenen Skin ansagen, Gegner-Skin verifizieren ───────────────────

-- Von Network.lua bei Spielstart gerufen (beide Seiten). Sendet Kartenrücken
-- (CBACK) und die Liste der gewählten Karten-Skins (CSKIN, je Key signiert).
function addon:CB_OnGameStart(peerName)
    peerBackId = nil
    peerSkins = {}
    if addon.HS_OnGameStart then addon:HS_OnGameStart(peerName) end   -- Helden-Skins (Reset + Ansage)
    if not peerName then return end
    local sel = Selected()
    if sel then
        addon:SendCommMessage(PREFIX, string.format("CBACK|%d|%s", sel, Data().owned[sel]), "WHISPER", peerName)
    end
    local parts = {}
    for cardId in pairs(SData().selected) do
        for _, key in ipairs(SelectedSkins(cardId)) do
            if OwnsSkin(key) then parts[#parts + 1] = key .. ":" .. SData().owned[key] end
        end
    end
    if #parts > 0 then
        addon:SendCommMessage(PREFIX, "CSKIN|" .. table.concat(parts, ","), "WHISPER", peerName)
    end
    if addon.Spec_CosmChanged then addon:Spec_CosmChanged() end   -- Host: eigene Kosmetik an Zuschauer
end

-- CSKIN|key1:sig1,key2:sig2 vom Gegner: nur verifizierte Einträge übernehmen
local peerSkinRaw = nil   -- verifizierte Rohliste (für Zuschauer-Weiterleitung durch den Host)
function addon:CS_OnComm(p, sender)
    local senderName = (sender or ""):match("^[^-]+")
    peerSkins = {}
    local raw = {}
    for key, sig in (p[2] or ""):gmatch("([^:,]+):([^:,]+)") do
        local skin = SKIN_BY_KEY[key]
        if skin and sig == SkinSig(senderName, key) then
            local l = peerSkins[skin.cardId] or {}
            peerSkins[skin.cardId] = l
            l[#l + 1] = key
            raw[#raw + 1] = key .. ":" .. sig
        end
    end
    peerSkinRaw = (#raw > 0) and table.concat(raw, ",") or nil
    if addon.Spec_CosmChanged then addon:Spec_CosmChanged() end   -- Host: an Zuschauer weiterreichen
    if addon.Board_Update then addon:Board_Update() end
end

-- ── Zuschauer-Kosmetik: Host verteilt beide Seiten (signiert, Zuschauer verifizieren) ──
-- Format: SPECCOSM|<sid>|<p1Name>|<p1Back:sig oder ->|<p1Skins oder ->|<p2Name>|<p2Back:sig>|<p2Skins>

-- Vom Host (Spectator.lua) gerufen, baut die aktuelle Kosmetik-Nachricht
function addon:CB_SpecCosmMsg(sessionId)
    local myBackPart, mySkinPart = "-", "-"
    local sel = Selected()
    if sel then myBackPart = sel .. ":" .. Data().owned[sel] end
    local parts = {}
    for cardId in pairs(SData().selected) do
        for _, key in ipairs(SelectedSkins(cardId)) do
            if OwnsSkin(key) then parts[#parts + 1] = key .. ":" .. SData().owned[key] end
        end
    end
    if #parts > 0 then mySkinPart = table.concat(parts, ",") end
    local peerBackPart = (peerBackId and peerBackSig) and (peerBackId .. ":" .. peerBackSig) or "-"
    -- Helden-Skins als Felder 9+10 angehängt (alte Zuschauer-Clients ignorieren sie)
    local myHeroPart, peerHeroPart = "-", "-"
    if addon.HS_CosmParts then myHeroPart, peerHeroPart = addon:HS_CosmParts() end
    local peerName = (addon.Net_GetPeerName and addon:Net_GetPeerName() or "?"):match("^[^-]+")
    -- Felder sind P1/P2-Reihenfolge, nicht "ich/Gegner": seit der Startspieler-
    -- Auslosung kann der Host P2 sein (wie SPECGAME in Spec_SendHeartbeat).
    -- Ohne Drehung zeigte der Zuschauer die Rücken vertauscht.
    local st = addon.GE_State and addon:GE_State()
    if st and st.myPlayerIdx == 2 then
        return string.format("SPECCOSM|%s|%s|%s|%s|%s|%s|%s|%s|%s",
            sessionId, peerName, peerBackPart, peerSkinRaw or "-",
            MyName(), myBackPart, mySkinPart, peerHeroPart, myHeroPart)
    end
    return string.format("SPECCOSM|%s|%s|%s|%s|%s|%s|%s|%s|%s",
        sessionId, MyName(), myBackPart, mySkinPart,
        peerName, peerBackPart, peerSkinRaw or "-", myHeroPart, peerHeroPart)
end

local function ParseCosmSide(name, backPart, skinPart)
    local backId = nil
    local bId, bSig = (backPart or "-"):match("^(%d+):(%x+)$")
    bId = tonumber(bId)
    if bId and SKIN_BY_ID[bId] and bSig == Sig(name, bId) then backId = bId end
    local skins = {}
    for key, sig in (skinPart or "-"):gmatch("([^:,]+):([^:,]+)") do
        local skin = SKIN_BY_KEY[key]
        if skin and sig == SkinSig(name, key) then
            local l = skins[skin.cardId] or {}
            skins[skin.cardId] = l
            l[#l + 1] = key
        end
    end
    return backId, skins
end

-- Beim Zuschauer: SPECCOSM übernehmen (jede Signatur selbst nachgeprüft)
function addon:CB_OnSpecCosm(p)
    local b1, s1 = ParseCosmSide(p[3] or "?", p[4], p[5])
    local b2, s2 = ParseCosmSide(p[6] or "?", p[7], p[8])
    specCosm = { backs = { b1, b2 }, skins = { s1, s2 } }
    if addon.HS_ParseCosm then
        specCosm.heroSkins = { addon:HS_ParseCosm(p[3] or "?", p[9]), addon:HS_ParseCosm(p[6] or "?", p[10]) }
    end
    if addon.Board_Update then addon:Board_Update() end
end

function addon:CB_SpecReset()
    specCosm = nil
end

-- CBACK|<skinId>|<sig> vom Gegner: nur verifiziert übernehmen
function addon:CB_OnComm(p, sender)
    local skinId, sig = tonumber(p[2]), p[3]
    local senderName = (sender or ""):match("^[^-]+")
    if skinId and sig and SKIN_BY_ID[skinId] and sig == Sig(senderName, skinId) then
        peerBackId, peerBackSig = skinId, sig
    else
        peerBackId, peerBackSig = nil, nil   -- ungültige Ansage → Standard-Rücken
    end
    if addon.Spec_CosmChanged then addon:Spec_CosmChanged() end   -- Host: an Zuschauer weiterreichen
    if addon.Board_Update then addon:Board_Update() end
end

-- ── Galerie-Fenster (Kosmetik-Menü) ─────────────────────────────────────────────

local COSM_UI = addon:UI_RegisterThemePalette({})

local function CreateCosmeticButton(parent, text, width, height, onClick)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(width, height)
    button:RegisterForClicks("LeftButtonUp")

    local border = button:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints()
    addon:UI_BindThemeTexture(border, COSM_UI.purpleSoft)
    local background = button:CreateTexture(nil, "BACKGROUND", nil, 1)
    background:SetPoint("TOPLEFT", 1, -1)
    background:SetPoint("BOTTOMRIGHT", -1, 1)
    addon:UI_BindThemeTexture(background, COSM_UI.button)
    local label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER")
    label:SetText(text)
    label:SetTextColor(0.92, 0.89, 1, 1)
    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetPoint("TOPLEFT", 1, -1)
    highlight:SetPoint("BOTTOMRIGHT", -1, 1)
    addon:UI_BindThemeTexture(highlight, COSM_UI.purple, 0.18)
    button:SetScript("OnEnter", function()
        border:SetColorTexture(unpack(COSM_UI.purple))
        label:SetTextColor(1, 1, 1, 1)
    end)
    button:SetScript("OnLeave", function()
        border:SetColorTexture(unpack(COSM_UI.purpleSoft))
        label:SetTextColor(0.92, 0.89, 1, 1)
    end)
    button:SetScript("OnClick", onClick)
    return button
end

local function CreateCosmeticEditBox(parent, width, height)
    local box = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    box:SetSize(width, height)
    box:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    box:SetBackdropColor(0.035, 0.030, 0.055, 1)
    box:SetBackdropBorderColor(unpack(COSM_UI.purpleSoft))
    box:SetFontObject(GameFontHighlightSmall)
    box:SetTextColor(0.96, 0.94, 1, 1)
    box:SetTextInsets(8, 8, 0, 0)
    box:SetAutoFocus(false)
    box:SetScript("OnEditFocusGained", function(self)
        self:SetBackdropBorderColor(unpack(COSM_UI.purple))
    end)
    box:SetScript("OnEditFocusLost", function(self)
        self:SetBackdropBorderColor(unpack(COSM_UI.purpleSoft))
    end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return box
end

local function EnableCosmeticScrolling(scroll)
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
        local target = self:GetVerticalScroll() - delta * 96
        self:SetVerticalScroll(math.max(0, math.min(maximum, target)))
    end)
end

local function CreateCosmeticWindow(name, sectionTitle, width, offsetX, offsetY)
    local f = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    f:SetSize(width, 480)
    f:SetPoint("CENTER", UIParent, "CENTER", offsetX or 0, offsetY or 0)
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    f:SetBackdropColor(unpack(COSM_UI.panel))
    f:SetBackdropBorderColor(unpack(COSM_UI.panelBorder))
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("DIALOG")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetScript("OnHide", function() addon:OpenCosmeticsMenu() end)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 20, -12)
    title:SetText("Arkana")
    title:SetTextColor(unpack(COSM_UI.title))
    local subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    subtitle:SetPoint("LEFT", title, "RIGHT", 8, 0)
    subtitle:SetText(sectionTitle)

    local close = CreateCosmeticButton(f, "×", 28, 24, function() f:Hide() end)
    close:SetPoint("TOPRIGHT", -10, -9)

    local line = f:CreateTexture(nil, "ARTWORK")
    line:SetHeight(2)
    line:SetPoint("TOPLEFT", 18, -46)
    line:SetPoint("TOPRIGHT", -18, -46)
    addon:UI_BindThemeTexture(line, COSM_UI.purple)

    if addon.UI_RegisterScalableFrame then addon:UI_RegisterScalableFrame(f) end
    table.insert(UISpecialFrames, name)
    return f
end

local function AddCosmeticFooter(f, refresh)
    local eb = CreateCosmeticEditBox(f, 240, 22)
    eb:SetPoint("BOTTOMLEFT", 18, 16)
    f.codeBox = eb

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("BOTTOMLEFT", eb, "TOPLEFT", 0, 4)
    hint:SetText("Freischalt-Code")
    hint:SetTextColor(0.74, 0.69, 0.84, 1)

    local redeem = CreateCosmeticButton(f, "Einlösen", 90, 22, function()
        local ok, msg = addon:CB_Redeem(eb:GetText())
        print((ok and "|cff00ff00[Arkana]|r " or "|cffff0000[Arkana]|r ") .. msg)
        if ok then eb:SetText(""); refresh() end
    end)
    redeem:SetPoint("LEFT", eb, "RIGHT", 8, 0)

    local request = CreateCosmeticButton(f, "Anfrage-Code", 120, 22, function()
        eb:SetText(addon:CB_RequestCode())
        eb:HighlightText()
        eb:SetFocus()
    end)
    request:SetPoint("LEFT", redeem, "RIGHT", 8, 0)

    f.countText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.countText:SetPoint("BOTTOMRIGHT", -12, 20)
end

local COLS, CELL_W, CELL_H, PAD = 5, 92, 124, 10
local gallery

local function GalleryRefresh()
    if not gallery then return end
    local sel = Selected()
    local count = 0
    for _, cell in ipairs(gallery.cells) do
        local owned = Owns(cell.skinId)
        cell.tex:SetDesaturated(not owned)
        cell.tex:SetAlpha(owned and 1 or 0.4)
        cell.sel:SetShown(cell.skinId == sel)
        cell.owned = owned
        if owned then count = count + 1 end
    end
    gallery.countText:SetText(count .. " / " .. #gallery.cells)
end

local function CreateGallery()
    local f = CreateCosmeticWindow("ARKANA_CardBackGallery", "Kartenrücken",
        COLS * (CELL_W + PAD) + PAD + 46, 0, 0)

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -55)
    scroll:SetPoint("BOTTOMRIGHT", -12, 68)
    local content = CreateFrame("Frame", nil, scroll)
    scroll:SetScrollChild(content)
    EnableCosmeticScrolling(scroll)
    content:SetSize(COLS * (CELL_W + PAD), 10)

    -- Bild-Vorschau beim Hover: doppelte Zellgröße (wie in den Skin-Galerien)
    local preview = CreateFrame("Frame", nil, f)
    preview:SetSize(CELL_W * 2, CELL_H * 2)
    preview:SetFrameStrata("TOOLTIP")
    preview.tex = preview:CreateTexture(nil, "ARTWORK")
    preview.tex:SetAllPoints()
    preview.tex:SetTexCoord(0, 1, 0, CARD_TEX_V)
    preview:Hide()

    f.cells = {}
    for i, skin in ipairs(SKINS) do
        local col, row = (i - 1) % COLS, math.floor((i - 1) / COLS)
        local cell = CreateFrame("Button", nil, content)
        cell:SetSize(CELL_W, CELL_H)
        cell:SetPoint("TOPLEFT", PAD / 2 + col * (CELL_W + PAD), -(PAD / 2 + row * (CELL_H + PAD + 14)))
        cell.skinId = skin.id

        cell.tex = cell:CreateTexture(nil, "ARTWORK")
        cell.tex:SetAllPoints()
        cell.tex:SetTexture(addon:CB_Texture(skin.id))
        cell.tex:SetTexCoord(0, 1, 0, CARD_TEX_V)

        -- Auswahl-Rahmen
        cell.sel = cell:CreateTexture(nil, "OVERLAY")
        cell.sel:SetPoint("TOPLEFT", -3, 3); cell.sel:SetPoint("BOTTOMRIGHT", 3, -3)
        addon:UI_BindThemeTexture(cell.sel, COSM_UI.purple, 0.55)
        cell.sel:Hide()

        local label = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("TOP", cell, "BOTTOM", 0, -2)
        label:SetText(skin.name)

        local highlight = cell:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        addon:UI_BindThemeTexture(highlight, COSM_UI.purple, 0.18)
        cell:SetScript("OnClick", function(self)
            if not self.owned then return end
            local d = Data()
            d.selected = (d.selected ~= self.skinId) and self.skinId or nil  -- Klick = wählen, nochmal = abwählen
            GalleryRefresh()
        end)
        cell:SetScript("OnEnter", function(self)
            preview.tex:SetTexture(addon:CB_Texture(self.skinId))
            -- Endgröße = Gesamt-Skalierung × Tooltip-Extra (siehe ApplyScales in Main.lua)
            preview:SetScale(ARKANA_Settings and (ARKANA_Settings.boardScale or 1.0) * (ARKANA_Settings.tooltipScale or 1.0) or 1.0)
            preview:ClearAllPoints()
            preview:SetPoint("CENTER", self, "CENTER", 0, 0)
            preview:Show()
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(skin.name, 1, 0.82, 0)
            GameTooltip:AddLine("ID: " .. self.skinId, 0.6, 0.6, 0.6)
            if self.owned then
                GameTooltip:AddLine(self.skinId == Selected() and "Klick: abwählen" or "Klick: auswählen", 1, 1, 1)
            else
                GameTooltip:AddLine("Nicht Freigeschaltet - Kann bei Events erworben werden", 1, 0.3, 0.3)
            end
            GameTooltip:Show()
        end)
        cell:SetScript("OnLeave", function() GameTooltip:Hide(); preview:Hide() end)
        f.cells[i] = cell
    end
    local rows = math.ceil(#SKINS / COLS)
    content:SetHeight(rows * (CELL_H + PAD + 14) + PAD)

    AddCosmeticFooter(f, GalleryRefresh)

    f:SetScript("OnShow", GalleryRefresh)
    return f
end

function addon:CB_ShowGallery()
    if not gallery then gallery = CreateGallery() end
    gallery:Show()
    GalleryRefresh()
end

-- ── Karten-Skins-Galerie (analog zur Rücken-Galerie, Auswahl pro Karte) ─────────

local skinGallery

local function SkinGalleryRefresh()
    if not skinGallery then return end
    local count = 0
    for _, cell in ipairs(skinGallery.cells) do
        local owned = OwnsSkin(cell.skinKey)
        cell.tex:SetDesaturated(not owned)
        cell.tex:SetAlpha(owned and 1 or 0.4)
        cell.sel:SetShown(IsSkinSelected(cell.cardId, cell.skinKey))
        cell.owned = owned
        if owned then count = count + 1 end
    end
    skinGallery.countText:SetText(count .. " / " .. #skinGallery.cells)
end

local function CreateSkinGallery()
    local f = CreateCosmeticWindow("ARKANA_CardSkinGallery", "Karten-Skins",
        COLS * (CELL_W + PAD) + PAD + 46, 0, 0)

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -55)
    scroll:SetPoint("BOTTOMRIGHT", -12, 68)
    local content = CreateFrame("Frame", nil, scroll)
    scroll:SetScrollChild(content)
    EnableCosmeticScrolling(scroll)
    content:SetSize(COLS * (CELL_W + PAD), 10)

    -- Bild-Vorschau beim Hover: doppelte Zellgröße (wie in der Helden-Skin-Galerie)
    local preview = CreateFrame("Frame", nil, f)
    preview:SetSize(CELL_W * 2, CELL_H * 2)
    preview:SetFrameStrata("TOOLTIP")
    preview.tex = preview:CreateTexture(nil, "ARTWORK")
    preview.tex:SetAllPoints()
    preview.tex:SetTexCoord(0, 1, 0, CARD_TEX_V)
    preview:Hide()

    f.cells = {}
    local pos, tourneyHdr = 0, false   -- pos = Rasterplatz (Überschrift belegt eine Zeile)
    for i, skin in ipairs(CARD_SKINS) do
        if skin.tourney and not tourneyHdr then
            tourneyHdr = true
            if pos % COLS ~= 0 then pos = pos + (COLS - pos % COLS) end   -- neue Zeile
            local hdr = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            hdr:SetPoint("TOPLEFT", PAD / 2, -(PAD / 2 + math.floor(pos / COLS) * (CELL_H + PAD + 14) + 8))
            hdr:SetText("|cffffd700Turnier-Skins|r |cff909090(nur als Turnierpreis)|r")
            pos = pos + COLS
        end
        local col, row = pos % COLS, math.floor(pos / COLS)
        pos = pos + 1
        local cell = CreateFrame("Button", nil, content)
        cell:SetSize(CELL_W, CELL_H)
        cell:SetPoint("TOPLEFT", PAD / 2 + col * (CELL_W + PAD), -(PAD / 2 + row * (CELL_H + PAD + 14)))
        cell.skinKey, cell.cardId, cell.tourney = skin.key, skin.cardId, skin.tourney

        cell.tex = cell:CreateTexture(nil, "ARTWORK")
        cell.tex:SetAllPoints()
        cell.tex:SetTexture(SkinTex(skin.key))
        cell.tex:SetTexCoord(0, 1, 0, CARD_TEX_V)

        cell.sel = cell:CreateTexture(nil, "OVERLAY")
        cell.sel:SetPoint("TOPLEFT", -3, 3); cell.sel:SetPoint("BOTTOMRIGHT", 3, -3)
        addon:UI_BindThemeTexture(cell.sel, COSM_UI.purple, 0.55)
        cell.sel:Hide()

        local label = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("TOP", cell, "BOTTOM", 0, -2)
        label:SetText(skin.name)

        local highlight = cell:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        addon:UI_BindThemeTexture(highlight, COSM_UI.purple, 0.18)
        cell:SetScript("OnClick", function(self)
            if not self.owned then return end
            -- Mehrfach-Auswahl: mehrere aktive Skins pro Karte → beschworene Diener
            -- bekommen (deterministisch über entityId) verschiedene Varianten
            local sel = SData().selected
            local list = sel[self.cardId]
            if type(list) == "string" then list = { list } end
            list = list or {}
            local found
            for i, k in ipairs(list) do
                if k == self.skinKey then found = i break end
            end
            if found then table.remove(list, found) else list[#list + 1] = self.skinKey end
            sel[self.cardId] = (#list > 0) and list or nil
            SkinGalleryRefresh()
        end)
        cell:SetScript("OnEnter", function(self)
            local cd = ARKANA_CardData and ARKANA_CardData[self.cardId]
            if cd and addon.DB_ShowCardTip then
                -- Karten-Tooltip wie im DeckBuilder: echter Kartenrahmen mit
                -- Mana/Werten/Text, Skin-Bild als Art-Override (Muster wie der
                -- große Kartenvorschau)
                addon:DB_ShowCardTip(cd, self, SkinTex(self.skinKey))
            else
                -- Fallback (Karte nicht in ARKANA_CardData): nacktes Bild wie bisher
                preview.tex:SetTexture(SkinTex(self.skinKey))
                -- Endgröße = Gesamt-Skalierung × Tooltip-Extra (siehe ApplyScales in Main.lua)
                preview:SetScale(ARKANA_Settings and (ARKANA_Settings.boardScale or 1.0) * (ARKANA_Settings.tooltipScale or 1.0) or 1.0)
                preview:ClearAllPoints()
                preview:SetPoint("CENTER", self, "CENTER", 0, 0)
                preview:Show()
            end
            -- Info-Text UNTER die Zelle, damit er dem Karten-Tooltip (rechts)
            -- nicht in die Quere kommt
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:SetText(skin.name, 1, 0.82, 0)
            GameTooltip:AddLine("Key: " .. self.skinKey, 0.6, 0.6, 0.6)
            GameTooltip:AddLine("Für: " .. ((cd and cd.name) or skin.cardId), 0.8, 0.8, 0.8)
            if self.owned then
                GameTooltip:AddLine(IsSkinSelected(self.cardId, self.skinKey) and "Klick: abwählen" or "Klick: auswählen", 1, 1, 1)
                GameTooltip:AddLine("Mehrere Skins derselben Karte wählbar — beschworene", 0.6, 0.6, 0.6)
                GameTooltip:AddLine("Diener bekommen dann verschiedene Varianten.", 0.6, 0.6, 0.6)
            elseif self.tourney then
                GameTooltip:AddLine("Nicht freigeschaltet — nur als Turnierpreis erhältlich.", 1, 0.3, 0.3)
            else
                GameTooltip:AddLine("Nicht freigeschaltet — ein gültiger Freischaltcode ist erforderlich.", 1, 0.3, 0.3)
            end
            GameTooltip:Show()
            -- Textbox ÜBER den großen Karten-Tooltip heben: beide liegen auf
            -- der TOOLTIP-Strata, das FrameLevel entscheidet — sonst verdeckt
            -- die Karte den Text (nach Show setzen, SetOwner resettet Level)
            if addon.deckBuilderTooltip then
                GameTooltip:SetFrameLevel(addon.deckBuilderTooltip:GetFrameLevel() + 5)
            end
        end)
        cell:SetScript("OnLeave", function()
            GameTooltip:Hide()
            preview:Hide()
            if addon.DB_HideCardTip then addon:DB_HideCardTip() end
        end)
        f.cells[i] = cell
    end
    content:SetHeight(math.ceil(pos / COLS) * (CELL_H + PAD + 14) + PAD)

    AddCosmeticFooter(f, SkinGalleryRefresh)

    f:SetScript("OnShow", SkinGalleryRefresh)
    return f
end

function addon:CS_ShowGallery()
    if not skinGallery then skinGallery = CreateSkinGallery() end
    skinGallery:Show()
    SkinGalleryRefresh()
end

-- ═══ Helden-Skins ════════════════════════════════════════════════════════════════
-- Alternative Helden-Portraits, pro Kategorie gruppiert. Bestehende Codes nutzen
-- denselben Signatur-Namespace wie Karten-Skins ("skin:<KEY>").
-- Textur: Textures\HeroFrames\Skins\<cat.dir>\<key>.tga (512x512, wie HeroFrames).

local HERO_SKIN_DIR = "Interface\\AddOns\\Arkana\\Textures\\HeroFrames\\Skins\\"

-- Klassen-Anzeige für den Tooltip ("Für: …")
local HERO_CLASS = {
    HERO_01 = "Krieger", HERO_02 = "Schamane", HERO_03 = "Schurke",
    HERO_04 = "Paladin", HERO_05 = "Jäger",    HERO_06 = "Druide",
    HERO_07 = "Hexenmeister", HERO_08 = "Magier", HERO_09 = "Priester",
}

-- Kategorien: name = Überschrift in der Galerie, dir = Unterordner,
-- unlock = Tooltip-Zeile für nicht freigeschaltete Skins. Namen/Texte pflegt der User.
local HERO_SKIN_CATS = {
    { name = "1000 Siege", dir = "1000-Wins",
      unlock = "Kann durch 1000 Siege erworben werden.",
      skins = {
        { key = "Corrupt_Garrosh", hero = "HERO_01", name = "Verderbter Garrosh" },
        { key = "Warchief_Thrall", hero = "HERO_02", name = "Kriegshäuptling Thrall" },
        { key = "Capn_Valeera", hero = "HERO_03", name = "Käpt'n Valeera" },
        { key = "Lightforged_Uther", hero = "HERO_04", name = "Lichtdurchfluteter  Uther" },
        { key = "Shando_Malfurion", hero = "HERO_06", name = "Shan'do Malfurion" },
        { key = "Shadow_Guldan", hero = "HERO_07", name = "Gul'dan der Schatten" },
        { key = "Fire_Mage_Jaina", hero = "HERO_08", name = "Feuermagierin Jaina" },
        { key = "King_Anduin", hero = "HERO_09", name = "König Anduin" },
      } },
    { name = "Special", dir = "Special",
      unlock = "Kann bei Events erworben werden.",
      skins = {
        { key = "Morgl_the_Oracle", hero = "HERO_02", name = "Morgl das Orakel" },
        { key = "Druide", hero = "HERO_06", name = "Druide" },
        { key = "Schurke", hero = "HERO_03", name = "Schurke" },
        { key = "Jäger", hero = "HERO_05", name = "Jäger" },    
        { key = "Krieger", hero = "HERO_01", name = "Krieger" },
        { key = "P.Garrosh", hero = "HERO_01", name = "Piraten Garrosh" },
        { key = "P.Magni", hero = "HERO_01", name = "Piraten Magni" },
        { key = "Magier", hero = "HERO_08", name = "Magier" },
        { key = "Paladin", hero = "HERO_04", name = "Paladin" },
        { key = "Priester", hero = "HERO_09", name = "Priester" },
        { key = "Hexenmeister", hero = "HERO_07", name = "Hexenmeister" },
        { key = "Nathanos", hero = "HERO_05", name = "Nathanos" },
      } },
    { name = "Special Skins für alle Helden", dir = "Special-all",
      unlock = "Kann bei Events erworben werden.",
      skins = {
        { key = "Arfus", heros = {"HERO_01", "HERO_02", "HERO_03", "HERO_04", "HERO_05", "HERO_06", "HERO_08", "HERO_09"}, name = "Arfus"},
        { key = "Chromie", heros = {"HERO_01", "HERO_02", "HERO_03", "HERO_04", "HERO_05", "HERO_06", "HERO_07", "HERO_08", "HERO_09"}, name = "Chromie" },
        { key = "Omen", heros = {"HERO_01", "HERO_02", "HERO_03", "HERO_04", "HERO_05", "HERO_06", "HERO_07", "HERO_08", "HERO_09"}, name = "Omen" },
        { key = "Ulfarby", heros = {"HERO_01", "HERO_02", "HERO_03", "HERO_04", "HERO_05", "HERO_06", "HERO_07", "HERO_08", "HERO_09"}, name = "Ulfarby" },
        
      } },
    --HERO_01 = "Krieger", HERO_02 = "Schamane", HERO_03 = "Schurke",
    --HERO_04 = "Paladin", HERO_05 = "Jäger",    HERO_06 = "Druide",
    --HERO_07 = "Hexenmeister", HERO_08 = "Magier", HERO_09 = "Priester",
}

local HERO_SKIN_BY_KEY = {}
for _, cat in ipairs(HERO_SKIN_CATS) do
    for _, s in ipairs(cat.skins) do
        s.tex = HERO_SKIN_DIR .. cat.dir .. "\\" .. s.key .. ".tga"
        s.unlock = cat.unlock
        -- Multi-Klassen-Skins: `heroes = { "HERO_02", "HERO_08" }` statt `hero = "..."`.
        -- Auswahl gilt immer für ALLE Klassen des Skins gemeinsam (die Netzwerk-
        -- Ansage trägt nur den Key, der Empfänger mappt auf alle Klassen).
        -- "heros" wird als Schreibweisen-Alias akzeptiert.
        s.heroes = s.heroes or s.heros or { s.hero }
        s.hero = s.heroes[1]
        HERO_SKIN_BY_KEY[s.key] = s
    end
end

local function HSData()
    ARKANA_CharData = ARKANA_CharData or {}
    local hs = ARKANA_CharData.heroSkins or {}
    ARKANA_CharData.heroSkins = hs
    hs.owned = hs.owned or {}
    hs.selected = hs.selected or {}   -- [heroId] = key (max. 1 Skin pro Held)
    return hs
end

local function OwnsHeroSkin(key)
    local d = HSData()
    return d.owned[key] ~= nil and d.owned[key] == SkinSig(MyName(), key)
end

-- Lokaler Testhelfer für die fest eingetragene Arkana-Spielleitung. Es werden
-- ausschließlich Kosmetik-Freischaltungen des aktuellen Charakters verändert;
-- kein Netzwerkpaket wird versendet und keine Auswahl wird automatisch gesetzt.
function addon:SEC_GrantAllTestCosmetics()
    if not addon:SEC_IsAdmin(LocalIdentity()) then
        return false, "Nur die Arkana-Spielleitung darf Testkosmetik freischalten."
    end

    local character = MyName()
    local backs, cardSkins, heroSkins = Data(), SData(), HSData()
    local backCount, cardSkinCount, heroSkinCount = 0, 0, 0

    for _, skin in ipairs(SKINS) do
        backs.owned[skin.id] = Sig(character, skin.id)
        backCount = backCount + 1
    end
    for _, skin in ipairs(CARD_SKINS) do
        cardSkins.owned[skin.key] = SkinSig(character, skin.key)
        cardSkinCount = cardSkinCount + 1
    end
    for key in pairs(HERO_SKIN_BY_KEY) do
        heroSkins.owned[key] = SkinSig(character, key)
        heroSkinCount = heroSkinCount + 1
    end

    if addon.CB_RefreshGalleries then addon:CB_RefreshGalleries() end
    if addon.Board_Update then addon:Board_Update() end
    return true, string.format(
        "Testkosmetik freigeschaltet: %d Kartenrücken, %d Karten-Skins und %d Helden-Skins.",
        backCount, cardSkinCount, heroSkinCount)
end

-- Key case-insensitiv auflösen (Codes kommen upper-case an)
function addon:HS_KeyByAny(key)
    if HERO_SKIN_BY_KEY[key] then return key end
    for k in pairs(HERO_SKIN_BY_KEY) do
        if k:upper() == key:upper() then return k end
    end
    return nil
end

function addon:HS_RedeemKey(key, hex)
    key = addon:HS_KeyByAny(key)
    if not key then return false, "Unbekannter Helden-Skin." end
    if hex ~= SkinSig(MyName(), key) then
        return false, "Code ungültig (falscher Charakter oder Tippfehler?)."
    end
    HSData().owned[key] = hex
    addon:ShowUnlockPopup(HERO_SKIN_BY_KEY[key].name, HERO_SKIN_BY_KEY[key].tex, 330 / 512, 429 / 512)
    return true, HERO_SKIN_BY_KEY[key].name .. " freigeschaltet!"
end

-- Gewählter Skin für einen Helden (eigene Anzeige)
function addon:HS_SelectedTexture(heroId)
    local d = HSData()
    local key = d.selected[heroId]
    if key and OwnsHeroSkin(key) then return HERO_SKIN_BY_KEY[key].tex end
    return nil
end

-- ── Netzwerk: Helden-Skins ansagen/verifizieren (gleiches Modell wie CBACK/CSKIN:
-- signierte Ansage, Empfänger prüft Sig gegen Absendername, Fälschung → Standard) ──

local peerHeroSkins = {}     -- [heroId] = key — verifizierte Helden-Skins des Gegners
local peerHeroSkinRaw = nil  -- verifizierte Rohliste (Zuschauer-Weiterleitung durch den Host)

-- Von CB_OnGameStart gerufen (peerName=nil → nur Reset)
function addon:HS_OnGameStart(peerName)
    peerHeroSkins = {}
    peerHeroSkinRaw = nil
    if not peerName then return end
    local d = HSData()
    local parts = {}
    for _, key in pairs(d.selected) do
        if OwnsHeroSkin(key) then parts[#parts + 1] = key .. ":" .. d.owned[key] end
    end
    if #parts > 0 then
        addon:SendCommMessage(PREFIX, "HSKIN|" .. table.concat(parts, ","), "WHISPER", peerName)
    end
end

-- HSKIN|key1:sig1,key2:sig2 vom Gegner: nur verifizierte Einträge übernehmen
function addon:HS_OnComm(p, sender)
    local senderName = (sender or ""):match("^[^-]+")
    peerHeroSkins = {}
    local raw = {}
    for key, sig in (p[2] or ""):gmatch("([^:,]+):([^:,]+)") do
        local skin = HERO_SKIN_BY_KEY[key]
        if skin and sig == SkinSig(senderName, key) then
            for _, h in ipairs(skin.heroes) do peerHeroSkins[h] = key end
            raw[#raw + 1] = key .. ":" .. sig
        end
    end
    peerHeroSkinRaw = (#raw > 0) and table.concat(raw, ",") or nil
    if addon.Spec_CosmChanged then addon:Spec_CosmChanged() end   -- Host: an Zuschauer weiterreichen
    if addon.Board_Update then addon:Board_Update() end
end

-- Für CB_SpecCosmMsg: eigener Teil (signiert) + verifizierter Gegner-Teil
function addon:HS_CosmParts()
    local d = HSData()
    local mine = {}
    for _, key in pairs(d.selected) do
        if OwnsHeroSkin(key) then mine[#mine + 1] = key .. ":" .. d.owned[key] end
    end
    return (#mine > 0) and table.concat(mine, ",") or "-", peerHeroSkinRaw or "-"
end

-- Für CB_OnSpecCosm: Zuschauer prüft jede Signatur selbst nach
function addon:HS_ParseCosm(name, part)
    local map = {}
    for key, sig in (part or "-"):gmatch("([^:,]+):([^:,]+)") do
        local skin = HERO_SKIN_BY_KEY[key]
        if skin and sig == SkinSig(name, key) then
            for _, h in ipairs(skin.heroes) do map[h] = key end
        end
    end
    return map
end

-- Anzeige-Auflösung für die Spiel-UI: Zuschauer-Seite > eigener/Peer-Skin.
-- isMine entspricht beim Zuschauen der P1-Seite (unten), wie CS_ArtFor.
function addon:HS_ArtFor(heroId, isMine)
    if Spectating() then
        local m = specCosm and specCosm.heroSkins and specCosm.heroSkins[isMine and 1 or 2]
        local key = m and m[heroId]
        local s = key and HERO_SKIN_BY_KEY[key]
        return s and s.tex or nil
    end
    if isMine then return addon:HS_SelectedTexture(heroId) end
    local key = peerHeroSkins[heroId]
    local s = key and HERO_SKIN_BY_KEY[key]
    return s and s.tex or nil
end

-- ── Helden-Skins-Galerie (Kategorien mit Überschrift + Trennlinie) ──────────────

local heroSkinGallery
local HERO_TEX_U, HERO_TEX_V = 330 / 512, 429 / 512   -- wie HEROFRAME_U/V (GameBoard.lua)
local HCELL_W, HCELL_H = 106, 124                     -- Helden-Zellen: breiter als Karten-Zellen

local function HeroSkinGalleryRefresh()
    if not heroSkinGallery then return end
    local sel = HSData().selected
    local count = 0
    for _, cell in ipairs(heroSkinGallery.cells) do
        local owned = OwnsHeroSkin(cell.skinKey)
        cell.tex:SetDesaturated(not owned)
        cell.tex:SetAlpha(owned and 1 or 0.4)
        cell.sel:SetShown(sel[cell.heroId] == cell.skinKey)
        cell.owned = owned
        if owned then count = count + 1 end
    end
    heroSkinGallery.countText:SetText(count .. " / " .. #heroSkinGallery.cells)
end

local function CreateHeroSkinGallery()
    local f = CreateCosmeticWindow("ARKANA_HeroSkinGallery", "Helden-Skins",
        COLS * (HCELL_W + PAD) + PAD + 46, 0, 0)

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -55)
    scroll:SetPoint("BOTTOMRIGHT", -12, 68)
    local content = CreateFrame("Frame", nil, scroll)
    scroll:SetScrollChild(content)
    EnableCosmeticScrolling(scroll)
    content:SetSize(COLS * (HCELL_W + PAD), 10)

    -- Bild-Vorschau beim Hover: doppelte Zellgröße, links neben der Zelle
    local preview = CreateFrame("Frame", nil, f)
    preview:SetSize(HCELL_W * 2, HCELL_H * 2)
    preview:SetFrameStrata("TOOLTIP")
    preview.tex = preview:CreateTexture(nil, "ARTWORK")
    preview.tex:SetAllPoints()
    preview.tex:SetTexCoord(0, HERO_TEX_U, 0, HERO_TEX_V)
    preview:Hide()

    f.cells = {}
    local y = PAD / 2
    for _, cat in ipairs(HERO_SKIN_CATS) do
        -- Kategorie-Überschrift + Trennlinie
        local header = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        header:SetPoint("TOPLEFT", PAD / 2, -y)
        header:SetText(cat.name)
        header:SetTextColor(unpack(COSM_UI.title))
        local line = content:CreateTexture(nil, "ARTWORK")
        addon:UI_BindThemeTexture(line, COSM_UI.purpleSoft)
        line:SetPoint("TOPLEFT", PAD / 2, -(y + 16))
        line:SetSize(COLS * (HCELL_W + PAD) - PAD, 1)
        y = y + 24

        for i, skin in ipairs(cat.skins) do
            local col, row = (i - 1) % COLS, math.floor((i - 1) / COLS)
            local cell = CreateFrame("Button", nil, content)
            cell:SetSize(HCELL_W, HCELL_H)
            cell:SetPoint("TOPLEFT", PAD / 2 + col * (HCELL_W + PAD), -(y + row * (HCELL_H + PAD + 14)))
            cell.skinKey, cell.heroId, cell.heroes = skin.key, skin.hero, skin.heroes

            cell.tex = cell:CreateTexture(nil, "ARTWORK")
            cell.tex:SetAllPoints()
            cell.tex:SetTexture(skin.tex)
            cell.tex:SetTexCoord(0, HERO_TEX_U, 0, HERO_TEX_V)

            cell.sel = cell:CreateTexture(nil, "OVERLAY")
            cell.sel:SetPoint("TOPLEFT", -3, 3); cell.sel:SetPoint("BOTTOMRIGHT", 3, -3)
            addon:UI_BindThemeTexture(cell.sel, COSM_UI.purple, 0.55)
            cell.sel:Hide()

            local label = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            label:SetPoint("TOP", cell, "BOTTOM", 0, -2)
            label:SetWidth(HCELL_W + PAD - 2)   -- lange Namen: abschneiden mit "…" statt Überlappen
            label:SetWordWrap(false)
            label:SetText(skin.name)

            local highlight = cell:CreateTexture(nil, "HIGHLIGHT")
            highlight:SetAllPoints()
            addon:UI_BindThemeTexture(highlight, COSM_UI.purple, 0.18)
            cell:SetScript("OnClick", function(self)
                if not self.owned then return end
                local sel = HSData().selected
                -- Multi-Klassen-Skin: Auswahl gilt für ALLE Klassen gemeinsam
                local newVal = (sel[self.heroId] ~= self.skinKey) and self.skinKey or nil
                for _, h in ipairs(self.heroes) do sel[h] = newVal end
                HeroSkinGalleryRefresh()
                if addon.Board_Update then addon:Board_Update() end
            end)
            cell:SetScript("OnEnter", function(self)
                preview.tex:SetTexture(skin.tex)
                -- Endgröße = Gesamt-Skalierung × Tooltip-Extra (siehe ApplyScales in Main.lua)
                preview:SetScale(ARKANA_Settings and (ARKANA_Settings.boardScale or 1.0) * (ARKANA_Settings.tooltipScale or 1.0) or 1.0)
                preview:ClearAllPoints()
                preview:SetPoint("CENTER", self, "CENTER", 0, 0)
                preview:Show()
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(skin.name, 1, 0.82, 0)
                GameTooltip:AddLine("Key: " .. self.skinKey, 0.6, 0.6, 0.6)
                local classes = {}
                for _, h in ipairs(self.heroes) do classes[#classes + 1] = HERO_CLASS[h] or h end
                local forText = (#classes >= 9) and "Alle Klassen" or table.concat(classes, ", ")
                GameTooltip:AddLine("Für: " .. forText, 0.8, 0.8, 0.8, true)   -- true = Zeilenumbruch
                if self.owned then
                    GameTooltip:AddLine("Freigeschaltet", 0.2, 1, 0.2)
                    GameTooltip:AddLine(HSData().selected[self.heroId] == self.skinKey and "Klick: abwählen" or "Klick: auswählen", 1, 1, 1)
                else
                    GameTooltip:AddLine("Nicht freigeschaltet — " .. skin.unlock, 1, 0.3, 0.3)
                end
                GameTooltip:Show()
            end)
            cell:SetScript("OnLeave", function() GameTooltip:Hide(); preview:Hide() end)
            f.cells[#f.cells + 1] = cell
        end
        y = y + math.ceil(#cat.skins / COLS) * (HCELL_H + PAD + 14) + 8
    end
    content:SetHeight(y + PAD)

    AddCosmeticFooter(f, HeroSkinGalleryRefresh)

    f:SetScript("OnShow", HeroSkinGalleryRefresh)
    return f
end

function addon:HS_ShowGallery()
    if not heroSkinGallery then heroSkinGallery = CreateHeroSkinGallery() end
    heroSkinGallery:Show()
    HeroSkinGalleryRefresh()
end

-- Offene Galerien nach einer Freischaltung sofort aktualisieren.
function addon:CB_RefreshGalleries()
    if gallery and gallery:IsShown() then GalleryRefresh() end
    if skinGallery and skinGallery:IsShown() then SkinGalleryRefresh() end
    if heroSkinGallery and heroSkinGallery:IsShown() then HeroSkinGalleryRefresh() end
end
