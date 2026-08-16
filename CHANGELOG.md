# Arkana – Changelog

Alle wichtigen Änderungen am Addon werden in dieser Datei dokumentiert.

Kartenspezifische Werte, Regelkorrekturen und bekannte Karteninteraktionen werden getrennt im [Karten-Changelog](KARTEN_CHANGELOG.md) geführt.

## 0.1.6 – 16. August 2026

Interner Build: `2026-08-16-f`

### Arkana-Spielleitung

- `Romash-Schattenhain` wurde als weiterer realmgebundener Arkana-Admin eingetragen. Er erhält Zugriff auf die Verteilung und lokale Admin-Testbefehle; die Karten-Sandbox bleibt ausschließlich `Annila-Schattenhain` vorbehalten.

### Karten-Sandbox

- Die Sandbox entfernt nach dem übersprungenen Mulligan sämtliche zufälligen Startkarten von der eigenen Hand und beginnt unmittelbar mit 10/10 Mana. Benötigte Testkarten werden gezielt über die Sandbox-Oberfläche hinzugefügt.

### Herausforderungen

- Im exakt benannten Ort `OOC-Gebiet` können keine Herausforderungen mehr gestartet werden. Die Sperre prüft Unterzone, Minimap-Ortsname und Zone direkt im zentralen Sendeablauf und gilt dadurch auch für Slash- oder direkte Funktionsaufrufe des unveränderten Clients.

### Sandbox-Berechtigung

- Die Karten-Sandbox ist ausschließlich für den realmgebundenen Charakter `Annila-Schattenhain` sichtbar und startbar. Artinea und alle übrigen Spieler erhalten keinen Zugriff.
- Menü, Slash-Befehle, Kompatibilitätsalias und Engine prüfen dieselbe zentrale Berechtigung; direkte Aufrufe des Sandbox-Modus werden zusätzlich in der Engine abgewiesen.
- Ein fester signierter Integritätsnachweis erschwert das bloße Austauschen des Namens. Da WoW-Addons vollständig lokal und lesbar ausgeführt werden, kann ausschließlich ein Serverdienst echte Manipulationssicherheit gewährleisten.

### Geplante Arbeiten

1. Karten- und Booster-Vergaben gegen direkte `/run`-Aufrufe absichern. Privilegierte Funktionen sollen keine ungeprüften lokalen Vergaben akzeptieren; für vollständige Manipulationssicherheit bleibt eine serverseitige Autorität erforderlich.
2. Das Kampffeld gestalterisch und hinsichtlich Übersichtlichkeit überarbeiten.
3. Weitere passende Karten-, Angriffs-, Treffer- und Übergangsanimationen ergänzen.

### Kartenregeln

- Der Gesichtlose Manipulator übernimmt jetzt die aktuellen Werte und Zustände seines Ziels statt nur dessen unveränderte Grundkarte. Auren werden danach korrekt für die neue Spielfeldseite berechnet.
- Die Klerikerin von Nordhain zieht jetzt regelgerecht eine Karte, wenn ein tatsächlich verletzter Diener auf einer beliebigen Spielfeldseite geheilt wird.
- „Kreis der Heilung“ verwendet nun den allgemeinen Heilungsablauf. Dadurch lösen geheilte Diener die Klerikerin und andere Heilungsreaktionen aus; Helden werden von diesem Zauber nicht länger fälschlich geheilt.
- Ausführliche Testfälle stehen im [Karten-Changelog](KARTEN_CHANGELOG.md).

## 0.1.5 – 15. August 2026

Interner Build: `2026-08-15-b`

### Karten-Sandbox

- Die festen Gegner-Dummys `0/30` und `30/30` wurden durch zwei Eingabefelder für Angriff und Leben ersetzt.
- Ein frei konfigurierter Dummy wird immer auf der gegnerischen Spielfeldseite beschworen. Zulässig sind 0–999 Angriff und 1–999 Leben; ungültige Eingaben werden vor dem Platzieren begrenzt.
- Mana auffüllen, Hand leeren und beide Spielfelder leeren bleiben als kompakte Sandbox-Werkzeuge verfügbar.

### Kartenregeln

