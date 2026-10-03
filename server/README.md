# Objektfilm-servern

Backend för Objektfilm (Fas 2): tar emot objekt, webbvarianter och specrevisioner från Mac-appen, låter mäklaren redigera och godkänna via en länk, och håller en renderkö som Macen hämtar jobb ur. Planen finns i `docs/plan-objektfilm-backend.md`, API:t i `docs/objektfilm-api-v1.md`.

**Val:** Nodes inbyggda `http` (inga ramverk) och `node:sqlite` (inbyggd, inga npm-beroenden). Servern har därför ingen `npm install`, ingen `node_modules` och minimal attackyta; routern, Range-stödet och kroppsgränserna är några hundra rader. TypeScript körs direkt av Node (bara "erasable" syntax, som `web/reel`). Specvalidering och tidslinje återanvänds från `web/reel/src/` (`reelSpec.ts`, `reelTimeline.ts`). Kräver Node 24 eller nyare (Node 25 finns på Macen).

## Köra lokalt utan Docker

```sh
cd web/reel && npm install && npm run build && cd ../../server   # webbdelen (/m, /a)

export OBJEKTFILM_ENV=dev                       # tillåter tillfällig signeringsnyckel
export OBJEKTFILM_DATA_DIR=$PWD/data            # standard är ./data (gitignorerad)
export OBJEKTFILM_PUBLIC_URL=http://127.0.0.1:8470
export OBJEKTFILM_PORT=8470 OBJEKTFILM_METRICS_PORT=9471
export OBJEKTFILM_HOST=127.0.0.1 OBJEKTFILM_METRICS_HOST=127.0.0.1
npm start                                       # node src/main.ts
curl -i http://127.0.0.1:8470/healthz
```

I produktion (`OBJEKTFILM_ENV=production`, standard) krävs `OBJEKTFILM_SIGNING_KEY` (minst 32 tecken, `openssl rand -base64 48`). Alla variabler står i `.env.example`. Inga hemligheter hör hemma i repot: `.env` och `data/` är gitignorerade.

## Köra med Docker

```sh
# från repots rot, utveckling på Macen (127.0.0.1:8470, metrics 127.0.0.1:9471, data i server/data-dev):
mkdir -p server/data-dev
docker compose -f server/compose.yaml -f server/compose.dev.yaml up --build

# kontroll och nyckel
curl -i http://127.0.0.1:8470/healthz
docker compose -f server/compose.yaml -f server/compose.dev.yaml exec app node src/cli.ts create-key --name "Fredrik" --scope photographer --label "Macen"
docker compose -f server/compose.yaml -f server/compose.dev.yaml down
```

Produktionsform (server3): `cp server/.env.example server/.env`, fyll i signeringsnyckeln, `mkdir -p server/data && chown 10470:10470 server/data`, sedan `docker compose -f server/compose.yaml up -d --build`. Portarna binds till `OBJEKTFILM_BIND` (standard `10.0.0.37`, i dev `127.0.0.1`). Containern kör som uid 10470 med `read_only`, `tmpfs /tmp`, `cap_drop: ALL`, `no-new-privileges`, `mem_limit`, och bara `./data` monterad. Loggar till Loki: `docker compose --profile promtail up -d`.

> Obs: Docker-bygget är inte provkört i den miljö där filerna skrevs (Docker-daemonen var avstängd). Filernas innehåll och konfigurationen (`docker compose config`) är kontrollerade, och samma filuppsättning som Dockerfilen kopierar (server/src + reelSpec.ts + reelTimeline.ts + web/reel/dist) är provkörd med Node.

## Nycklar och CLI

```sh
node src/cli.ts create-key --name "Fredrik" --scope photographer --label "Macen"   # visas en gång
node src/cli.ts create-key --name "Fredrik" --scope render --label "Renderworker"  # samma fotograf, scope render
node src/cli.ts list-keys
node src/cli.ts revoke-key --id <nyckel-id>
node src/cli.ts backup --out backups/objektfilm-2026-10-03.db
node src/cli.ts verify-backup --file backups/objektfilm-2026-10-03.db
node src/cli.ts restore --from backups/objektfilm-2026-10-03.db [--force]
node src/cli.ts purge
```

Mac-appen behöver två nycklar: `photographer` (objekt, bilder, spec, länkar) och `render` (renderkön). Båda hör till samma fotograf, och renderworkern ser bara den fotografens jobb. Nyckeln lagras bara som hash på servern.

## Tester

```sh
cd server && npm test                            # node --test "test/*.test.ts"
node --test "server/test/*.test.ts"              # från repots rot
cd web/reel && npm test                          # webbdelen, inklusive shareApi
```

