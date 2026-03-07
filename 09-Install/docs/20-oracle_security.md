# Step 20 – Post-Installation Security Hardening

**Phase:** 4 – Post-Installation (nach erfolgreichem WebLogic / Forms / Reports-Betrieb)
**Runs as:** `root`

---

## Übersicht

Diese Checkliste wird **nach** Abschluss der Installation und Verifikation durchgeführt.
Während der Installation wurden temporäre Privilegien gewährt (z. B. NOPASSWD sudo),
die nun zurückgenommen werden müssen.

---

## 1 – sudo-Konfiguration zurücknehmen

### Warum

Während der Installationsphase (Skripte `01` bis `05`) wurde `oracle` NOPASSWD-sudo
gewährt, damit die Skripte mit `sudo -n` (nicht-interaktiv) ausgeführt werden konnten.
Das ist nach der Installation ein unnötiges Sicherheitsrisiko.

### Option A – wheel-Gruppe wieder auf Passwort-Pflicht setzen

Wenn die Erleichterung über die `wheel`-Gruppe gewährt wurde:

```bash
# Aktuellen Stand prüfen
grep wheel /etc/sudoers
# %wheel  ALL=(ALL)  NOPASSWD: ALL   ← temporäre Installations-Einstellung

# Sicher bearbeiten
visudo

# Zeile ändern von:
%wheel  ALL=(ALL)  NOPASSWD: ALL
# Zu:
%wheel  ALL=(ALL)  ALL
```

Verifikation:

```bash
# Als oracle – muss nun nach Passwort fragen (Exit-Code ≠ 0 ohne Passwort)
sudo -n true 2>&1
# Erwartete Ausgabe: sudo: a password is required
```

### Option B – sudoers Drop-in entfernen

Wenn das Drop-in `/etc/sudoers.d/oracle-fmw` angelegt wurde:

```bash
# Inhalt prüfen
cat /etc/sudoers.d/oracle-fmw

# Entfernen
rm /etc/sudoers.d/oracle-fmw

# Sicherheitscheck – kein Syntaxfehler in verbleibenden Dateien
visudo -c
# Erwartete Ausgabe: /etc/sudoers: parsed OK
```

---

## 2 – oracle-Benutzer: sudo ganz entfernen (optional, empfohlen)

Wenn der `oracle`-Benutzer nach der Installation keinerlei sudo-Zugriff mehr braucht:

```bash
# Aus wheel-Gruppe entfernen
gpasswd -d oracle wheel

# Prüfen
id oracle
# groups= darf wheel nicht mehr enthalten

# Test
su - oracle -c "sudo -l"
# Erwartete Ausgabe: User oracle is not allowed to run sudo on ...
```

> **Hinweis:** Der WebLogic-Betrieb (NodeManager, AdminServer, ManagedServer)
> benötigt kein sudo. Die JVMs starten als `oracle`-Benutzer ohne erhöhte Rechte.

---

## 3 – Prüfliste nach Härtung

```bash
# sudo-Konfiguration – oracle darf kein NOPASSWD haben
sudo -l -U oracle | grep NOPASSWD
# Erwartete Ausgabe: (leer)

# wheel-Gruppe
grep wheel /etc/sudoers /etc/sudoers.d/* 2>/dev/null
# Darf kein NOPASSWD: ALL mehr enthalten

# Drop-in-Datei weg
ls -la /etc/sudoers.d/
# oracle-fmw darf nicht mehr auftauchen

# oracle-Gruppen
id oracle
# kein wheel, kein sudo
```

---

## 4 – Weitere Härtungsmaßnahmen (Betrieb)

| Maßnahme | Beschreibung | Wann |
|---|---|---|
| sudo NOPASSWD entfernen | Siehe Abschnitt 1 + 2 | Nach Installation |
| SELinux re-aktivieren | `SELINUX=enforcing` in `/etc/selinux/config` + Reboot | Nach Abnahme (optional) |
| Firewall-Regeln prüfen | Nur Port 80/443 extern offen; 7001/9001/9002/5556 intern | Nach Installation |
| WebLogic Console: HTTPS erzwingen | Admin Console nur über SSL erreichbar | Nach Zertifikats-Setup |
| WebLogic Passwörter rotieren | `boot.properties` neu verschlüsseln | Nach Erstinstallation |
| oracle `.bash_history` bereinigen | Passwörter aus History entfernen | Nach Erstinstallation |

---

## Referenzen

| Thema | Quelle |
|---|---|
| sudo-Konfiguration | `09-Install/docs/00-root_set_os_parameter.md` – Prerequisites-Abschnitt |
| Firewall-Ports | `09-Install/docs/00-root_set_os_parameter.md` – Verification-Abschnitt |
| WebLogic Password-Konzept | `00-Setup/weblogic_sec.sh` |