- „Immer wenn Ihr einen Zauber wirkt“-Trigger werden jetzt vor dem eigentlichen Zaubertext abgearbeitet. Dadurch zieht der Goblinauktionator auch bei Schattenschritt und Verschwinden regelgerecht eine Karte, bevor er das Spielfeld verlässt.
- Echte „Nachdem Ihr einen Zauber gewirkt habt“-Effekte bleiben hinter dem Zaubertext; der Wilde Pyromant wurde dafür auf einen getrennten Nach-Zauber-Trigger umgestellt.
- Schattenschritt kann nach einem vorausgehenden Auktionator-Zug keine elfte Handkarte mehr erzeugen. Ist die Hand bereits voll, verfällt der zurückgenommene Diener.
- Ausführliche Kartenfälle stehen im [Karten-Changelog](KARTEN_CHANGELOG.md).

## 0.1.4 – 14. August 2026

Interner Build: `2026-08-14-b`

### Karten-Sandbox

- Die Test-Dummys `0/30` und `30/30` verwenden jetzt das Kartenbild des Alarm-o-Bots (`EX1_006`).
- Es wird ausschließlich das Artwork übernommen. Die Dummys erhalten weder den Zugbeginn-Effekt noch den Mech-Typ oder andere Eigenschaften des Alarm-o-Bots.

### Spielende

- Der Einflug-, Zoom- und Überschwingeffekt des Ergebnistexts wurde für Sieg, Niederlage, Unentschieden und das neutrale Sandbox-Ende entfernt.
- Ergebnistext, Wertungshinweis, Countdown und Rückkehr zum Hauptmenü bleiben unverändert sichtbar.
- **Geplant:** Das Spielende erhält später eine neu entwickelte, dezente Animation. Vorgesehen ist eine kurze Überblendung ohne Zoom, Überschwingen, Erschütterung oder blockierende Partikeleffekte; bis dahin bleibt die Anzeige bewusst statisch.

## 0.1.3 – 13. August 2026

Interner Build: `2026-08-13-bd`

### Karten-Sandbox

- Das bisherige Bot-Match wurde durch eine lokale Karten-Sandbox ersetzt; sie startet über „Sandbox“ im Hauptmenü oder `/arkana sandbox`. `/arkana bot` bleibt als kompatibler Alias erhalten.
- Das aktive Deck dient als Ausgangspunkt. Ist es nicht vollständig spielbar, stellt die Sandbox automatisch ein neutrales Testdeck bereit, damit Kartentests nicht am Deckzustand scheitern.
- Mulligan und gegnerische Aktionen werden übersprungen. Das passive Trainingsziel beendet lediglich automatisch seinen Zug und besitzt 9999 Leben.
- Eine angedockte Testfläche durchsucht Diener, Zauber und Waffen nach Name oder Karten-ID. Ein Klick legt die gewählte Karte ausschließlich im laufenden Test auf die eigene Hand.
- Zusätzliche Werkzeuge füllen Mana auf, leeren die Hand, beschwören einen gegnerischen Test-Dummy oder räumen beide Spielfelder direkt auf.
- Gegner-Dummys können als `0/30` für normale Zieltests oder als `30/30` platziert werden. Der 30/30-Dummy verursacht beim angegriffenen Kampfziel 30 Gegenschaden und kann dadurch eigene Todesröcheln-Diener zuverlässig sterben lassen.
- Die Sandbox besitzt keinen Zugtimer. Tödlicher Testschaden beendet sie nicht automatisch, sondern hält betroffene Helden für weitere Prüfungen bei mindestens einem Leben.
- „Sandbox beenden“ schließt den Test ausdrücklich neutral; es wird weder Sieg noch Niederlage oder Unentschieden gespeichert.
- Die Sandbox läuft vollständig lokal, besitzt keinen Netzwerk-Peer und sendet weder Duell-Whisper noch Zuschauer-, Lobby- oder Ranglistenpakete.
- Laufende Duelle, Herausforderungen und Zuschauerpartien blockieren den Start der Sandbox, damit Sitzungszustände nicht vermischt werden.
- Das Hauptmenü passt seine Höhe bei sichtbarer Verteilerverwaltung dynamisch an, damit der neue Button nicht mit dem Rangbereich überlappt.

### Fehlerbehebung

