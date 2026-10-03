# Plan: Objektfilm Fas 2, backend på egna servrar

*Planen är skriven 3 oktober 2026 och bygger bara på läsning. Inga filer har ändrats och inget har körts mot servrarna. **[V]** betyder att uppgiften är verifierad i repot, med källa. **[A]** betyder att det är ett antagande som måste prövas.*

---

## 0. Fem saker från läsningen som styr planen

1. **Klientens IP-adress går inte att se.** Routern SNAT:ar 443-forwarden, så cheetah ser gatewayens `10.0.0.x` som källa för all WAN-trafik **[V: `network/entrypoints.md`, kommentar i `vhosts.yml`]**. Två följder:
   - Begränsning per IP fungerar inte, så takten måste begränsas per token och per API-nyckel.
   - DSM-ACL:en `e2103e2d-…` skyddar ingenting. Det enda som spärrar är att namnet saknas i publik DNS.
2. **Tjänsten blir miljöns första med riktiga kunddata.** Det är bilder på hem, kopplade till adress, och mäklarens namn. Det krockar med principen "Ingen instans är produktion" **[V: `CLAUDE.md`, `services/what-runs-where.md`]**. Det finns heller ingen offsite-backup i miljön **[V: `runbooks/backup-strategy.md`]**.
3. **Webbvarianten har inte samma sha256 som originalet.** `sha256` i specen är originalets identitet **[V: `docs/reel-spec-v1.md` 2.1]**. Servern kan alltså inte kontrollera hashen mot den nedskalade bilden. Blobbar lagras därför under originalets hash, och varianten får en egen integritetshash.
4. **En ändring i `vhosts.yml` startar om DSM nginx.** Handlern `restart dsm nginx` startar om nginx, och det studsar hela Container Manager på cheetah, alltså även Pi-hole och Tailscale **[V: `roles/dsm_reverse_proxy/handlers/main.yml`]**. Det steget är utåtriktat och kräver ditt OK.
5. **runner1 passar inte för kunddata.** Säkerhetsmodellen säger "maskinen håller inga hemligheter … når inte produktionsdata", och CI kör som docker-gruppen, vilket i praktiken är root **[V: `hosts/runner1.md`]**.

---

## 1. Placering

### Värd: **server3** (10.0.0.37)

| Kandidat | Bedömning |
|---|---|
| **server3** | **Rekommenderas.** Värden bär redan låg publik last (demo bakom cheetahs RP) bredvid ac-stable. Cirka 5 GB RAM är ledigt i vila och cirka 130 GB disk är ledig **[V: `what-runs-where.md`, `flytt-fran-110.md` målbild]**. Den har redan Rundecks nyckel, `promtail-system` och node_exporter **[V: `hosts/server3.md`, `deploy-promtail-system.yml`]**. |
| runner1 | Nej. CI-modellen "engångs, inte isolerad" förbjuder i praktiken produktionsdata. CPU-trycket är dessutom högt på natten **[V: `hosts/runner1.md`]**. |
| ops1 | Nej. "ops1 kör inte produkten och ska inte kunna göra det" **[V: `hosts/ops1.md`]**. |
| cheetah | Bara som reserv. Den bär redan publika Erugo via en Ansible-roll, men flyttplanen avfärdade uttryckligen att lägga produkt på samma maskin som övervakningen. DSM har dessutom compose v1, icke-deklarativa containrar och nginx-omstarter som studsar allt **[V: `flytt-fran-110.md` "Alternativ som avfärdats", `roles/erugo/defaults`]**. |

**Risk med server3:** det är den enda värden som har AssetCores age-identitet **[V]**. En ny publik tjänst där ökar attackytan. Motåtgärder:
- containern kör som annan användare än root, med `read_only: true`, `cap_drop: [ALL]` och `no-new-privileges`
- ingen docker-socket och inga monteringar utanför `~/objektfilm/data`
- ett eget docker-nätverk

Värdera själv om det räcker (öppen fråga F2).

### Datalagring på server3 (allt under `/home/fredrike/objektfilm/`)

| Vad | Var | Storlek [A] |
|---|---|---|
| Databas (SQLite, WAL) | `data/db/objektfilm.db` | < 100 MB |
| Webbvarianter | `data/blobs/img/<sha256-orig[0:2]>/<sha256-orig>/w1600.jpg` + `w480.jpg` | cirka 0,5 MB × 25 per objekt |
| MP4 | `data/blobs/mp4/<sha256-mp4>.mp4` | 15–40 MB per film |
| **Original** | **Stannar på Macen** (enligt plan 5.3) | – |

Med 50 objekt per månad och 90 dagars gallring blir det cirka 5–10 GB **[A]**.

### Backup enligt miljöns mönster

