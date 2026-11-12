# Reports-Entwicklung mit Git – der Arbeitsablauf

Diese Skripte verbinden den Oracle Reports Builder mit einem Git-Repository.
Jeder Entwickler arbeitet in seiner eigenen Kopie (Clone) unter
`E:\git\<Ihr Login>`, holt sich vor der Arbeit den neuesten Stand und checkt
fertige Berichte wieder ein. Beim Einchecken wird jeder Bericht zusätzlich als
lesbare XML-Datei abgelegt – so sieht man im Git-Server, *was* sich geändert
hat.

Sie brauchen dafür keine Git-Befehle – die Skripte machen das.

## Der Ablauf auf einen Blick

```
  ARBEITSBEGINN
        |
        v
  +-------------------------------+
  | 1. pull.ps1                   |   neuesten Stand vom Git-Server holen
  +-------------------------------+   (Ihre eigenen Änderungen bleiben)
        |
        v
  +-------------------------------+
  | 2. Reports Builder starten    |   Desktop-Verknüpfung "Reports Builder (Git)"
  +-------------------------------+   (mit Administrator-Rechten)
        |
        v
  +-------------------------------+
  | 3. Bericht öffnen, ändern,    |   Berichte liegen in Reports\source\*.rdf,
  |    speichern und schließen    |   Bilder in Reports\images\
  +-------------------------------+
        |
        |   (zwischendurch jederzeit:  status.ps1  - was ist offen?)
        v
  +-------------------------------+
  | 4. checkin.ps1                |   a) neuer Stand auf dem Server? -> erst holen
  |                               |   b) Liste der geänderten Dateien:
  |                               |      Nummer / a (alle) / x (abbrechen)
  |                               |   c) Kommentar: was und warum
  |                               |   d) Bericht .rdf -> .xml umwandeln
  |                               |   e) einchecken und hochladen
  +-------------------------------+
        |
        v
  GIT-SERVER  (Kollegen holen es sich mit pull.ps1)
```

## Einmalige Einrichtung (pro Benutzer)

1. **Git for Windows** ist installiert (fragt der Administrator).
2. **Repository holen** – in einem PowerShell-Fenster:

   ```powershell
   git clone https://<git-server>/<gruppe>/<repo>.git E:\git\$env:USERNAME
   ```

   Ist Ihr Git-Login ein LDAP-Konto, das anders heißt als Ihre
   Windows-Anmeldung, steht es in der Adresse:
   `https://<ldap-login>@<git-server>/...` (Kennwort fragt Git einmal ab und
   merkt es sich).
3. **Name und E-Mail setzen** – einmal:

   ```powershell
   cd E:\git\$env:USERNAME
   .\Reports\git_setup.ps1
   ```

4. **DB-Login für die XML-Umwandlung** – eine Datei mit einer Zeile
   `userid=<db user>/<kennwort>@<tns alias>`, entweder persönlich unter
   `%USERPROFILE%\.rwconv\login.txt` oder an der festen Stelle, die Ihr
   Administrator in `convert_rdf.ps1` eingetragen hat. Die Datei liegt nie im
   Repository.
5. **Desktop-Verknüpfung "Reports Builder (Git)"** – richtet der
   Administrator ein; sie startet den Builder mit Ihren Git-Ordnern als
   Suchpfad (`REPORTS_PATH`).

## Schritt für Schritt

### 1. Arbeitsbeginn: `pull.ps1`