- Die Sandbox-Funktionen werden am tatsächlichen Arkana-Addonobjekt registriert; Hauptmenü und Slash-Befehl melden eine unvollständige Installation sichtbar.
- Die Engine prüft bei Dienerangriffen jetzt den tatsächlichen Angriffszähler zusätzlich zum abgeleiteten Angriffsflag. Eine Instanz ohne Windzorn kann dadurch auch bei einem veralteten Statusflag niemals zweimal im selben Zug angreifen.
- Der Bot führt ergänzend ein eigenes Angriffskonto pro Entitäts-ID und Zug. Zwei gleich aussehende Kartenkopien bleiben getrennt, dieselbe Instanz wird ohne Windzorn aber höchstens einmal ausgewählt.

### Karten

- Die Änderungen an Geheimnisbewahrerin und Argentumkommandant sowie offene Karteninteraktionen sind im neuen [Karten-Changelog](KARTEN_CHANGELOG.md) dokumentiert.

## 0.1.2 – 13. August 2026

Interner Build: `2026-08-13-aw`

### Testkosmetik

- Der lokale Befehl `/arkana testkosmetik` schaltet sämtliche im aktuellen Katalog enthaltenen Kartenrücken, Karten-Skins und Helden-Skins für den eingeloggten Charakter frei.
- Der Befehl ist ausschließlich für Annila und Artinea als realmgebundene Arkana-Spielleitung verfügbar; andere Charaktere erhalten keine Freischaltung.
- Die Testfreischaltung sendet keine Netzwerkdaten, verändert keine Kosmetika anderer Spieler und wählt keinen Skin automatisch aus.
- Bereits geöffnete Kosmetikgalerien und das Spielbrett werden nach der Freischaltung sofort aktualisiert.

## 0.1.1 – 13. August 2026

Interner Build: `2026-08-13-av`

### Datenschutz und Serververträglichkeit

- Arkana tritt beim Login keinem eigenen Kanal mehr automatisch bei und hält keinen dauerhaften Kanal-Wächter mehr aktiv.
- Die Einstellungen enthalten zwei sichtbare, standardmäßig deaktivierte Freigaben für Zuschauerübertragung und öffentliche Rangdaten.
- Ein Duell erscheint nur dann in der Zuschauer-Lobby, wenn beide Spieler die Zuschauerfreigabe vor Beginn des Duells aktiviert hatten.
- Im gemeinsamen Kanal werden bei freigegebenen Duellen nur Spielernamen, Klassen, Zugnummer, Wertungsstatus und Build im reduzierten 10-Sekunden-Takt angekündigt.
- Decklisten, Spielaktionen, Kosmetikdaten und Zuschauernamen werden nicht mehr im Kanal verteilt, sondern ausschließlich per Whisper an tatsächlich beigetretene Zuschauer beziehungsweise die beiden Duellanten gesendet.
- Rangdaten werden nur noch von Spielern beantwortet und veröffentlicht, die „Rang öffentlich teilen“ ausdrücklich aktiviert haben.
- Duellnachrichten verwenden ausschließlich gezielte Addon-Whisper; die früher umschaltbaren Party- und öffentlichen Duellkanäle wurden entfernt.
- Eingehende Zuschauer-, Rang- und Verteilungsnachrichten werden auf die erwartete Übertragungsart geprüft.
- Arkana liest weiterhin keine TRP-Profile, Chatverläufe, Gildenlisten, `/who`-Ergebnisse, Inspect-Daten oder sonstige fremde Charakterdaten aus.

### Entfernte Funktionen

- Das Handelsmodul wurde vollständig aus dem Ladeverzeichnis entfernt; dazu gehören Netzwerkpakete, Bestands- und Kosmetik-Transfer-APIs sowie der versteckte Slash-Befehl.
- Entwicklungs- und Diagnosebefehle für Ping, Kanalauswahl, unbegrenzte Testbooster, Modelltests und interne Zustandsdaten wurden aus dem Release-Build entfernt.
- Der unbegrenzte lokale Testbooster-Pfad wurde einschließlich Signatur- und Bestandsfunktionen entfernt.
- Drei ungenutzte Backup-Texturen wurden aus dem Release-Paket entfernt.

### Transparenz und Rollen