- **Databasen, varje natt.** `sqlite3 .backup` (eller `VACUUM INTO`) körs i containern och age-krypteras till en **egen mottagare**, `objektfilm-backup`. Identiteten finns bara i lösenordshanteraren och på Macen, inte på server3. Principen "maskinen som skapar backuper ska inte kunna läsa dem" kommer från **[V: `hosts/server3.md`]**. Filen skickas med `scp -O` till `cheetah:/volume1/backups/objektfilm/`, på samma sätt som stagings `/volume1/backups/assetcore/staging` **[V: `flytt-fran-110.md`; `-O`-fällan i `hosts/server3.md`]**. Kopiorna gallras efter 30 dagar så att raderade objekt försvinner även ur backupen.
- **Blobbar säkerhetskopieras inte.** Webbvarianterna kan laddas upp igen från Macen, där originalen finns, och MP4:or kan renderas om från godkänd spec. Återställning går då till så här: återställ databasen, låt Macen ladda upp saknade sha256 via `POST /assets/check`, och köa om renderingen för objekt med status `rendered`. Det håller backupen liten och GDPR-vänlig. Vill du ändå ha MP4 med i backupen är det öppen fråga F5.
- **Bevisad återställning varje vecka.** Ett Rundeck-jobb packar upp backupen i en temporär container och kör `PRAGMA integrity_check` plus en räkning mot den levande databasen. Mönstret är detsamma som i AssetCores DR-bevis.

### Gränsen mellan repona

| Repo | Äger |
|---|---|
| **photoflow** (`/Users/fredrik/Developer/photo-preprocesser`) | Appkoden, `server/Dockerfile`, `server/compose.yaml`, deploy-playbooken `server/ansible/deploy.yml` (rsync + build på värden, som AssetCores "riktiga releaser görs från Mac:en") och hemligheter i `server/secrets/film.sops.env` (sops+age som AssetCore) |
| **EriksvikSite** | DNS i tre lager, RP-vhost, Prometheus-skrapmål, Rundeck-jobb (heartbeat, backup, återställningsbevis), heartbeat-watchdogens EXPECT-lista och dokumentation (`hosts/server3.md`, `network/entrypoints.md`, `services/what-runs-where.md`, ny `runbooks/objektfilm.md`) |

---

## 2. Exponering

### Namn: `film.eriksvik.site`

Namnet täcks av det befintliga wildcard-certet och terminering i DSM RP **[V: `vhosts.yml`-huvudet]**. Om du senare vill ha ett eget varumärkesdomännamn är det öppen fråga F1. Det kräver i så fall en utökad cert-pipeline.

### De tre lagren, i två steg

**Steg B, LAN och Tailscale ("inte skyltad"):**

`ansible/vars/vhosts.yml`, under en ny rubrik `# ── objektfilm (PhotoFlow) ──`:
```yaml
  - fqdn: film.eriksvik.site
    backend_host: 10.0.0.37
    backend_port: 8470
    description: "Objektfilm (PhotoFlow) — mäklarlänkar + renderkö. Egen token-auth, ingen ACL (hade ändå inte hållit mot WAN)."
```
`ansible/vars/pihole_hosts.yml`:
```yaml
  - ip: 10.0.0.5
    hostname: film.eriksvik.site
    note: "Objektfilm — LAN via cheetahs RP till server3:8470 (som demo)"
```
`ansible/vars/godaddy_records.yml` → lägg `film.eriksvik.site` i **`godaddy_omit_fqdns`** under steg B. Annars skapar nästa reconcile en publik post, vilket är exakt det som hände med `status` **[V]**.

**Steg C, publikt:** ta bort namnet ur `godaddy_omit_fqdns`. A-posten genereras då från vhosts.yml **[V: `deploy-godaddy-dns.yml`-huvudet]**.

Kommandon, alla från `ansible/` med `.venv/bin/ansible-playbook`:
```sh
playbooks/deploy-entrypoints.yml --check     # läs "would add"
playbooks/deploy-entrypoints.yml              # ⚠ startar om DSM nginx (with-maintenance 5m)
playbooks/deploy-pihole-dns.yml               # default add
dig @10.0.0.5 film.eriksvik.site | grep flags # kräver "aa"
playbooks/deploy-godaddy-dns.yml --check      # läs BÅDE would add och would remove
playbooks/deploy-godaddy-dns.yml              # steg C
dig +short NS eriksvik.site; dig +short @1.1.1.1 film.eriksvik.site
```

Efter steg B behöver även telegrafs probelista uppdateras, eftersom den genereras från vhosts.yml. Det schemalagda `healthcheck: entrypoints` läker det med `fix=true`, men larmar en gång först **[V: `rundeck/jobs/healthcheck-entrypoints.yaml`]**. Kör `deploy-telegraf.yml` själv i samma veva.

**Mät det som serveras.** Hasha svaret för `film` och jämför med svaret för ett påhittat namn mot WAN-IP:n, eftersom cheetah svarar 200 med Synologys standardsida för okända namn **[V: `entrypoints.md`]**. Lägg därför till headern `X-Objektfilm: 1` och ett fast `/healthz`-svar som sonden kan kontrollera.

### Säkerhetsåtgärder för en publik tjänst

