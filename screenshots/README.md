# Screenshots — Aufnahme-Anleitung

Dieser Ordner enthält die Bilder, die in der Haupt-README eingebunden werden.
Die README verlinkt auf die unten genannten Dateinamen — nimm die Screenshots
auf dem laufenden VPS auf und lege sie **mit exakt diesen Namen** hier ab.

> **Wichtig — vor dem Hochladen:** Screenshots und Beispiel-Configs dürfen keine
> echten Secrets zeigen. Unkritisch sind interne WireGuard-IPs (`10.100.0.x`),
> Gerätenamen und Public Keys. **Schwärze oder vermeide:** die echte öffentliche
> VPS-IP/Domain, vollständige Client-`PrivateKey`-Werte und scanbare QR-Codes
> echter Clients (lege lieber einen Wegwerf-Test-Client `demo` an und entferne
> ihn nach dem Foto wieder).

---

## Benötigte Bilder

| Dateiname | Inhalt | So aufnehmen |
| --- | --- | --- |
| `dashboard-radar.png` | Live-Dashboard, Radar-Ansicht | `sudo /root/Wireguard2Home.sh` → `3) Status Dashboard (Live)` → `1) Radar`, dann Terminal-Screenshot |
| `dashboard-inspector.png` | Live-Dashboard, Inspector-Ansicht | im Live-Dashboard `v` oder `tab` drücken (wechselt zu Inspector), dann Screenshot |
| `menu.png` | Hauptmenü mit Status-Banner | `sudo /root/Wireguard2Home.sh` → Screenshot der Startansicht (Banner + Menü) |
| `client-list.png` | Client-Übersicht | Menü → `1) Client Manager` → `2) Vorhandene Clients anzeigen` |
| `client-qr.png` | QR-Code einer Client-Config | Menü → `1` → `3) Client-Config inkl. QR-Code anzeigen` (Test-Client `demo`!) |

## Tipps für schöne Terminal-Screenshots

- **Terminalbreite:** mindestens 100 Spalten, damit die Dashboard-Tabellen nicht umbrechen.
- **Theme:** dunkler Hintergrund zeigt die Farb-Statusanzeigen (grün/gelb/rot) am besten.
- **Schrift:** eine Monospace-Schrift mit guter Unicode-Unterstützung (für die `█`/`#`-Balken).
- **macOS:** Terminal/iTerm-Fenster fokussieren → `Cmd+Shift+4`, dann `Leertaste`, dann Fenster anklicken.
- **Zuschneiden:** auf den relevanten Bereich beschneiden, Fensterrahmen ist ok.

## QR-Code separat exportieren (optional)

Die Client-PNG mit QR-Code liegt nach dem Anlegen direkt im Client-Verzeichnis
und kann statt eines Terminal-Screenshots auch direkt verwendet werden:

```bash
# Pfad (Standard SERVICE_USER=root):
/root/wg-clients/<name>.png
```

Für die README am besten einen Test-Client `demo` anlegen, dessen `.png`
hierher kopieren (als `client-qr.png`), und den Test-Client danach wieder entfernen.
