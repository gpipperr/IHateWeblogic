---
nav_title: "Skripte (Deutsch)"
title: "Oracle Reports Entwicklung mit Git – der Arbeitsablauf"
description: "Arbeitsablauf der Reports-Entwickler mit Git unter Windows: Menü, pull, checkin, Status, Freigabe nach Produktion per Release-Tag."
---

# Reports-Entwicklung mit Git – der Arbeitsablauf

Diese Skripte verbinden den Oracle Reports Builder mit einem Git-Repository.
Jeder Entwickler arbeitet in seiner eigenen Kopie (Clone) unter
`E:\git\<Ihr Login>\oracle-report`, holt sich vor der Arbeit den neuesten Stand und checkt
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
  | 3. Bericht öffnen, ändern,    |   Berichte liegen in source\*.rdf,
  |    speichern und schließen    |   Bilder in images\
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
  |                               |   e) einchecken (jeder Bericht einzeln)
  |                               |      und hochladen
  +-------------------------------+
        |
        v
  GIT-SERVER (main)  -->  automatisch auf DEV
        |                 (Kollegen holen es sich mit pull.ps1)
        v
  +-------------------------------+
  | 5. release_tag.ps1            |   auf DEV getestet? prod-Tag setzen
  +-------------------------------+   --> Produktion
```

## Aufbau des Repositorys

```
  E:\git\<Ihr Login>\oracle-report\     (Ihre Kopie des Repositorys)
    menu.cmd, menu.ps1, menu.ini        Menü per Doppelklick
    README.md
    deploy\                             alle Skripte (pull.ps1, checkin.ps1, ...)
    source\                             Berichte (.rdf) - die öffnet der Builder
    xml\                                XML zu jedem Bericht (schreibt checkin.ps1)
    images\                             Bilder der Berichte
```

In die Produktion gehen nur `source\*.rdf` und `images\*`.

## Einmalige Einrichtung (pro Benutzer)

1. **Git for Windows** ist installiert (fragt der Administrator).
2. **Repository holen** – in einem PowerShell-Fenster:

   ```powershell
   git clone https://<git-server>/<gruppe>/oracle-report.git E:\git\$env:USERNAME\oracle-report
   ```

   Ist Ihr Git-Login ein LDAP-Konto, das anders heißt als Ihre
   Windows-Anmeldung, steht es in der Adresse:
   `https://<ldap-login>@<git-server>/...` (Kennwort fragt Git einmal ab und
   merkt es sich).
3. **Name und E-Mail setzen** – einmal:

   ```powershell
   cd E:\git\$env:USERNAME\oracle-report
   .\deploy\git_setup.ps1
   ```

4. **DB-Login für die XML-Umwandlung** – eine Datei mit einer Zeile
   `userid=<db user>/<kennwort>@<tns alias>`, entweder persönlich unter
   `%USERPROFILE%\.rwconv\login.txt` oder an der festen Stelle, die Ihr
   Administrator in [`convert_rdf.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/convert_rdf.ps1) eingetragen hat. Die Datei liegt nie im
   Repository.
5. **Desktop-Verknüpfung "Reports Builder (Git)"** – richtet der
   Administrator ein; sie startet den Builder mit Ihren Git-Ordnern als
   Suchpfad (`REPORTS_PATH`).
6. **Desktop-Icon für das Menü** – einmal:
   - Rechtsklick auf `E:\git\<Ihr Login>\oracle-report\menu.cmd` → *Senden an*
     → *Desktop (Verknüpfung erstellen)*.
   - Verknüpfung → *Eigenschaften* → *Erweitert* → **"Als Administrator
     ausführen"** anhaken ([`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1) braucht das).

## Ohne Tippen: das Menü

Doppelklick auf das Desktop-Icon öffnet das Menü:

