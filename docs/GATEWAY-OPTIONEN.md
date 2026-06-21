# Gateway-Optionen: Raspberry Pi vs. Fritzbox

Dieses Dokument beschreibt die Unterschiede zwischen dem **Standard-Gateway (Pi/SBC)**
und der **Fritzbox als Gateway-Host**, dokumentiert bekannte Durchsatz-Probleme,
Lösungsansätze und einen **reversiblen Testplan**.

> **Hinweis:** Alle IP-Adressen und Hostnamen in diesem Dokument sind **Beispiele**
> oder Platzhalter (`192.168.x.x`, `vpn.example.com`). Echte Werte gehören nur in
> `/etc/wireguard/wg0.conf` und `/etc/wireguard2home.conf` auf den Systemen — nicht ins Git.

---

## Architektur im Vergleich

### Variante A — Pi als Gateway (Standard, Gate2homeTunnel)

```text
Internet
   │
   ▼
VPS (Hub, 10.100.0.1)
   │  WireGuard
   ▼
Fritzbox (NAT: UDP 51820 → Pi)     ← zusätzlicher Hop
   ▼
Pi (Gateway, 10.100.0.2)
   │  Routing + optional NAT
   ▼
Heimnetz (z. B. 192.168.x.x — Plex, NAS, …)
```

### Variante B — Fritzbox als Gateway

```text
Internet
   │
   ▼
VPS (Hub, 10.100.0.1)
   │  WireGuard (direkt auf Fritzbox terminiert)
   ▼
Fritzbox (Gateway, 10.100.0.2)
   │
   ▼
Heimnetz (Plex, NAS, …)
```