- Charakterdaten werden künftig als normale lesbare SavedVariables-Tabelle gespeichert; vorhandene Daten aus dem früheren kompakten Format werden einmalig und verlustfrei migriert.
- Arkana-Freigaben sind transparent hex-kodiert und mit einem Integritätsmarker versehen; sie werden nicht mehr als Verschlüsselung bezeichnet.
- Der bisher verschleierte Signatur-Namespace ist im Quellcode offen dokumentiert. Clientseitige Signaturen werden ausdrücklich nicht als serverseitige Sicherheit dargestellt.
- Sichtbare Bezeichnungen unterscheiden die „Arkana-Spielleitung“ klar von Administratoren des Schattenhain-Servers.
- [COMPLIANCE.md](COMPLIANCE.md) dokumentiert Datenflüsse, Freigaben und die noch notwendige externe Serverfreigabe.
- [ASSET_AUDIT.md](ASSET_AUDIT.md) hält den aktuellen Texturbestand und die vor einer Veröffentlichung noch zu belegenden Bildrechte fest.

## 0.1.0 – 13. August 2026

Interner Build: `2026-08-13-au`

### Fehlerbehebungen und Sicherheit

- Admins, Verteiler und Empfänger werden bei Freigaben jetzt mit ihrem vollständigen, normalisierten Charakter-Realm-Namen geprüft.
- Die Hauptadmins sind ausdrücklich auf `Annila-Schattenhain` und `Artinea-Schattenhain` begrenzt; gleichnamige Charaktere anderer Realms erhalten keine Adminrechte.
- Bereits vergebene ältere Basispakete und Verteilerrechte bleiben über eine kontrollierte Kompatibilitätsprüfung gültig.
- Die Verteilerverwaltung migriert alte realmlose Einträge automatisch auf die realmgebundene Identität.
- Booster werden beim Öffnen erst nach einer vollständig erfolgreichen Ziehung in die Sammlung geschrieben; bei einem Katalogfehler bleiben keine kostenlosen Teilbelohnungen zurück.
- Auch das Hinzufügen vergebener Booster ist jetzt atomar: ungültige oder doppelte Serien verändern den Boosterbestand nicht teilweise.
- Das vollständige Texturpaket wurde wieder in den Projektordner übernommen, damit saubere Installationen alle Kartenbilder, Rahmen, Ränge, Booster und Kosmetikgrafiken enthalten.

### Hauptmenü

- Sämtliche sichtbaren Fenstertitel, Bereichsüberschriften, Aktionshinweise und Spielendmeldungen verwenden jetzt normale Schreibweise statt durchgehender Großbuchstaben.
- Das Hauptmenü wurde vollständig auf einen dunklen Arkana-Stil mit lila Linien und Akzenten umgestellt.
- Das aktive Deck kann direkt im Hauptmenü mit Pfeiltasten gewechselt werden.
- Bei der Deckauswahl im Hauptmenü werden nur vollständige Decks mit 30 Karten berücksichtigt.
- Beim aktiven Deck wird nur noch der Deckname angezeigt; seine Schriftfarbe entspricht der zugehörigen Klasse.
- Der bisherige Menüpunkt „Deck-Builder“ heißt jetzt kurz „Decks“; auch das zugehörige Fenster verwendet diese Bezeichnung.
- Der Herausforderungsbutton heißt jetzt kurz „Herausfordern“.
- Der Handelsbutton wurde aus dem Hauptmenü entfernt.
- Der Rangbereich wurde vereinfacht: Das Rangmedaillon steht zentriert, die Punkte werden zentriert darunter angezeigt.
- Saisoninformationen und die Ranked-Checkbox wurden aus dem Menü entfernt.
- Der Kosmetik-Tab öffnet jetzt eine zentrale Auswahl für Kartenrücken, Karten-Skins und Helden-Skins.
- Beim Öffnen von Rangliste oder Kosmetik wird das Hauptmenü geschlossen und nach dem Schließen wieder geöffnet.
- Die Kosmetikgalerien ersetzen ihr Auswahlmenü ebenfalls vollständig und kehren beim Schließen dorthin zurück; alle Galerien öffnen nun mittig.
- Der Menüpunkt „Verteilung“ wird ausschließlich Hauptadmins und eingetragenen Booster-Verteilern angezeigt.
- Ein neuer Einstellungsbutton öffnet die zentrale Darstellungskonfiguration direkt aus dem Hauptmenü.
- Die Größe der Arkana-Fenster kann dort unabhängig von Spielbrett und Tooltips zwischen 60 und 150 Prozent eingestellt werden.
- Die Fensterskalierung wird gespeichert und automatisch auf bereits geöffnete sowie später erzeugte Arkana-Fenster angewendet.
- Die senkrechten lila Akzentstreifen an den linken Kanten von Fenstern, Buttons, Dropdowns und Listeneinträgen wurden entfernt; Rahmen und horizontale Trennlinien bleiben erhalten.
- Dünne Farbflächen und Trennlinien werden ohne Textur-Pixelrasterung dargestellt; Fensterpositionen rasten nach dem Verschieben auf echten Bildschirmpixeln ein.
- Die drei Kosmetikgalerien verwenden jetzt ebenfalls den dunklen Arkana-Rahmen mit lila Titelleiste und Akzenten.
- Freischalt-Codefelder sowie Einlösen- und Anfrage-Buttons wurden in den Custom-Stil übertragen.
- Die Scrollleisten der Kosmetikgalerien sind ausgeblendet; per Mausrad kann weiterhin gescrollt werden.
- Auswahlrahmen, Hoverzustände und Kategorie-Trennlinien wurden an das lila Arkana-Design angepasst.

