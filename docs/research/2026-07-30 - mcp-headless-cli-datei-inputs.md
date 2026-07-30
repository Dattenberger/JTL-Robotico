---
date: 2026-07-30
author: Lukas + Claude (research session)
status: Research
context: Kann ein interaktiv über Claude Code per OAuth authentifizierter MCP-Server (hier YouTrack) auch non-interaktiv von der CLI genutzt werden, inklusive Übergabe von Markdown-Dateien als Eingabedaten — bewertet am Anwendungsfall „Markdown-Quelldatei → YouTrack-KB-Artikel synchronisieren".
related-plan: n/a (plan-free research)
related-adrs: —
---

# MCP headless von der CLI nutzen — mit Datei-Inputs

Untersucht am konkreten Fall der YouTrack-Knowledge-Base-Artikel dieses Repos:
Die Quelldateien liegen unter
[`docs/plans/2026-07-10 - mssql-ops-infrastruktur/reports/`](../plans/2026-07-10%20-%20mssql-ops-infrastruktur/reports/)
und werden per MCP-Tool `update_article` nach YouTrack hochgeladen (Artikel
`JTL-A-20` deutsch, `JTL-A-21` englisch). Gesucht ist ein wiederholbarer,
skriptbarer Befehl statt eines manuellen Copy-Paste-Schritts in einer
interaktiven Session.

Alle Befunde sind auf `vm-dev2` am 2026-07-30 mit **Claude Code 2.1.220**
empirisch geprüft; jeder Test war lesend (kein `update_article`, kein
OAuth-Flow).

## 1. Vision und Motivation

### 1.1 Warum die Frage gestellt wurde

Die YouTrack-REST-API kann Artikel nur **ganz** überschreiben (oder anhängen) —
kein Teil-Edit, kein Datei-Upload. Deshalb ist die Markdown-Datei im Git-Repo
die Single Source of Truth und YouTrack nur das Publikationsziel. Jede
Änderung erfordert heute eine interaktive Claude-Code-Session, in der ein
Modell den Dateiinhalt liest und per MCP hochlädt. Das ist teuer, nicht
reproduzierbar und nicht cron-fähig.

### 1.2 Was gelöst werden soll

1. **Reproduzierbarkeit** — derselbe Befehl erzeugt dasselbe Ergebnis, ohne
   dass ein Modell entscheidet, welcher Teil der Datei hochgeladen wird.
2. **Skriptbarkeit** — Aufruf aus einem Shell-Skript, einem Git-Hook oder CI.
3. **Kein Copy-Paste** — der Dateiinhalt kommt aus der Datei, nicht aus dem
   Prompt.

### 1.3 Verworfene Annahme

Die naheliegende Annahme „für Skripte nimmt man `--bare`" ist hier **falsch**
und war der aufwendigste Einzelbefund dieser Recherche — siehe §5.1.

## 2. Findings + Conclusions

**Kurzantwort: Ja, das geht — und es funktioniert heute ohne jede
Konfigurationsänderung.** Ein `claude -p`-Lauf desselben Unix-Users nutzt
dieselben persistierten MCP-OAuth-Credentials wie die interaktive Session.
Empirisch verifiziert:

```console
$ echo "Rufe mcp__youtrack__get_current_user auf und gib NUR Login und E-Mail aus." \
    | claude -p --model sonnet --allowedTools "mcp__youtrack__get_current_user"
Login: **lukas**
E-Mail: **lukas@dattenberger.com**
```

Und mit Datei-Input im selben Lauf (`@`-Referenz plus MCP-Tool):

```console
$ claude -p --model haiku --allowedTools "Read" "mcp__youtrack__get_article" -- \
    'Lies @docs/plans/2026-07-10 - mssql-ops-infrastruktur/reports/youtrack-testmandant-reset-kurzanleitung.md
     und rufe mcp__youtrack__get_article fuer JTL-A-20. Gib NUR aus: erste Zeile der
     lokalen Datei, Titel des YouTrack-Artikels. Nichts aendern.'
**Erste Zeile der lokalen Datei:** # JTL-Testmandanten (YouTrack-Artikel JTL-A-20)
**Titel des YouTrack-Artikels:**   JTL-Testmandanten
```

Die drei wesentlichen Einschränkungen:

