# Sicherheitsüberblick — figma-console-mcp (podman)

## 1. Zweck

Der Container stellt einem lokal laufenden KI-Assistenten (OpenCode)
lesenden Zugriff auf Figma-Inhalte bereit. Er läuft als stdio-basierter
MCP-Server unter podman auf der Linux-Entwickler-VM der nutzenden
Person. Die Kommunikation mit Figma
erfolgt ausschliesslich über deren öffentliche REST-API
(`api.figma.com`) mittels eines persönlichen Zugriffstokens (PAT).
Schreibende Operationen auf Figma-Inhalte sind nicht vorgesehen und
werden durch zwei unabhängige Kontrollen verhindert.

## 2. Datenfluss

```
  OpenCode-Editor  <--stdin/stdout-->  Container  --HTTPS-->  api.figma.com
    (lokale VM)        (nur Text)      (Sandbox)             (Figma-Konto)
```

Es existieren keine weiteren ausgehenden Verbindungen: keine
Telemetrie, kein Cloud-Relay, kein OAuth-Proxy, keine Update-Abfragen.

Das Ziel `api.figma.com` stellt dabei keine neue Angriffsfläche dar:
dieselbe API wird bereits von der regulären Figma-Web- und
Desktop-Anwendung verwendet, die im Arbeitsalltag ohnehin im Einsatz
ist. Der Container nutzt lediglich denselben Endpoint mit einem anderen
Client und einem eng begrenzten, Nur-Lese-Scope. Aus Netzwerk- und
Datenabflusssicht kommt dadurch kein neues Ziel hinzu, das
freigeschaltet, überwacht oder neu bewertet werden müsste.

## 3. Umgang mit dem Zugriffstoken

Das einzige Geheimnis im Betrieb ist ein persönlicher Figma-Zugriffstoken.
Dieser wird manuell erstellt und ausschliesslich mit Lese-Scopes versehen
(im Installationsskript entsprechend dokumentiert und am Bildschirm
hervorgehoben). Die Ablage erfolgt ausschliesslich lokal in
`~/.config/opencode/opencode.json` mit Dateiberechtigungen `600`. Eine
Kompromittierung kann über die Figma-Oberfläche jederzeit durch
Widerruf des Tokens behoben werden.

## 4. Abwehr gegen bösartige Prompts und prompt-injizierte Figma-Inhalte

| Angriffsidee                                         | Warum der Angriff scheitert                                                |
|-------------------------------------------------------|-----------------------------------------------------------------------------|
| Exfiltration von `~/.ssh/id_rsa` oder ähnlichen Dateien | Der Container besitzt keine Host-Mounts; Host-Dateien sind im Container nicht sichtbar. |
| Übertragung von Figma-Daten an einen Drittserver     | Der ausgeführte Code enthält nur einen einzigen Ausgangspfad: `api.figma.com`. Upstream-Quellcode wurde per Grep verifiziert. |
| Veränderung von Figma-Inhalten oder Kommentaren       | (a) Die Desktop Bridge ist nicht installiert und es werden keine Ports veröffentlicht; (b) der Token besitzt keine Schreib-Scopes — Figma weist entsprechende Aufrufe serverseitig ab. |
| Persistenz von Malware im Dateisystem                 | Der Root-Filesystem-Zugriff ist `--read-only`. Schreibbar sind lediglich zwei tmpfs-Bereiche im Arbeitsspeicher, die bei Sitzungsende verworfen werden. |
| Privilege Escalation oder Container-Ausbruch          | Ausführung als Non-Root-Benutzer, `--cap-drop=ALL`, `no-new-privileges`.    |
| Entgegennahme eingehender Verbindungen                | Es werden keine Ports veröffentlicht; der interne WebSocket-Listener ist von aussen nicht erreichbar. |
| Rückfluss des PAT über eine API-Antwort               | Figmas API gibt Authentifizierungs-Tokens nicht in Antworten zurück.        |

**Restrisiken:** Bestehen bleiben (a) das LLM-typische Risiko, dass der
Assistent mehr der legitim zugänglichen Figma-Inhalte abruft als
beabsichtigt, sowie (b) Prompt-Injection über geladene Figma-Inhalte.
Beide Risiken sind allgemeiner LLM-Natur und keine
Container-Ausbruchsrisiken.

