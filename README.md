# Wireguard2Home

> **Self-contained WireGuard VPN stack that bypasses CGNAT.** A lightweight VPS acts as hub; a Gateway-Host (Raspberry Pi or any Linux machine) bridges your entire home LAN through the encrypted tunnel — reachable from any device, anywhere in the world.
>
> Features a single-script bootstrap installer with all sub-scripts embedded (no GitHub dependency at runtime), a live traffic dashboard with per-client RX/TX stats, a full client manager with QR-code export, automated offsite backups to the Gateway-Host, and a one-command restore. Supports full-tunnel, split-tunnel, and home-DNS filter modes. Runs on Debian, Ubuntu, Fedora, Arch, openSUSE and Raspberry Pi OS.

---

Eigenständiger WireGuard-VPN-Stack zum Überbrücken von CGNAT. Ein leichtgewichtiger VPS dient als Knotenpunkt; ein Gateway-Host (Raspberry Pi oder jeder andere Linux-Rechner) verbindet das gesamte Heimnetz verschlüsselt mit dem Tunnel — erreichbar von jedem Gerät, überall auf der Welt.

Enthält einen vollständig eigenständigen Bootstrap-Installer mit eingebetteten Sub-Scripts (kein GitHub-Zugriff zur Laufzeit nötig), ein Live-Traffic-Dashboard mit RX/TX-Statistiken pro Client, einen vollständigen Client-Manager mit QR-Code-Export, automatisierte Offsite-Backups zum Gateway-Host sowie eine Ein-Befehl-Wiederherstellung. Unterstützt Full-Tunnel, Split-Tunnel und Heimnetz-DNS-Filter. Läuft auf Debian, Ubuntu, Fedora, Arch, openSUSE und Raspberry Pi OS.

---

# Schnellnavigation