```
============================================================
 Oracle Reports Git Handling
============================================================

 1 - pull.ps1              - Hole die letzten Änderungen vom Git-Server
 2 - status.ps1            - Zeige den aktuellen Status an
 3 - status_detail.ps1     - Liste der letzten Check-ins mit Tag und Stand in Produktion
 4 - checkin.ps1           - Bericht einchecken und nach DEV verteilen
 5 - release_tag.ps1 -List - Zeige, was noch nicht in Produktion ist
 6 - release_tag.ps1       - Release-Tag setzen - Bericht in Produktion einspielen

 c = Bildschirm loeschen und Menue neu anzeigen   x / q = beenden
------------------------------------------------------------

Wähle eine Option oder breche mit x / q ab :
```

- Nummer eingeben: kurze Erklärung, dann läuft das Skript **im selben
  Fenster**. Danach erscheint das Menü **direkt darunter wieder** – die
  Ausgabe des Skripts bleibt darüber stehen (nach oben scrollen). Der
  nächste Schritt ist also einfach die nächste Nummer.
- `c` = Bildschirm löschen und das Menü neu anzeigen (wenn es nach
  mehreren Skripten unübersichtlich wird).
- `x` oder `q` = beenden, das Fenster schließt sich.
- Nur falls ein Skript mit Strg+C abgebrochen wurde und das Menü weg ist:
  **`m` + Enter** startet es im selben Fenster neu.
- Was im Menü steht (Reihenfolge, Texte, Parameter), steht in
  [`menu.ini`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/menu.ini) – Änderungen dort macht der Git-Ansprechpartner.
- Die Skripte liegen in `deploy\`, das Menü im obersten Ordner – das steht
  in `menu.ini` als `SkriptPfad = deploy`. Andere Ablage: `SkriptPfad`
  ändern, für alle in `[Menue]` oder je Eintrag, relativ (`deploy`, `..`)
  oder absolut mit `%VARIABLE%` (`E:\git\%USERNAME%\oracle-report\deploy`).
  [`menu.cmd`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/menu.cmd), [`menu.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/menu.ps1) und `menu.ini` bleiben zusammen in einem Ordner.
- Die Fenstergröße (60 Zeilen) steht oben in `menu.cmd` (`ZEILEN`,
  `SPALTEN`). Im Windows Terminal (Windows 11) gilt dessen eigene
  Einstellung.

Die Skripte lassen sich weiterhin auch direkt im PowerShell-Fenster starten,
wie unten beschrieben.

## Schritt für Schritt

### 1. Arbeitsbeginn: `pull.ps1`