**Kernunterschied:** Bei Variante B entfällt die UDP-Portweiterleitung und der
zusätzliche WireGuard-Hop über den Pi. Die Fritzbox 7690 kann WireGuard laut
[PC-WELT-Test](https://www.pcwelt.de/article/2366881/avm-fritzbox-7690-test.html)
mit **>900 Mbit/s** betreiben — deutlich mehr als ein Pi hinter NAT-Portforward.

---

## Reverse Proxy (NPM) und Plex — wie der Datenfluss wirklich aussieht

Der Reverse Proxy auf dem VPS ersetzt **keinen** VPN-Tunnel. Er nutzt ihn.

### Pfad: `https://plex.deinedomain.de` (ohne WireGuard-App beim Client)

```text
Client (Browser/App)
   │  HTTPS :443
   ▼
VPS — Nginx Proxy Manager (Let's Encrypt)
   │  HTTP/HTTPS weitergeleitet an Backend-IP
   ▼
WireGuard-Tunnel (VPS → Gateway → Heimnetz)
   ▼
Plex-Server (z. B. 192.168.x.x:32400)
```

**Antwortweg (Video-Stream):**

```text
Plex-Server → Gateway → Tunnel → VPS → NPM → Client
```

Beide Richtungen laufen durch den Tunnel. Für parallele Streams ist vor allem die
**Upload-Richtung vom Heimnetz** (Gateway → VPS) relevant — dort liefern die Daten
für den Stream.

### Was der Reverse Proxy **nicht** ist

| Annahme | Realität |
| --- | --- |
| „Plex geht direkt über das Internet zum VPS“ | Nein — der VPS leitet nur weiter, der Plex-Server bleibt zu Hause |
| „NPM umgeht WireGuard“ | Nein — NPM erreicht Heimnetz-IPs nur über `wg0`-Routing |
| „Portfreigabe Plex am VPS“ | Nicht vorgesehen und unsicher |

### Plex-Zugriff — zwei Wege

| Weg | Client braucht | Datenpfad | Typisch für |
| --- | --- | --- | --- |
| **VPN** | WireGuard-App | Client ↔ VPS ↔ Tunnel ↔ Plex (LAN-IP) | Voller Zugriff, Admin, alle Dienste |
| **Reverse Proxy** | Nur Browser/App + URL | Wie oben über NPM | Einzelner Dienst öffentlich, z. B. Plex Web |

### Grobe Kapazität paralleler Streams (Direct Play, Richtwerte)

| Tunnel (Gateway → VPS) | 1080p (~10 Mbit/Stream) | 4K (~40–80 Mbit/Stream) |
| --- | --- | --- |
| ~200 Mbit/s (Pi, gemessen) | ~15–19 Streams | 2–4 Streams |
| ~900 Mbit/s (Fritzbox, laut Test) | deutlich mehr | 10+ Streams |

Transcoding auf dem Plex-Server belastet zusätzlich CPU/RAM — unabhängig vom Tunnel.

---

## Bekannte Probleme und Erkenntnisse

### Asymmetrischer Tunnel-Durchsatz (Pi-Gateway)

In Praxis-Messungen (iperf3 über den Tunnel, TCP):

| Richtung | Ca.-Wert | Bedeutung |
| --- | --- | --- |
| VPS → Gateway (Heim-Download durch Tunnel) | ~113 Mbit/s | z. B. Downloads von außen, NPM-Antworten mit wenig Payload |
| Gateway → VPS (Heim-Upload durch Tunnel) | ~194 Mbit/s | **Streaming von Plex nach außen**, wichtig für parallele Streams |

Der VPS selbst ist nicht der Engpass (externer Download >1 Gbit/s gemessen).

### Fritzbox 7690 — Hardware-Beschleunigung

AVM bestätigt Durchsatz-Probleme bei **FritzOS 8.20+** hinter Glasfaser/Kabelmodem
mit aktivierter Paket-/Hardware-Beschleunigung
([WinFuture](https://winfuture.de/news,156796.html)).
Das betrifft den **gesamten Router-Durchsatz**, nicht nur WireGuard.

**Getestet:** Nur „Hardware-Beschleunigung“ deaktivieren → Tunnel-Durchsatz unverändert (~113 Mbit).
→ Der Engpass beim Pi-Setup liegt eher am Pfad **VPS → Fritzbox-NAT → Pi**, nicht an der
reinen Leitung (Ookla am PC kann deutlich höhere Werte zeigen als curl/iperf vom Pi).

### Fritzbox WireGuard — Konfigurationsfalle

Wenn in der Fritzbox-WG-Config im `[Interface]`-Block eine reine Tunnel-IP (`x.x.x.x/32`)
als `Address` steht, erzwingt die Fritzbox intern **Source-NAT**. Geräte im Heimnetz
erscheinen dann nicht mit ihrer echten IP.

**Lösung:** `Address` = echte LAN-IP der Fritzbox, z. B. `192.168.x.1/24`
([Details](https://florian-puschmann.de/fritzbox-mit-pfsense-ueber-wireguard-verbinden-die-versteckte-konfigurationsfalle/)).

### DMZ / Exposed Host auf dem Pi

**Nicht empfohlen** als Ersatz für UDP-51820-Portfreigabe:

- leitet **alle** Ports an den Pi weiter (SSH, etc.)
- bringt für WireGuard-Durchsatz meist keinen relevanten Vorteil
- vergrößert die Angriffsfläche erheblich

---

## Gate2homeTunnel — was sich bei Fritzbox-Gateway ändert

| Feature | Pi-Gateway | Fritzbox-Gateway |
| --- | --- | --- |
| `install-gateway-host.sh` | ✅ | ❌ manuell |
| Tunnel-Speedtest (SSH/iperf) | ✅ | ❌ manuell |
| Offsite-Backup zum Gateway | ✅ | ❌ anderer Zielhost nötig |
| Client-Manager auf VPS | ✅ | ✅ |
| Reverse Proxy (NPM) | ✅ | ✅ (Backend-IP = Plex-LAN-IP) |
| NAT/Masquerade Heimnetz | Pi (`iptables`) | Fritzbox (intern) |

---

## Testplan: Fritzbox als Gateway (reversibel)

Ziel: Messen, ob der Tunnel-Durchsatz steigt — ohne Produktivbetrieb dauerhaft zu riskieren.

### Phase 0 — Vorbereitung (15 Min.)

1. **Backups erstellen**
   - VPS: Menü → Backup (oder `Wireguard2Home.sh` Backup)
   - Fritzbox: *System → Sicherung → Sichern*
   - Pi: `sudo cp /etc/wireguard/wg0.conf /root/wg0.conf.bak.test`

2. **Basiswerte dokumentieren** (vor dem Test, auf dem VPS):

   ```bash
   # Tunnel VPS → Gateway
   iperf3 -c 10.100.0.2 -t 15 -f m

   # Tunnel Gateway → VPS (Pi als Client)
   ssh root@10.100.0.2 iperf3 -c 10.100.0.1 -t 15 -f m
   ```

3. **Wartungsfenster** einplanen (kurze Tunnel-Unterbrechung beim Peer-Wechsel).

### Phase 1 — Fritzbox WireGuard einrichten (parallel, Pi bleibt aktiv)

1. Fritzbox: *Internet → Freigaben → VPN → WireGuard*
2. Neue Verbindung als **Client** zum VPS (nicht Server-Modus)
3. Config-Export bearbeiten (siehe [Konfigurationsvorlage](#fritzbox-konfigurationsvorlage))
4. **Noch nicht** den Pi-Peer am VPS entfernen

### Phase 2 — VPS-Peer für Fritzbox hinzufügen

1. Öffentlichen Key der Fritzbox aus der WG-Config kopieren
2. Am VPS **zusätzlichen** Peer eintragen (Test-IP z. B. `10.100.0.12/32`):

   ```ini
   # Test-Peer Fritzbox — noch nicht produktiv
   [Peer]
   PublicKey = <FRITZBOX_PUBLIC_KEY>
   AllowedIPs = 10.100.0.12/32, 192.168.x.0/24
   PersistentKeepalive = 25
   ```

3. `sudo wg syncconf wg0 <(wg-quick strip wg0)` oder Dienst neu laden

4. Prüfen: `sudo wg show` — Handshake zur Fritzbox?

### Phase 3 — Durchsatz messen (Fritzbox als Gateway)

```bash
# Auf VPS: iperf3-Server auf Gateway-Test-IP
# (Fritzbox muss iperf3 nicht haben — Test von VPS zu erreichbarer FB-WG-IP)

# VPS → Fritzbox (über Tunnel)
iperf3 -c 10.100.0.12 -t 20 -P 4 -f m

# Fritzbox → VPS: ggf. von LAN-Gerät hinter FB oder zweitem iperf-Host
```

**Erfolgskriterium:** VPS → Heim deutlich über ~120 Mbit/s (Ziel: möglichst nah an
Heim-Upload / Ookla-Werte).

### Phase 4 — Funktionstest

| Test | Erwartung |
| --- | --- |
| Ping `10.100.0.12` vom VPS | Antwort |
| Ping `192.168.x.x` (Plex-Host) vom VPS | Antwort |
| VPN-Client: Heimnetz erreichbar | Ja |
| Plex über VPN (LAN-IP:32400) | Spielt ab |
| NPM → Plex-Backend (falls genutzt) | Forward-Hostname = Plex-LAN-IP |

### Phase 5 — Entscheidung

**Bei Erfolg (Durchsatz deutlich besser):**

1. Fritzbox dauerhaft auf `10.100.0.2` umstellen (Standard-Gateway-IP)
2. Pi-Peer am VPS entfernen
3. UDP-Portfreigabe 51820 → Pi an Fritzbox **löschen**
4. Pi-WG-Dienst stoppen: `sudo systemctl disable --now wg-quick@wg0`
5. NPM-Backend für Plex auf LAN-IP zeigen lassen

**Bei Misserfolg oder Problemen → Rollback (Phase 6)**

### Phase 6 — Rollback auf Pi-Gateway

1. Fritzbox-WG-Verbindung deaktivieren/löschen
2. VPS `wg0.conf` aus Backup wiederherstellen (Pi-Peer mit `10.100.0.2`)
3. `sudo systemctl restart wg-quick@wg0`
4. Pi: `sudo systemctl start wg-quick@wg0`
5. Fritzbox: UDP 51820 → Pi Portfreigabe prüfen
6. `sudo wg show` — Handshake Pi?
7. Tunnel-Speedtest wiederholen

**Rollback-Dauer:** ca. 5–10 Minuten mit vorhandenen Backups.

---

## Fritzbox-Konfigurationsvorlage

> Platzhalter anpassen. `Address` in `[Interface]` = **echte Fritzbox-LAN-IP**.

```ini
[Interface]
# WICHTIG: LAN-IP der Fritzbox, nicht nur /32-Tunnel-IP
Address = 192.168.x.1/24
PrivateKey = <FRITZBOX_PRIVATE_KEY>

[Peer]
PublicKey = <VPS_WG_PUBLIC_KEY>
Endpoint = vpn.example.com:51820
AllowedIPs = 10.100.0.0/24
PersistentKeepalive = 25
```

Am VPS (Produktiv, nach erfolgreichem Test):

```ini
[Peer]
PublicKey = <FRITZBOX_PUBLIC_KEY>
AllowedIPs = 10.100.0.2/32, 192.168.x.0/24
PersistentKeepalive = 25
```

---

## Plex über NPM einrichten (beide Gateway-Varianten)

1. DNS: `plex.deinedomain.de` → VPS-IP (A-Record)
2. NPM: *Proxy Hosts → Add*
   - Domain: `plex.deinedomain.de`
   - Forward Hostname: `192.168.x.x` (Plex-Server LAN-IP)
   - Forward Port: `32400`
   - Scheme: `http` (oder `https` wenn Plex lokal TLS hat)
3. SSL: Let's Encrypt aktivieren
4. Plex: *Einstellungen → Netzwerk* — „Custom server access URLs“ ggf. `https://plex.deinedomain.de`

**Hinweis:** Stream-Qualität und parallele Streams hängen vom Tunnel-Durchsatz ab
(siehe Tabelle oben). Fritzbox-Gateway verbessert vor allem den Streaming-Pfad nach außen.

---

## Offene Punkte / spätere Projekt-Arbeit

- [ ] Optionaler Installer-Hinweis für Fritzbox-Gateway in `install-vps.sh`
- [ ] Speedtest-Alternative ohne SSH-Gateway (reiner `iperf3`-Modus)
- [ ] NPM-Beispiel „Plex“ in README ergänzen
- [ ] Automatisches Erkennen des Gateway-Typs im Dashboard

---

## Referenzen

- [Fritzbox 7690 WireGuard >900 Mbit (PC-WELT)](https://www.pcwelt.de/article/2366881/avm-fritzbox-7690-test.html)
- [FritzOS 8.20 Durchsatz-Bug Glasfaser (WinFuture)](https://winfuture.de/news,156796.html)
- [Fritzbox WG Address-NAT-Falle](https://florian-puschmann.de/fritzbox-mit-pfsense-ueber-wireguard-verbinden-die-versteckte-konfigurationsfalle/)
- [Gate2homeTunnel README — Reverse Proxy](../README.md#reverse-proxy)