* [Projektziel](#projektziel)
* [Infrastruktur](#infrastruktur)
* [WireGuard Netz](#wireguard-netz)
* [Adressierung](#adressierung)
* [Features](#features)
* [Status Dashboard](#status-dashboard)
* [Projektstruktur](#projektstruktur)
* [Installer](#installer)
* [Laufzeit-Konfiguration](#laufzeit-konfiguration)
* [Starten](#starten)
* [Menü](#menü)
* [Sicherheit](#sicherheit)
* [Backup Empfehlung](#backup-empfehlung)
* [Restore](#restore)
* [Reboot Verhalten](#reboot-verhalten)
* [Monitoring Stack](#monitoring-stack)
* [Reverse Proxy](#reverse-proxy)
* [Hardware-Anforderungen](#hardware-anforderungen)
* [Lizenz](#lizenz)
* [Geplante Features](#geplante-features)
* [Mögliche Erweiterungen](#mögliche-erweiterungen)

---

# Projektziel

Das Ziel dieses Projekts ist der Aufbau einer vollständig kontrollierten privaten Infrastruktur für:

* sicheren Heimnetz-Zugriff
* CGNAT-Bypass
* Remote-Zugriff
* Reverse-Proxying
* Selfhosting
* VPN Infrastruktur
* mobile Clients
* Zero-Trust ähnliche Netzwerke

Die Infrastruktur basiert auf:

```text
Internet
   │
   ▼
VPS (WireGuard Hub)
   │
   ▼
WireGuard Tunnel
   │
   ▼
Raspberry Pi Gateway
   │
   ▼
Heimnetzwerk
```

---

# Infrastruktur

## VPS

Funktionen:

* WireGuard Server
* Reverse Proxy
* SSL Termination
* CrowdSec
* Fail2Ban
* Watchtower
* Statping-NG
* Tunnel Hub

---

## Raspberry Pi

Funktionen:

* Heimnetz Gateway
* Tunnel Endpoint
* Routing
* Zugriff auf internes LAN

---

## Heimnetz

Aktuelles Netz:

```text
192.168.50.0/24
```

---

# WireGuard Netz

```text
10.100.0.0/24
```

---

# Adressierung

| Gerät                | IP         |
| -------------------- | ---------- |
| VPS                  | 10.100.0.1 |
| Raspberry Pi Gateway | 10.100.0.2 |
| Clients ab           | 10.100.0.3 |

---

# Features

## Client erstellen

Automatisch:

* nächste freie IP finden
* Keypair generieren
* `.conf` erzeugen
* QR-Code erzeugen
* PNG speichern
* Server-Config erweitern

---

## DNS Auswahl

Beim Erstellen eines Clients wird ein DNS-Server zugewiesen. Die Optionen sind in drei Gruppen aufgeteilt:

### Heimnetz-DNS — Anfragen gehen durch den Tunnel ins Heimnetz

Diese beiden Optionen sind **entweder/oder** — je nachdem was im Heimnetz läuft:

| Option | Beispielwert | Wann verwenden |
| ------ | ------------ | -------------- |
| **Heim-DNS-Server** | `192.168.50.53` | Pi-hole, AdGuard Home oder eigener DNS-Server vorhanden → Werbeblocker, eigene Regeln, lokale Hostnamen aktiv |
| **Router** | `192.168.50.1` | Kein dedizierter DNS-Server → Router übernimmt DNS, lokale DHCP-Hostnamen erreichbar (z. B. `nas.fritz.box`) |

> Nur eine der beiden Optionen wählen — sie decken denselben Anwendungsfall ab, für unterschiedliche Heimnetz-Setups.

### Öffentliche DNS — Anfragen gehen direkt ins Internet

| Option | DNS |
| ------ | --- |
| Cloudflare | `1.1.1.1, 1.0.0.1` |
| Google | `8.8.8.8, 8.8.4.4` |
| OpenDNS | `208.67.222.222, 208.67.220.220` |

### Sonstiges

| Option | Bedeutung |
| ------ | --------- |
| Kein DNS | Keine `DNS =`-Zeile in der Config — Gerät nutzt eigene Einstellungen |
| Custom DNS | Freie Eingabe, z. B. `192.168.50.200` oder `1.1.1.1, 8.8.8.8` |

### Presets anpassen

Die lokalen Werte sind Beispielwerte und sollten über `/etc/wireguard2home.conf` auf das eigene Heimnetz angepasst werden:

```bash
WIREGUARD2HOME_DNS_HOME_LABEL="AdGuard Home"
WIREGUARD2HOME_DNS_HOME_VALUE="192.168.50.53"
WIREGUARD2HOME_DNS_ROUTER_LABEL="FRITZ!Box"
WIREGUARD2HOME_DNS_ROUTER_VALUE="192.168.50.1"
```

Für reine Split-Tunnel-Clients ohne Namensauflösung kann `Kein DNS` gewählt werden.

---

## Tunnel Modi

### Full Tunnel

```ini
AllowedIPs = 0.0.0.0/0
```

Gesamter Traffic läuft über VPN.
Sinnvoll für Reisen, fremde WLANs und wenn der Client immer so verhält, als wäre er komplett im geschützten Heim- oder VPS-Netz.

---

### Split Tunnel Heimnetz

```ini
AllowedIPs = 192.168.50.0/24, 10.100.0.0/24
```

Nur Heimnetzverkehr über VPN. Das normale Internet bleibt lokal.

---

### Split Tunnel + Heim-DNS-Filter

Beispiel:

```ini
DNS = 192.168.50.53
AllowedIPs = 192.168.50.0/24, 10.100.0.0/24, 192.168.50.53/32
```

Praktisch für Handy, Tablet oder Laptop unterwegs:

* Internet bleibt direkt über Mobilfunk oder lokales WLAN
* Interne Heimnetz-Ziele sind über WireGuard erreichbar
* DNS wird fest auf den Heim-DNS (AdGuard Home, Pi-hole) gesetzt

---

### Individueller Split Tunnel

Beispiel:

```ini
AllowedIPs = 192.168.50.10/32, 192.168.50.20/32, 10.100.0.0/24
```

Nur ausgewählte Hosts/Netze über VPN.

---

# Status Dashboard

Wireguard2Home enthält ein integriertes WireGuard-Dashboard mit:

* Online-/Offline-/Stale-Status
* letztem Handshake
* interner WireGuard-IP
* externem Endpoint
* RX/TX Traffic pro Client (live, täglich, monatlich)

Verfügbare Ansichten:

* `radar` — kompakte Live-Tafel
* `inspector` — Detailansicht mit Ranglisten und Infra-Block

Tasten:

* `v` oder `tab` zum Umschalten
* `q` zum Beenden

## Speedtests

* `Tunnel Speedtest` — misst den Durchsatz über den WireGuard-Tunnel mit `iperf3`
* `VPS Aussen-Speedtest` — misst einen HTTP-Download vom VPS als Richtwert für die äußere Anbindung

---

# Projektstruktur

## Repository

```text
README.md
install-wireguard2home.sh     ← Self-contained Bootstrap (6000+ Zeilen, beinhaltet alle Sub-Scripts)
install-vps.sh                ← VPS-Installer (eigenständig und im Bootstrap eingebettet)
install-gateway-host.sh       ← Gateway-Host-Installer (eigenständig und im Bootstrap eingebettet)
Wireguard2Home.sh             ← Zentrale CLI für den VPS-Betrieb
wireguard-dashboard.sh        ← Live-Dashboard (eigenständig und im Bootstrap eingebettet)
create-wg-client.sh           ← Client-Manager (eigenständig und im Bootstrap eingebettet)
backup-wireguard2home.sh      ← Backup-Script (eigenständig und im Bootstrap eingebettet)
restore-wireguard2home.sh     ← Restore-Script (eigenständig und im Bootstrap eingebettet)
runtime-paths.sh              ← Gemeinsame Laufzeit-Konfiguration (eingebettet)
```

Hinweis:
Auf dem VPS wird produktiv nur `Wireguard2Home.sh` verwendet.
Die Einzel-Scripts bleiben im Repository als kanonische Quelle und Referenz.
`install-wireguard2home.sh` bündelt alle Sub-Scripts als eingebettete Heredocs —
eine Installation benötigt keine externen Downloads.

## Wichtige Pfade (Standard-Setup)

| Pfad | Inhalt |
| --- | --- |
| `/etc/wireguard/wg0.conf` | WireGuard Server-Config |
| `/root/Wireguard2Home.sh` | Zentrale CLI |
| `/root/wg-clients/` | Client-Configs und QR-Codes |
| `/root/backups/gate2home/` | Lokale Backups |
| `/etc/wireguard2home.conf` | Laufzeit-Konfiguration |

Die Pfade unter `/root/` sind Standardwerte für `SERVICE_USER=root`.
Mit `--service-user USERNAME` werden alle App-Dateien stattdessen ins Home des angegebenen Users gelegt.

---

# Installer

## Bootstrap (empfohlener Weg)

Der Bootstrap `install-wireguard2home.sh` ist **vollständig eigenständig** — alle Sub-Scripts sind eingebettet.
Ein einzelner Download genügt; es sind keine weiteren Remote-Zugriffe nötig.

> **Root-Login ist nicht nötig.** Der Installer benötigt Root-Rechte (für `wg`, `systemctl`, `iptables`),
> aber jeder User mit `sudo`-Berechtigung kann ihn ausführen.

### Download via curl

```bash
curl -fsSL \
  https://raw.githubusercontent.com/wikicell/Wireguard2Home/main/install-wireguard2home.sh \
  -o install-wireguard2home.sh
chmod +x install-wireguard2home.sh
```

### Download via wget

```bash
wget -O install-wireguard2home.sh \
  https://raw.githubusercontent.com/wikicell/Wireguard2Home/main/install-wireguard2home.sh
chmod +x install-wireguard2home.sh
```

### Alternativ: SCP aus einem lokalen Klon

```bash
scp install-wireguard2home.sh user@DEIN_VPS:~/
```

### Dann starten

```bash
sudo ./install-wireguard2home.sh
```

Wenn das Script im gleichen Verzeichnis wie die Einzel-Scripts liegt (z. B. bei einem `git clone`),
nutzt es die lokalen Dateien direkt. Andernfalls extrahiert es die eingebetteten Versionen.
Als letzter Fallback lädt es fehlende Scripts von GitHub nach.

---

### Bootstrap auf dem VPS starten

```bash
sudo ./install-wireguard2home.sh --role vps
```

* richtet den VPS vollständig ein (Pakete, Keys, wg0.conf-Template, Wireguard2Home.sh)
* zeigt danach einen fertigen Gateway-Host-Befehl mit allen benötigten Keys

---

### Bootstrap auf dem Gateway-Host starten

```bash
sudo ./install-wireguard2home.sh --role gateway --vps-host root@DEIN_VPS
```

Mit eigenem SSH-Key:

```bash
sudo ./install-wireguard2home.sh --role gateway --vps-host root@DEIN_VPS --vps-ssh-key ~/.ssh/id_rsa
```

* stößt den VPS-Installer remote per SSH an
* überträgt benötigte Scripts per SCP (kein GitHub-Download auf dem VPS nötig)
* liest VPS WireGuard-Key und Backup-Key automatisch aus
* installiert den Gateway-Host lokal mit genau diesen Werten

---

### Manuelle Installation (Schritt für Schritt)

Wer lieber einzelne Scripts manuell ausführen möchte, kann die Einzel-Scripts direkt aus dem Repository nutzen.

**VPS:**

```bash
sudo ./install-vps.sh
```

**Gateway-Host:**

```bash
sudo ./install-gateway-host.sh \
  --server-public-key "VPS_PUBLIC_KEY" \
  --vps-backup-public-key "VPS_BACKUP_PUBLIC_KEY"
```

---

### Bootstrap-Optionen

* `--role vps|gateway`
  Erzwingt die Installationsrichtung.
* `--vps-host USER@HOST`
  Adresse des VPS für den Gateway-Weg (mit SSH-Zugriff).
* `--vps-ssh-key PFAD`
  SSH-Key für die VPS-Verbindung, wenn kein Agent-Key verfügbar ist.
* `--service-user USER`
  Lokaler administrativer User für App-Dateien, Backups und Client-Configs.
* `--service-home PFAD`
  Home-Pfad des lokalen Service-Users.
* `--remote-service-user USER`
  Service-User auf dem VPS.
* `--remote-service-home PFAD`
  Home des Service-Users auf dem VPS.
* `--remote-install-dir PFAD`
  Zielverzeichnis für Scripts auf dem VPS.

---

## VPS-Installer (install-vps.sh)

Der VPS-Installer richtet Kern-Abhängigkeiten, Verzeichnisse, den Backup-SSH-Key und bei Bedarf ein `wg0.conf`-Template ein.

```bash
curl -fsSL \
  https://raw.githubusercontent.com/wikicell/Wireguard2Home/main/install-vps.sh \
  -o install-vps.sh
chmod +x install-vps.sh
sudo ./install-vps.sh
```

Optional:

```bash
sudo ./install-vps.sh --with-ufw-fail2ban --with-docker
```

### Installationsoptionen

* `--script-source PFAD` — alternative Quelle für `Wireguard2Home.sh`
* `--config-file PFAD` — abweichender Pfad für `/etc/wireguard2home.conf`
* `--service-user USER` — administrativer User für App-Dateien
* `--service-home PFAD` — Home des Service-Users
* `--backup-ssh-user USER` — User für den Offsite-Backup-SSH-Key
* `--backup-remote-user USER` — Ziel-User auf dem Gateway-Host
* `--server-address CIDR` — lokale WireGuard-IP des VPS
* `--wg-network CIDR` — WireGuard-Subnetz
* `--listen-port PORT` — WireGuard-Lauschport (Standard: 51820)
* `--lan-subnet CIDR` — Heimnetz hinter dem Gateway-Host
* `--dns-home-label TEXT` — Anzeigename für Heim-DNS-Preset
* `--dns-home-value IPS` — DNS-Wert für Heim-DNS-Preset
* `--dns-router-label TEXT` — Anzeigename für zweites DNS-Preset
* `--dns-router-value IPS` — DNS-Wert für zweites Preset
* `--with-ufw-fail2ban` — installiert zusätzlich ufw und fail2ban (Host)
* `--with-docker` — installiert Docker und Compose-Plugin
* `--with-reverse-proxy` — Reverse-Proxy-Stack (Nginx Proxy Manager); impliziert `--with-docker`
* `--with-monitoring` — Monitoring-Stack (Uptime-Tool, Watchtower, CrowdSec); impliziert `--with-docker`
* `--uptime-tool statping|kuma` — Verfügbarkeits-Monitoring: Statping-NG (Standard) oder Uptime Kuma (interaktiv abgefragt)
* `--with-crowdsec-bouncer` — aktiviert zusätzlich den CrowdSec Firewall-Bouncer (Standard: aus)
* `--pushover-token` / `--pushover-user` — Pushover-Zugang für Watchtower-Benachrichtigungen (optional, interaktiv abgefragt)
* `--with-swap` — richtet eine Swap-Datei ein (Standard: 1024 MB unter `/swapfile`); empfohlen bei wenig RAM zusammen mit `--with-monitoring`
* `--swap-size-mb N` — Größe der Swap-Datei in MB (Standard: 1024)
* `--swap-file PFAD` — Pfad der Swap-Datei (Standard: `/swapfile`)

Hinweis: Bei `--with-monitoring` prüft der Installer den verfügbaren RAM und
warnt (bzw. fragt interaktiv nach), wenn weniger als ~900 MB erkannt werden.
Details unter [Hardware-Anforderungen](#hardware-anforderungen).

### Keys auf dem VPS

```bash
# WireGuard Server Public Key
sudo cat /etc/wireguard/server_public.key

# SSH Public Key für Offsite-Backups zum Gateway-Host
# (Pfad hängt vom SERVICE_USER ab, Standard: root)
sudo cat /root/.ssh/gate2home_backup.pub
# oder mit eigenem Service-User:
# cat ~/.ssh/gate2home_backup.pub
```

---

## Gateway-Host-Installer (install-gateway-host.sh)

Richtet Kern-Abhängigkeiten, IP-Forwarding, Backup-Empfangsverzeichnis und ein `wg0.conf`-Template ein.

```bash
curl -fsSL \
  https://raw.githubusercontent.com/wikicell/Wireguard2Home/main/install-gateway-host.sh \
  -o install-gateway-host.sh
chmod +x install-gateway-host.sh
sudo ./install-gateway-host.sh
```

Unterstützte Distributionen:

| Zielsystem | Status |
| --- | --- |
| Raspberry Pi OS | Gut unterstützt |
| Debian / Ubuntu | Gut unterstützt |
| Fedora / Rocky / AlmaLinux | Unterstützt (dnf/yum) |
| Arch Linux | Unterstützt (pacman) |
| openSUSE | Unterstützt (zypper) |
| VM mit systemd | Gut unterstützt |
| VM ohne systemd | Teilweise — Dienste manuell starten |

Beispiel mit NAT/Masquerade:

```bash
sudo ./install-gateway-host.sh \
  --server-public-key "VPS_PUBLIC_KEY" \
  --vps-backup-public-key "VPS_BACKUP_PUBLIC_KEY" \
  --enable-masquerade \
  --masquerade-interface eth0
```

### Installationsoptionen

* `--gateway-address CIDR` — WireGuard-IP des Gateway-Hosts (Standard: 10.100.0.2/24)
* `--wg-network CIDR` — WireGuard-Subnetz
* `--lan-subnet CIDR` — Heimnetz hinter dem Gateway-Host
* `--service-user USER` — lokaler administrativer User
* `--server-endpoint HOST:PORT` — WireGuard-Endpoint des VPS
* `--server-public-key KEY` — WireGuard-Public-Key des VPS
* `--vps-backup-public-key KEY` — SSH-Public-Key des VPS für Backup-Zugriff
* `--enable-masquerade` — NAT/Masquerade in wg0.conf-Template
* `--masquerade-interface IFACE` — ausgehendes Interface für NAT (z. B. eth0)

### Gateway-Host Public Key

```bash
sudo cat /etc/wireguard/raspberry_public.key
```

---

## Reihenfolge einer frischen Installation

1. VPS: `install-wireguard2home.sh --role vps` ausführen.
2. VPS Public Key und Backup Public Key notieren (vom Installer ausgegeben).
3. Gateway-Host: `install-wireguard2home.sh --role gateway --vps-host root@VPS` ausführen.
   Oder manuell: `install-gateway-host.sh` mit beiden Keys ausführen.
4. Den vom Gateway-Installer ausgegebenen Peer-Block in `/etc/wireguard/wg0.conf` auf dem VPS eintragen.
5. Auf beiden Systemen `systemctl restart wg-quick@wg0` prüfen.
6. Auf dem VPS `/root/Wireguard2Home.sh` starten.

---

# Laufzeit-Konfiguration

Alle Scripts lesen `/etc/wireguard2home.conf` und passen Pfade und User entsprechend an.

Typische Anpassungen:

```bash
WIREGUARD2HOME_SERVICE_USER=w2h
WIREGUARD2HOME_SERVICE_HOME=/home/w2h
WIREGUARD2HOME_BACKUP_SSH_USER=backupbot
WIREGUARD2HOME_BACKUP_SSH_HOME=/home/backupbot
WIREGUARD2HOME_BACKUP_REMOTE_USER=backup
WIREGUARD2HOME_BACKUP_REMOTE_HOME=/srv/backup
WIREGUARD2HOME_CLIENT_DIR=/home/w2h/wg-clients
WIREGUARD2HOME_BACKUP_BASE=/home/w2h/backups/gate2home
WIREGUARD2HOME_PRE_RESTORE_ROOT=/home/w2h/pre-restore-backups
WIREGUARD2HOME_STATE_DIR=/var/lib/gate2home/wg-dashboard
WIREGUARD2HOME_TARGET_SCRIPT=/home/w2h/Wireguard2Home.sh
WIREGUARD2HOME_BACKUP_SSH_KEY=/home/backupbot/.ssh/gate2home_backup
WIREGUARD2HOME_BACKUP_REMOTE_HOST=10.100.0.2
WIREGUARD2HOME_BACKUP_REMOTE_TARGET=/srv/backup/backups/from-vps
WIREGUARD2HOME_DNS_HOME_LABEL="AdGuard Home"
WIREGUARD2HOME_DNS_HOME_VALUE=192.168.50.53
WIREGUARD2HOME_DNS_ROUTER_LABEL="FRITZ!Box"
WIREGUARD2HOME_DNS_ROUTER_VALUE=192.168.50.1
WIREGUARD2HOME_LAN_SUBNET=192.168.50.0/24
WIREGUARD2HOME_SPEEDTEST_HOST=10.100.0.2
WIREGUARD2HOME_SPEEDTEST_USER=root
WIREGUARD2HOME_SPEEDTEST_SIZE_MB=64
```

Hinweis:

* Systemnahe Dateien wie `/etc/wireguard`, `systemctl` und `sysctl` bleiben weiterhin Root-Aufgaben.
* Die Konfiguration macht das Projekt benutzerkonfigurierbar, nicht root-frei.

---

# Starten

```bash
# Standard (SERVICE_USER=root):
sudo /root/Wireguard2Home.sh

# Mit eigenem Service-User:
sudo /home/USERNAME/Wireguard2Home.sh
```

---

# Menü

```text
1) Client Manager
2) Status Dashboard (Snapshot)
3) Status Dashboard (Live)
4) Backup erstellen
5) Restore starten
6) Speedtests
7) Hilfe
8) Beenden
```

---

# Sicherheit

Das Projekt verwaltet Private Keys, VPN-Zugangsdaten und interne Netzstrukturen. Daher:

* niemals öffentlich teilen
* Backups verschlüsseln
* Zugriff auf das Client-Verzeichnis absichern (Standard: `/root/wg-clients`)

---

# Backup Empfehlung

Wichtige Verzeichnisse:

```text
/etc/wireguard/
/root/wg-clients/
/root/backups/gate2home/
```

Im Standard-Setup liegen Client-Dateien, Backups und Restore-Snapshots unter `/root`.
Mit einer angepassten `/etc/wireguard2home.conf` verschieben sich diese Pfade passend zum gewählten Service-User.

---

# Restore

Wireguard2Home enthält eine integrierte Restore-Funktion für gesicherte Gate2Home-Backups.

## Interaktiv starten

```bash
sudo /root/Wireguard2Home.sh   # Standard (SERVICE_USER=root)
```

Dann im Menü: `5) Restore starten`

## Varianten

* `Echter Restore`
* `Dry-Run`

## Restore-Modi

* `wireguard` — stellt `/etc/wireguard` wieder her
* `clients` — stellt das konfigurierte Client-Verzeichnis wieder her
* `full` — stellt alle gesicherten Verzeichnisse wieder her

Vor jeder Wiederherstellung wird der aktuelle Zustand zusätzlich unter dem konfigurierten Restore-Snapshot-Pfad gesichert (Standard: `/root/pre-restore-backups/`).

---

# Reboot Verhalten

WireGuard startet automatisch:

```bash
sudo systemctl enable wg-quick@wg0
```

Das Setup ist reboot-sicher.

---

# Monitoring Stack

Optionaler Docker-Stack auf dem VPS, aktivierbar mit `--with-monitoring`:

* Verfügbarkeits-Monitoring — wahlweise **Statping-NG** (Standard, Port `8080`,
  öffentliche Status-Seiten) oder **Uptime Kuma** (Port `3001`), auswählbar
  interaktiv oder per `--uptime-tool statping|kuma`
* Watchtower — automatische Container-Updates
* CrowdSec — Angriffserkennung (SSH + Nginx Proxy Manager)
* Pushover — Benachrichtigungen über Watchtower (Token/User interaktiv oder per `--pushover-token` / `--pushover-user`)
* Fail2Ban — Host-seitig über `--with-ufw-fail2ban`

Beispiel:

```bash
# Standard (Statping-NG)
sudo ./install-vps.sh --with-monitoring

# Mit Statping-NG statt Uptime Kuma
sudo ./install-vps.sh --with-monitoring --uptime-tool statping
```

Hinweise:

* `--with-monitoring` installiert bei Bedarf automatisch Docker und das Compose-Plugin.
* Der CrowdSec **Firewall-Bouncer** ist standardmäßig **aus** (Schutz vor versehentlichem SSH-Aussperren) und lässt sich mit `--with-crowdsec-bouncer` aktivieren.
* Pushover-Secrets landen ausschließlich in einer root-only `/opt/watchtower/.env` — niemals im Repository.

## Compose-Dateien (Monitoring)

Der Installer legt die folgenden Dateien an. Sie sind hier dokumentiert, falls
du sie manuell prüfen, anpassen oder ohne den Installer ausrollen möchtest.

Das Verfügbarkeits-Monitoring wird je nach `--uptime-tool` als **eine** der
beiden folgenden Varianten ausgerollt.

### Statping-NG — `/opt/statping/docker-compose.yml` (Standard)

Öffentliche Status-Seiten (ähnlich wie statuspage.io), konfigurierbare Services,
optionaler HTTPS-Zugang über NPM. Kein separater nginx-proxy nötig — NPM übernimmt
SSL und Reverse Proxy. Das Image `statping/statping:dev` ist das aufgegebene
Original-Projekt; wir verwenden das aktiv gewartete Fork-Image.

```yaml
services:
  statping:
    image: adamboutcher/statping-ng:latest
    container_name: statping-ng
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:8080"
    volumes:
      - ./app:/app
    environment:
      - DB_CONN=sqlite
      - NAME=Gate2Home Status
      - DESCRIPTION=Dienst-Ueberwachung
```

> **Sicherheit:** Port `8080` ist auf `127.0.0.1` gebunden — nur NPM (auf
> demselben Host) kann darauf zugreifen. Kein Direktzugriff aus dem Internet.
> Docker umgeht UFW via iptables direkt; `127.0.0.1`-Binding ist die einzig
> zuverlässige Absicherung.

**Setup:** NPM als HTTPS-Proxy konfigurieren (Port 81, per SSH-Tunnel erreichbar):
Proxy Host anlegen → Forward Hostname `localhost`, Port `8080`, SSL/Let's Encrypt aktivieren.

### Uptime Kuma — `/opt/uptime-kuma/docker-compose.yml` (`--uptime-tool kuma`)

Intern orientiertes Monitoring ohne öffentliche Status-Seiten-Funktion.

```yaml
services:
  uptime-kuma:
    image: louislam/uptime-kuma:1
    container_name: uptime-kuma
    restart: unless-stopped
    ports:
      - "127.0.0.1:3001:3001"
    volumes:
      - ./data:/app/data
```

> **Sicherheit:** Port `3001` auf `127.0.0.1` — Zugriff nur via NPM-Proxy oder
> SSH-Tunnel: `ssh -L 3001:localhost:3001 root@VPS_IP -N`

### Watchtower — `/opt/watchtower/docker-compose.yml`

```yaml
services:
  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    restart: unless-stopped
    env_file:
      - .env
    environment:
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_SCHEDULE=0 0 4 * * *
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
```

Die zugehörige `/opt/watchtower/.env` (Modus `600`, nur `root`) enthält bei
gesetzten Pushover-Werten:

```ini
WATCHTOWER_NOTIFICATIONS=shoutrrr
WATCHTOWER_NOTIFICATION_URL=pushover://shoutrrr:<TOKEN>@<USER>
PUSHOVER_TOKEN=<TOKEN>
PUSHOVER_USER=<USER>
```

Ohne Pushover bleiben diese Zeilen auskommentiert und Watchtower läuft ohne
Benachrichtigungen.

### CrowdSec — `/opt/crowdsec/docker-compose.yml`

```yaml
services:
  crowdsec:
    image: crowdsecurity/crowdsec:latest
    container_name: crowdsec
    restart: unless-stopped
    environment:
      - COLLECTIONS=crowdsecurity/sshd crowdsecurity/nginx-proxy-manager
    volumes:
      - ./config:/etc/crowdsec
      - ./data:/var/lib/crowdsec/data
      - /var/log:/var/log:ro
      - /opt/npm/data/logs:/opt/npm/data/logs:ro
```

CrowdSec-Acquisition — `/opt/crowdsec/config/acquis.yaml`:

```yaml
---
filenames:
  - /var/log/auth.log
labels:
  type: syslog
---
filenames:
  - /opt/npm/data/logs/*.log
labels:
  type: nginx
```

---

# Reverse Proxy

Optionaler Docker-Stack auf dem VPS, aktivierbar mit `--with-reverse-proxy`:

* Nginx Proxy Manager — Admin-UI auf Port `81`, HTTP/HTTPS auf `80`/`443`
* automatische SSL-Zertifikate (Let's Encrypt)
* externe Domains
* Heimnetz Reverse Proxying (über den WireGuard-Tunnel zum Gateway-Host)

Beispiel:

```bash
sudo ./install-vps.sh --with-reverse-proxy
```

Erst-Login im Nginx Proxy Manager: `admin@example.com` / `changeme` — bitte sofort ändern.

## Compose-Datei (Reverse Proxy)

### Nginx Proxy Manager — `/opt/npm/docker-compose.yml`

```yaml
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    container_name: npm
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "127.0.0.1:81:81"
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
```

> **Sicherheit:** Port `81` (Admin-Panel) ist auf `127.0.0.1` gebunden — nicht
> direkt aus dem Internet erreichbar. Docker umgeht UFW-Regeln via iptables;
> ein `127.0.0.1`-Binding ist die einzig zuverlässige Absicherung.
>
> **Zugriff auf das Admin-Panel** per SSH-Tunnel vom lokalen Rechner:
> ```bash
> ssh -L 8181:localhost:81 root@VPS_IP -N
> ```
> Dann im Browser: `http://localhost:8181`

Manuelles Ausrollen (statt über den Installer):

```bash
cd /opt/npm
sudo docker compose up -d
```

Beide Stacks lassen sich kombinieren:

```bash
sudo ./install-vps.sh --with-reverse-proxy --with-monitoring
```

---

# Hardware-Anforderungen

WireGuard selbst ist ein Kernel-Modul und braucht praktisch kein RAM. Der reine
Tunnel läuft daher auch auf sehr kleinen VPS problemlos. Der optionale
Reverse-Proxy- und Monitoring-Stack läuft dagegen in Docker-Containern und
braucht spürbar mehr Arbeitsspeicher.

## VPS (Hub)

| Szenario | vCores | RAM | Disk | Port |
|---|---|---|---|---|
| Nur Tunnel | 1 | 0.5 GB | 10 GB | beliebig |
| Tunnel + Reverse Proxy | 1–2 | 1 GB | 10–20 GB | je nach Last |
| Tunnel + Reverse Proxy + Monitoring | 2 | 2 GB | 20–40 GB | echte 1 Gbit/s |
| Komfortabel Gigabit, voller Stack | 2–4 | 2 GB | 20–40 GB | echte 1 Gbit/s |

Grober RAM-Bedarf des vollen Stacks im Leerlauf:

| Komponente | RAM (typisch) |
|---|---|
| Ubuntu Base + systemd | ~150–200 MB |
| Docker-Daemon | ~80 MB |
| Nginx Proxy Manager | ~150 MB |
| Statping-NG (Standard)    | ~90 MB |
| Uptime Kuma (alternativ)  | ~120 MB |
| CrowdSec | ~120 MB |
| Watchtower | ~30 MB |
| **Summe** | **~650–700 MB** |

Auf einem 0.5-GB-VPS übersteigt das den physischen RAM — Container können vom
OOM-Killer beendet werden. Abhilfe:

* **Swap** als Notnagel: `--with-swap` (siehe unten). Federt das RAM-Limit ab,
  ist aber langsamer als echter RAM.
* **Upgrade** auf ≥ 1 GB (besser 2 GB) RAM — die saubere Lösung für den vollen Stack.
* **Monitoring auslagern** auf den Gateway-Host (Raspberry), der den VPS durch
  den Tunnel überwacht.

## Gigabit ausreizen

Entscheidend sind drei Dinge — RAM ist dabei *nicht* der Flaschenhals:

1. **CPU:** WireGuard-Verschlüsselung ist CPU-gebunden. 1 vCore schafft je nach
   CPU grob 400–900 Mbit/s. Für stabile, symmetrische Gigabit-Last (plus
   Reverse-Proxy/TLS) sind **2+ vCores** mit AES-NI empfehlenswert.
2. **Provider-Port:** Viele günstige VPS haben einen gedrosselten oder geteilten
   Uplink (100–500 Mbit/s). Prüfe die zugesicherte **Anbindung/Port-Speed** —
   sonst helfen auch viele Cores nichts.
3. **Gesamte Kette:** Es zählt der langsamste Punkt aus VPS-Uplink,
   Heimanschluss-Upload und CGNAT-Pfad.

## Swap einrichten

Bei wenig RAM richtet der Installer auf Wunsch eine Swap-Datei ein:

```bash
sudo ./install-vps.sh --with-reverse-proxy --with-monitoring --with-swap
```

Standardmäßig 1024 MB unter `/swapfile`, dauerhaft via `/etc/fstab`, mit
`vm.swappiness=10`. Größe/Pfad anpassbar über `--swap-size-mb` und `--swap-file`.
Bei aktivem `--with-monitoring` prüft der Installer den RAM und warnt vor zu
wenig Arbeitsspeicher (interaktiv mit Rückfrage), sofern kein Swap angefordert
wurde.

## Gateway-Host

Ein Raspberry Pi (oder vergleichbarer SBC) mit 1 GB RAM genügt für die
Gateway-Rolle. Für Gigabit-Durchsatz über den Tunnel gilt auch hier: die CPU
ist der begrenzende Faktor — ein Raspberry Pi 4/5 ist deutlich schneller als
ältere Modelle.

---

# Lizenz

Dieses Projekt steht unter der `MIT License`.

Die vollständigen Lizenzbestimmungen stehen in [LICENSE](LICENSE).

Kurz gesagt:

* Nutzung, Anpassung und Weitergabe sind erlaubt
* auch kommerzielle Nutzung ist erlaubt
* der Copyright- und Lizenzhinweis muss erhalten bleiben
* die Software wird ohne Gewähr bereitgestellt

---

# Geplante Features

## WebUI

* Browserbasierte Clientverwaltung
* QR-Code direkt im Browser
* Multiuser, Rollen, Audit Logs

## REST API

* Client erstellen / löschen
* QR-Code abrufen
* Status abrufen
* DNS Profile verwalten

## Dockerisierung

* WireGuard Manager Container
* API Container
* WebUI Container

---

# Mögliche Erweiterungen

* `WebUI mit Rollenmodell` — Browseroberfläche mit Login, Rollen, Audit-Log
* `REST API` — Automatisierung, externe Integrationen, Mobile-Apps
* `Tailscale- oder ZeroTier-Fallback` — alternativer Overlay bei blockiertem UDP
* `AdGuard Home / Pi-hole Integration` — DNS-Profile mit Blocklisten koppeln
* `GeoIP Blocking` — ergänzend zu CrowdSec und Fail2Ban
* `VLAN Awareness` — gezielter Zugriff auf Teilnetze
* `Multi-Gateway Support` — mehrere Standorte im selben Hub
* `Backup-Verschlüsselung` — mit `age` oder `gpg`
* `Mehrere Offsite-Ziele` — S3, Hetzner Storage Box, zweiter VPS
* `Metrics Exporter` — Prometheus-Anbindung
* `Grafana Dashboard` — historische Traffic- und Backup-Visualisierung
* `HA- oder Warm-Standby-Modell` — zweiter VPS als Standby
* `Geräteprofile und Vorlagen` — vordefinierte Profile für iPhone, macOS, IoT

---

# Zielplattformen

Clients:

* iPhone
* iPad
* macOS
* Windows
* Android
* Linux

---

# Projektstatus

```text
MVP / produktiv nutzbar
```

Die Infrastruktur läuft bereits produktiv mit:

* CGNAT Bypass
* VPS Hub
* Raspberry Gateway
* Reverse Proxy
* SSL
* VPN Clients
* Monitoring
* Backups
* Security Stack
