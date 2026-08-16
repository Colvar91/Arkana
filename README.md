# Arkana

[![Downloads](https://img.shields.io/github/downloads/Colvar91/Arkana/total?style=for-the-badge&label=Downloads)](https://github.com/Colvar91/Arkana/releases)
[![Latest Release](https://img.shields.io/github/v/release/Colvar91/Arkana?style=for-the-badge&label=Version)](https://github.com/Colvar91/Arkana/releases/latest)

**Arkana** ist ein rundenbasiertes Sammelkarten- und Duell-Addon für World of Warcraft. Es bringt Deckbau, Kartenpartien, Booster, Kosmetik, eine Rangliste und einen Zuschauermodus direkt in die WoW-Oberfläche.

> Version `0.1.6` · Build `2026-08-16-f` · Interface `90207` · Sprache: Deutsch

Arkana befindet sich in aktiver Entwicklung. Die aktuelle Fassung ist noch keine Freigabe durch das Schattenhain-Team; Hinweise für eine spätere Abnahme stehen in [COMPLIANCE.md](COMPLIANCE.md).

## Funktionen

- Charaktergebundene Kartensammlung und mehrere Decks mit jeweils 30 Karten
- Rundenbasierte Duelle mit Dienern, Zaubern, Waffen, Heldenfähigkeiten und Geheimnissen
- Herausforderungen über das aktuell ausgewählte Ziel
- Animiertes Öffnen von Classic-, Custom- und legendären Boostern
- Kartenrücken, Karten-Skins und Helden-Skins im eigenen Kosmetikbereich
- Arkana-Rangsystem mit Rangbild und Punkten
- Zuschauermodus für ausdrücklich freigegebene laufende Partien
- Modernes dunkles Design mit Standard-, WoW- und neun Klassenthemes
- Einstellbare Fenster-, Spielfeld- und Tooltip-Skalierung sowie Spielfelddeckkraft
- Lokale Karten-Sandbox für berechtigte Entwicklungstests

## Einstieg

Ein neuer Charakter beginnt ohne Karten und Booster. Die Arkana-Spielleitung kann dem ausgewählten Charakter einmalig das charaktergebundene Basispaket geben. Darin ist jede als `Free` eingestufte Karte genau zweimal enthalten; Karten von `Common` bis `Legendary` gehören nicht zum Basispaket.

Danach läuft eine erste Partie so ab:

1. Über **Decks** ein Deck erstellen und speichern.
2. Das aktive Deck im Hauptmenü mit den Pfeilen auswählen.
3. Einen Spieler mit Arkana als WoW-Ziel auswählen.
4. **Herausfordern** anklicken und auf die Annahme warten.

Im Ort `OOC-Gebiet` können keine Herausforderungen gestartet werden.

## Hauptmenü

| Bereich | Aufgabe |
|---|---|
| Decks | Decks erstellen, bearbeiten, importieren und exportieren |
| Herausfordern | Das ausgewählte Ziel zu einer Partie einladen |
| Zuschauen | Freigegebene laufende Partien anzeigen und ansehen |
| Rangliste | Arkana-Ränge der freigegebenen Spieler anzeigen |
| Booster | Vorhandene Booster öffnen und neue Karten erhalten |
| Kosmetik | Kartenrücken, Karten- und Helden-Skins auswählen |
| Einstellungen | Skalierung, Deckkraft, Theme und Freigaben verwalten |
| Verteilung | Basispakete, Booster und Verteiler verwalten; nur für berechtigte Rollen sichtbar |

## Booster und Verteilung

Basispakete, Booster und Verteilerrechte werden nur an das ausgewählte Ziel übertragen und sind an dessen Charakter gebunden. Eingetragene Booster-Verteiler dürfen ausschließlich Classic-Booster vergeben. Ein Verteiler kann einem Empfänger höchstens drei Booster pro Woche geben; ein Empfänger kann insgesamt höchstens neun Booster pro Woche erhalten. Die Arkana-Spielleitung verwaltet Verteiler und die verfügbaren Booster-Typen.

Da WoW-Addons vollständig auf dem Rechner des Spielers liegen, sind lokale Signaturen nur Integritätsbarrieren für den unveränderten Client. Eine technisch nicht umgehbare Kartenökonomie würde einen vom Serverbetreiber kontrollierten Dienst erfordern.

## Befehle

`/arkana` und `/ark` öffnen das Hauptmenü. Zusätzlich stehen folgende Befehle zur Verfügung:

| Befehl | Funktion |
|---|---|
| `/arkana challenge` | Ausgewähltes Ziel herausfordern |
| `/arkana booster` | Boosterfenster öffnen |
| `/arkana skins` | Kosmetikbereich öffnen |
| `/arkana spectate` | Zuschauermodus beziehungsweise Lobby öffnen |
| `/arkana settings` | Einstellungen öffnen |
| `/arkana build` | Aktuellen Build anzeigen |
| `/arkana check` | Sammlung, Decks und lokalen Speicherzustand prüfen |
| `/arkana msgs on\|off` | Arkana-Infomeldungen ein- oder ausschalten |
| `/arkana 3d on\|off` | 3D-Zaubereffekte ein- oder ausschalten |
| `/arkana tooltips <0.1-2.0>` | Tooltip-Skalierung festlegen |
| `/arkana reset` | Positionen, Größen, Deckkraft und Theme zurücksetzen |

Die Befehle `/arkana verteilung`, `/arkana testkosmetik` und `/arkana sandbox` sind nur für die jeweils eingetragenen Arkana-Rollen verfügbar. Die Sandbox verändert weder Sammlung noch Rang oder Spielstatistik und wird neutral beendet.

## Installation

1. Den vollständigen Ordner `Arkana` nach `<World of Warcraft>/Interface/AddOns/` kopieren.
2. Prüfen, dass `Arkana.toc` direkt im Ordner `Arkana` liegt und kein zusätzlicher Unterordner dazwischenliegt.
3. Arkana in der Addon-Auswahl des vorgesehenen WoW-Clients aktivieren.
4. WoW neu starten oder nach einem Update `/reload` ausführen.
5. Mit `/arkana build` kontrollieren, ob der erwartete Build geladen wurde.

Die benötigten Ace3-Bibliotheken sind im Addon enthalten.

## Datenschutz und Netzwerk

Arkana liest keine TRP-Profile, Chatverläufe, Gilden-, Freundes- oder `/who`-Listen und greift nicht auf fremde SavedVariables zu. Das aktuelle Ziel wird nur für Herausforderungen und berechtigte Verteilungen verwendet.

Netzwerkverkehr entsteht erst durch eine passende Nutzeraktion, etwa eine Herausforderung, eine Verteilung oder das Öffnen von Zuschauer- beziehungsweise Ranglistenfunktionen. Das Addon enthält keine Spielerbanns, Handelssperren, Rollbacks, Radar- oder Umgebungsscanner, globalen Kartenfund-Broadcasts oder Versionswerbung. Einzelheiten stehen in [COMPLIANCE.md](COMPLIANCE.md).

## Projektstruktur

| Pfad | Inhalt |
|---|---|
| `Core/` | Sammlung, Netzwerk, Regeln, Rangsystem, Sicherheit und Kartendaten |
| `UI/` | Hauptmenü, Decks, Booster, Spielfeld, Animationen und Verwaltungsfenster |
| `Textures/` | Karten-, Rahmen-, Rang-, Booster- und Kosmetikgrafiken |
| `CHANGELOG.md` | Allgemeine Änderungen am Addon |
| `KARTEN_CHANGELOG.md` | Kartenregeln, Fehlerkorrekturen und Testfälle |
| `COMPLIANCE.md` | Datenschutz-, Netzwerk- und Serverprüfung |
| `ASSET_AUDIT.md` | Prüfstand der verwendeten Grafikdateien |

## Entwicklungsstand

Die nächsten geplanten Schwerpunkte sind die weitere Absicherung privilegierter Vergaben, eine gestalterische Überarbeitung des Kampffelds und zusätzliche Karten-, Treffer- und Übergangsanimationen. Behobene Fehler und Regeländerungen werden getrennt im [allgemeinen Changelog](CHANGELOG.md) und im [Karten-Changelog](KARTEN_CHANGELOG.md) dokumentiert.

## Mitwirkende

Arkana wurde von **Tecro** und **Varoo** erstellt. Fortgeführt von Annila.