Testerna startar en riktig server på slumpad port mot en temporär datakatalog (aldrig mot `./data`) och täcker nycklar/scope, mäklarlänkar (utgången/återkallad 410, fel Origin), 412 och idempotent spec, statusflödet, superseded-jobb, long-poll (204 och väckning), signerade media-URL:er och Range, storleksgränser (413), poolvalidering, GPS-spärr, gallring, backup/återställning (`integrity_check`), migrationer och att loggen saknar personuppgifter.

## Backup och återställning

- **Backup:** `node src/cli.ts backup --out <fil>` gör en konsekvent kopia med `VACUUM INTO` (funkar medan servern kör) och kör `PRAGMA integrity_check` på resultatet. I planen kör ett Rundeck-jobb detta nattetid i containern och age-krypterar filen innan den skickas till NAS:en (`docker compose exec app node src/cli.ts backup --out /data/backups/…`, katalogen måste ligga under `/data`).
- **Blobbar säkerhetskopieras inte.** Webbvarianter kan laddas upp igen från Macen och MP4 kan renderas om från godkänd spec.
- **Återställning:** stoppa servern, `node src/cli.ts restore --from <fil> --force` (verifierar backupen först och sparar den gamla databasen som `….före-återställning`), starta servern. Låt Macen därefter kontrollera `POST /assets/check` och ladda upp saknade bilder, och köa om renderingen för objekt som var `rendered`.
- **Veckovis bevis:** `node src/cli.ts verify-backup --file <fil>` skriver `integrity_check` och radantal att jämföra mot den levande databasen.

## Datakatalog

```
data/db/objektfilm.db            SQLite (WAL), schema versionerat med PRAGMA user_version
data/blobs/img/<ab>/<sha256>/w1600.jpg, w480.jpg   (under ORIGINALETS hash)
data/blobs/mp4/<sha256>.mp4
data/tmp/                        pågående uppladdningar (städas av gallringen)
```

## Hur Mac-appen (steg A4) använder API:t

1. **Inställningar:** server-URL och de två API-nycklarna (Keychain). "Testa anslutning" = `GET /api/v1/me` (både `photographer`- och `render`-nyckel ger svar; `scope` i svaret visar vilken det är).
2. **Skicka till mäklare:** `PUT /objects/by-reel/{reelId}` (reelId = `reel.json`:s `id`) → `objectId`. `POST /assets/check` med alla pool-sha256 (originalens hash, samma som `assets[].sha256`) → ladda upp `missing` som `PUT /assets/{sha256}/w1600` och `/w480` (JPEG, sRGB, **utan EXIF/GPS**, ≤ 4 MB; servern nekar GPS-data). `PUT /objects/{id}/pool` med alla färdiga bilder (`assetId`, `sha256`, `width`, `height`, `analysis`). `PUT /objects/{id}/spec` med `If-Match: "0"` första gången; specen skrivs om `local → store` (`{"kind":"store","key":"img/<sha256>"}`; servern skriver om i alla fall). `POST /objects/{id}/links` → visa/dela `url` (token visas bara då).
3. **Hämta ändringar:** `GET /objects/{id}` (`ETag`/`currentRevision`, `status`). Ny revision → hämta `spec` och mappa `store → local` via sha256 (okända fält ska bevaras). Spara alltid med `If-Match: "<lastSyncedRevision>"`; vid 412 innehåller svaret aktuell spec: fråga "Mäklaren har ändrat. Ladda om?". Omförsök med samma kropp är ofarligt (idempotent).
4. **Statusvy:** `GET /objects?status=&since=`. Status: `draft`, `proposed` (hos mäklaren), `approved` (väntar på rendering), `rendered`. En ändring från någon part tar `approved`/`rendered` tillbaka till `proposed`.
5. **Renderworker:** slinga med `POST /render-jobs/claim?wait=25` (render-nyckel; 204 = inget jobb, försök igen direkt; server-timeout för proxyn är 60 s). Jobbet innehåller specen (`store`) och `outputId` att rendera. `POST /render-jobs/{id}/heartbeat` var 60:e sekund (409 `superseded` = avbryt, mäklaren har ändrat). `PUT /render-jobs/{id}/output?width=&height=&duration=` med `Content-Type: video/mp4` (≤ 300 MB, strömma från disk). 409 `superseded` = släng filen. Vid fel: `POST /render-jobs/{id}/fail {message}` (3 försök, sedan `failed`).
6. **Fotografen kan godkänna åt mäklaren:** `POST /objects/{id}/approve {revision}`. **Radera:** `DELETE /objects/{id}`. **Återkalla länk:** `DELETE /links/{id}`.
7. Felkoder och texter är svenska och kan visas direkt (`error.message`).
