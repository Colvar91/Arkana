# Arkana – Datenschutz- und Serverprüfung

Stand: 16. August 2026 · Build `2026-08-16-f`

Dieses Dokument beschreibt, was der veröffentlichungsnahe Client technisch tut. Es ist keine Freigabe durch das Schattenhain-Team. Arkana sollte erst verteilt werden, nachdem das Team die konkrete Version schriftlich genehmigt und – falls verlangt – in den vorgesehenen Launcher-/Addon-Prozess aufgenommen hat.

## Lokale Daten

Arkana speichert nur eigene Addon-Daten des eingeloggten Charakters: Sammlung, Booster, Decks, aktives Deck, Arkana-Spielstatistik, Rangfortschritt, Kosmetika, Freigaben und UI-Einstellungen. Die charakterbezogenen Daten liegen lesbar in `ARKANA_CharData`. Ein vorhandener Spielstand im früheren kompakten Format wird einmalig lokal migriert.

Der Client liest keine TRP-Profile, Chatverläufe, Gildenlisten, `/who`-Listen, Freundeslisten, Inspect-Daten oder fremde SavedVariables. Das aktuelle Ziel wird nur für „Herausfordern“ und die berechtigte Arkana-Verteilung verwendet.

## Netzwerkverkehr

| Zweck | Transport | Inhalt | Auslöser |
|---|---|---|---|
| Duell | Whisper an den ausgewählten Gegner | Handshake, Deckliste, Spielaktionen, Ergebnis | Herausforderung/Annahme |
| Verteilung | Whisper an das ausgewählte Ziel | Zielgebundene Arkana-Freigabe und Bestätigung | Berechtigte Spielleitung/Verteiler |
| Zuschauer-Lobby | Temporärer Kanal `ARKANA` | Beide Namen, Klassen, Zugnummer, Wertungsstatus, Build | Nur wenn beide Duellanten vorher zugestimmt haben |
| Zuschauer-Stream | Whisper an beigetretene Zuschauer | Decklisten, Aktionen und Kosmetik | Zuschauer tritt einem freigegebenen Spiel bei |
| Rangliste | Temporärer Kanal `ARKANA` | Abfrage; Rangantwort nur bei Opt-in | Spieler öffnet Rangliste bzw. hat Rangfreigabe aktiviert |
| Karten-Sandbox | Kein Transport (nur lokal) | Lokaler Testzustand, gewählte Testkarten und passives Trainingsziel | Spieler startet „Sandbox“ oder `/arkana sandbox` |

Der Addon-Kanal wird nicht beim Login automatisch betreten. Zuschauer- und Rangfreigabe sind standardmäßig aus. Lobby-Heartbeats laufen höchstens alle zehn Sekunden. Arkana schreibt keine normalen Chatnachrichten und versendet keine Versionswerbung.

Sandbox-Sitzungen sind lokale, neutrale Kartentests und ausschließlich für `Annila-Schattenhain` freigeschaltet. Testkarten und frei konfigurierbare Gegner-Dummys existieren nur im flüchtigen Spielzustand, werden nicht in die Sammlung geschrieben und erzeugen keine Duell-, Zuschauer-, Lobby- oder Ranglistennachrichten. Das Beenden verändert weder Rang noch Spielstatistik. Menü, Sandbox-Modul und Engine prüfen die realmgebundene Berechtigung samt Integritätsnachweis. Weil der gesamte Addoncode beim Spieler liegt, bleibt auch diese Prüfung mit einem vollständig veränderten Client technisch umgehbar; eine nicht umgehbare Berechtigung erfordert eine serverseitige Autorität.

## Arkana-Rollen

„Arkana-Spielleitung“ und „Booster-Verteiler“ sind ausschließlich Rollen innerhalb dieses Addons. Sie verleihen keine Rechte auf Schattenhain, keine GM-/Moderationsrechte und keinen Zugriff auf fremde Charakterdaten. Das Werkzeug kann nur Arkana-Basiskarten, Booster und Arkana-Verteilerrechte verwalten.

Die realmgebundenen Arkana-Admins sind `Annila-Schattenhain`, `Artinea-Schattenhain` und `Romash-Schattenhain`.

Der lokale Befehl `/arkana testkosmetik` ist auf diese Arkana-Spielleitung beschränkt. Er schaltet ausschließlich Kosmetik des eigenen Charakters frei und erzeugt keinen Netzwerkverkehr. Er vergibt keine Karten oder Booster.

Clientseitige Signaturen und Absenderprüfungen sind Integritätsbarrieren für den unveränderten Client, aber keine unüberwindbare Sicherheitsgrenze. Wenn Booster oder Ranglistenwerte serverweit verbindlich sein sollen, muss die Autorität in einen vom Betreiber kontrollierten Serverdienst verlagert werden.

## Bewusst nicht enthalten

- Spielerbanns, Handelssperren oder Sanktionen
- Snapshots, Rollbacks oder Abruf fremder Spielstände
- Kartenhandel und Kosmetikhandel
- Radar-, Anwesenheits- oder Umgebungsscanner
- TRP-/Profil-Auswertung
- globale Seltenheits-, Versions- oder Werbe-Broadcasts
- Release-Befehle für dauerhafte Testkarten, unbegrenzte Testbooster oder interne Zustandsdaten; die flüchtigen Karten der lokalen Sandbox werden nicht gespeichert

## Noch offene Freigabepunkte

1. Schriftliche Genehmigung der konkreten Addon-Version durch das Schattenhain-Team einholen. Das [Schattenhain-Regelwerk](https://wiki.schattenhain.de/Regelwerk) und der [Einstiegsleitfaden](https://wiki.schattenhain.de/index.php/Einstieg_ins_Rollenspiel) bleiben maßgeblich.
2. Klären, ob die Installation ausschließlich über den Schattenhain-Launcher oder dessen freigegebene Addon-Liste erfolgen muss.
3. Für jede ausgelieferte Grafik Herkunft und Nutzungsrecht in [ASSET_AUDIT.md](ASSET_AUDIT.md) belegen. Bis dahin ist der Texturbestand nicht als zur Veröffentlichung freigegeben zu betrachten.
4. Die Blizzard-[Richtlinien für UI-Addons](https://eu.forums.blizzard.com/de/wow/t/richtlinien-f%C3%BCr-die-entwicklung-von-addons-f%C3%BCr-die-benutzeroberfl%C3%A4che-von-wow/32618) gegen die finale Paket- und Verteilungsform prüfen.

## Abnahmetest

- Frischer Charakter: beide Datenschutzfreigaben stehen auf „Aus“.
- Login ohne UI-Aktion: kein Beitritt zum Kanal `ARKANA` und keine Arkana-Sendung.
- Nur ein Duellant stimmt zu: Partie erscheint nicht in der Lobby.
- Beide stimmen zu: Lobby-Metadaten erscheinen; Decks/Aktionen sind keine Kanalpakete.
- Rangfreigabe aus: auf `RKPING` wird keine eigene Rangantwort gesendet.
- Karten-Sandbox: kein Addon-Netzwerkverkehr; vergebene Testkarten verändern die Sammlung nicht und „Sandbox beenden“ erzeugt weder Sieg, Niederlage noch Unentschieden.
- Verteilung: nur ausgewähltes Online-Ziel erhält die Freigabe; falscher Absender, falsches Ziel und Wiederholung werden abgewiesen.
- `/arkana trade`, `/arkana testbooster`, `/arkana ping`, `/arkana channel`, `/arkana m2check`, `/arkana dstest` und `/arkana debug` öffnen keine versteckten Funktionen.
