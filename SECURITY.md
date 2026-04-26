# Sicherheitsüberblick — figma-console-mcp (podman)

## 1. Zweck

Dieses Repo paketiert den OSS-Server
[`southleft/figma-console-mcp`](https://github.com/southleft/figma-console-mcp)
als gehärteten, langlaufenden podman-Container für eine
Linux-Entwickler-Workstation. Der Container stellt einem lokal laufenden
MCP-Client (OpenCode, Cursor, Claude Code o. ä.) lesenden Zugriff auf
Figma-Inhalte bereit. Die Kommunikation mit Figma erfolgt
ausschliesslich über deren öffentliche REST-API (`api.figma.com`)
mittels eines persönlichen Zugriffstokens (PAT).
Schreibende Operationen auf Figma-Inhalte sind nicht vorgesehen und
werden durch zwei unabhängige Kontrollen verhindert (kein Schreib-Scope
am Token, keine Bridge-Tools im Transport).

## 2. Datenfluss

```
  MCP-Client                       Container                          api.figma.com
  (OpenCode/Cursor/...) <--HTTP--> mcp-proxy :8000 <--stdio--> node   --HTTPS-->
  (lokale VM)           loopback   (Sandbox)                  (Child)            (Figma-Konto)
                        127.0.0.1:23148
```

Der Container veröffentlicht genau einen Port und ausschliesslich auf
das Loopback-Interface (`127.0.0.1:23148 → 8000`). `mcp-proxy` startet
pro MCP-Client-Sitzung einen `node /app/dist/local.js`-Kindprozess und
überbrückt dessen stdio auf streamable-http. Es existieren keine
weiteren ausgehenden Verbindungen: keine Telemetrie, kein Cloud-Relay,
kein OAuth-Proxy, keine Update-Abfragen.

Das Ziel `api.figma.com` stellt keine neue Angriffsfläche dar:
dieselbe API wird bereits von der regulären Figma-Web- und
Desktop-Anwendung verwendet. Der Container nutzt denselben Endpoint
mit einem anderen Client und einem eng begrenzten Nur-Lese-Scope. Aus
Netzwerk- und Datenabflusssicht kommt kein neues Ziel hinzu, das
freigeschaltet, überwacht oder neu bewertet werden müsste.

## 3. Umgang mit dem Zugriffstoken

Das einzige Geheimnis im Betrieb ist ein persönlicher Figma-PAT.
Dieser wird manuell erstellt und ausschliesslich mit Lese-Scopes
versehen (File content, Variables, optional Dev resources / Library
content — jeweils Read-only; keine Write-Scopes). Die Ablage erfolgt
ausschliesslich lokal in der Repo-eigenen `.env`-Datei mit
Dateiberechtigungen `600`; podman injiziert sie via `env_file` in den
Container. Eine Kompromittierung kann über die Figma-Oberfläche
jederzeit durch Widerruf des Tokens behoben werden.

## 4. Abwehr gegen bösartige Prompts und prompt-injizierte Figma-Inhalte

| Angriffsidee                                          | Warum der Angriff scheitert                                                |
|-------------------------------------------------------|-----------------------------------------------------------------------------|
| Exfiltration von `~/.ssh/id_rsa` oder ähnlichen Dateien | Der Container besitzt keine Host-Bind-Mounts; Host-Dateien sind im Container nicht sichtbar. |
| Übertragung von Figma-Daten an einen Drittserver       | Der ausgeführte Code enthält nur einen einzigen ausgehenden Pfad: `api.figma.com`. |
| Veränderung von Figma-Inhalten oder Kommentaren        | (a) Die Figma-Desktop-Bridge wird zwar als Datei mitgeliefert, aber nicht gestartet; mcp-proxy ruft ausschliesslich `node /app/dist/local.js` auf, und es werden keine Bridge-Ports veröffentlicht. (b) Der Token besitzt keine Schreib-Scopes — Figma weist entsprechende Aufrufe serverseitig ab. |
| Persistenz von Malware im Dateisystem                  | Der Root-Filesystem-Zugriff ist `--read-only`. Schreibbar sind lediglich zwei tmpfs-Bereiche (`/tmp`, `/home/node/.figma-console-mcp`) im Arbeitsspeicher, die bei Container-Neustart verworfen werden. |
| Privilege Escalation oder Container-Ausbruch           | Ausführung als Non-Root-Benutzer (`node`), `--cap-drop=ALL`, `no-new-privileges`, `pids_limit=64`, Memory/CPU-Cap. |
| Eingehende Verbindungen aus dem Netz                   | Der einzige veröffentlichte Port ist an `127.0.0.1` gebunden und damit von anderen Hosts nicht erreichbar; lokale Prozesse auf der VM können sich verbinden. |
| Rückfluss des PAT über eine API-Antwort                | Figmas API gibt Authentifizierungs-Tokens nicht in Antworten zurück.        |

**Restrisiken:** Bestehen bleiben (a) das LLM-typische Risiko, dass der
Assistent mehr der legitim zugänglichen Figma-Inhalte abruft als
beabsichtigt, (b) Prompt-Injection über geladene Figma-Inhalte und (c)
dass jeder lokale Prozess auf derselben VM Anfragen an
`127.0.0.1:23148` stellen und damit den PAT-Scope nutzen kann (Single-User-
Workstation-Annahme). Punkte (a) und (b) sind allgemeiner LLM-Natur und
keine Container-Ausbruchsrisiken.

## 5. Härtungsmassnahmen zur Laufzeit

Read-only-Rootfs · zwei verwerfbare tmpfs-Scratch-Bereiche
(`/tmp`, `/home/node/.figma-console-mcp`) · `--cap-drop=ALL` ·
`no-new-privileges` · Non-Root-Benutzer (`node`) · genau ein Port,
ausschliesslich auf `127.0.0.1` gebunden · keine Host-Volume-Mounts ·
`pids_limit=64`, `mem_limit=512m`, `cpus=1.0` · langlaufender Dienst
unter rootless podman bzw. systemd-Quadlet (`restart: unless-stopped`).

## 6. STRIDE-Zuordnung

| STRIDE-Kategorie                | Massnahme in diesem Setup                                                          |
|---------------------------------|-------------------------------------------------------------------------------------|
| **S**poofing                    | PAT ausschliesslich mit Leserechten, lokal in `.env` (chmod 600); einziger Port nur auf Loopback erreichbar. |
| **T**ampering                   | Read-only-Rootfs; Image an einen Upstream-Tag (`VERSION` in `.env`) gepinnt und reproduzierbar baubar. |
| **R**epudiation                 | Aktivität wird via `podman logs` bzw. `journalctl --user -u figma-console-mcp.service` vollständig erfasst. |
| **I**nformation Disclosure      | Keine Host-Mounts, keine Telemetrie, ein einziges ausgehendes Ziel, PAT-Datei `chmod 600`. |
| **D**enial of Service           | Single-Tenant-Workstation; Memory-/CPU-/PID-Limits; tmpfs-only-Schreibpfade verhindern persistente Wirkung eines Absturzes. |
| **E**levation of Privilege      | Non-Root, `--cap-drop=ALL`, `no-new-privileges`.                                    |

## 7. OWASP Top 10 für LLM-Anwendungen (relevante Punkte)

| Punkt                                | Massnahme in diesem Setup                                                        |
|---------------------------------------|-----------------------------------------------------------------------------------|
| **LLM01 Prompt Injection**           | Nicht verhindert (allgemeines LLM-Risiko); die Auswirkungsreichweite ist jedoch durch Sandbox und reinen Lese-Token begrenzt: injizierte Anweisungen verfügen weder über einen Schreibpfad noch über ein Exfiltrationsziel ausser Figma. |
| **LLM02 Sensitive Info Disclosure**  | Kein Zugriff auf Host-Dateien; nur ein ausgehendes Ziel; PAT-Datei `chmod 600`.   |
| **LLM06 Excessive Agency**           | Die Tool-Oberfläche ist auf lesende Figma-API-Aufrufe reduziert; sämtliche Schreib- und Bridge-Tools sind sowohl transportseitig als auch per Token-Scope deaktiviert. |
| **LLM10 Unbounded Consumption**      | Memory-, CPU- und PID-Limits am Container; tmpfs statt persistentem Speicher; pro MCP-Client-Sitzung genau ein Node-Kindprozess. |

## 8. Vergleich mit Figmas gehostetem Remote-MCP

Ein gehosteter Remote-MCP fügt dem Datenpfad eine zusätzliche,
privilegierte Drittpartei hinzu. Diese sieht jeden MCP-Tool-Aufruf des
Assistenten, hält einen OAuth-Token zum Figma-Konto auf eigener
Infrastruktur und würde bei einer Kompromittierung sämtliche
verbundenen Nutzer:innen betreffen. Die vorliegende Container-Lösung
entfernt diese Zwischenstation vollständig: Figma empfängt dieselben
einzelnen REST-Aufrufe wie bei einer regulären Browser-Nutzung, und der
Verkehr zwischen Assistent und Tool verbleibt lokal auf dem
Loopback-Interface. Weniger Parteien im Datenpfad reduzieren die
Angriffsfläche und das Exfiltrationsrisiko. Im Gegenzug entfällt der
Komfort einer gehosteten Lösung: Aufbau und Installation erfolgen lokal.

## 9. Incident Response

- **PAT kompromittiert:** Widerruf in Figma (Einstellungen → Personal
  Access Tokens); anschliessend `.env` mit einem neuen Lese-Token
  aktualisieren und den Dienst neu starten
  (`podman-compose restart` bzw.
  `systemctl --user restart figma-console-mcp.service`).
- **Verdacht auf Image-Manipulation:**
  `podman rmi localhost/figma-console-mcp:local && ./scripts/build.sh`
  rebaut das Image aus dem in `.env` gepinnten Upstream-Tag.

## 10. Zusammenfassung

Podman-sandboxed MCP-Server-Wrapper für Figma. Nur-Lese-PAT,
ausschliesslich ausgehend zu `api.figma.com`, ein einziger Port auf
`127.0.0.1` gebunden, keine Host-Mounts, Non-Root, Read-only-Rootfs,
alle Capabilities entfernt, Memory-/CPU-/PID-Limits.
Schreibzugriffe werden sowohl durch fehlenden Transport (keine
Bridge-Tools veröffentlicht) als auch durch Token-Scope blockiert.