### Farbthemen

- In den Einstellungen stehen jetzt elf Farbthemen zur Auswahl: Standard, WoW sowie Druide, Jäger, Magier, Paladin, Priester, Schurke, Schamane, Hexenmeister und Krieger.
- Das neue WoW-Theme kombiniert einen dunklen blauschwarzen Hintergrund mit warmen Lederflächen, goldenen Messinglinien und goldener Titelschrift.
- Die neun Klassenthemen verwenden die jeweiligen WoW-Klassenfarben für Rahmen, Linien, Buttons, Hervorhebungen, Titel und dezent eingefärbte Hintergründe.
- Das gewählte Theme gilt einheitlich für Hauptmenü, Einstellungen, Decks, Booster, Kosmetikgalerien, Verteilung, Zuschauerfenster und Rangliste.
- Ein Themewechsel wird sofort auf bereits geöffnete Arkana-Fenster angewendet und accountweit gespeichert.
- Beim Themewechsel werden auch verbliebene Farben eines zuvor verwendeten Themes erkannt und ersetzt, damit keine gemischten lila und klassenfarbenen Linien oder Rahmen mehr stehen bleiben.
- Die Pfeiltasten im Einstellungsfenster wechseln direkt zwischen allen elf Themes.
- „Zurücksetzen“ stellt neben Position, Skalierung und Deckkraft jetzt auch das Standard-Theme wieder her.

### Decks

- Die Deckverwaltung wurde vollständig neu gestaltet und an das moderne Arkana-Design angepasst.
- Die Kartensammlung verwendet nun ungefähr zwei Drittel der Fensterbreite; der Deckinhalt wird kompakt rechts angezeigt.
- In der Sammlung können bis zu sechs Karten pro Reihe dargestellt werden.
- Sammlung und Deckinhalt sind optisch klar voneinander getrennt.
- Metallische WoW-Standardrahmen und alte rot-goldene Buttons wurden durch dunkle Flächen und lila Akzente ersetzt.
- Die Umschaltung zwischen Listen- und Rasteransicht wurde verständlicher beschriftet.
- Der Deckstand wird deutlich als „X / 30 Karten“ angezeigt und abhängig vom Zustand farblich hervorgehoben.
- Ein leerer Deckbereich zeigt jetzt einen hilfreichen Hinweis anstelle einer unbeschrifteten Fläche.
- Klassenüberschriften wurden vereinfacht und die langen grünen Trennzeichen entfernt.
- Import und Export besitzen eindeutig beschriftete Buttons.
- Die Regler für die Kartengröße sind beschriftet und nur in der jeweiligen Rasteransicht sichtbar.
- Die frühere Wunschliste heißt nun „Favoriten“.
- Überflüssige Besitzanzeigen auf den Karten wurden entfernt.
- Die sichtbaren vertikalen Scrollleisten wurden entfernt; Sammlung und Deck lassen sich weiterhin mit dem Mausrad scrollen.
- Der Button „Aktivieren“ wurde entfernt, da das aktive Deck direkt im Hauptmenü gewählt wird.
- Kartenrücken, Karten-Skins und Helden-Skins wurden aus der Deckverwaltung entfernt und in den Kosmetik-Tab verschoben.
- Dropdown-Menüs wurden vollständig durch eigene dunkle Arkana-Menüs mit lila Rahmen und Hoverzuständen ersetzt.
- Namens-, Such- und Deckcode-Textfelder verwenden jetzt den eigenen Arkana-Stil mit Fokusmarkierung.