| Område | Åtgärd |
|---|---|
| **Token** | 32 slumpbyte (256 bitar) i base64url. Bara `sha256(token)` lagras. Länkformen är `https://film.eriksvik.site/m#<token>`. **Token ligger i fragmentet**, som aldrig skickas till servern. JS läser det och skickar `Authorization: Link <token>`. Då hamnar token aldrig i DSM nginx-loggar, Loki eller Referer. |
| **Utgång och återkallning** | Standard 30 dagar, högst 90. Länken kan återkallas från Macen. En utgången länk ger 410 och en sida med texten "Kontakta fotografen". |
| **API-nyckel** | Formen är `pf_<32 byte base64url>`, lagrad som hash och med scope `photographer` respektive `render`. Nyckeln skapas med `docker compose exec app node src/cli.ts create-key --name …`, som skriver ut den en enda gång. |
| **Takt** | **Per token och per nyckel**, inte per IP: 120 anrop/min, 30 spec-skrivningar/timme per länk, plus ett globalt tak. Ogiltiga tokens räknas globalt. Över 50 på 5 minuter ger en varningsrad i loggen och en räknare som larmar. Ogiltig auth får fast fördröjning. |
| **Storleksgränser i appen** | JSON 256 KB, bild 4 MB (bara `image/jpeg`, och dimensionerna kontrolleras ur headern), MP4 300 MB (bara med scope `render`). Högst 40 assets per objekt och 30 klipp per spec. |
| **Storleksgräns i DSM RP** | `client_max_body_size` är **[A: okänt]**. `manage_rp.py` sätter bara timeouts på 60 s **[V]**. Testa i steg B med `curl -T` mot en testendpoint. Ger det 413 införs uppladdning i delar (8 MB per del, `PUT /uploads/{id}?offset=`). |
| **Timeouts** | `proxy_read_timeout` är 60 **[V]**, så long-poll får hålla högst 25 s. |
| **Inga index** | `robots.txt` med `Disallow: /`, `X-Robots-Tag: noindex, nofollow` och ingen kataloglistning. Ändrande GET-anrop finns inte, så att länkförhandsvisning i iMessage är ofarlig. |
| **CORS** | Inga CORS-headers alls, eftersom allt ligger på samma ursprung. Mäklarens endpoints avvisar `Origin` som inte är `https://film.eriksvik.site`. |
| **CSP** | `default-src 'self'; img-src 'self' blob: data:; media-src 'self' blob:; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'`. Dessutom `Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff` och `Permissions-Policy` med kamera och mikrofon avstängda. HSTS sätts av appen **utan** `includeSubDomains`, eftersom RP:n har `hsts: False` **[V]**. |
| **Mediafiler** | HMAC-signerade URL:er (`/media/<exp>/<sig>/<key>`) med 1 timmes giltighet och `Cache-Control: private`. Range-stöd för MP4 krävs, annars spelar inte iOS Safari upp filen. |
| **Loggning** | JSON till stdout med `objectId`, `linkId` (internt id, inte token), endpoint, status och tid. **Inga** adresser, namn, IP-adresser (de är ändå gatewayens), user-agent eller token. Loki behåller loggar i 30 dagar **[V: `roles/loki_cheetah/defaults`]**. |
| **Port på server3** | Publicera `10.0.0.37:8470:8080` och `10.0.0.37:9471:9471` (mätvärden, proxas **inte**). Kontrollera att portarna är lediga med `ss -ltn` **[A]**. Begränsa gärna 8470 till källa 10.0.0.5 med en `DOCKER-USER`-regel, eftersom Docker kringgår ufw **[A: brandväggstyp på server3 ej dokumenterad]**. |

### Fällorna i `CLAUDE.md`

- **DSM Auto Block:** inga SSH-loopar mot cheetah. Batcha i en session.
- **Enskild bind-monterad fil:** konfig ges via env-variabler och katalogmonteringar. Om en fil måste monteras återskapar deploy containern (som i `docs_site`).
- **`restart`:** använd `unless-stopped` på server3, där DSM:s egenhet inte gäller.
- **`with-maintenance`** finns bara på cheetah (och .110) **[V: `flytt-fran-110.md` fas 4]**. Deploy-playbooken får alltså inte förutsätta den på server3.

---

## 3. Stack

**Rekommendation: Node 24 LTS + TypeScript (Fastify) + SQLite.**

| Alternativ | För | Emot |
|---|---|---|
| **Node/TS** | Återanvänder `web/reel/src/reelSpec.ts`, som redan är skriven som "erasable TS" så att Node kan köra den direkt **[V: filhuvudet]**. Spec-validering och revisionslogik delas med redigeraren. Ett språk för webb och server. | Ytterligare ett runtime i miljön, men det är litet. |
| Swift/Vapor | Delar `ReelSpec.swift` | Codable **tappar okända fält** vid omkodning, vilket bryter mot "läsare ska ignorera och bevara". Tyngre bygge. Webben behöver TS ändå. |
| Go | En statisk binär, lätt drift | Tredje språket, ingen återanvändning |
| Python/FastAPI | Välkänt för Ansible-skripten | Ingen återanvändning |

