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
erscheinen dann nicht mit ihrer echten IP — Ping auf die Fritzbox-LAN-IP antwortet von
der Tunnel-IP (`10.100.0.x`).

**Teil-Lösung:** Exportierte Config anpassen: `Address = 192.168.x.1/24` statt `/32`
([Details](https://florian-puschmann.de/fritzbox-mit-pfsense-ueber-wireguard-verbinden-die-versteckte-konfigurationsfalle/)).
→ Fritzbox antwortet dann mit korrekter LAN-IP, **leitet aber im VPN-Anbieter-Modus
trotzdem nicht zuverlässig an andere LAN-Geräte weiter** (siehe Testergebnisse unten).

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
| NAT Full-Tunnel-Clients → Internet | VPS (`MASQUERADE` in `wg0.conf`) | VPS (`MASQUERADE` in `wg0.conf`) |

### VPS: zwei NAT-Aufgaben (nicht verwechseln)

| Traffic | Wer macht NAT? | PostUp auf dem VPS |
| --- | --- | --- |
| NPM → Plex/NAS (`192.168.x.x`) | Fritzbox leitet LAN weiter | `DOCKER-USER`-Regeln (NPM/Docker → `wg0`) |
| Handy Full Tunnel → Internet | **VPS** maskiert `10.100.0.0/24` Richtung `eth0` | `MASQUERADE` in `wg0.conf` |

Bei der Netcup-Migration war `MASQUERADE` kurzzeitig entfernt (nur FORWARD + Docker-Regeln).
Full-Tunnel-Clients konnten das Heimnetz erreichen, aber kein Internet/Speedtest. Korrektur:
`scripts/vps-wg-postup.sh` (wird von `netcup-migrate-production.sh` und `netcup-fritzbox-minimal.sh` genutzt).

**Boot-Reihenfolge:** `wg-quick@wg0` startet nach `docker.service`, da die `DOCKER-USER`-Chain
erst dann existiert. Zusätzlich: `gate2home-docker-wg-routes.service` zieht NPM-Regeln nach.

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

## Fritzbox-Testergebnisse (Praxis, Juni 2025)

Getestet: Fritzbox **7690**, FRITZ!OS mit WireGuard, Glasfaser-Anschluss, VPS als Hub,
Pi parallel als produktiver Gateway (`10.100.0.2`).

### Konfigurationsvarianten

| Variante | Ergebnis |
| --- | --- |
| Import mit `Address = 10.100.0.12/32` (VPN-Anbieter-Modus) | Tunnel grün, Fritzbox-LAN-Ping antwortet von Tunnel-IP (NAT) |
| Export angepasst: `Address = 192.168.x.1/24`, neu importiert | Fritzbox-LAN-Ping antwortet korrekt von `192.168.x.1` |
| Geräteliste „Heimgeräte freigeben“ | Pi taucht nicht auf — Option ist für **Outbound** (Internet über VPN), nicht für Inbound-Routing |

### Erreichbarkeit (vom VPS aus)

| Ziel | Pi-Gateway (`10.100.0.2`) | Fritzbox-Test (`192.168.x.0/24` via FB-Peer) |
| --- | --- | --- |
| Gateway-Tunnel-IP | ✅ Ping ~16 ms | ❌ `10.100.0.12` nach LAN-IP-Umstellung nicht mehr aktiv |
| Fritzbox LAN-IP (`192.168.x.1`) | — | ✅ Ping ~16 ms (nach `/24`-Fix) |
| Andere LAN-Geräte (z. B. Pi `192.168.x.198`) | ✅ über Pi-Peer | ❌ kein Ping, keine Pakete auf `tcpdump` am Pi |
| Heimnetz-Services (Monitoring) | ✅ typisch über Pi-Peer + NPM | Abhängig vom Prüfpfad (siehe unten) |

### Durchsatz (iperf3, TCP)

| Pfad | Richtung | Ca.-Wert |
| --- | --- | --- |
| VPS ↔ Pi (Tunnel `10.100.0.2`) | VPS → Pi | ~113 Mbit/s |
| VPS ↔ Pi (Tunnel `10.100.0.2`) | Pi → VPS | ~194–211 Mbit/s |
| VPS extern (Cloudflare) | Download | >1 Gbit/s |
| Fritzbox-Pfad zu LAN-Geräten | — | Nicht messbar (kein Forwarding) |

### Zwischenfazit Fritzbox

- **VPN-Anbieter-Modus** eignet sich nicht als vollwertiger Gate2home-Gateway-Ersatz.
- **Erreichbarkeit im Monitoring** kann trotzdem „grün“ sein, wenn Prüfungen über den
  **Pi-Tunnel**, **NPM/Reverse-Proxy** oder **VPN-Clients** laufen — das ist kein
  Widerspruch zu den Fritzbox-Forwarding-Tests.
- Für **Performance als Hauptziel** bleibt der Pi-Gateway (oder künftig LAN-LAN-Modus
  „Router anderer Hersteller“) relevant — nicht der VPN-Anbieter-Import.

### Offen / nächster Versuch

- [ ] LAN-LAN-Assistent („WireGuard-fähiger Router“) statt VPN-Anbieter-Import
- [ ] Performance-Test mit klar definiertem Prüfpfad (siehe nächster Abschnitt)
- [ ] Fritzbox-Test-Peer am VPS aufräumen nach Abschluss der Experimente

---

## Monitoring vs. Performance-Test

| | Monitoring (z. B. Uptime Kuma) | Performance-Test (iperf3) |
| --- | --- | --- |
| **Frage** | „Ist der Dienst erreichbar?“ | „Wie viel Mbit/s schafft der Pfad?“ |
| **Typisch** | HTTP/TCP-Connect, Ping, kleine Payload | Dauerlast, viele MByte/s |
| **Pfad** | Oft NPM → LAN-IP oder VPN-Client → LAN | Muss exakt definiert werden |
| **Ergebnis** | Grün ab ~1 erfolgreicher Request | Plateau bei realem Durchsatz-Limit |

**Monitoring grün + iperf ~110 Mbit** schließen sich nicht aus: Der Dienst antwortet,
der Tunnel ist aber bandbreitenbegrenzt.

---

## Valider Performance-Test — Methodik

### Was gemessen werden soll (Pfad festlegen)

Vor jedem Test **einen** Prüfpfad benennen:

```text
A) VPS → Gateway-Host (Tunnel-IP)          # Hub ↔ Gateway, Basis
B) VPS → LAN-Gerät (Heimnetz-IP)          # z. B. Plex-Host, NPM-Backend
C) Gateway-Host → VPS                      # Upload-Richtung (Streaming nach außen)
D) VPN-Client → LAN-Gerät                  # Endnutzer-Perspektive
E) Internet → NPM → LAN-Gerät              # Reverse-Proxy-Pfad (Plex öffentlich)
```

Jeder Pfad kann **unterschiedliche** Mbit-Zahlen liefern. Vergleiche nur gleiche Pfade.

### Technische Voraussetzungen

| # | Voraussetzung | Warum |
| --- | --- | --- |
| 1 | **iperf3** auf beiden Endpunkten des Pfads | Standard-Messwerkzeug; in Gate2homeTunnel auf VPS + Pi installiert |
| 2 | **SSH-Zugang** VPS → Gateway (Speedtest-Key) | Server starten, Tests automatisieren |
| 3 | **Kein paralleler Lasttest** | Sonst verfälschte Werte |
| 4 | **Klare Peer-Situation** | Pi- und Fritzbox-Peer nicht unbeabsichtigt mischen |
| 5 | **30–60 s Wartefenster** | Kein Plex-Transcode, kein großer Download parallel |
| 6 | **4 parallele TCP-Streams, 20 s** | Entspricht verbessertem Gate2homeTunnel-Speedtest |

### Empfohlene Kommandos (auf dem VPS)

```bash
# Pfad A: VPS → Gateway (4 Streams)
iperf3 -c 10.100.0.2 -t 20 -P 4 -f m

# Pfad C: Gateway → VPS (4 Streams)
ssh root@10.100.0.2 iperf3 -c 10.100.0.1 -t 20 -P 4 -f m

# Pfad B: VPS → Plex-Host im LAN (iperf3 -s auf Plex-Host oder NAS nötig)
iperf3 -c 192.168.x.PLEX -t 20 -P 4 -f m
```

Eingebauter Test: `Wireguard2Home.sh` → Menü → Speedtests (nutzt Pfad A + C).

### Was wir vom Betreiber brauchen

1. **Welcher Pfad ist das Hauptziel?** (z. B. Plex-Streaming = Pfad C oder E)
2. **IP des Plex-/Service-Hosts** im Heimnetz (für Pfad B/E)
3. **Läuft der Fritzbox-Test-Peer noch parallel?** (ja/nein — beeinflusst Routing)
4. **Monitoring-Setup kurz beschreiben:** prüft Kuma NPM-URL, LAN-IP direkt, oder VPN?
5. **Optional:** iperf3 auf Plex-Host/NAS installierbar? (für realistischen Pfad B)
6. **Wartungsfenster** (~5 Min.) ohne aktive Streams

### Erfolgskriterien (Beispiel Performance-Ziel)

| Szenario | Mindest-Ziel | Stretch |
| --- | --- | --- |
| 1× 4K Direct Play von außen | Pfad C ≥ 80 Mbit/s | ≥ 200 Mbit/s |
| 3× 1080p parallel | Pfad C ≥ 40 Mbit/s | ≥ 100 Mbit/s |
| NPM/Plex öffentlich | Pfad E messen | Vergleich mit Pfad C |

---

## Fritzbox-Konfigurationsvorlage (Import-Datei)

> **Wichtig:** Für den **Import in die Fritzbox** (VPN-Anbieter-Wizard) gilt ein
> anderes Format als für manuelle `wg0.conf` auf Linux. Die `Address` muss die
> **Tunnel-IP** sein (`/32`), nicht die LAN-IP der Fritzbox.
>
> Die LAN-IP-Regel (`192.168.x.1/24`) per Export-Anpassung behebt NAT auf der Fritzbox
> selbst, ersetzt aber **nicht** den LAN-LAN-Modus für Weiterleitung an andere Geräte.

```ini
[Interface]
PrivateKey = <wird erzeugt — nie ins Git committen>
Address = 10.100.0.12/32

[Peer]
PublicKey = <VPS_WG_PUBLIC_KEY>
Endpoint = vpn.example.com:51820
AllowedIPs = 10.100.0.0/24
PersistentKeepalive = 25
```

### Fritzbox-UI (7690, FRITZ!OS 7.50+)

Laut [AVM-Anleitung](https://uk.fritz.com/service/knowledge-base/dok/FRITZ-Box-7690/3688_Connecting-the-FRITZ-Box-to-a-VPN-provider-via-WireGuard/):

1. *Internet → Freigaben → VPN (WireGuard) → Verbindung hinzufügen*
2. **„Netzwerke verbinden“** (Link Networks) — nicht „Einzelnes Gerät“
3. „Bereits am entfernten Standort eingerichtet?“ → **Ja**
4. Name vergeben → DNS-Domains → **Konfigurationsdatei hochladen**
5. **Nicht** aktivieren: „Gesamten IPv4-Netzwerkverkehr über VPN“ (das wäre Full-Tunnel vom Heimnetz!)
6. Verbindung speichern

**AVM-Einschränkung:** Wenn bereits WireGuard-Verbindungen auf der Fritzbox
existieren (z. B. für Smartphone-Fernzugriff), müssen diese **vorher gelöscht**
werden, bevor die Fritzbox als VPN-**Client** zu einem externen Anbieter eingerichtet
werden kann.

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