PowerShell **als Administrator** starten (Rechtsklick → "Als Administrator
ausführen") – `checkin.ps1` braucht das später, so reicht ein Fenster für
alles. Dann:

```powershell
cd E:\git\$env:USERNAME
.\Reports\pull.ps1
```

Das Skript holt die Check-ins der Kollegen und zeigt die letzten fünf an. Ihre
eigenen, noch nicht eingecheckten Änderungen bleiben erhalten. Hat ein Kollege
genau den Bericht geändert, an dem Sie auch arbeiten, bricht es ab – **es wird
nichts überschrieben**. Dann den Git-Ansprechpartner fragen.

### 2. Reports Builder starten

Über die Desktop-Verknüpfung **"Reports Builder (Git)"**. Berichte immer aus
`E:\git\<Ihr Login>\Reports\source\` öffnen und dort speichern – nicht aus
anderen Ordnern.

### 3. Arbeiten

Bericht ändern, **speichern und schließen**. Neue Bilder nach
`Reports\images\`. Sprechen Sie sich ab, wer an welchem Bericht arbeitet –
zwei Personen am selben Bericht kann Git nicht zusammenführen (`.rdf` ist
eine Binärdatei).

### 4. Zwischendurch: `status.ps1` (nur anzeigen)

```powershell
.\Reports\status.ps1
```

Zeigt, ohne etwas zu ändern:

- welche Dateien Sie geändert, aber noch nicht eingecheckt haben,
- Check-ins, die bei Ihnen gespeichert, aber noch nicht auf dem Git-Server sind,
- Check-ins auf dem Git-Server, die Sie noch nicht haben,
- die letzten 5 Check-ins – bei Ihnen und auf dem Git-Server.

Am Ende steht, welches Skript als Nächstes dran ist.

### 5. Fertig: `checkin.ps1`

```powershell
.\Reports\checkin.ps1
```

```
Geaenderte Dateien:
    1  geaendert  Reports/source/umsatz.rdf
    2  neu        Reports/source/kunden.rdf
    3  neu        Reports/images/logo.png

Welche Datei einchecken? Nummer (nur diese), a (alle) oder x (abbrechen): 1

Ausgewaehlt: geaendert  Reports/source/umsatz.rdf
Kommentar fuer diesen Check-in (was und warum): Spalte Rabatt ergaenzt
Wandle Reports/source/umsatz.rdf -> Reports/xml/umsatz.xml
...
OK - eingecheckt: Spalte Rabatt ergaenzt
```

Eingecheckt wird **nur die Auswahl** – die anderen Dateien bleiben liegen und
können später eingecheckt werden. Zu einem Bericht gehört immer seine
XML-Datei, die das Skript selbst erzeugt; XML-Dateien nie von Hand ändern.

## Nach dem Einchecken: DEV und Produktion

Gearbeitet wird im Branch **`development`**. Jedes Hochladen dorthin
verteilt **alle** Berichte automatisch auf den Linux-**DEV**-Reports-Server.
Dort testen Sie den Bericht über `rwservlet`. Das Ergebnis der Verteilung
steht in GitLab unter **Build → Pipelines** (grün oder rot).

In die **Produktion** kommt ein Bericht nur einzeln und nur nach
Genehmigung:

```
  Bericht auf DEV getestet
        |
        v
  +-------------------------------+
  | .\Reports\promote.ps1 umsatz  |   a) Bilder mitnehmen? Nummern / a / Enter
  |                               |   b) Grund der Freigabe
  |                               |   c) legt in GitLab einen Merge Request an
  +-------------------------------+      (Ihr Arbeitsordner bleibt, wie er ist)
        |
        v
  GitLab: Merge Request "Release umsatz: <Grund>"
        |   der Verantwortliche prüft, genehmigt und führt ihn zusammen (main)
        v
  GitLab: Pipeline auf main, Knopf "Play"  -->  PRODUKTION
          (nur die freigegebenen Berichte, alle anderen bleiben auf DEV)