PowerShell **als Administrator** starten (Rechtsklick → "Als Administrator
ausführen") – [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1) braucht das später, so reicht ein Fenster für
alles. Dann:

```powershell
cd E:\git\$env:USERNAME\oracle-report
.\deploy\pull.ps1
```

Das Skript holt die Check-ins der Kollegen und zeigt die letzten fünf an. Ihre
eigenen, noch nicht eingecheckten Änderungen bleiben erhalten. Hat ein Kollege
genau den Bericht geändert, an dem Sie auch arbeiten, bricht es ab – **es wird
nichts überschrieben**. Dann den Git-Ansprechpartner fragen.

### 2. Reports Builder starten

Über die Desktop-Verknüpfung **"Reports Builder (Git)"**. Berichte immer aus
`E:\git\<Ihr Login>\oracle-report\source\` öffnen und dort speichern – nicht aus
anderen Ordnern.

### 3. Arbeiten

Bericht ändern, **speichern und schließen**. Neue Bilder nach
`images\`. Sprechen Sie sich ab, wer an welchem Bericht arbeitet –
zwei Personen am selben Bericht kann Git nicht zusammenführen (`.rdf` ist
eine Binärdatei).

### 4. Zwischendurch: `status.ps1` (nur anzeigen)

```powershell
.\deploy\status.ps1
```

Zeigt, ohne etwas zu ändern:

- welche Dateien Sie geändert, aber noch nicht eingecheckt haben,
- Check-ins, die bei Ihnen gespeichert, aber noch nicht auf dem Git-Server sind,
- Check-ins auf dem Git-Server, die Sie noch nicht haben,
- die letzten 5 Check-ins – bei Ihnen und auf dem Git-Server.

Am Ende steht, welches Skript als Nächstes dran ist.

Mehr Details zu den letzten Check-ins – eine Zeile pro Datei, mit Tag und dem Stand in der Produktion:

```powershell
.\deploy\status_detail.ps1        # die letzten 20 Check-ins
.\deploy\status_detail.ps1 50     # die letzten 50
```

```
|Datum           |Commit ID|Datei            |Tag                                     |Prod |
|----------------|---------|-----------------|----------------------------------------|-----|
|2026-11-12 17:08|1c28588  |source/kunde.rdf |NO_TAG                                  |offen|
|2026-11-12 17:08|f7c434c  |source/umsatz.rdf|prod-2026-11-12_1708_umsatz.rdf         |PROD |
|2026-11-12 17:08|f7c434c  |xml/umsatz.xml   |  Freigabe Produktion: umsatz.rdf -     |-    |
|                |         |                 |  Umsatz Spalte                         |     |
|2026-11-12 17:07|52819c1  |source/umsatz.rdf|NO_TAG                                  |alt  |
|2026-11-12 17:07|52819c1  |xml/umsatz.xml   |                                        |-    |

Offen fuer die Produktion (in dieser Liste): 1 Datei(en) - kunde.rdf
```

- **Tag:** der Tag des Check-ins, ohne Tag `NO_TAG`. Hat der Tag einen
  Kommentar (`git tag -a`), steht er eingerückt in der Zeile darunter, lange
  Kommentare umgebrochen – so bleibt die Tabelle schmal.
- **Prod:**

  | Prod | Bedeutung |
  |---|---|
  | `PROD` | genau diese Version ist in der Produktion |
  | `offen` | wartet auf die Freigabe: die Datei war **noch nie** in der Produktion (z.B. ein neuer Bericht) **oder** diese Version ist **neuer** als die in der Produktion. Mehrere offene Versionen einer Datei: freigegeben wird in der Regel die neueste – danach wird sie `PROD`, die älteren offenen werden `alt` |
  | `alt` | ältere Version – die Produktion hat eine andere |
  | `-` | geht nicht in die Produktion (`.xml`, Skripte, Doku, gelöschte Dateien) |

- Darunter: welche Dateien **dieser Liste** noch offen sind – nur die
  gezeigten Check-ins; ältere offene erst mit größerer Anzahl
  (`status_detail.ps1 50`). Danach eine kurze Legende der Spalte Prod.
- Den Namen des Freigabe-Skripts zeigt die Liste nur, wenn er oben im
  Skript in `$ReleaseSkript` eingetragen ist (Standard: leer – jeder hat
  sein eigenes, z.B. `release_tag.ps1`).
- Tags und Stand sind die vom letzten [`pull.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/pull.ps1) – das Skript holt nichts vom
  Git-Server. Meldet es „die Produktion hat neuere Versionen als Ihr Stand“:
  erst `pull.ps1`.

Nur bestimmte Dateien – Teil des Dateinamens genügt, Groß/Klein egal (bei Umlauten muss Groß/Klein stimmen):

```powershell
.\deploy\status_detail.ps1 -File umsatz       # die letzten 20 Check-ins mit 'umsatz' im Dateinamen
.\deploy\status_detail.ps1 5 -File umsatz     # nur die letzten 5
```

### 5. Fertig: `checkin.ps1`

```powershell
.\deploy\checkin.ps1
```