## 5. Härtungsmassnahmen zur Laufzeit

Read-only-Rootfs · zwei verwerfbare tmpfs-Scratch-Bereiche ·
`--cap-drop=ALL` · `no-new-privileges` · Non-Root-Benutzer · keine
veröffentlichten Ports · keine Host-Volume-Mounts · `--rm`
(Container-Zerstörung bei Sitzungsende).

## 6. STRIDE-Zuordnung

| STRIDE-Kategorie                | Massnahme in diesem Setup                                                          |
|---------------------------------|-------------------------------------------------------------------------------------|
| **S**poofing                    | PAT ausschliesslich mit Leserechten, lokal gehalten; keine eingehenden Ports.       |
| **T**ampering                   | Read-only-Rootfs; Image an einen Upstream-Tag gepinnt und reproduzierbar baubar.    |
| **R**epudiation                 | Ausführung im Vordergrundprozess; `podman logs` erfasst die Aktivität vollständig. |
| **I**nformation Disclosure      | Keine Host-Mounts, keine Telemetrie, ein einziges ausgehendes Ziel, PAT-Datei `chmod 600`. |
| **D**enial of Service           | Single-Tenant-Prozess; durch `--rm` und tmpfs hat ein Absturz keine persistente Wirkung. |
| **E**levation of Privilege      | Non-Root, `--cap-drop=ALL`, `no-new-privileges`.                                    |

## 7. OWASP Top 10 für LLM-Anwendungen (relevante Punkte)

| Punkt                                | Massnahme in diesem Setup                                                        |
|---------------------------------------|-----------------------------------------------------------------------------------|
| **LLM01 Prompt Injection**           | Nicht verhindert (allgemeines LLM-Risiko), die Auswirkungsreichweite ist jedoch durch Sandbox und reinen Lese-Token begrenzt: injizierte Anweisungen verfügen weder über einen Schreibpfad noch über ein Exfiltrationsziel ausser Figma. |
| **LLM02 Sensitive Info Disclosure**  | Kein Zugriff auf Host-Dateien; nur ein ausgehendes Ziel; PAT-Datei `chmod 600`.   |
| **LLM06 Excessive Agency**           | Die Tool-Oberfläche ist auf lesende Figma-API-Aufrufe reduziert; sämtliche Schreib- und Bridge-Tools sind sowohl transportseitig als auch per Token-Scope deaktiviert. |
| **LLM10 Unbounded Consumption**      | `--rm` pro Sitzung, ausschliesslich tmpfs-Scratch, keine Persistenz im Hintergrund. |

## 8. Vergleich mit Figmas gehostetem Remote-MCP

Ein gehosteter Remote-MCP fügt dem Datenpfad eine zusätzliche,
privilegierte Drittpartei hinzu. Diese sieht jeden MCP-Tool-Aufruf des
Assistenten, hält einen OAuth-Token zum Figma-Konto auf eigener
Infrastruktur und würde bei einer Kompromittierung sämtliche
verbundenen Nutzer:innen betreffen. Die vorliegende Container-Lösung
entfernt diese Zwischenstation vollständig: Figma empfängt dieselben
einzelnen REST-Aufrufe wie bei einer regulären Browser-Nutzung, und der
Verkehr zwischen Assistent und Tool verbleibt lokal. Weniger Parteien im
Datenpfad reduzieren die Angriffsfläche und das Exfiltrationsrisiko. Im
Gegenzug entfällt der Komfort einer gehosteten Lösung: Aufbau und
Installation erfolgen lokal.

## 9. Incident Response

- **PAT kompromittiert:** Widerruf in Figma (Einstellungen → Personal
  Access Tokens); anschliessend `./install.sh` mit einem neuen
  Lese-Token ausführen.
- **Verdacht auf Image-Manipulation:**
  `podman rmi figma-console-mcp && ./build.sh` rebaut das Image aus dem
  gepinnten Upstream.

## 10. Zusammenfassung

Podman-sandboxed stdio-MCP-Server für Figma. Nur-Lese-PAT,
ausschliesslich ausgehend zu `api.figma.com`, keine Ports, keine
Mounts, Non-Root, Read-only-Rootfs, alle Capabilities entfernt.
Schreibzugriffe werden sowohl durch fehlenden Transport als auch durch
Token-Scope blockiert.