### Karten und Booster

- Neue Charaktere starten ohne Karten.
- Das charaktergebundene Basispaket enthält ausschließlich die sammelbaren FREE-Karten in jeweils zwei Exemplaren.
- Der Besitz dieser FREE-Karten ist fest auf exakt zwei Exemplare gesetzt und kann weder durch Booster noch durch Handel oder interne Mengenänderungen verändert werden.
- COMMON-, RARE-, EPIC- und LEGENDARY-Karten sind nicht im Basispaket enthalten.
- Der Booster-Bereich wurde wieder in das Hauptmenü eingebaut und an das dunkle Arkana-Design angepasst.
- Der Booster-Bereich unterstützt jetzt Classic-, Custom- und Legendär-Booster mit ihren vorhandenen eigenen Packmotiven.
- Classic-Booster enthalten fünf Karten ab Common; die fünfte Karte ist garantiert Rare oder besser.
- Custom-Booster enthalten ausschließlich Karten ab Rare und garantieren mindestens eine Karte ab Epic.
- Legendär-Booster enthalten fünf Karten; der fünfte Kartenplatz ist garantiert legendär.
- Die zusätzliche Namenszeile unter gezogenen Karten wurde entfernt; die Kartenbilder werden stattdessen größer und mittig dargestellt.
- Die Booster-Ergebnisse verwenden nur noch das vollständige Kartenbild; zusätzliche farbige Kartentexte, die je nach Kartenmotiv schlecht lesbar waren, werden nicht mehr eingeblendet.
- Beim Öffnen bleibt das Booster-Pack jetzt rund 2,4 Sekunden sichtbar und wackelt deutlich stärker, bevor die Karten aufgedeckt werden.
- Die Packbewegung verwendet native WoW-Animationsgruppen statt einer Lua-Berechnung pro Bildframe, wodurch die Öffnungsphase flüssiger läuft.
- Beim Öffnen werden Boosterbestand und Kartensammlung nur noch einmal aktualisiert; doppelte Bestandsdurchläufe und fünf einzelne Deck-Builder-Aktualisierungen wurden entfernt.
- Der lila Leuchthintergrund hinter dem animierten Booster-Pack wurde entfernt.
- Das Booster-Pack wurde im Ergebnisbereich optisch mittig ausgerichtet und etwas nach unten versetzt.
- Beim Verlassen des Boosterfensters werden die letzte Ziehung und laufende Animationen vollständig aus der Ansicht entfernt.
- Booster-Bestände und gezogene Karten werden charaktergebunden gespeichert.
- Legendäre Karten dürfen weiterhin einmal, alle anderen Karten zweimal pro Deck verwendet werden.
- Alte Booster-Codes werden nicht mehr angenommen.
- Globale Chatmeldungen über gezogene legendäre oder anderweitig seltene Karten wurden entfernt.

### Herausforderungen und Duelle

- Spieler werden ausschließlich über das aktuell ausgewählte Ziel herausgefordert; eine Namenseingabe ist nicht mehr erforderlich.
- Normale Spielerherausforderungen sind immer ungewertet.
- Eingehende gewertete Herausforderungen älterer Clients werden abgelehnt.
- Die spätere Freigabe gewerteter Partien ist für einen gesonderten Turnierleiter-Ablauf vorgesehen.
- Vor dem Duell werden Build, Protokoll, Kartendaten und Deckgültigkeit beider Clients geprüft.

### Zuschauen