```
Geaenderte Dateien:
    1  geaendert  source/umsatz.rdf
    2  neu        source/kunden.rdf
    3  neu        images/logo.png

Welche Datei einchecken? Nummer (nur diese), a (alle) oder x (abbrechen): 1

Ausgewaehlt: geaendert  source/umsatz.rdf
Kommentar fuer diesen Check-in (was und warum): Spalte Rabatt ergaenzt
Wandle source/umsatz.rdf -> xml/umsatz.xml
...
Check-in: Spalte Rabatt ergaenzt (umsatz.rdf)
...
OK - eingecheckt (1 Check-in(s)): Spalte Rabatt ergaenzt
Die Pipeline in GitLab verteilt die Berichte jetzt auf DEV (Build -> Pipelines).
```

Eingecheckt wird **nur die Auswahl** – die anderen Dateien bleiben liegen und
können später eingecheckt werden. Zu einem Bericht gehört immer seine
XML-Datei, die das Skript selbst erzeugt; XML-Dateien nie von Hand ändern.

## Nach dem Einchecken: DEV und Produktion

Es gibt nur den Branch **`main`**. Jeder Bericht wird **einzeln**
eingecheckt – das macht [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1) selbst, auch bei der Auswahl `a`
(ein Check-in pro Bericht, mit seiner XML-Datei).

- **DEV:** Jedes Hochladen verteilt die geänderten Berichte automatisch auf
  den Linux-**DEV**-Reports-Server – normalerweise genau den eingecheckten
  Bericht. Dort testen Sie ihn über `rwservlet`. Das Ergebnis steht in
  GitLab unter **Build → Pipelines** (grün oder rot).
- **Produktion:** Ein **`prod-`-Tag** auf den Check-in des Berichts startet
  die Verteilung in die Produktion – genau dieser Check-in, sonst nichts.

```
  Bericht auf DEV getestet
        |
        v
  +----------------------------------+
  | .\deploy\release_tag.ps1         |   a) Liste: noch nicht in Produktion
  |                                  |   b) Nummer des Check-ins wählen
  |                                  |   c) Tag-Kommentar (Enter = Vorschlag)
  |                                  |   d) Tag prod-<Datum>_<bericht> setzen
  +----------------------------------+      und zum Git-Server senden
        |
        v
  GitLab: Pipeline zum Tag  -->  PRODUKTION
          (nur der Bericht dieses Check-ins, alle anderen bleiben, wie sie sind)
```

### Freigeben: `release_tag.ps1`

```powershell
.\deploy\release_tag.ps1                  # anzeigen, dann Nummer wählen (Enter = nichts)
.\deploy\release_tag.ps1 -List            # nur anzeigen – keine Frage, kein Tag
.\deploy\release_tag.ps1 -File umsatz     # nur Dateien mit 'umsatz' im Namen
.\deploy\release_tag.ps1 -Filter ''       # alle Dateien statt nur .rdf
```

1. **Noch nicht in Produktion:** die Check-ins auf dem Git-Server, die neuer
   sind als der Stand des Berichts in der Produktion – nummeriert, neueste
   zuerst, mit Dateien und einer Liste pro Datei. In der Produktion ist der
   Check-in mit dem zuletzt gesetzten `prod-`-Tag des Berichts.
2. **Letzte Check-ins:** die letzten 20 Check-ins nach Datum, neueste zuerst
   – jede Datei mit dem Tag ihres Check-ins, ohne Tag `NO_TAG`:

   ```
   Datum             Commit   Datei              Tag
   2026-11-12 17:08  1c28588  source/kunde.rdf   NO_TAG
   2026-11-12 17:08  f7c434c  source/umsatz.rdf  prod-2026-11-12_1708_umsatz.rdf
   ```

   Danach die **letzten 20 Freigaben**, nach Tag sortiert (neuester zuerst)
   – pro Tag nur die Dateien seines Check-ins:

   ```
   Datum             Tag                              Commit   Datei              Freigeber
   2026-11-12 17:08  prod-2026-11-12_1708_umsatz.rdf  f7c434c  source/umsatz.rdf  gpi
   2026-11-12 17:08  prod-2026-11-12_1708_lager.rdf   70b578b  source/lager.rdf   gpi
   ```