**Databas: SQLite** (better-sqlite3, eller `node:sqlite` om den är stabil när bygget görs **[A]**).
- En fil, ingen extra container och trivial `.backup`.
- Optimistisk låsning går rakt: `UPDATE … WHERE revision = ?`.
- Postgres vore konsekvent med AssetCore men ger två containrar och PITR-maskineri som tjänsten inte behöver. Byt om flera fotografer eller skrivlast motiverar det (öppen fråga F4).

**Ingen bildbehandling på servern.** Macen gör webbvarianterna, och servern läser bara JPEG-headern för dimensionerna (t.ex. `image-size`). Inget sharp/libvips ger mindre image och mindre attackyta.

**Containern.** `server/Dockerfile` bygger i flera steg: Vite bygger `web/reel` till `dist/`, sedan `node:24-bookworm-slim` med uid 10470. Byggkontexten är repots rot med `.dockerignore`.

`server/compose.yaml`:
```yaml
services:
  app:
    build: { context: .., dockerfile: server/Dockerfile }
    container_name: objektfilm-app
    restart: unless-stopped
    user: "10470:10470"
    read_only: true
    tmpfs: [/tmp]
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    mem_limit: ${OBJEKTFILM_MEM_LIMIT:-512m}   # samma mönster som observability (${…:-2g})
    cpus: 1.0
    env_file: .env                              # renderas från sops vid deploy, 0600
    ports: ["10.0.0.37:8470:8080", "10.0.0.37:9471:9471"]
    volumes: ["./data:/data"]                   # katalog, inte enskilda filer
    healthcheck:
      test: ["CMD", "node", "src/healthcheck.ts"]
      interval: 30s
      timeout: 5s
      retries: 3
  promtail:
    profiles: [promtail]                        # av som default, som AssetCores PROMTAIL_PROFILE
    image: grafana/promtail:3.4.2
    ...                                          # labels {app="objektfilm", host="server3"}
```

- `mem_limit` följer mönstret i `roles/observability/files/docker-compose.yml` **[V]**.
- `/healthz` kontrollerar att databasen svarar (`SELECT 1`), att `data/` är skrivbar och att det finns minst 5 GB ledigt.

---

## 4. API

Prefixet är `/api/v1`. Statiska sidor ligger på `/` (en landningssida som ger 200, vilket entrypoint-sonden kräver), `/m` (mäklarredigeraren) och `/a` (arkivet).

### Datamodell (SQLite)

```
photographers(id, name, created_at, disabled_at)
api_keys(id, photographer_id, key_hash, scope 'photographer'|'render', label, created_at, revoked_at, last_used_at)
objects(id uuid, photographer_id, reel_id UNIQUE, address, session_id, kind,
        status 'draft'|'proposed'|'approved'|'rendered',
        current_revision, approved_revision, created_at, updated_at,
        purge_after, deleted_at)
object_assets(object_id, asset_id, sha256, width, height, analysis_json, sort,   -- kandidatpoolen (alla färdiga bilder)
              PRIMARY KEY(object_id, sha256))
blobs(sha256_orig, variant 'w1600'|'w480', variant_sha256, bytes, created_at,
      PRIMARY KEY(sha256_orig, variant))
spec_revisions(object_id, revision, spec_json, content_hash, author_role, author_ref, created_at,
               PRIMARY KEY(object_id, revision))
links(id, object_id, token_hash UNIQUE, label, created_at, expires_at, revoked_at, last_used_at)
render_jobs(id, object_id, revision, output_id, status 'queued'|'claimed'|'done'|'failed'|'superseded',
            worker_id, lease_until, attempts, error, created_at, finished_at)
renders(id, object_id, revision, output_id, sha256, bytes, width, height, duration, created_at)
workers(id, label, last_seen_at)
events(id, object_id, at, actor_role, actor_ref, type, data_json)        -- utan IP/UA/adress
```

**Kanonisk spec på servern.** `assets[].sources` skrivs om till `[{kind:"store", key:"img/<sha256>"}]`. Lokala sökvägar lagras aldrig.

- Till webben levereras `sources` som signerade `url`.
- Till Macen levereras specen med `store`, och Macen mappar tillbaka till `local` via sha256.
- Servern sätter `revision`, `updatedAt`, `updatedBy` och `status` i specen, så att specen speglar objektet.

### Fotografens API (`Authorization: Bearer pf_…`, scope `photographer`)

