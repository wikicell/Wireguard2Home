# Wireguard2Home

> **Self-contained WireGuard VPN stack that bypasses CGNAT.** A lightweight VPS acts as hub; a Gateway-Host (Raspberry Pi or any Linux machine) bridges your entire home LAN through the encrypted tunnel — reachable from any device, anywhere in the world.
>
> Features a single-script bootstrap installer with all sub-scripts embedded (no GitHub dependency at runtime), a live traffic dashboard with per-client RX/TX stats, a full client manager with QR-code export, automated offsite backups to the Gateway-Host, and a one-command restore. Supports full-tunnel, split-tunnel, and home-DNS filter modes. Runs on Debian, Ubuntu, Fedora, Arch, openSUSE and Raspberry Pi OS.

---

Eigenständiger WireGuard-VPN-Stack zum Überbrücken von CGNAT. Ein leichtgewichtiger VPS dient als Knotenpunkt; ein Gateway-Host (Raspberry Pi oder jeder andere Linux-Rechner) verbindet das gesamte Heimnetz verschlüsselt mit dem Tunnel — erreichbar von jedem Gerät, überall auf der Welt.

---

# Schnellnavigation

* [Schnellstart](#schnellstart)
* [Architektur](#architektur)
* [Features](#features)
* [Installation](#installation)
* [Betrieb](#betrieb)
* [Monitoring Stack](#monitoring-stack)
* [Reverse Proxy](#reverse-proxy)
* [Backup & Restore](#backup--restore) *(inkl. Cron, Migration)*
* [Sicherheit](#sicherheit)
* [Hardware-Anforderungen](#hardware-anforderungen)
* [Fehlerbehebung](#fehlerbehebung)
* [Roadmap](#roadmap)
* [Versionierung](#versionierung)
* [Lizenz](#lizenz)

---

# Schnellstart

> Für eine frische Installation auf VPS und Gateway-Host — alle anderen Details folgen in den jeweiligen Abschnitten.

**Schritt 1 — Bootstrap herunterladen (auf dem Zielhost):**

```bash
curl -fsSL \
  https://raw.githubusercontent.com/wikicell/Wireguard2Home/main/install-wireguard2home.sh \
  -o install-wireguard2home.sh
chmod +x install-wireguard2home.sh
```

**Schritt 2 — VPS einrichten:**

```bash
sudo ./install-wireguard2home.sh --role vps
```

**Schritt 3 — Gateway-Host einrichten** (auf dem Raspberry Pi / Gateway-Rechner):

```bash
sudo ./install-wireguard2home.sh --role gateway --vps-host root@DEIN_VPS
```

Der Bootstrap richtet VPS und Gateway-Host vollständig ein, überträgt alle Keys automatisch und aktiviert WireGuard auf beiden Seiten. Kein manuelles Eintragen von Keys nötig.

**Schritt 4 — VPN-Verwaltung starten:**

```bash
sudo /root/Wireguard2Home.sh
```

---

# Architektur

## Topologie

```text
Internet
   │
   ▼
VPS (WireGuard Hub, öffentliche IP)
   │  WireGuard-Tunnel
   ▼
Gateway-Host (Raspberry Pi o. ä., hinter CGNAT)
   │  Routing + NAT
   ▼
Heimnetzwerk
```

Das Projekt löst das CGNAT-Problem: Der Heimanschluss hat keine öffentlich erreichbare IP. Der VPS hat eine feste IP und dient als Hub — der Gateway-Host baut den Tunnel aktiv auf.

## Komponenten

### VPS (Hub)

* WireGuard Server — zentraler Tunnelpunkt
* Reverse Proxy (optional) — Nginx Proxy Manager
* Monitoring (optional) — Uptime Kuma, Watchtower, CrowdSec
* SSL-Termination — Let's Encrypt über NPM
* Fail2Ban / CrowdSec — Zugriffsschutz

### Gateway-Host (Heimnetz-Seite)

* WireGuard Client — baut Tunnel zum VPS auf
* IP-Forwarding + NAT/Masquerade — Heimnetz-Routing
* Backup-Empfänger — empfängt automatische Offsite-Backups vom VPS

### WireGuard-Adressierung

| Gerät | WireGuard-IP |
| --- | --- |
| VPS | 10.100.0.1 |
| Gateway-Host | 10.100.0.2 |
| Clients ab | 10.100.0.3 |

WireGuard-Netz: `10.100.0.0/24`  
Heimnetz (Beispiel): `192.168.50.0/24` — beim Setup auf das eigene Subnetz anpassen.

---

# Features

## Client-Manager

Clients (Smartphones, Laptops, etc.) werden über das interaktive Menü angelegt:

* nächste freie IP automatisch ermitteln
* Keypair generieren
* `.conf`-Datei erzeugen
* QR-Code erzeugen und als PNG speichern
* Server-Config live aktualisieren (ohne Tunnel-Unterbrechung)

## DNS-Auswahl

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

## Tunnel-Modi

### Full Tunnel

```ini
AllowedIPs = 0.0.0.0/0
```

Gesamter Traffic läuft über VPN. Sinnvoll für Reisen und fremde WLANs.

### Split Tunnel Heimnetz

```ini
AllowedIPs = 192.168.50.0/24, 10.100.0.0/24
```

Nur Heimnetzverkehr über VPN. Das normale Internet bleibt lokal.

### Split Tunnel + Heim-DNS-Filter

```ini
DNS = 192.168.50.53
AllowedIPs = 192.168.50.0/24, 10.100.0.0/24, 192.168.50.53/32
```

Handy, Tablet oder Laptop unterwegs: Internet bleibt direkt, Heimnetz und Heim-DNS sind erreichbar.

### Individueller Split Tunnel

```ini
AllowedIPs = 192.168.50.10/32, 192.168.50.20/32, 10.100.0.0/24
```

Nur ausgewählte Hosts/Netze über VPN.

## Status Dashboard

Integriertes Live-Dashboard mit:

* Online-/Offline-/Stale-Status pro Client
* letztem Handshake, interner WireGuard-IP, externem Endpoint
* RX/TX Traffic (live, täglich, monatlich)

Ansichten: `radar` (Übersicht) und `inspector` (Detailansicht).  
Tasten: `v`/`tab` zum Umschalten, `q` zum Beenden.

## Speedtests

* **Tunnel Speedtest** — misst den Durchsatz über den WireGuard-Tunnel mit `iperf3`
* **VPS Aussen-Speedtest** — misst einen HTTP-Download als Richtwert für die VPS-Anbindung

---

# Installation

## Projektstruktur

```text
install-wireguard2home.sh     ← Self-contained Bootstrap (alle Installer eingebettet)
install-vps.sh                ← VPS-Installer (eigenständig + im Bootstrap eingebettet)
install-gateway-host.sh       ← Gateway-Host-Installer (eigenständig + im Bootstrap eingebettet)
Wireguard2Home.sh             ← Zentrale CLI: Client-Manager, Dashboard, Backup, Restore, Speedtests
```

`Wireguard2Home.sh` ist eine **einzige, eigenständige Datei** — Client-Verwaltung, Live-Dashboard, Backup und Restore sind als Funktionen darin enthalten (keine separaten Sub-Scripts). Das hält die Logik an einer Stelle und verhindert Inkonsistenzen. Der Bootstrap bündelt die drei Installer als Heredocs — keine externen Downloads zur Laufzeit nötig.

## Bootstrap (empfohlener Weg)

> **Root-Login ist nicht nötig.** Der Installer benötigt Root-Rechte (für `wg`, `systemctl`, `iptables`), aber jeder User mit `sudo`-Berechtigung kann ihn ausführen.

```bash
# curl
curl -fsSL \
  https://raw.githubusercontent.com/wikicell/Wireguard2Home/main/install-wireguard2home.sh \
  -o install-wireguard2home.sh

# wget
wget -O install-wireguard2home.sh \
  https://raw.githubusercontent.com/wikicell/Wireguard2Home/main/install-wireguard2home.sh

chmod +x install-wireguard2home.sh
sudo ./install-wireguard2home.sh
```

### Bootstrap-Optionen

| Option | Beschreibung |
| --- | --- |
| `--role vps\|gateway` | Installationsrichtung erzwingen |
| `--vps-host USER@HOST` | VPS-Adresse für den Gateway-Weg |
| `--vps-ssh-key PFAD` | SSH-Key für VPS-Verbindung |
| `--service-user USER` | Lokaler administrativer User |
| `--service-home PFAD` | Home-Pfad des Service-Users |
| `--remote-service-user USER` | Service-User auf dem VPS |
| `--remote-service-home PFAD` | Home des Service-Users auf dem VPS |
| `--remote-install-dir PFAD` | Zielverzeichnis für Scripts auf dem VPS |
| `--update` | Nur Runtime-Skripte aktualisieren (Keys/Config bleiben unangetastet) |

**Skripte aktualisieren ohne Neuinstallation:**

Zuerst immer den aktuellen Bootstrap holen — er enthält die neuen Script-Versionen eingebettet:

```bash
curl -fsSL https://raw.githubusercontent.com/wikicell/Wireguard2Home/main/install-wireguard2home.sh \
  -o install-wireguard2home.sh && chmod +x install-wireguard2home.sh

# Nur VPS aktualisieren (auf dem VPS ausführen):
sudo ./install-wireguard2home.sh --update

# VPS + Gateway-Host gleichzeitig (vom Gateway-Host aus):
sudo ./install-wireguard2home.sh --update --role gateway --vps-host root@DEIN_VPS
```

`--update` aktualisiert lokal `Wireguard2Home.sh`; beim Gateway-Weg zusätzlich
`install-vps.sh` und `install-gateway-host.sh` auf dem VPS — ohne WireGuard-Config,
Keys oder Docker-Stacks anzufassen.

## VPS-Installer (install-vps.sh)

```bash
# Nur VPS, ohne optionale Stacks
sudo ./install-wireguard2home.sh --role vps

# Mit Reverse Proxy und Monitoring
sudo ./install-wireguard2home.sh --role vps --with-reverse-proxy --with-monitoring
```

### Installationsoptionen

| Option | Beschreibung |
| --- | --- |
| `--script-source PFAD` | Alternative Quelle für `Wireguard2Home.sh` |
| `--config-file PFAD` | Abweichender Pfad für `/etc/wireguard2home.conf` |
| `--service-user USER` | Administrativer User für App-Dateien |
| `--service-home PFAD` | Home des Service-Users |
| `--listen-port PORT` | WireGuard-Lauschport (Standard: 51820) |
| `--lan-subnet CIDR` | Heimnetz hinter dem Gateway-Host |
| `--with-ufw-fail2ban` | Installiert ufw und fail2ban (Host) |
| `--with-docker` | Installiert Docker und Compose-Plugin |
| `--with-reverse-proxy` | Reverse-Proxy-Stack (NPM); impliziert `--with-docker` |
| `--with-monitoring` | Monitoring-Stack (Uptime Kuma, Watchtower, CrowdSec); impliziert `--with-docker` |
| `--with-crowdsec-bouncer` | CrowdSec Firewall-Bouncer (Standard: aus, Schutz vor SSH-Aussperren) |
| `--pushover-token TOKEN` | Pushover API-Token für Watchtower-Benachrichtigungen |
| `--pushover-user KEY` | Pushover User-Key |
| `--with-swap` | Swap-Datei einrichten (Standard: 1024 MB unter `/swapfile`) |
| `--swap-size-mb N` | Größe der Swap-Datei in MB |
| `--swap-file PFAD` | Pfad der Swap-Datei |

> Bei `--with-monitoring` prüft der Installer den verfügbaren RAM und warnt bei weniger als ~900 MB. Details unter [Hardware-Anforderungen](#hardware-anforderungen).

### Keys auf dem VPS

```bash
# WireGuard Server Public Key
sudo cat /etc/wireguard/server_public.key

# SSH Public Key für Offsite-Backups (Standard: root)
sudo cat /root/.ssh/gate2home_backup.pub
```

## Gateway-Host-Installer (install-gateway-host.sh)

Richtet Kern-Abhängigkeiten, IP-Forwarding, NAT/Masquerade und ein `wg0.conf`-Template ein.

**NAT/Masquerade ist standardmäßig aktiv** — das LAN-Interface wird automatisch über die Default-Route erkannt. Das ist eine Grundvoraussetzung für den Heimnetz-Zugriff vom VPS und von Clients aus.

> Ohne Masquerade landen Pakete am Heimnetz-Gerät, aber die Antwort findet keinen Weg zurück (das Heimgerät kennt `10.100.0.0/24` nicht).

| Zielsystem | Status |
| --- | --- |
| Raspberry Pi OS | Gut unterstützt |
| Debian / Ubuntu | Gut unterstützt |
| Fedora / Rocky / AlmaLinux | Unterstützt (dnf/yum) |
| Arch Linux | Unterstützt (pacman) |
| openSUSE | Unterstützt (zypper) |
| VM mit systemd | Gut unterstützt |
| VM ohne systemd | Teilweise — Dienste manuell starten |

```bash
# Standard — Masquerade automatisch aktiv:
sudo ./install-gateway-host.sh \
  --server-public-key "VPS_PUBLIC_KEY" \
  --vps-backup-public-key "VPS_BACKUP_PUBLIC_KEY"

# Interface manuell angeben:
sudo ./install-gateway-host.sh \
  --server-public-key "VPS_PUBLIC_KEY" \
  --vps-backup-public-key "VPS_BACKUP_PUBLIC_KEY" \
  --masquerade-interface eth0

# Masquerade deaktivieren (nur wenn Router statische Routen kennt):
sudo ./install-gateway-host.sh \
  --server-public-key "VPS_PUBLIC_KEY" \
  --vps-backup-public-key "VPS_BACKUP_PUBLIC_KEY" \
  --no-masquerade
```

### Installationsoptionen

| Option | Beschreibung |
| --- | --- |
| `--gateway-address CIDR` | WireGuard-IP des Gateway-Hosts (Standard: 10.100.0.2/24) |
| `--lan-subnet CIDR` | Heimnetz hinter dem Gateway-Host |
| `--service-user USER` | Lokaler administrativer User |
| `--server-endpoint HOST:PORT` | WireGuard-Endpoint des VPS |
| `--server-public-key KEY` | WireGuard-Public-Key des VPS |
| `--vps-backup-public-key KEY` | SSH-Public-Key des VPS für Backup-Zugriff |
| `--masquerade-interface IFACE` | LAN-Interface für NAT manuell angeben |
| `--no-masquerade` | Masquerade deaktivieren |

```bash
# Gateway-Host Public Key
sudo cat /etc/wireguard/raspberry_public.key
```

## Reihenfolge einer frischen Installation

1. **VPS:** `sudo ./install-wireguard2home.sh --role vps` ausführen.
2. Der Installer gibt VPS Public Key und Backup Public Key aus — diese werden intern weitergegeben.
3. **Gateway-Host:** `sudo ./install-wireguard2home.sh --role gateway --vps-host root@VPS` ausführen.
4. Der Bootstrap überträgt den Gateway-Peer-Block automatisch per SCP auf den VPS und lädt WireGuard neu.
5. Tunnel prüfen: `wg show` auf beiden Systemen — `latest handshake` muss erscheinen.
6. **VPS:** `sudo /root/Wireguard2Home.sh` starten.

## Laufzeit-Konfiguration

Alle Scripts lesen `/etc/wireguard2home.conf` und passen Pfade und User entsprechend an.

**Wichtige Pfade (Standard `SERVICE_USER=root`):**

| Pfad | Inhalt |
| --- | --- |
| `/etc/wireguard/wg0.conf` | WireGuard Server-Config |
| `/root/Wireguard2Home.sh` | Zentrale CLI |
| `/root/wg-clients/` | Client-Configs und QR-Codes |
| `/root/backups/gate2home/` | Lokale Backups |
| `/etc/wireguard2home.conf` | Laufzeit-Konfiguration |

Mit `--service-user USERNAME` werden alle App-Dateien ins Home des angegebenen Users gelegt.

Typische Anpassungen in `/etc/wireguard2home.conf`:

```bash
WIREGUARD2HOME_SERVICE_USER=w2h
WIREGUARD2HOME_SERVICE_HOME=/home/w2h
WIREGUARD2HOME_BACKUP_SSH_USER=backupbot
WIREGUARD2HOME_BACKUP_REMOTE_USER=backup
WIREGUARD2HOME_BACKUP_REMOTE_HOME=/srv/backup
WIREGUARD2HOME_DNS_HOME_LABEL="AdGuard Home"
WIREGUARD2HOME_DNS_HOME_VALUE=192.168.50.53
WIREGUARD2HOME_DNS_ROUTER_LABEL="FRITZ!Box"
WIREGUARD2HOME_DNS_ROUTER_VALUE=192.168.50.1
WIREGUARD2HOME_LAN_SUBNET=192.168.50.0/24
WIREGUARD2HOME_SPEEDTEST_HOST=10.100.0.2
```

> Systemnahe Dateien wie `/etc/wireguard`, `systemctl` und `sysctl` bleiben weiterhin Root-Aufgaben. Die Konfiguration macht das Projekt benutzerkonfigurierbar, nicht root-frei.

---

# Betrieb

## Starten

```bash
# Standard (SERVICE_USER=root):
sudo /root/Wireguard2Home.sh

# Mit eigenem Service-User:
sudo /home/USERNAME/Wireguard2Home.sh
```

## Menü

Beim Start zeigt eine Statuszeile den aktuellen Zustand (Tunnel aktiv?,
Anzahl Clients, Gateway-Handshake, Endpoint):

```text
========================================
Wireguard2Home  v1.2.0
========================================
  Tunnel: aktiv     Clients: 2    Gateway: verbunden (vor 12s)
  Endpoint: 203.0.113.10:51820
========================================

  Verwalten
    1) Client Manager
    2) Status Dashboard (Snapshot)
    3) Status Dashboard (Live)

  Wartung
    4) Backup erstellen
    5) Restore starten
    6) Speedtests

    7) Hilfe
    8) Beenden
```

## Reboot-Verhalten

WireGuard startet automatisch nach Neustart (wird vom Installer eingerichtet):

```bash
# Manuell prüfen / aktivieren:
sudo systemctl enable wg-quick@wg0
sudo systemctl status wg-quick@wg0
```

---

# Monitoring Stack

Optionaler Docker-Stack auf dem VPS, aktivierbar mit `--with-monitoring`:

* **Uptime Kuma** — Verfügbarkeits-Monitoring (Port `3001`, via NPM erreichbar)
* **Watchtower** — automatische Container-Updates (täglich 04:00 Uhr)
* **CrowdSec** — verhaltensbasierte Angriffserkennung (SSH + NPM-Logs)
* **Pushover** — Benachrichtigungen über Watchtower (optional, interaktiv oder per Flag)
* **Fail2Ban** — Host-seitig über `--with-ufw-fail2ban`

```bash
sudo ./install-vps.sh --with-monitoring
```

* `--with-monitoring` installiert Docker bei Bedarf automatisch.
* Der CrowdSec **Firewall-Bouncer** ist standardmäßig **aus** (Schutz vor SSH-Aussperren) — aktivierbar mit `--with-crowdsec-bouncer`.
* Pushover-Secrets landen ausschließlich in einer root-only `/opt/watchtower/.env`.

## Compose-Dateien (Monitoring)

### Uptime Kuma — `/opt/uptime-kuma/docker-compose.yml`

```yaml
services:
  uptime-kuma:
    image: louislam/uptime-kuma:2
    container_name: uptime-kuma
    restart: unless-stopped
    expose:
      - "3001"
    volumes:
      - ./data:/app/data
    networks:
      - proxy_net

networks:
  proxy_net:
    external: true
    name: gate2home_proxy
```

**In NPM:** Forward Hostname `uptime-kuma`, Port `3001`.

**Erster Zugriff:** Keine Standard-Zugangsdaten — beim ersten Aufruf der Domain erscheint die Registrierung. Admin-Account sofort anlegen, bevor die Domain öffentlich erreichbar ist.

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

Die zugehörige `/opt/watchtower/.env` (Modus `600`, nur `root`) enthält bei gesetzten Pushover-Werten:

```ini
WATCHTOWER_NOTIFICATIONS=shoutrrr
WATCHTOWER_NOTIFICATION_URL=pushover://shoutrrr:<TOKEN>@<USER>
PUSHOVER_TOKEN=<TOKEN>
PUSHOVER_USER=<USER>
```

Ohne Pushover bleiben diese Zeilen auskommentiert — Watchtower läuft ohne Benachrichtigungen.

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

* **Nginx Proxy Manager** — Admin-UI auf Port `81`, HTTP/HTTPS auf `80`/`443`
* Automatische SSL-Zertifikate (Let's Encrypt)
* Externe Domains
* Heimnetz Reverse Proxying (über den WireGuard-Tunnel zum Gateway-Host)

```bash
sudo ./install-vps.sh --with-reverse-proxy

# Beide Stacks kombinieren:
sudo ./install-vps.sh --with-reverse-proxy --with-monitoring
```

**Erstzugang zum Admin-Panel** per SSH-Tunnel (Port 81 ist auf localhost gebunden — nicht direkt aus dem Internet erreichbar):

```bash
ssh -L 8181:localhost:81 root@VPS_IP -N
```
→ `http://localhost:8181` — Erst-Login: `admin@example.com` / `changeme` — **sofort ändern**.

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
    networks:
      - proxy_net

networks:
  proxy_net:
    external: true
    name: gate2home_proxy
```

> **Sicherheit:** Port `81` (Admin-Panel) ist auf `127.0.0.1` gebunden — Docker umgeht UFW via iptables direkt; `127.0.0.1`-Binding ist die einzig zuverlässige Absicherung.

> **Docker-Netzwerk:** NPM und alle Backend-Dienste (Uptime Kuma etc.) teilen das externe Netzwerk `gate2home_proxy`, das beim ersten Installer-Lauf automatisch angelegt wird.

## Dienst über NPM erreichbar machen (Schritt für Schritt)

Voraussetzung: Eine (Sub-)Domain zeigt per DNS-A-Record auf die öffentliche VPS-IP.

1. SSH-Tunnel öffnen: `ssh -L 8181:localhost:81 root@VPS_IP -N`
2. NPM Admin öffnen: `http://localhost:8181`
3. Erst-Login durchführen und Passwort sofort ändern
4. *Proxy Hosts* → *Add Proxy Host*:
   - **Domain Names:** `status.deinedomain.de`
   - **Forward Hostname:** `uptime-kuma` ← Container-Name im Docker-Netzwerk
   - **Forward Port:** `3001`
   - **Scheme:** `http`
5. Tab *SSL* → *Request a new SSL Certificate* → Let's Encrypt aktivieren
6. Speichern → Uptime Kuma ist unter `https://status.deinedomain.de` erreichbar

---

# Backup & Restore

## Backup

Das integrierte Backup-System (Menüpunkt 4) erstellt ein vollständiges Archiv aller relevanten Konfigurationen und Daten:

| Pfad | Inhalt |
| --- | --- |
| `/etc/wireguard/` | WireGuard Keys und Server-Config |
| `/root/wg-clients/` | Client-Configs und QR-Codes |
| `/opt/npm/` | Nginx Proxy Manager — Compose, Proxy-Konfigurationen, SSL-Zertifikate |
| `/opt/uptime-kuma/` | Uptime Kuma — Compose und Datenbank (Monitore, Alerts, Admin-Account) |
| `/opt/watchtower/` | Watchtower — Compose und `.env` (inkl. Pushover-Token) |
| `/opt/crowdsec/` | CrowdSec — Compose und Daten-Volume |
| `/etc/crowdsec/` | CrowdSec Host-Konfiguration |
| `/etc/fail2ban/` | Fail2Ban-Konfiguration |
| `/etc/ufw/` | UFW-Firewall-Regeln |

Nicht vorhandene Pfade werden automatisch übersprungen (z. B. wenn der Monitoring-Stack nicht installiert wurde).

Backups werden als `.tar.gz` gespeichert und automatisch per `rsync` zum Gateway-Host übertragen (Offsite-Sicherung). Lokale und Remote-Rotation sind konfigurierbar (`LOCAL_KEEP_COUNT`, `RPI_KEEP_COUNT`).

> Private Keys, VPN-Zugangsdaten und Client-Configs sind sensibel — Backups verschlüsseln und niemals öffentlich teilen.

### Backup manuell prüfen

```bash
LATEST=$(ls -t /root/backups/gate2home/gate2home-backup-*.tar.gz | head -1)
echo "Prüfe: $LATEST"
tar -tzf "$LATEST" | grep -E "wireguard|uptime|npm|watchtower|wireguard2home"
```

> **Hinweis:** Nie `tar -tzf *.tar.gz` mit Glob verwenden — wenn mehrere Archive vorhanden sind, interpretiert tar alles nach dem ersten Archiv als "Datei zum Suchen". Immer den expliziten Pfad oder `$(ls -t | head -1)` verwenden.

### Automatisches Backup (Cron)

`--backup-only` führt das Backup nicht-interaktiv aus (kein Menü, kein Bestätigungsdialog) — ideal für Cronjobs:

```bash
# Täglich um 03:00 Uhr
echo "0 3 * * * root /root/Wireguard2Home.sh --backup-only" | sudo tee /etc/cron.d/gate2home-backup
sudo chmod 644 /etc/cron.d/gate2home-backup
```

## Restore

Das Restore-System (Menüpunkt 5) stellt gesicherte Backups wieder her.

```bash
sudo /root/Wireguard2Home.sh   # → Menü → 5) Restore starten
```

**Restore-Modi:**

| Modus | Was wird wiederhergestellt |
| --- | --- |
| `wireguard` | `/etc/wireguard` (Keys und Server-Config) |
| `clients` | Client-Verzeichnis (`.conf`-Dateien und QR-Codes) |
| `full` | Alles — inkl. Docker-Stacks, Laufzeit-Config, WireGuard |

**Varianten:** Echter Restore oder Dry-Run (zeigt nur was passieren würde).

Vor jeder Wiederherstellung wird der aktuelle Zustand automatisch unter `/root/pre-restore-backups/` gesichert. Das Archiv wird vor der Extraktion auf Integrität geprüft — bei einem beschädigten Backup bricht der Restore sicher ab.

## Migration auf neuen VPS

Vollständige Prozedur um ein laufendes System auf einen frischen VPS umzuziehen:

**1. Neuen VPS vorbereiten** (Pakete, Docker, Scripts):
```bash
sudo ./install-wireguard2home.sh --role vps --with-reverse-proxy --with-monitoring
```

**2. Backup vom alten VPS auf neuen VPS übertragen:**
```bash
# Vom lokalen Rechner oder Gateway-Host:
scp root@ALTER_VPS:/root/backups/gate2home/gate2home-backup-DATUM.tar.gz \
    root@NEUER_VPS:/root/backups/gate2home/
```

**3. Full Restore starten:**
```bash
sudo /root/Wireguard2Home.sh  # → 5) Restore → 3) full
```

**Was automatisch passiert:**
- `/etc/wireguard/` mit alten Keys → Gateway-Host und alle Clients verbinden sich ohne Änderung
- `/etc/wireguard2home.conf` → Endpoint, DNS, Pfade korrekt
- Docker-Netzwerk `gate2home_proxy` wird angelegt (falls nicht vorhanden)
- Alle Docker-Stacks werden automatisch gestartet (NPM, Uptime Kuma, Watchtower, CrowdSec)
- WireGuard wird neu gestartet

---

# Sicherheit

## Netzwerk

* **WireGuard** — state-of-the-art Verschlüsselung (ChaCha20, Poly1305, Curve25519)
* **NAT/Masquerade** — Heimnetz-Geräte sind vom VPS aus nicht direkt adressierbar
* **Port-Bindings** — Admin-Panels (NPM Port 81, Monitoring Port 3001) sind auf `127.0.0.1` gebunden; Docker-Bypass von UFW via iptables macht `127.0.0.1`-Binding zur einzig zuverlässigen Absicherung
* **Kein öffentlicher SSH-Key** im Repository — alle sensiblen Werte sind Platzhalter

## Zugangsdaten und Keys

* Private WireGuard-Keys: nur unter `/etc/wireguard/` (Modus `600`, nur root)
* Backup-SSH-Key: unter `~/.ssh/gate2home_backup` (Modus `600`)
* Client-Configs: unter `/root/wg-clients/` (Modus `700`, einzelne `.conf` Modus `600`)
* Pushover-Tokens: root-only `/opt/watchtower/.env` (Modus `600`), niemals im Git

## Empfehlungen

* Backups verschlüsseln (z. B. mit `age` oder `gpg`)
* Fail2Ban aktivieren: `--with-ufw-fail2ban`
* CrowdSec Firewall-Bouncer erst nach stabilem Setup: `--with-crowdsec-bouncer`
* Regelmäßige Updates: `sudo ./install-wireguard2home.sh --update`
* SSH-Root-Login mit Key absichern, Passwort-Login deaktivieren

---

# Hardware-Anforderungen

WireGuard selbst ist ein Kernel-Modul und braucht praktisch kein RAM. Der reine Tunnel läuft auch auf sehr kleinen VPS problemlos. Der optionale Reverse-Proxy- und Monitoring-Stack läuft in Docker-Containern und braucht spürbar mehr Arbeitsspeicher.

## VPS

| Szenario | vCores | RAM | Disk |
|---|---|---|---|
| Nur Tunnel | 1 | 0,5 GB | 10 GB |
| Tunnel + Reverse Proxy | 1–2 | 1 GB | 10–20 GB |
| Tunnel + Reverse Proxy + Monitoring | 2 | 2 GB | 20–40 GB |

**RAM-Bedarf des vollen Stacks (Leerlauf):**

| Komponente | RAM (typisch) |
|---|---|
| Ubuntu Base + systemd | ~150–200 MB |
| Docker-Daemon | ~80 MB |
| Nginx Proxy Manager | ~150 MB |
| Uptime Kuma | ~120 MB |
| CrowdSec | ~120 MB |
| Watchtower | ~30 MB |
| **Summe** | **~650–700 MB** |

Auf einem 0,5-GB-VPS übersteigt das den physischen RAM. Abhilfe:

* **Swap** als Notnagel: `--with-swap` (1024 MB Standard, langsamer als echter RAM)
* **Upgrade** auf ≥ 1 GB RAM — saubere Lösung für den vollen Stack
* **Monitoring auslagern** auf den Gateway-Host, der den VPS durch den Tunnel überwacht

```bash
# Mit Swap für kleine VPS:
sudo ./install-vps.sh --with-reverse-proxy --with-monitoring --with-swap
```

## Gigabit ausreizen

WireGuard-Verschlüsselung ist CPU-gebunden. 1 vCore schafft je nach CPU grob 400–900 Mbit/s. Für stabile Gigabit-Last (plus TLS/Proxy) sind **2+ vCores mit AES-NI** empfehlenswert. Entscheidend ist außerdem der **Provider-Port-Speed** — viele günstige VPS haben gedrosselte Uplinks.

## Gateway-Host

Ein Raspberry Pi 4/5 (≥ 1 GB RAM) genügt vollständig. Ältere Pi-Modelle sind CPU-seitig deutlich langsamer; für Gigabit-Durchsatz ist ein Pi 4 oder neuerer SBC empfehlenswert.

---

# Fehlerbehebung

## Tunnel steht nicht (`wg show` zeigt keinen Handshake)

```bash
# Auf dem VPS: Peer-Config prüfen
sudo cat /etc/wireguard/wg0.conf | grep -v PrivateKey

# Auf dem Gateway-Host: Verbindung prüfen
sudo wg show
sudo systemctl status wg-quick@wg0
sudo journalctl -u wg-quick@wg0 -n 30
```

Häufigste Ursachen:
* Falscher `PublicKey` im `[Peer]`-Block → neu setzen mit `sudo sed -i ...` oder Installer erneut ausführen
* VPS-Firewall blockiert UDP 51820 → `sudo ufw allow 51820/udp`
* Kein Masquerade auf dem Gateway-Host → PostUp/PostDown in `wg0.conf` prüfen

## Heimnetz nicht erreichbar (Tunnel steht, aber kein Ping zu 192.168.x.x)

```bash
# IP-Forwarding aktiv?
cat /proc/sys/net/ipv4/ip_forward   # muss 1 sein

# Masquerade-Regel aktiv?
sudo iptables -t nat -L POSTROUTING -n -v
```

Kein Eintrag → Masquerade fehlt: PostUp/PostDown in `/etc/wireguard/wg0.conf` einkommentieren und `sudo systemctl restart wg-quick@wg0`.

## NPM-Admin-Panel nicht erreichbar

Port 81 ist auf `127.0.0.1` gebunden — kein Direktzugriff aus dem Internet. Zugriff per SSH-Tunnel:

```bash
ssh -L 8181:localhost:81 root@VPS_IP -N
```
→ `http://localhost:8181`

## Dienst gibt 502 zurück

```bash
# Kann NPM den Backend-Dienst erreichen?
docker exec npm curl -s -o /dev/null -w "%{http_code}" http://uptime-kuma:3001
```

* `200` → Netzwerkpfad OK, Forward-Hostname in NPM falsch eingetragen
* `Connection refused` → Netzwerk `gate2home_proxy` nicht verbunden oder Container nicht gestartet

```bash
# Docker-Netzwerk prüfen
docker network inspect gate2home_proxy

# Container-Status
docker ps
```

## `--update` bringt keine Änderungen

`--update` aktualisiert nur die Runtime-Skripte. Neue Installer-Flags (z. B. `--with-monitoring`) erfordern einen vollständigen Installer-Lauf:

```bash
sudo ./install-wireguard2home.sh --role vps --with-monitoring
```

---

# Roadmap

## Geplante Features

* **WebUI** — Browserbasierte Clientverwaltung, QR-Code im Browser, Multiuser mit Rollen
* **REST API** — Client erstellen/löschen, Status abrufen, DNS-Profile verwalten
* **Dockerisierung** — WireGuard Manager, API und WebUI als Container

## Mögliche Erweiterungen

* `WebUI mit Rollenmodell` — Browseroberfläche mit Login, Rollen, Audit-Log
* `REST API` — Automatisierung, externe Integrationen, Mobile-Apps
* `Tailscale- oder ZeroTier-Fallback` — alternativer Overlay bei blockiertem UDP
* `AdGuard Home / Pi-hole Integration` — DNS-Profile mit Blocklisten koppeln
* `GeoIP Blocking` — ergänzend zu CrowdSec und Fail2Ban
* `Multi-Gateway Support` — mehrere Standorte im selben Hub
* `Backup-Verschlüsselung` — mit `age` oder `gpg`
* `Metrics Exporter` — Prometheus-Anbindung für historische Traffic-Visualisierung
* `HA-/Warm-Standby-Modell` — zweiter VPS als Standby

---

# Versionierung

Das Projekt folgt [Semantic Versioning](https://semver.org/lang/de/) (`MAJOR.MINOR.PATCH`):

| Ziffer | Wann erhöhen | Beispiel |
| --- | --- | --- |
| **PATCH** (`1.2.x`) | Kleinere Fixes, Bugfixes, Doku | Endpoint-Erkennung, Backup-Pfad ergänzt |
| **MINOR** (`1.x.0`) | Neue Features, größere Änderungen (abwärtskompatibel) | Status-Banner, Monitoring-Stack, `--update` |
| **MAJOR** (`x.0.0`) | Große/breaking Änderungen | geändertes Config-Format, neue Architektur |

Die aktuelle Version wird im Banner und über `--help` angezeigt und steckt in
`W2H_VERSION` in jedem Script.

## Changelog

### v1.2.0
* Status-Übersicht im Menü-Banner (Tunnel, Clients, Gateway-Handshake, Endpoint)
* Sicherheitsabfrage vor echtem Restore; bessere Fehlermeldungen mit Lösungshinweis
* Menü-Gruppierung (Verwalten/Wartung), konsistente Ja/Nein-Prompts
* `wg syncconf` statt Service-Neustart beim Client-Anlegen/-Entfernen (keine Tunnel-Unterbrechung)
* Datei-Lock gegen doppelte IP-Vergabe; `eval` durch `nameref` ersetzt (Security)
* Redundante Standalone-Scripts entfernt — `Wireguard2Home.sh` ist alleinige Quelle
* Backup/Restore vollständig: `wireguard2home.conf`, Uptime Kuma, CrowdSec; Docker-Netzwerk + Stack-Autostart beim Restore

### v1.1.0
* Optionaler Monitoring-Stack (Uptime Kuma, Watchtower, CrowdSec) und Reverse Proxy (NPM)
* `--update`-Mechanismus, `--with-swap`, IPv4-bevorzugte Endpoint-Erkennung
* NAT/Masquerade standardmäßig aktiv mit automatischer Interface-Erkennung

### v1.0.0
* Erstes Release: CGNAT-Bypass, VPS-Hub + Gateway-Host, Client-Manager mit QR-Code,
  Live-Dashboard, Offsite-Backups, Restore, Self-contained Bootstrap

---

# Lizenz

Dieses Projekt steht unter der `MIT License`.

Die vollständigen Lizenzbestimmungen stehen in [LICENSE](LICENSE).

* Nutzung, Anpassung und Weitergabe sind erlaubt (auch kommerziell)
* Copyright- und Lizenzhinweis muss erhalten bleiben
* Die Software wird ohne Gewähr bereitgestellt