3. **Freigabe:** Nummer aus Teil 1 eingeben – oder eine **Commit-ID** aus
   Teil 2, auch einen älteren Check-in → Tag mit Kommentar auf genau diesen
   Check-in, z.B. `prod-2026-11-12_1430_umsatz.rdf`, zum Git-Server senden →
   die Pipeline verteilt den Bericht in die Produktion. Neuere Check-ins
   gehen **nicht** mit.

- Freigegeben wird der Stand auf dem **Git-Server**: den Bericht zuerst mit
  [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1) einchecken und hochladen, auf DEV testen, dann
  [`release_tag.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/release_tag.ps1).
- Standard: nur `.rdf`-Dateien. `-Filter '*.png'` zeigt z.B. nur Bilder –
  auch ein Bild kommt so mit einem eigenen Tag in die Produktion.
- Ein Tag gibt **nur seinen Check-in** frei. Ältere Check-ins anderer
  Berichte bleiben, wo sie sind.

| Meldung von [`release_tag.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/release_tag.ps1) | Was tun |
|---|---|
| `ACHTUNG : Es gibt N neuere(n) Check-in(s) dieser Datei(en)` | Sie haben eine ältere Version gewählt, die neueren gehen nicht mit – mit `n` abbrechen und die neuere wählen (außer Sie wollen bewusst zurück auf die ältere) |
| `Der Check-in hat N Dateien - alle gehen in die Produktion` | ein alter Check-in mit mehreren Dateien – nur taggen, wenn alle in die Produktion sollen |
| `Alles freigegeben - keine offenen Check-ins` | nichts zu tun |
| Pipeline rot: `the tag is on a merge commit` | Tag liegt auf einer Zusammenführung – Git-Ansprechpartner fragen (Tag löschen, richtigen Check-in taggen) |

**Zurück auf eine ältere Version:** in `release_tag.ps1` die Commit-ID des
älteren Check-ins aus Teil 2 eingeben (oder `-Commit <id>`), die
ACHTUNG-Meldung mit `j` bestätigen – er bekommt einen neuen Tag und geht
wieder in die Produktion; die neueren Check-ins stehen danach wieder als
offen in der Liste.

## Die Auswahl beim Einchecken

| Eingabe | Bedeutung |
|---|---|
| Nummer | nur diese eine Datei einchecken (bei einem Bericht mit seiner XML-Datei; der Berichtsname kommt in Klammern hinter den Kommentar) |
| `a` | alle geänderten Dateien einchecken – jede als eigener Check-in (gleicher Kommentar, Dateiname in Klammern dahinter) |
| `n` | nichts Neues einchecken, nur Check-ins hochladen, die bei Ihnen gespeichert, aber noch nicht auf dem Git-Server sind (z.B. nach einem fehlgeschlagenen Hochladen). Wird nur angeboten, wenn es solche gibt. |
| `x` oder Enter | abbrechen – es wird nichts eingecheckt |

Bei einem Bericht (`.rdf`) hängt `checkin.ps1` den Dateinamen immer in
Klammern an den Kommentar an – „Spalte Rabatt ergaenzt (umsatz.rdf)“. So
zeigt GitLab in der Liste der Check-ins, welcher Bericht es war. Steht der
Name schon im Kommentar, wird er nicht noch einmal angehängt.

Auch ein leerer Kommentar bricht ab.

## Wenn eine Meldung kommt