- Das Fenster für laufende Spiele wurde vollständig auf das dunkle Arkana-Design umgestellt.
- Jede Partie wird als eigene zweizeilige Karte mit Spielern, Klassen, Zug und Wertungsstatus dargestellt.
- Duelle mit einer inkompatiblen Addon-Version können nicht mehr über den Zuschauerbutton geöffnet werden.
- Die sichtbare Scrollleiste wurde entfernt; die Liste bleibt per Mausrad scrollbar und aktualisiert sich weiterhin automatisch.

### Rangliste

- Die Ranganzeige wurde vollständig aus normalen Spieler- und TRP3-Tooltips entfernt; Rangdaten erscheinen nur noch im Hauptmenü und in der Rangliste.
- Das Rangsystem läuft dauerhaft und nicht mehr in Quartalssaisons.
- Vorhandene Ergebnisse und Rangpunkte bleiben erhalten und werden nicht mehr automatisch zurückgesetzt.
- Saison-Countdown, Saisonhistorie und Saisonbelohnungsfenster wurden entfernt.
- Die Rangliste trägt nur noch den Titel „Rangliste“.
- Rangdaten werden zwischen aktuellen Clients über einen permanenten Ranked-Bereich synchronisiert.
- Der legendäre Kartenrücken bleibt eine dauerhafte Belohnung beim Erreichen von Legende.
- Das Ranglistenfenster verwendet jetzt den modernen Arkana-Rahmen mit lila Akzenten und eigenen Buttons.
- Die Spielstatistik wurde aus den Ranglistenzeilen entfernt; dort stehen nur noch Spielername und Rangfortschritt.
- Siege, Niederlagen und Unentschieden werden nicht mehr mit den Ranglistenansagen übertragen.
- Spielername und Rang werden mittig neben dem Rangmedaillon ausgerichtet.
- Das Ranglistenfenster wurde passend zum vereinfachten Inhalt kompakter gestaltet.
- Der eigene Ranglisteneintrag wird optisch hervorgehoben.
- Die sichtbare Scrollleiste wurde entfernt; die Rangliste bleibt per Mausrad scrollbar.

### Verteilung, Rechte und entfernte Scannerfunktionen