| Metod | Väg | Beskrivning |
|---|---|---|
| GET | `/me` | Testar anslutningen |
| PUT | `/objects/by-reel/{reelId}` | Idempotent upsert av objekt (`address`, `sessionID`, `kind`) → `{objectId, status, currentRevision}` |
| POST | `/assets/check` | `{sha256:[…]}` → `{missing:[…]}` |
| PUT | `/assets/{sha256}/{variant}` | `image/jpeg`. Servern beräknar `variant_sha256` och lagrar under originalhashen |
| PUT | `/objects/{id}/pool` | Hela kandidatpoolen med `width/height/analysis` (krävs för att webben ska kunna lägga till en bild med rimlig rörelse) |
| GET | `/objects/{id}` | Status, aktuell spec (`ETag: "<rev>"`), länkar, renderingar |
| PUT | `/objects/{id}/spec` | `If-Match: "<rev>"` → 200 med ny revision, **412** med aktuell spec vid krock. Identiskt innehåll (samma `content_hash`) räknas inte som ny revision, så omförsök blir ofarliga |
| POST | `/objects/{id}/links` | `{label, expiresInDays}` → `{linkId, url}` (token visas bara här). Första länken flyttar `draft → proposed` |
| DELETE | `/links/{id}` | Återkallar länken |
| POST | `/objects/{id}/approve` | (valfritt, F6) fotografen godkänner på mäklarens uppdrag, loggas som `actor=photographer` |
| DELETE | `/objects/{id}` | Hård radering: rader, blobbar som inte längre refereras och händelser |
| GET | `/objects?status=&since=` | Listan som Macens statusvy använder |

### Mäklarens API (`Authorization: Link <token>`)