1. **`--bare` bricht es** — genau das Flag, das die Doku für CI empfiehlt,
   schaltet OAuth- und Keychain-Zugriff ab und macht den Lauf unbrauchbar (§5.1).
2. **Der Access-Token lebt nur ~1 Stunde**; jeder headless Lauf hängt am
   Refresh-Token. Solange das Refresh gelingt, merkt niemand etwas — wenn
   YouTrack es ablehnt, ist ein **interaktiver** Re-Login nötig, den ein Cron
   nicht selbst ausführen kann (§5.2).
3. **Ein Modell in der Mitte ist für diesen Upload eine Belastung**, nicht ein
   Vorteil: welcher Teil der Datei hochgeladen wird, steht als Prosa-Regel in
   der Datei („ab der H1 unten") und muss vom Modell bei jedem Lauf neu korrekt
   interpretiert werden. Die Regel ist mechanisch exakt abbildbar (§6.3).

**Empfehlung (§6.4):** Für den dauerhaften Sync ein deterministisches
Shell-Skript gegen die YouTrack-REST-API — kein Modell im Datenpfad. Der
`claude -p`-Weg bleibt der Ad-hoc-Pfad, der ohne neue Credentials sofort
funktioniert.

## 3. Mechanik — Datei-Inhalte an `claude -p` übergeben

Vier Wege, absteigend nach Eignung für diesen Fall:

| Weg | Syntax | Eignung |
|---|---|---|
| **`@pfad`-Referenz im Prompt-String** | `claude -p -- 'Nimm @docs/x.md und …'` | ✅ beste Wahl — Claude liest die Datei per `Read`-Tool, der Pfad bleibt im Prompt sichtbar und ist damit greppbar |
| **stdin-Pipe** | `cat x.md \| claude -p 'Prompt'` | ✅ gut, aber der Prompt kann dann nicht mehr über stdin kommen; Limit 10 MB (ab v2.1.128) |
| **Pfad in Prosa + `--allowedTools "Read"`** | `claude -p -- 'Lies docs/x.md …'` | ⚠️ funktioniert, aber das Modell muss den Pfad selbst auflösen |
| **`--append-system-prompt-file`** | `--append-system-prompt-file ./regeln.txt` | für **Regeln**, nicht für Nutzdaten |

> [!IMPORTANT]
> **Gotcha: variadische Flags fressen das Prompt-Argument.**
> `--allowedTools`, `--disallowedTools`, `--tools`, `--mcp-config` und
> `--plugin-dir` sind variadisch (space-separated). Steht der Prompt dahinter
> ohne Trenner, wird jedes Prompt-Wort als Tool-Name gelesen:
>
> ```console
> $ claude -p --allowedTools "Read" --disallowedTools "Bash" "Rufe das Tool auf."
> Permission deny rule "Rufe" matches no known tool — check for typos.
> Permission deny rule "das" matches no known tool — check for typos.
> …
> Error: Input must be provided either through stdin or as a prompt argument when using --print
> ```
>
> Abhilfe: `--` vor den Prompt setzen (verifiziert), oder den Prompt per stdin
> pipen. Die offizielle CLI-Referenz dokumentiert das nicht.

### 3.1 Berechtigungs-Flags

- **`--allowedTools`** nimmt MCP-Tools unter ihrem vollen Namen, z. B.
  `mcp__youtrack__update_article`. Bash-Regeln nutzen Prefix-Matching mit
  Leerzeichen vor dem Stern: `Bash(git diff *)`.
- **`--permission-mode dontAsk`** verweigert alles, was nicht durch eine
  Allow-Regel oder den Read-only-Command-Set gedeckt ist — der passende
  Modus für abgeriegelte Läufe. `acceptEdits` erlaubt Schreibzugriff auf
  Dateien, nicht auf Netzwerk-Tools.
- **`--dangerously-skip-permissions`** ist hier nicht nötig; eine
  Allow-Liste mit genau einem MCP-Tool ist die engere und wartbarere Variante.
- **`--max-budget-usd`** begrenzt die Kosten eines Lauf (nur mit `-p`) — sinnvoll
  als Sicherung in einem Cron.

### 3.2 Lauffähige Beispielzeile für den Anwendungsfall

```bash
cd /home/lukas/WebStorm/JTL-Robotico && \
claude -p --model sonnet --permission-mode dontAsk \
  --allowedTools "Read" "mcp__youtrack__update_article" \
  --max-budget-usd 1.00 --output-format json -- \
  'Lies @docs/plans/2026-07-10 - mssql-ops-infrastruktur/reports/youtrack-testmandant-reset-kurzanleitung.md.
   Lade AUSSCHLIESSLICH den Teil ab der zweiten H1-Zeile (alles nach dem
   ersten "---"-Trenner, die Pflege-Preamble gehoert NICHT dazu) unveraendert
   und vollstaendig per mcp__youtrack__update_article nach JTL-A-20 hoch
   (append=false, summary nicht aendern). Aendere keinen Buchstaben am Inhalt.
   Melde am Ende nur die hochgeladene Zeichenzahl.' \
| jq -r '.result'
```

> [!WARNING]
> Diese Zeile **schreibt** nach YouTrack. Für einen Probelauf
> `mcp__youtrack__update_article` durch `mcp__youtrack__get_article` ersetzen
> und den Prompt auf „vergleiche" umstellen — genau so wurden die Tests dieser
> Recherche gefahren.

## 4. Auth-Persistenz — Befund

### 4.1 Wo die Konfiguration liegt

`claude mcp get youtrack` in dieser Umgebung:

```
youtrack:
  Scope: User config (available in all your projects)
  Status: ✔ Connected
  Type: http
  URL: https://dattenberger.youtrack.cloud/mcp
  OAuth: client_id configured, callback_port 29352
```

Der Server steht also in **User-Scope**, gespeichert in `~/.claude.json` unter
`mcpServers.youtrack` mit den Feldern `type`, `url` und `oauth.{clientId,
callbackPort}` — **kein Token in dieser Datei**. Weil User-Scope in allen
Projekten lädt, ist der Server aus jedem Arbeitsverzeichnis heraus verfügbar;
eine projektlokale `.mcp.json` existiert in diesem Repo nicht.

Vollständige Serverliste dieser Umgebung (`claude mcp list`):

| Server | Transport | Status |
|---|---|---|
| `youtrack` (User-Scope) | HTTP | ✔ Connected |
| `robotico` (User-Scope) | HTTP | ✘ Failed — statischer `Authorization`-Header abgelehnt, Token-Format erneuert (`rtok_mcp_…`), neues Token nötig |
| `claude.ai Figma`, `Asana`, `Google Cloud BigQuery` | Connector | ✔ Connected |
| `claude.ai Gmail`, `Google Calendar`, `Google Drive` | Connector | ! Needs authentication |
| `plugin:cloudflare:cloudflare-docs` | HTTP | ✔ Connected |
| `plugin:cloudflare:` `-api`, `-bindings`, `-builds`, `-observability` | HTTP | ! Needs authentication |

### 4.2 Wo die Tokens liegen

`~/.claude/.credentials.json`, Dateimodus `600`, zwei Top-Level-Schlüssel:
`claudeAiOauth` (Anthropic-Login) und `mcpOAuth`. Pro Server ein Eintrag unter
`<name>|<hash>`, hier `youtrack|d19f9e2ab2576a78`, mit der Feldstruktur:

| Feld | Typ | Bedeutung |
|---|---|---|
| `serverName`, `serverUrl` | string | Zuordnung zum Config-Eintrag |
| `accessToken` | string | kurzlebig — siehe unten |
| `refreshToken` | string | **die eigentlich tragende Credential** |
| `expiresAt` | number | ms-Epoch des Access-Token-Ablaufs |
| `scope`, `discoveryState` | string / object | OAuth-Metadaten |

Zum Zeitpunkt der Messung (2026-07-30 01:22 Uhr) stand `expiresAt` auf
`1785370554249` = **2026-07-30 02:16 Uhr**, also **~53 Minuten Restlaufzeit**.
Der Access-Token lebt damit etwa eine Stunde; jeder headless Lauf, der später
als das läuft, ist auf einen erfolgreichen Refresh angewiesen. Laut Doku
erneuert Claude Code den Token bei einem `401` automatisch, reconnectet und
wiederholt die Anfrage einmal — das passiert unbemerkt und erklärt, warum die
Tests hier durchliefen.

Auf `~/.claude-secrets.md` bezogen: unter `## Repo: /home/lukas/WebStorm/excel_ekl`
existiert ein Eintrag **„YouTrack Cloud KB reference account (test-only,
2026-07-13)"** mit den Feldern Purpose / Base URL / Demo article / Login /
Password / Scope — also ein **Login-Paar, kein API-Token**. Ein permanenter
YouTrack-Token (`perm:…`) ist im Secret-Store nicht vorhanden, und in keinem
Repo unter `~/WebStorm` findet sich bestehende YouTrack-REST-Nutzung
(Suche nach `youtrack.cloud/api` und `perm:` über `*.ts/*.js/*.sh/*.py/*.ps1`
ergibt null Treffer). Option (b) in §6 braucht also eine einmalige
Token-Erstellung.

## 5. Grenzen

### 5.1 `--bare` schaltet genau das ab, was hier gebraucht wird

Die offizielle Doku empfiehlt `--bare` als „recommended mode for scripted and
SDK calls" und kündigt es als künftigen Default für `-p` an. Für einen
OAuth-MCP-Lauf ist es aber das falsche Flag: Bare-Mode überspringt die
Auto-Discovery von MCP-Servern **und** liest weder OAuth noch Keychain
(„Bare mode skips OAuth and keychain reads. For Anthropic authentication, set
`ANTHROPIC_API_KEY` or configure an `apiKeyHelper`"). Gemessen:

```console
$ claude --bare -p --mcp-config ./mcp-yt.json \
    --allowedTools "mcp__youtrack__get_article" -- 'Titel von JTL-A-20?'
Not logged in · Please run /login
```

Der Lauf scheitert also bereits an der Anthropic-Authentifizierung, bevor MCP
überhaupt eine Rolle spielt. **Konsequenz:** Läuft `-p` künftig per Default
bare, bricht ein heute funktionierender Cron-Job still — das ist das größte
Wartungsrisiko dieses Weges.

### 5.2 Interaktiver Re-Login lässt sich nicht automatisieren

Der Doku-Satz, der die verbreitete Aussage „interaktiv authentifizierte
MCP-Server können in headless/cron-Läufen fehlen" trägt, steht in
[`docs/en/mcp`](https://code.claude.com/docs/en/mcp) im Abschnitt
*Authenticate with remote MCP servers*:

> In non-interactive mode there's no `/mcp` panel, so Claude Code can't run the
> OAuth flow for you. As of v2.1.196, when a configured server needs
> authentication during a `claude -p` or Agent SDK run with tool search
> enabled, which is the default, Claude Code tells Claude that the server's
> tools are unavailable until you authorize it. […] Complete the sign-in from
> an interactive session with `/mcp` or `claude mcp login <name>`.

**Bewertung:** Die Aussage ist korrekt, aber schwächer als sie klingt. Sie
betrifft nur den Fall, dass **noch nie** oder **nicht mehr gültig**
authentifiziert wurde. Ein gültiger Refresh-Token trägt headless Läufe
unbegrenzt weiter, weil Claude Code den Access-Token selbst erneuert. Bricht
das Refresh (YouTrack lehnt den Refresh-Token ab, z. B. nach Passwortwechsel
oder Token-Revocation), verhält sich der headless Lauf **freundlich, aber
nutzlos**: Claude bekommt gesagt, die Tools des Servers seien nicht verfügbar,
und berichtet das — der Job endet mit Exit-Code 0 und ohne Upload. Ein Cron
muss das Ergebnis also inhaltlich prüfen, nicht nur den Exit-Code.
`claude mcp login youtrack` (ab v2.1.186 direkt aus der Shell, mit
`--no-browser`-Variante) heilt es, braucht aber einen Menschen.

Für CI-Gates gibt es einen sauberen Hebel: mit `--output-format stream-json`
enthält das `system/init`-Event die Felder `mcp_servers` (Name + Status) und
`mcp_server_errors`. Ein Job kann darauf abbrechen, bevor er etwas hochlädt.

### 5.3 Weitere headless-Bruchstellen

- **`requiresUserInteraction`-Tools:** Ein MCP-Server kann ein Tool per
  `_meta["anthropic/requiresUserInteraction"]` als immer-bestätigungspflichtig
  markieren. Solche Tools werden in `dontAsk` **verweigert** und lassen sich
  auch per Allow-Regel oder `bypassPermissions` nicht freischalten. Die
  YouTrack-Tools sind davon nicht betroffen (die Tests liefen durch), aber ein
  Server-Update könnte das ändern.
- **Kosten und Kontext:** Der erste, nicht optimierte Testlauf kostete
  **0,37 USD** für eine triviale Vergleichsaufgabe (8 Turns, 277 k
  Cache-Read-Tokens), weil `-p` ohne `--bare` denselben Kontext lädt wie eine
  interaktive Session — inklusive CLAUDE.md, Skills und Plugins. Für einen
  Sync, der eigentlich ein `curl` ist, ist das ein hoher Preis pro Lauf.
- **Nicht-Determinismus im Datenpfad:** In einem Testlauf mit falschem Pfad
  hat das Modell eigenständig entschieden, nicht weiterzumachen und
  nachzufragen — richtig, aber ein Cron kann darauf nicht antworten. Bei einem
  Voll-Überschreiben ist die Kehrseite gefährlicher: ein Modell, das den
  Dateiinhalt „glättet", zerstört den Artikel ohne Fehlermeldung.
- **Background-MCP-Calls:** Lange MCP-Aufrufe wandern in `-p` nicht
  automatisch in den Hintergrund, sofern nicht `CLAUDE_AUTO_BACKGROUND_TASKS=1`
  gesetzt ist — für kurze Artikel-Uploads irrelevant.
- **Ausgabelimits:** MCP-Tool-Output wird bei 25 000 Tokens gekappt
  (`MAX_MCP_OUTPUT_TOKENS` hebt das). Beim *Lesen* großer Artikel relevant,
  beim Schreiben nicht.

## 6. Optionsvergleich und Empfehlung

### 6.1 Option (a) — MCP headless über `claude -p`

| | |
|---|---|
| **Setup** | keines — funktioniert heute |
| **Robustheit** | mittel: LLM im Datenpfad, Token-Refresh als stille Abhängigkeit, `--bare`-Default-Umstellung als Zeitbombe |
| **Wartbarkeit** | mittel: der Prompt *ist* die Spezifikation; Regeln stehen in Prosa, nicht in Code |
| **Kosten** | ~0,05–0,40 USD pro Lauf |
| **Stärke** | versteht Absichten („aktualisiere auch den Stand-Datum-Hinweis") — gut für Ad-hoc-Arbeit |

### 6.2 Option (b) — direkter REST-Call gegen die YouTrack-API

Endpunkt und Aufrufform (JetBrains-Doku):

```bash
curl -X POST \
  'https://dattenberger.youtrack.cloud/api/articles/JTL-A-20?fields=id,idReadable,summary' \
  -H "Authorization: Bearer $YOUTRACK_TOKEN" \
  -H 'Accept: application/json' -H 'Content-Type: application/json' \
  --data-binary @payload.json
```

`payload.json` enthält `{"content": "<markdown>"}` — mit `jq -Rs '{content:.}'`
sauber aus der Datei erzeugt, ohne Quoting-Fallen. Nötige Rechte: *Update
Article*.

| | |
|---|---|
| **Setup** | einmalig: permanenter Token in YouTrack erzeugen, in `~/.claude-secrets.md` unter `## Repo: /home/lukas/WebStorm/JTL-Robotico` ablegen (heute nicht vorhanden, s. §4.2) |
| **Robustheit** | hoch: deterministisch, idempotent, kein Modell, kein Token-Refresh-Problem, Exit-Code aussagekräftig |
| **Wartbarkeit** | hoch: die Extraktionsregel steht als Code da und ist testbar |
| **Kosten** | 0 |
| **Schwäche** | Token-Handling liegt bei uns; kein „versteht Absichten" |

### 6.3 Die Extraktionsregel ist mechanisch — und das ist das Argument

Die Quelldateien tragen eine Pflege-Preamble, die **nicht** hochgeladen werden
darf; die Datei sagt selbst „den GESAMTEN Inhalt (ab der H1 unten)". Diese
Regel ist exakt abbildbar — geprüft an beiden Dateien:

```console
$ awk 'f; /^---$/{f=1}' youtrack-testmandant-reset-kurzanleitung.md | sed '/./,$!d' | head -1
# JTL-Testmandanten            # 6070 Zeichen (Datei gesamt: 6813)

$ awk 'f; /^---$/{f=1}' youtrack-testmandant-reset-kurzanleitung.en.md | sed '/./,$!d' | head -1
# JTL Test Mandants            # 5790 Zeichen
```

Ein `claude -p`-Lauf muss diese Regel bei **jedem** Aufruf aus Prosa neu
ableiten; das Skript macht es einmal richtig. Zusammen mit der 1:n-Zuordnung
(zwei Dateien → `JTL-A-20` / `JTL-A-21`) ist das genau der Fall, in dem eine
Mapping-Tabelle im Skript der Prompt-Formulierung überlegen ist.

### 6.4 Option (c) — MCP-Server-CLI direkt ansprechen

Für YouTrack **nicht anwendbar**: der Server ist ein remote HTTP-Endpunkt
(`https://dattenberger.youtrack.cloud/mcp`), kein lokal startbarer
stdio-Prozess mit CLI. Ein generischer MCP-Client (MCP Inspector CLI o. ä.)
könnte ihn ansprechen, müsste aber seinen **eigenen** OAuth-Flow und
Token-Store mitbringen — er kann `~/.claude/.credentials.json` nicht
mitbenutzen. Das ergäbe eine zweite Credential-Haltung für dieselbe API und
wäre schlechter als (b), das dieselbe API direkt und dokumentiert anspricht.

### 6.5 Empfehlung

> [!IMPORTANT]
> **Für den wiederholbaren „Markdown → YouTrack-Artikel"-Sync: Option (b),
> ein kleines Shell-Skript gegen die REST-API.** Der Upload ist ein reiner
> Byte-Transfer mit einer festen Extraktionsregel — ein Sprachmodell im
> Datenpfad bringt keinen Nutzen und trägt drei Risiken (stiller
> Inhaltsdrift, Token-Refresh-Abhängigkeit, `--bare`-Default-Umstellung).
>
> **Für Ad-hoc-Arbeit bleibt Option (a) der richtige Weg** — sie braucht keine
> neue Credential und ist genau dann besser, wenn Inhalt *und* Formulierung
> zusammen überarbeitet werden.

Umsetzungsschritte für (b), in dieser Reihenfolge:

- [ ] Permanenten YouTrack-Token mit *Update Article*-Recht erzeugen und unter
      `## Repo: /home/lukas/WebStorm/JTL-Robotico` in `~/.claude-secrets.md`
      ablegen.
- [ ] Skript `scripts/youtrack-sync-article.sh` mit Mapping-Tabelle
      (Datei → Artikel-ID), `awk`-Extraktion, `jq -Rs`-Payload, `--fail`-Curl
      und Verifikations-`GET` nach dem `POST`.
- [ ] Trockenlauf-Schalter (`--dry-run`: extrahieren, Zeichenzahl und Diff
      gegen den aktuellen Artikelinhalt zeigen, nicht schreiben).
- [ ] Die Pflege-Blockquotes in beiden Quelldateien und den Verweis in
      `docs/SQL/MSSQL-OPS-ARCHITECTURE.md` (Zeile 30, „per MCP hochladen")
      auf das Skript umstellen, damit es nur eine dokumentierte Vorgehensweise
      gibt.

Bis das Skript existiert, ist die Beispielzeile aus §3.2 der Weg mit dem
geringsten Aufwand.

## 6a. MCP-CLI-Client — gibt es das, und ist es sinnvoll?

Nachfrage des Users (2026-07-30): Weder „Modell im Datenpfad" (§6.1) noch
„eigenes REST-Skript" (§6.2) überzeugt — gesucht ist **ein CLI-Command, der
die MCP-Server von Claude Code direkt nutzt**. Befund in drei Teilen:

### 6a.1 In Claude Code: existiert nicht

`claude mcp --help` (v2.1.220, vollständig ausgelesen) kennt genau diese
Subcommands: `add`, `add-from-claude-desktop`, `add-json`, `get`, `list`,
`login`, `logout`, `remove`, `reset-project-choices`, `serve`. **Kein
`call`/`invoke`/`run`.** Die CLI *verwaltet* MCP-Server, sie *ruft* sie nicht
auf; der Aufruf passiert ausschließlich im Modell-Loop. `claude mcp serve` ist
die Gegenrichtung (Claude Code selbst als MCP-Server für andere Clients) und
löst diesen Fall nicht. Eine Issue-Suche in `anthropics/claude-code` nach
einem entsprechenden Feature-Request förderte nur Bug-Reports zu MCP-Aufrufen
zutage (u.a. #80026, #69739), keinen Request für ein Direktaufruf-Verb — das
ist ein schwaches Negativ-Indiz, kein Beweis.

### 6a.2 Generischer MCP-Client: existiert — mit eigener Auth

Der **MCP-Inspector** hat einen `--cli`-Modus, der Tools deterministisch ohne
LLM aufruft:

```bash
npx @modelcontextprotocol/inspector --cli https://dattenberger.youtrack.cloud/mcp \
  --transport http --method tools/call \
  --tool-name update_article --tool-args-json '{"articleId":"JTL-A-20","content":"…"}'
```

Authentifizierung: `--header "Authorization: Bearer …"` bzw. `--use-stored-auth`
mit Tokens aus **seinem eigenen** Store `~/.mcp-inspector/storage/oauth.json`.

Claude Code legt seine MCP-OAuth-Daten dagegen in `~/.claude/.credentials.json`
unter `mcpOAuth` ab, je Server ein Eintrag mit `serverName`, `serverUrl`,
`accessToken`, `refreshToken`, `clientId`, `redirectUri`, `expiresAt`, `scope`
(Struktur verifiziert; Werte nicht zitiert). Ein Fremdclient könnte diese
Felder technisch übernehmen — aber Format und **Refresh-Logik gehören Claude
Code**: wer den Token nebenher benutzt, hängt an einem Vertrag, den niemand
garantiert.

### 6a.3 Für unseren YouTrack-Fall scheitert der Weg an der Auth-Topologie

Entscheidender Befund: Die YouTrack-Credentials, mit denen in dieser Session
`update_article` lief, liegen **überhaupt nicht auf dieser Maschine**.

```console
$ claude mcp get youtrack
youtrack:
  Scope: User config (available in all your projects)
  Status: ! Needs authentication
  Type: http
  URL: https://dattenberger.youtrack.cloud/mcp
```

Der lokal konfigurierte HTTP-Server ist **unauthentifiziert**, und
`~/.claude/.credentials.json` enthält für ihn keinen `mcpOAuth`-Eintrag (dort
stehen nur die vier Cloudflare-Plugin-Server). Die tatsächlich benutzten
`mcp__youtrack__*`-Tools kommen also über die **claude.ai-Seite**; ihr Token
liegt serverseitig im Account, nicht im Dateisystem. Konsequenz: Ein lokaler
CLI-Client kann diese Autorisierung **nicht** mitbenutzen — auch nicht per
Kopieren. Er bräuchte eine eigene YouTrack-Autorisierung; und sobald man die
ohnehin einrichtet, ist der direkte REST-Call (§6.2) der kürzere Weg.

### 6a.4 Bewertung: wann MCP-CLI sinnvoll ist — und wann nicht

MCP ist ein Protokoll, damit **Modelle** Werkzeuge entdecken und benutzen
können: selbstbeschreibende Schemas, Tool-Listen, Aushandlung. In einem Skript,
das den Aufruf bereits genau kennt, ist dieser Apparat Ballast — ein
npx-Prozess je Aufruf, Protokoll-Handshake und eine Token-Abhängigkeit, um am
Ende einen HTTP-Request abzusetzen, den `curl` in einer Zeile erledigt.

| Servertyp | MCP-CLI sinnvoll? | Begründung |
|---|---|---|
| Offene, dokumentierte REST-API (YouTrack) | **Nein** | Der MCP-Server ist eine dünne Hülle; Permanent Token + `curl` ist weniger beweglich und besser debugbar |
| Gekapselte Konnektoren (Figma, BigQuery, Asana) | **Ja, potenziell** | Der Server kapselt Auth und nicht-triviale Logik, die man sonst nachbauen müsste |
| Ad-hoc-Exploration / Debugging eines MCP-Servers | **Ja** | Genau der Zweck des Inspector-CLI-Modus (Tool-Listen, Probeaufrufe) |

Für den „Markdown → YouTrack-Artikel"-Sync bleibt die Empfehlung aus §6.4
bestehen: deterministisches Skript gegen die REST-API. Der MCP-Weg ist hier
nicht *unmöglich*, sondern nur der aufwendigere Weg zum selben HTTP-Aufruf.

## 7. Information Gaps

1. **Lebensdauer des Refresh-Tokens** — gemessen ist nur der Access-Token
   (~1 h). Wie lange YouTrack-Cloud-Refresh-Tokens gültig bleiben und ob sie
   bei Inaktivität verfallen, ist offen. Bis das geklärt ist, muss ein Cron
   auf Option (a) das Ergebnis inhaltlich prüfen (§5.2). Owner: offen.
2. **Berechtigungsumfang eines permanenten Tokens** — ob der YouTrack-Plan
   Tokens mit auf die KB eingeschränktem Scope zulässt oder nur
   Voll-Benutzerrechte, ist nicht geprüft. Fallback: Token unter einem
   dedizierten Service-Account statt unter `lukas` erzeugen. Owner: Lukas.
3. **Der `robotico`-MCP-Server ist defekt** (§4.1, statisches
   `Authorization`-Header-Token abgelehnt, neues `rtok_mcp_…`-Token nötig).
   Für diese Frage irrelevant, aber ein offener Nebenbefund. Owner: Lukas.
4. **Ob `-p` tatsächlich auf `--bare` umgestellt wird** und ab welcher Version,
   ist nur als Ankündigung dokumentiert. Ein Skript, das (a) nutzt, sollte
   `--bare` niemals implizit erben — d. h. Flags explizit setzen und den
   Serverstatus prüfen. Owner: offen.

## 8. References

- Claude Code — [Run Claude Code programmatically (headless)](https://code.claude.com/docs/en/headless)
  — stdin-Pipe, `--output-format json|stream-json`, `--allowedTools`,
  `--bare`-Semantik, `system/init`-Felder `mcp_servers` / `mcp_server_errors`
- Claude Code — [Connect Claude Code to tools via MCP](https://code.claude.com/docs/en/mcp)
  — Scopes (local/project/user), Token-Refresh bei `401`,
  Non-interactive-Auth-Absatz (§5.2), `requiresUserInteraction`,
  `MCP_TOOL_TIMEOUT` / `MAX_MCP_OUTPUT_TOKENS`
- Claude Code — [CLI reference](https://code.claude.com/docs/en/cli-reference)
  — `--system-prompt-file`, `--append-system-prompt-file`, `--permission-mode`,
  `--strict-mcp-config`, `--max-budget-usd`
- YouTrack — [Operations with Specific Article](https://www.jetbrains.com/help/youtrack/devportal/operations-api-articles.html)
  (`POST /api/articles/{articleID}`) und
  [Permanent Token Authorization](https://www.jetbrains.com/help/youtrack/devportal/authentication-with-permanent-token.html)
- YouTrack — [Manage Permanent Tokens](https://www.jetbrains.com/help/youtrack/cloud/manage-permanent-token.html)
- Quelldateien des Anwendungsfalls:
  [`reports/youtrack-testmandant-reset-kurzanleitung.md`](../plans/2026-07-10%20-%20mssql-ops-infrastruktur/reports/youtrack-testmandant-reset-kurzanleitung.md)
  (→ `JTL-A-20`) und
  [`reports/youtrack-testmandant-reset-kurzanleitung.en.md`](../plans/2026-07-10%20-%20mssql-ops-infrastruktur/reports/youtrack-testmandant-reset-kurzanleitung.en.md)
  (→ `JTL-A-21`)
- Querverweis auf die heutige Vorgehensweise:
  [`docs/SQL/MSSQL-OPS-ARCHITECTURE.md`](../SQL/MSSQL-OPS-ARCHITECTURE.md) Zeile 30
- Lokale Konfiguration (gelesen, nicht verändert): `~/.claude.json`
  (`mcpServers.youtrack`, User-Scope), `~/.claude/.credentials.json`
  (`mcpOAuth["youtrack|…"]`, Modus 600)