- Annila und Artinea sind als gleichberechtigte Hauptadmins für das Verteilungswerkzeug eingetragen.
- Die Verteilung erfolgt ausschließlich an den aktuell ausgewählten Spieler; eine freie Namenseingabe ist nicht vorhanden.
- Hauptadmins können im Verteilungswerkzeug zwischen Classic-, Custom- und Legendär-Boostern wechseln.
- Die Booster-Vergabe wurde als kompakte Auswahlleiste mit klar getrenntem Typ, Mengenfeld und Senden-Button neu gestaltet.
- Eingetragene Verteiler sehen ausschließlich den fest eingestellten Booster-Typ „Classic“; die Auswahlpfeile für andere Typen werden bei ihnen nicht angezeigt.
- Hauptadmins können über das Verteilungswerkzeug bis zu 9 Booster des gewählten Typs an den aktuell ausgewählten Spieler vergeben.
- Hauptadmins können sich mit `/arkana testbooster [classic|custom|legendär] <1-999>` direkt signierte Testbooster des gewählten Typs geben.
- Testbooster umgehen für Hauptadmins das Verteiler- und Empfänger-Wochenlimit vollständig und verändern dessen aktuellen Zähler nicht; normale Vergaben bleiben weiterhin begrenzt.
- Jeder zusätzlich eingetragene Verteiler kann demselben Empfänger innerhalb von 7 Tagen insgesamt höchstens 3 Booster geben und im Mengenfeld maximal 3 auswählen.
- Ein Empfänger kann über alle Verteiler zusammen innerhalb von 7 Tagen höchstens 9 Booster erhalten.
- Beide 7-Tage-Grenzen werden beim Empfänger anhand der WoW-Serverzeit geprüft und charaktergebunden gespeichert; abgelaufene Vergaben geben ihre Menge automatisch wieder frei.
- Bei einem erreichten Limit werden die verbleibende Menge und der nächste mögliche Freigabezeitpunkt angezeigt.
- Hauptadmins können den aktuell ausgewählten Charakter als Booster-Verteiler eintragen oder wieder entfernen.
- Eingetragene Verteiler werden beim ausführenden Hauptadmin charaktergebunden erfasst; Änderungen werden erst nach erfolgreicher Bestätigung des online befindlichen Ziels übernommen.
- Die Adminansicht zeigt die Anzahl der beim jeweiligen Hauptadmin bestätigten Verteiler an.
- Widerrufe sind signiert und alte Freigaben werden beim entfernten Verteiler gegen erneutes Einspielen gesperrt.
- Entfernte Verteiler verlieren den Menüpunkt „Verteilung“; ein noch geöffnetes Verteilungsfenster wird geschlossen.
- Booster-Verteiler erhalten einen signierten, charaktergebundenen Berechtigungsnachweis und dürfen ausschließlich Classic-Booster vergeben; Basispakete, Custom- und Legendär-Booster sowie weitere Verteilerrechte bleiben den Hauptadmins vorbehalten.
- Die Classic-Beschränkung wird nicht nur im Fenster, sondern auch bei Signaturerstellung, Signaturprüfung und Annahme durch den Empfänger erzwungen; ein veränderter Verteilerclient kann keine anderen Booster-Typen einschleusen.
- Das Verteilungsfenster passt sich an die Rolle an: Hauptadmins sehen alle Verwaltungsbereiche, eingetragene Verteiler nur die Booster-Vergabe.
- Mengenfeld und Hinweistext passen sich an die Rolle an: Hauptadmins sehen maximal 9, Verteiler maximal 3.
- Beschreibungen und Buttontexte im Verteilungsfenster wurden gekürzt, damit sie sich nicht mehr überschneiden.
- Basispaket-Freigaben werden verschlüsselt übertragen, signiert, an den Zielcharakter gebunden und innerhalb der verschlüsselten Charakterablage gespeichert.
- Booster- und Rechtefreigaben werden verschlüsselt übertragen und müssen vom online befindlichen Zielclient bestätigt werden; bei ausbleibender Bestätigung erscheint nach acht Sekunden ein Hinweis.
- Bei Basispaket- und Verteiler-Freigaben muss der echte WoW-Absender Annila oder Artinea sein; Booster-Freigaben akzeptieren zusätzlich eingetragene Verteiler mit gültigem Berechtigungsnachweis.
- Der echte WoW-Absender muss mit dem signierenden Verteiler übereinstimmen; manipulierte, wiederholte oder das 7-Tage-Limit überschreitende Booster-Freigaben werden abgewiesen.
- Interne Bestandsänderungen sind nicht global aufrufbar und doppelte Booster-Serials werden automatisch verworfen.
- Das Verteilungswerkzeug enthält keine Funktionen zum Lesen fremder Sammlungen, Charakterablagen oder sonstiger privater Spielerdaten.
- Funktionen zum Bannen von Spielern, Sperren des Handels und Zurücksetzen oder Abrufen von Spieler-Snapshots sind nicht mehr Bestandteil des Addons.
- Der Radar- beziehungsweise Anwesenheitsscanner wurde aus dem Client entfernt.
- Zugehörige alte Einstellungen und gespeicherte Verwaltungsdaten werden nicht weitergeführt.

### Kompatibilität und Daten

- Der automatische Versions-Broadcast und die Chatmeldung über verfügbare neuere Builds wurden entfernt.
- Direkte Kompatibilitätsprüfungen beim Start eines Duells und beim Zuschauen bleiben erhalten, damit unterschiedliche Builds keine fehlerhaften Partien beginnen.
- Decks, Statistiken, aktives Deck, Ranked-Daten und Kosmetik werden charakterbezogen gespeichert.
- Alte Arkana-/HearthstoneWoW-Daten können weiterhin einmalig übernommen werden.
- Die Speicherung schützt vorhandene Charakterdaten davor, bei einem Ladefehler versehentlich überschrieben zu werden.
- Die lokale Charakterablage besitzt eine Integritätsprüfung; beschädigte Daten werden nicht stillschweigend durch einen leeren Spielstand ersetzt.
- Da Arkana ein clientseitiges WoW-Addon ohne eigenen Server ist, erschweren Signaturen, Absenderbindung und verschlüsselte Ablage Manipulationen im unveränderten Client, können einen vollständig veränderten Addon-Client jedoch nicht absolut verhindern.
- Der interne Build-Stempel kann weiterhin mit `/arkana build` geprüft werden.