| Meldung | Bedeutung | Was tun |
|---|---|---|
| `PowerShell mit 'Als Administrator ausfuehren' starten` | die Reports-Werkzeuge brauchen Administrator-Rechte | PowerShell schließen, mit Rechtsklick "Als Administrator ausführen" neu starten |
| `DB-Login-Datei nicht gefunden` | die Datei für die XML-Umwandlung fehlt | einrichten wie in der Einrichtung Punkt 4 |
| `Wandlung von ... fehlgeschlagen` mit `REP-`-Meldung | der Bericht lässt sich nicht umwandeln (Fehler im Bericht oder falscher DB-Login) | Bericht im Builder öffnen und kompilieren, Login-Datei prüfen – es wurde nichts eingecheckt |
| `rwconverter hat keine Meldung geliefert` | die Umwandlung hat kein Ergebnis gebracht | wie oben |
| `Ein Kollege hat denselben Bericht geaendert` | Sie und ein Kollege haben denselben Bericht geändert | nichts wurde überschrieben – Bericht sichern, Git-Ansprechpartner fragen |
| `Ihr Check-in ist lokal gespeichert, aber NICHT auf dem Git-Server` | das Hochladen ging nicht (Netz, Server, Kollege gleichzeitig) | später erneut [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1) – mit `n` nur hochladen |
| `Ungueltige Auswahl` | Eingabe war keine gültige Nummer | Skript neu starten |

## Die Skripte

| Skript | Wann |
|---|---|
| [`menu.cmd`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/menu.cmd) / [`menu.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/menu.ps1) | Menü per Doppelklick (Desktop-Icon): Skript wählen, läuft im selben Fenster, danach kommt das Menü wieder (`c` = Bildschirm löschen, `x` / `q` = beenden); Inhalt aus [`menu.ini`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/menu.ini) |
| [`git_setup.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/git_setup.ps1) | einmal pro Benutzer: Name, E-Mail, Zeilenende |
| [`pull.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/pull.ps1) | zu Arbeitsbeginn: neuesten Stand holen |
| [`status.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/status.ps1) | jederzeit: was ist offen – lokal und auf dem Git-Server (ändert nichts) |
| [`status_detail.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/status_detail.ps1) | Liste der letzten 20 Check-ins: Datum, Commit ID, Datei, Tag, Prod (`PROD` / `offen` / `alt`) – eine Zeile pro Datei (ändert nichts) |
| [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1) | Berichte einchecken: Auswahl, Kommentar, Umwandlung nach XML, hochladen |
| [`convert_rdf.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/convert_rdf.ps1) | wird von [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1) aufgerufen; einzeln: `.\deploy\convert_rdf.ps1 umsatz` wandelt `source\umsatz.rdf` nach `xml\umsatz.xml` |
| [`checkin_only.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin_only.ps1) | wie [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1), aber ohne Reports-Teil – für einen Rechner ohne Reports Builder |
| [`release_tag.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/release_tag.ps1) | einen getesteten Bericht für die Produktion freigeben: zeigt offene Check-ins und die letzten `prod-`-Tags, setzt den Tag – die Pipeline verteilt dann in die Produktion; Standard nur `.rdf`, `-Filter` ändert das; `-List` = nur anzeigen |

## Regeln

- Es gibt nur den Branch `main` ([`status.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/status.ps1) warnt sonst).
- Jeder Bericht ein eigener Check-in – [`checkin.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/checkin.ps1) macht das selbst.
- Vor der Arbeit [`pull.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/pull.ps1), danach `checkin.ps1` – möglichst am selben Tag.
- In die Produktion nur über einen `prod-`-Tag mit [`release_tag.ps1`](https://github.com/gpipperr/IHateWeblogic/blob/main/70-Customer-Projects/Reports14_builder_windows/scripts/release_tag.ps1) – nie von Hand kopieren.
- Ein Bericht – eine Person zur gleichen Zeit (absprechen).
- XML-Dateien erzeugt nur das Skript.
- Kennwörter nie in Dateien im Repository und nie in einen Kommentar.
- Kein `git stash`, kein Zusammenführen von Hand – im Zweifel den
  Git-Ansprechpartner fragen.

Technischer Hintergrund (englisch): [`Git_checkin.md`](../Git_checkin.md) und [`Git_deploy.md`](../Git_deploy.md) im IHateWeblogic-Projekt,
Ordner `70-Customer-Projects/Reports14_builder_windows`.