| Metod | Väg | Beskrivning |
|---|---|---|
| GET | `/share` | Adress, status, spec med signerade URL:er, pool (w480 för rutnätet, w1600 för förhandsvisning) och renderingar |
| PUT | `/share/spec` | `If-Match`. Vid 412 visar UI:t "Fotografen har ändrat, ladda om". Validering: alla `timeline[].asset` måste finnas i objektets pool (beslut 10.1 #11), `duration` inom 0,5–10 s, `minReaderVersion ≤ 1` |
| POST | `/share/approve` | `{revision}` måste vara lika med `current_revision`, annars 409. Skapar `render_job` per `outputs[]` |
| GET | `/share/renders/{id}` | MP4 med Range-stöd, `Content-Disposition: inline; filename="Objektfilm.mp4"` (adressen hålls utanför filnamnet) |

### Renderkön (`Authorization: Bearer pf_…`, scope `render`)

| Metod | Väg | Beskrivning |
|---|---|---|
| POST | `/render-jobs/claim?wait=25` | Long-poll. Svarar 200 med `{jobId, objectId, revision, spec, leaseUntil}` eller 204. Uppdaterar `workers.last_seen_at` även vid 204 |
| POST | `/render-jobs/{id}/heartbeat` | Förlänger lease till +10 min |
| PUT | `/render-jobs/{id}/output` | `video/mp4`, strömmas till disk och sha256 beräknas. Är `revision != approved_revision` blir jobbet `superseded` (svar 409) och filen kastas |
| POST | `/render-jobs/{id}/fail` | `{message}`. Efter 3 försök blir jobbet `failed` och syns i heartbeat |

### Statusflöde

```
draft ──(första länk)──► proposed ◄──(ändring av någon part)── approved / rendered
                            │
                     (mäklaren godkänner rev N)
                            ▼
                         approved ──(MP4 för rev N uppladdad)──► rendered
```

- En ändring i läge `approved` skickar objektet tillbaka till `proposed`. Köade jobb sätts till `superseded`, och ett jobb som redan är hämtat avvisas vid uppladdning.
- I läge `rendered` står tidigare MP4:or kvar som "tidigare version" tills gallringen tar dem.
- Varje övergång ger en rad i `events`.

### Gallring

En daglig gallring körs i appen kl. 03:30. `purge_after` sätts så här:
- `rendered_at + 90 d`, annars
- `updated_at + 90 d` för objekt som aldrig godkänts.

Rundecks heartbeat kontrollerar att det **inte** finns några objekt med `purge_after < now()`.

---

## 5. Mac-appens del (photoflow-repot)

### Nya filer, i projektets stil (ren logik i `nonisolated enum`, tester i `PhotoFlow/Tests/`)

| Fil | Typ | Innehåll |
|---|---|---|
| `Sources/Services/KeychainStore.swift` | `nonisolated enum` | `kSecClassGenericPassword`, service `se.digido.photoflow.objektfilm`, account = serverns host. Aldrig UserDefaults. I dag finns ingen Keychain-kod i appen **[V: grep]** |
| `Sources/Services/Reel/ReelServerClient.swift` | `actor` | URLSession med typade endpoints, `If-Match`, 412 och omförsök. Appen är inte sandboxad, så nätverk behöver ingen entitlement **[V: `PhotoFlow.entitlements`]** |
| `Sources/Services/Reel/ReelWebVariant.swift` | `nonisolated enum` | `CGImageSourceCreateThumbnailAtIndex` → 1600 px och 480 px på längsta sidan, sRGB, JPEG 0,8. **Tar bort EXIF/GPS** |
| `Sources/Services/Reel/ReelUploadPlanner.swift` | `nonisolated enum` (ren) | Vilka sha256 som saknas, `local → store` i specen, poolen från analysen. Testbar utan nätverk |
| `Sources/Services/Reel/ReelSyncMerger.swift` | `nonisolated enum` (ren) | Serverns spec → lokal: `store → local` via sha256-index (från cachen `reel_analysis.json`, som redan nycklas på SHA-256 **[V: commit 7141843]**). Rapporterar saknade hashar |
| `Sources/Services/Reel/ReelRemoteState.swift` | Codable | `reel-remote.json` bredvid `reel.json` i FILM-mappen: `{server, objectId, lastSyncedRevision, links[]}`. Dessutom ett appindex i Application Support: `objectId → FILM-mapp`, så att renderaren hittar originalen |
| `Sources/Services/Reel/ReelRenderWorker.swift` | `actor` | Long-poll-slinga med backoff, claim → slå upp mapp → `ReelSyncMerger` → `ReelRenderer.export` → ladda upp → spara MP4 även lokalt. Heartbeat var 60:e sekund. `ProcessInfo.beginActivity` under rendering så att App Nap inte stryper |

`ReelRenderer.fileURL(for:)` löser bara `local`-källor **[V]**. Mergern måste därför alltid skriva lokala sökvägar innan rendering.

### UI

- **`ReelEditorView`:** knappen **"Skicka till mäklare…"** bredvid "Rendera" (rad cirka 115). Ett ark tar mäklarens namn och giltighet (30 d) och visar förloppet "Laddar upp 12/24". Sedan visas länken med **Kopiera** och **Dela** (`NSSharingServicePicker`: Meddelanden/Mail).
- **Statusmärke** i redigerarens huvud: "Utkast · Hos mäklaren (rev 4) · Godkänd, väntar på rendering · Renderad". Knappen **"Hämta ändringar"** körs också automatiskt när fönstret öppnas. Vid 412 visas dialogen "Mäklaren har ändrat. Ladda om?"
- **`SettingsView`:** ny sektion "Objektfilm" med server-URL, API-nyckel (sparas i Keychain), "Testa anslutning" och reglaget "Rendera godkända filmer automatiskt när appen är igång".
- **Historik/Dashboard:** en liten köindikator, och `NotificationService` meddelar när en film är renderad och uppladdad.
- **Senare:** `photoflow-cli reel-worker --once` för en launchd-agent, om du vill rendera utan att appen är öppen.

---

## 6. Drift

### Övervakning

| Vad | Hur | Var det ändras |
|---|---|---|
| Mätvärden | `/metrics` på `:9471`: `objektfilm_render_queue_oldest_seconds`, `_worker_last_seen_seconds`, `_invalid_auth_total`, `_uploads_bytes_total`, `_objects{status}`, `_purge_overdue` | EriksvikSite `roles/observability/files/prometheus.yml` (nytt `job_name: objektfilm`, mål `10.0.0.37:9471`) → `deploy-observability.yml -l ops1` |
| Containerloggar | promtail-profilen i compose → Loki `{app="objektfilm"}` | photoflow `server/compose.yaml` |
| Värd | Finns redan: node_exporter, cAdvisor (AssetCores) och promtail-system på server3 **[V]** | – |
| **Leveranskontroll** | Rundeck `objektfilm: heartbeat` var 15:e minut, se nedan | `rundeck/jobs/objektfilm-heartbeat.yaml` |
| Backup | Rundeck `objektfilm: backup` 02:50 och `objektfilm: återställningsbevis` måndagar 04:45 | `rundeck/jobs/objektfilm-backup*.yaml` |
| Backstopp | Lägg till `"objektfilm-heartbeat:40"` och `"objektfilm-backup:1560"` i `EXPECT` | `rundeck/heartbeat-watchdog.sh` → `deploy-heartbeat-watchdog.yml` |
| RP-sond | Följer automatiskt med `healthcheck: entrypoints` (läser vhosts.yml) **[V]** | – |

**`objektfilm: heartbeat` mäter det som faktiskt levereras.** Jobbet följer mönstret i `observability-heartbeat.yaml`. Skilj "SSH fungerar inte" från "tjänsten är nere".

1. **Publika vägen:** `curl --resolve film.eriksvik.site:443:176.10.208.245 https://film.eriksvik.site/healthz` ska ge 200, rätt kropp och headern `X-Objektfilm`, så att det inte är Synologys standardsida.
2. **Hela kedjan mot ett kanarieobjekt:** ett testobjekt med en egen länk, utan riktig data. `GET /api/v1/share` → hämta en asset via den signerade URL:en → jämför `variant_sha256`. Det bevisar token, databas, blobbar och signering.
3. **Kön:** äldsta `approved` utan rendering äldre än 4 timmar ger varning. Har workern dessutom inte setts på 24 timmar blir det fail. En avstängd Mac på kvällen ska inte väcka någon.
4. **Gallring:** `purge_overdue` större än 0 ger fail.
5. **Disk:** `data/` och `df /` på server3 över 85 % ger varning.
6. **Senaste backup:** NAS-kopians mtime mäts **på cheetah**, inte lokalt **[V: lärdomen i `hosts/server3.md`]**.

Heartbeat skickas till Loki på `http://10.0.0.5:3100` med `{job="cron", task="objektfilm-heartbeat", host="server3", result=…}`. Discord meddelas via `notify-discord.sh` och speglas automatiskt till Loki **[V: `runbooks/larmhistorik.md`]**.

**Larm i Grafana:** skriv inga `count_over_time(...[26h])`-regler, eftersom de inte kan slockna **[V: `CLAUDE.md`]**. Mät aktuellt läge.

### GDPR

| Data | Var | Hur länge |
|---|---|---|
| Webbvarianter (utan EXIF/GPS) | server3 `data/blobs/img` | 90 d efter rendering eller senaste aktivitet |
| Specar, revisioner, adress | server3 SQLite | Samma, raderas med objektet |
| MP4 | server3 `data/blobs/mp4` + lokalt på Macen | Samma på servern |
| Mäklarens namn (länketikett) | `links.label` | Samma |
| Händelselogg | `events` (utan IP/UA) | Raderas med objektet |
| Driftloggar (utan personuppgifter) | Loki | 30 d |
| Krypterad databasbackup | cheetah `/volume1/backups/objektfilm` | 30 d |
| Original | Bara fotografens Mac | Som i dag |

- All lagring sker hemma i Sverige, så ingen molnleverantör behöver ett biträdesavtal för lagringen. GoDaddy hanterar bara DNS.
- Det som återstår är rollfördelningen (personuppgiftsansvarig eller biträde) mot mäklarna, villkor och en samtyckesruta om säljaren (plan 8.4).
- **Radering på begäran:** `DELETE /objects/{id}` raderar direkt. Backupen försvinner inom 30 dagar, och det dokumenteras.

---

## 7. Genomförande i steg

Storlek: S ≈ 1 dag, M ≈ 2–4 dagar, L ≈ 1 vecka. 🔒 = utåtriktat, kräver ditt uttryckliga OK.

| # | Steg | Repo | Storlek | Lokal verifiering |
|---|---|---|---|---|
| **A1** | Färdigställ `web/reel` (tidslinjen passerar `PhotoFlow/Tests/Fixtures/Reel/timeline-vectors.json`, tolerans 1e-9) plus redigeraren | photoflow | M | `node --test web/reel/test` |
| **A2** | `server/`: schema, domänlogik (status, låsning, tokens, validering), routes, CLI och tester (`node:test`): 412 vid krock, idempotent spec, superseded-jobb, utgången länk, poolvalidering, gallring | photoflow | L | `node --test server/test` |
| **A3** | `server/Dockerfile`, `compose.yaml`, `compose.dev.yaml` (port `127.0.0.1:8470`, ingen promtail). `docs/objektfilm-api-v1.md` (eller `server/openapi.yaml`) | photoflow | S | `docker compose -f server/compose.yaml -f server/compose.dev.yaml up --build` på Macen. Docker finns redan där (AssetCores dev-miljö **[V: `services/environments.md`]**) |
| **A4** | Mac: Keychain, klient, webbvariant, planerare, merger, "Skicka till mäklare", hämta ändringar, renderworker, inställningar | photoflow | L | Mot `http://localhost:8470`. Hela flödet går att köra på en maskin: skicka, ändra i Safari på Macen, godkänn, rendera, arkiv |
| **A5** | Backup- och återställningsskript i appen (`node src/cli.ts backup --out …`) plus test | photoflow | S | Lokalt |
| **B0** | Kontrollera på server3 med **en** SSH-session: `ss -ltn`, `df -h /`, brandväggstyp, `docker compose version` | – | S | 🔒 läsning mot produktionsvärd, ofarligt men be om OK |
| **B1** | `server/ansible/deploy.yml` (rsync → `~/objektfilm`, sops → `.env` 0600, `compose up -d --build`, vänta på `/healthz`). Skapa age-paret `objektfilm-backup` (identiteten till lösenordshanteraren) | photoflow | M | `--check` |
| **B2** | 🔒 **Första deploy till server3** | photoflow | S | `curl http://10.0.0.37:8470/healthz` från LAN |
| **B3** | EriksvikSite-ändringar på branch: vhosts.yml, pihole_hosts.yml, `godaddy_omit_fqdns`, prometheus.yml, Rundeck-jobb, EXPECT, dokumentation (`hosts/server3.md`, `network/entrypoints.md`, `services/what-runs-where.md`, `runbooks/objektfilm.md` + `nav:` i `mkdocs.yml`) | EriksvikSite | M | `--check` på alla playbooks |
| **B4** | 🔒 `deploy-entrypoints.yml` (**startar om DSM nginx, studsar Pi-hole och Tailscale cirka 60 s**, välj tid), `deploy-pihole-dns.yml`, `deploy-telegraf.yml` | EriksvikSite | S | `dig @10.0.0.5 … | grep flags` (aa), `openssl s_client -servername film.eriksvik.site -connect 10.0.0.5:443` |
| **B5** | 🔒 `deploy-observability.yml -l ops1`, `deploy-heartbeat-watchdog.yml`, import av Rundeck-jobb (admin-formulärinloggning, fasta `uuid:`), `rd-run.sh "sync: pull EriksvikSite"`, `rd-run.sh "objektfilm: heartbeat"` | EriksvikSite | S | Grön körning, heartbeat syns i Loki |
| **B6** | Test i steg B, på LAN/Tailscale med riktig HTTPS: iPhone, Web Share med fil till IG Reels/TikTok (plan 10.2), 413-test med stor MP4, Range-uppspelning | – | S | Riktig iPhone |
| **C1** | 🔒 **Publik exponering:** ta bort namnet ur `godaddy_omit_fqdns`, `deploy-godaddy-dns.yml --check` och läs `would add`/`would remove`, sedan skarp körning | EriksvikSite | S | `dig +short @1.1.1.1 film.eriksvik.site`, hashjämförelse mot påhittat namn via WAN-IP |
| **C2** | 🔒 **Push av EriksvikSite till `main`** (publicerar docs.eriksvik.site inom cirka 90 s) | EriksvikSite | S | Sidan syns. En ny katalog kräver omstart av `eriksvik-docs`, men `runbooks/` är redan symlänkad **[V]** |
| **C3** | Pilot med en mäklare | – | – | – |

Commits och push i photoflow-repot görs bara när du ber om det. I EriksvikSite är push till `main` alltid 🔒.

---

## 8. Öppna frågor, med rekommendation

| # | Fråga | Rekommendation |
|---|---|---|
| F1 | Domän: `film.eriksvik.site` eller ett eget varumärke (t.ex. ett namn under digido.se)? | `film.eriksvik.site` för piloten, eftersom certet redan finns. Byt först när fler mäklare kommer. Det kräver en utökad cert-pipeline. |
| F2 | Räcker containerhärdningen för en publik tjänst på server3, där age-identiteten bor? | Ja för piloten, med härdningen i avsnitt 2. Alternativet är att flytta identiteten till lösenordshanteraren och köra återställningsbevisen med strömmad dekryptering. |
| F3 | Hur benämns instansen, med tanke på "Ingen instans är produktion"? | Kalla den **"pilot med riktiga data"** och skriv det i `services/what-runs-where.md`. Den är inte produktion i AssetCores mening, men data- och GDPR-hygienen gäller fullt ut. |
| F4 | SQLite eller Postgres? | SQLite. Byt om det blir fler än cirka 5 samtidiga fotografer eller behov av PITR. |
| F5 | Ska MP4 ingå i backupen? | Nej. De kan renderas om från godkänd spec. Ta med dem om Macen inte alltid är kvar (t.ex. byte av dator). |
| F6 | Får fotografen godkänna på mäklarens uppdrag? | Ja, men det loggas som `actor=photographer` och syns för mäklaren. |
| F7 | Gallring: 90 dagar efter rendering, eller "när objektet är sålt"? | 90 dagar automatiskt, plus manuell radering. "Sålt" går inte att veta utan integration. |
| F8 | Länkens giltighet? | 30 dagar som standard, högst 90, och den kan förlängas från Macen. |
| F9 | Offsite-backup saknas i hela miljön. Ska den här tjänsten tvinga fram den? | Inte som blockerare för piloten, eftersom originalen finns på Macen. Lägg upp en uppgift: Backblaze B2 enligt `backup-strategy.md` lager 3, med `/volume1/backups/objektfilm` först i kön. |
| F10 | Ska renderworkern kunna köra utan att appen är öppen? | Inte i v1. Det räcker med reglaget i appen och tydlig status ("Renderas när fotografens dator är igång"). launchd och CLI tas upp om väntetiden blir ett problem. |
| F11 | Begränsa server3:8470 till källa 10.0.0.5 med `DOCKER-USER`? | Ja, om B0 visar att det är enkelt. Annars räcker bindningen till LAN-IP. |

---

### Viktigaste filerna för genomförandet
- `/Users/fredrik/Developer/photo-preprocesser/web/reel/src/reelSpec.ts`: delas mellan redigeraren och servervalideringen
- `/Users/fredrik/Developer/photo-preprocesser/PhotoFlow/Sources/Views/Reel/ReelEditorModel.swift`: "Skicka till mäklare", synk och status
- `/Users/fredrik/Developer/photo-preprocesser/PhotoFlow/Sources/Services/Reel/ReelRenderer.swift`: renderworkern, lokal upplösning av källor (`fileURL(for:)`)
- `/Users/fredrik/Developer/EriksvikSite/ansible/vars/vhosts.yml`, `/Users/fredrik/Developer/EriksvikSite/ansible/vars/pihole_hosts.yml` och `/Users/fredrik/Developer/EriksvikSite/ansible/vars/godaddy_records.yml`: DNS i tre lager
- `/Users/fredrik/Developer/EriksvikSite/rundeck/jobs/observability-heartbeat.yaml`: förlaga till `objektfilm-heartbeat.yaml`. Dessutom `/Users/fredrik/Developer/EriksvikSite/rundeck/heartbeat-watchdog.sh` (EXPECT-listan)