```

- Freigegeben wird der Stand auf dem **Git-Server**. Den Bericht also zuerst
  mit `checkin.ps1` einchecken und hochladen, dann `promote.ps1`.
- Nur dieser eine Bericht (mit seiner XML-Datei und den gewählten Bildern)
  geht nach `main`. Ihre anderen Berichte bleiben in `development`.
- Ist der Bericht in `main` schon genau so, meldet das Skript es und tut
  nichts.

| Meldung von `promote.ps1` | Was tun |
|---|---|
| `gibt es auf dem Git-Server in development nicht` | Name prüfen, oder den Bericht zuerst mit `checkin.ps1` einchecken |
| `ist bei Ihnen geaendert und noch nicht eingecheckt` | zuerst `checkin.ps1`, dann wieder `promote.ps1` |
| `ein anderer als auf dem Git-Server` | `status.ps1` ansehen: noch nicht gesendet (`checkin.ps1`, Auswahl `n`) oder noch nicht geholt (`pull.ps1`) |
| `ist in main schon genau so` | nichts zu tun |
| `OK - Merge Request ... angelegt` | in GitLab wartet der Merge Request auf die Genehmigung |

## Die Auswahl beim Einchecken

| Eingabe | Bedeutung |
|---|---|
| Nummer | nur diese eine Datei einchecken (bei einem Bericht mit seiner XML-Datei) |
| `a` | alle geänderten Dateien einchecken |
| `n` | nichts Neues einchecken, nur Check-ins hochladen, die bei Ihnen gespeichert, aber noch nicht auf dem Git-Server sind (z.B. nach einem fehlgeschlagenen Hochladen). Wird nur angeboten, wenn es solche gibt. |
| `x` oder Enter | abbrechen – es wird nichts eingecheckt |

Auch ein leerer Kommentar bricht ab.

## Wenn eine Meldung kommt

| Meldung | Bedeutung | Was tun |
|---|---|---|
| `PowerShell mit 'Als Administrator ausfuehren' starten` | die Reports-Werkzeuge brauchen Administrator-Rechte | PowerShell schließen, mit Rechtsklick "Als Administrator ausführen" neu starten |
| `DB-Login-Datei nicht gefunden` | die Datei für die XML-Umwandlung fehlt | einrichten wie in der Einrichtung Punkt 4 |
| `Wandlung von ... fehlgeschlagen` mit `REP-`-Meldung | der Bericht lässt sich nicht umwandeln (Fehler im Bericht oder falscher DB-Login) | Bericht im Builder öffnen und kompilieren, Login-Datei prüfen – es wurde nichts eingecheckt |
| `rwconverter hat keine Meldung geliefert` | die Umwandlung hat kein Ergebnis gebracht | wie oben |
| `Ein Kollege hat denselben Bericht geaendert` | Sie und ein Kollege haben denselben Bericht geändert | nichts wurde überschrieben – Bericht sichern, Git-Ansprechpartner fragen |
| `Ihr Check-in ist lokal gespeichert, aber NICHT auf dem Git-Server` | das Hochladen ging nicht (Netz, Server, Kollege gleichzeitig) | später erneut `checkin.ps1` – mit `n` nur hochladen |
| `Ungueltige Auswahl` | Eingabe war keine gültige Nummer | Skript neu starten |

## Die Skripte

| Skript | Wann |
|---|---|
| `git_setup.ps1` | einmal pro Benutzer: Name, E-Mail, Zeilenende |
| `pull.ps1` | zu Arbeitsbeginn: neuesten Stand holen |
| `status.ps1` | jederzeit: was ist offen – lokal und auf dem Git-Server (ändert nichts) |
| `checkin.ps1` | Berichte einchecken: Auswahl, Kommentar, Umwandlung nach XML, hochladen |
| `convert_rdf.ps1` | wird von `checkin.ps1` aufgerufen; einzeln: `.\Reports\convert_rdf.ps1 umsatz` wandelt `source\umsatz.rdf` nach `xml\umsatz.xml` |
| `checkin_only.ps1` | wie `checkin.ps1`, aber ohne Reports-Teil – für einen Rechner ohne Reports Builder |
| `promote.ps1` | einen getesteten Bericht für die Produktion freigeben: `.\Reports\promote.ps1 umsatz` legt den Merge Request nach `main` an |

## Regeln

- Gearbeitet wird im Branch `development` (`status.ps1` warnt sonst).
- Vor der Arbeit `pull.ps1`, danach `checkin.ps1` – möglichst am selben Tag.
- In die Produktion nur über `promote.ps1` – nie von Hand nach `main`.
- Ein Bericht – eine Person zur gleichen Zeit (absprechen).
- XML-Dateien erzeugt nur das Skript.
- Kennwörter nie in Dateien im Repository und nie in einen Kommentar.
- Kein `git stash`, kein Zusammenführen von Hand – im Zweifel den
  Git-Ansprechpartner fragen.

Technischer Hintergrund (englisch): `Git_checkin.md` und `Git_deploy.md` im IHateWeblogic-Projekt,
Ordner `70-Customer-Projects/Reports14_builder_windows`.
