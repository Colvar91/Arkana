# Arkana – Karten-Changelog

Dieses Changelog dokumentiert ausschließlich Änderungen an einzelnen Karten und ihren Regelinteraktionen. Änderungen an Sammlung, Boostern, Deckverwaltung, Oberfläche und Netzwerk stehen weiterhin im allgemeinen [CHANGELOG.md](CHANGELOG.md).

Statusangaben:

- **Behoben:** Die Regeländerung ist im angegebenen Build enthalten.
- **Geprüft:** Kartendaten und relevante Enginepfade wurden kontrolliert; es wurde kein Kartenfehler festgestellt.
- **Offen:** Der Fehler ist bestätigt, aber noch nicht behoben.

## 16. August 2026

### Build `2026-08-16-b`

#### Gesichtsloser Manipulator (`EX1_564`) – behoben

- Statt einer unmodifizierten Grundkarte entsteht jetzt eine unabhängige Kopie des aktuellen Zielzustands.
- Basiswertänderungen, Verzauberungen, aktueller Schaden, Gottesschild, Verstohlenheit, Einfrieren, Schweigen, Kartentrigger und zusätzliche Todesröcheln werden übernommen.
- Aura-Boni werden nicht als dauerhafte Werte dupliziert, sondern nach der Verwandlung passend zur Spielfeldseite des Manipulators neu berechnet.
- Der Manipulator bleibt eine neu beschworene Instanz: Er übernimmt weder den Angriffszähler noch eine vorübergehende gegnerische Kontrollzuordnung. Ansturm und Windzorn aus der kopierten Karte werden anschließend normal ausgewertet.
- Die kopierten Tabellen sind voneinander getrennt; Schweigen oder auslaufende Verzauberungen der Kopie verändern das Original nicht.

### Build `2026-08-16-a`

#### Klerikerin von Nordhain (`CS2_235`) – behoben

- Jede aktive, ungesilencete Klerikerin zieht jetzt genau eine Karte je tatsächlich geheiltem Diener.
- Dabei zählen sowohl eigene als auch gegnerische Diener; geheilte Helden lösen die Karte weiterhin nicht aus.
- Vollständig gesunde Diener stellen kein Leben wieder her und lösen deshalb keinen Kartenzug aus.
- Mehrere Klerikerinnen reagieren getrennt und ziehen jeweils eine Karte pro geheiltem Diener.

#### Kreis der Heilung (`EX1_621`) – behoben

- Die Heilung aller Diener wird nicht mehr direkt in die Lebenswerte geschrieben, sondern durchläuft den zentralen Heilungsablauf.
- Dadurch lösen Klerikerin von Nordhain und andere Heilungsreaktionen zuverlässig für jeden tatsächlich geheilten Diener aus.
- Der Zauber heilt entsprechend seinem Kartentext keine Helden mehr.
- Auchenaiseelenpriesterin kann die Heilung weiterhin regelgerecht in Schaden umwandeln; in diesem Fall wird kein Heilungs-Trigger ausgelöst.

#### Lichtwächterin (`EX1_001`) – mitkorrigiert

- Ihr Heilungs-Trigger berücksichtigt jetzt Charaktere auf beiden Spielfeldseiten statt nur die Seite der Lichtwächterin.
- Sie erhält weiterhin genau +2 Angriff pro tatsächlich geheiltem Charakter und keinen Bonus für wirkungslose Heilung auf vollem Leben.

## 15. August 2026

### Build `2026-08-15-a`

#### Goblinauktionator (`EX1_095`) – behoben

- Eigene gewirkte Zauber ziehen weiterhin genau eine Karte je aktivem, ungesilencetem Goblinauktionator; gegnerische Zauber lösen ihn nicht aus.
- Sein „Immer wenn“-Trigger wird nun vor dem eigentlichen Zaubertext abgearbeitet.
- Schattenschritt auf den Goblinauktionator zieht deshalb zuerst eine Karte und nimmt ihn anschließend auf die Hand zurück.
- Verschwinden zieht ebenfalls zuerst und entfernt den Auktionator erst danach vom Spielfeld.
- Der bereits vorhandene Schutz gegen rückwirkende Trigger bleibt erhalten: Ein Diener, der erst durch den aktuellen Zauber übernommen wurde, reagiert nicht auf denselben Zauber.
- Der Wilde Pyromant verwendet jetzt einen getrennten Nach-Zauber-Trigger und verursacht seinen Flächenschaden weiterhin erst nach der Wirkung des Zaubers.
- Füllt der Auktionator-Zug beim Schattenschritt den letzten Handplatz, entsteht keine unzulässige elfte Karte; der zurückgenommene Diener verfällt stattdessen.

## 13. August 2026

### Build `2026-08-13-ba`

#### Geheimnisbewahrerin (`EX1_080`) – behoben

- Der zuvor fehlende Kartentrigger wurde ergänzt.
- Die Geheimnisbewahrerin erhält unmittelbar und dauerhaft +1/+1, sobald ein Geheimnis erfolgreich ausgespielt wird.
- Geheimnisse beider Spieler lösen den Effekt aus.
- Normale Zauber, Diener und Waffen lösen den Effekt nicht aus.
- Ein durch Gegenzauber verhindertes Geheimnis gilt nicht als ausgespielt und gewährt daher keinen Bonus.
- Mehrere Geheimnisbewahrerinnen reagieren jeweils separat.
- Der Trigger legt den Namen eines gegnerischen Geheimnisses nicht offen.

### Build `2026-08-13-az`

#### Argentumkommandant (`EX1_067`) – geprüft und abgesichert

- Die Kartendaten wurden als korrekt bestätigt: 6 Mana, 4 Angriff, 2 Leben, neutral, selten, Ansturm und Gottesschild.
- Ansturm erlaubt unmittelbar nach dem Ausspielen genau einen Angriff.
- Die Engine prüft das numerische Angriffslimit jetzt zusätzlich zum abgeleiteten Angriffsstatus. Ohne Windzorn kann dieselbe Karteninstanz nicht zweimal im selben Zug angreifen.
- Der lokale Bot führt zusätzlich ein Angriffskonto pro Entitäts-ID und Zug. Zwei ausgespielte Kopien werden getrennt behandelt; jede einzelne Kopie darf ohne Windzorn nur einmal angreifen.
- Ein zweiter Angriff bleibt ausschließlich mit Windzorn oder nach dem erneuten Ausspielen als neue Karteninstanz möglich.

#### Argentumkommandant gegen Giftig – offen

- Die normale Gottesschild-Interaktion verhindert den ersten eingehenden Schaden korrekt.
- Die nachgelagerte Giftig-Auswertung kann momentan trotzdem die tödliche Markierung setzen und dadurch einen Diener durch Gottesschild hindurch vernichten.
- Der Fehler liegt in der allgemeinen Wechselwirkung zwischen Gottesschild und Giftig und betrifft daher nicht ausschließlich den Argentumkommandanten.
