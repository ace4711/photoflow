# Objektfilm API v1

Servern i `server/`. Allt ligger under `/api/v1` utom sidor och media. JSON är UTF-8. Alla svar har `X-Objektfilm: 1`, `Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff`, `X-Robots-Tag: noindex, nofollow` och en strikt CSP. Inga CORS-headers sätts: allt ligger på samma ursprung.

## 1. Behörighet

| Roll | Header | Gäller för |
|---|---|---|
| Fotograf | `Authorization: Bearer pf_<…>` (scope `photographer`) | `/me`, `/objects…`, `/assets…`, `/links/{id}` |
| Renderworker | `Authorization: Bearer pf_<…>` (scope `render`) | `/me`, `/render-jobs…` |
| Mäklare | `Authorization: Link <token>` | `/share…` |

- API-nycklar skapas med CLI:t (`node src/cli.ts create-key --name … --scope photographer|render`) och visas en gång. Servern lagrar bara `sha256(nyckel)`. En nyckel hör till en fotograf. Renderworkern ser bara den fotografens jobb.
- Mäklarens token är 32 slumpbyte i base64url. Den ligger i länkens **fragment** (`/m#<token>`), skickas aldrig till servern av webbläsaren och går bara i headern. Servern lagrar bara `sha256(token)`.
- Mäklarens anrop med en `Origin`-header som inte är serverns eget ursprung (eller `OBJEKTFILM_EXTRA_ORIGINS`) ger 403.

## 2. Fel

Alla fel har formen

```json
{ "error": { "code": "revision_conflict", "message": "Svenskt meddelande som kan visas för användaren." } }
```

plus eventuella extrafält (t.ex. `currentRevision`, `spec`).

| Status | `code` (urval) | När |
|---|---|---|
| 400 | `bad_json`, `bad_if_match` | Trasig JSON, `If-Match` som inte är ett revisionsnummer |
| 401 | `unauthorized` | Saknad/ogiltig nyckel eller token (fast fördröjning, räknas i `objektfilm_invalid_auth_total`) |
| 403 | `wrong_scope`, `bad_origin` | Fel scope; mäklaranrop med fel `Origin` |
| 404 | `not_found` | Okänt eller annans objekt, jobb, länk |
| 405 | `method_not_allowed` | |
| 409 | `revision_mismatch`, `no_spec`, `reel_taken`, `superseded`, `not_claimed` | Se respektive endpoint |
| 410 | `link_expired`, `link_revoked`, `media_expired` | Länk utgången/återkallad ("Kontakta fotografen"), signerad media-URL utgången |
| 412 | `revision_conflict` | `If-Match` är inte aktuell revision. Kroppen innehåller `currentRevision` och aktuell `spec`. |
| 413 | `payload_too_large` | JSON > 256 kB, bild > 4 MB, MP4 > 300 MB |
| 415 | `unsupported_media_type`, `bad_image`, `bad_mp4` | Fel `Content-Type` eller innehåll |
| 422 | `invalid_spec`, `bad_*`, `too_many_assets`, `gps_in_image`, `image_too_large` | Valideringsfel |
| 428 | `precondition_required` | `If-Match` saknas på spec-PUT |
| 429 | `rate_limited` | Takten överskriden. `Retry-After` anger sekunder. |
| 503 | `web_missing` | Webbdelen är inte byggd |

**Takt** (per nyckel/länk, inte per IP eftersom klientens IP inte syns bakom routern): 120 anrop/min per nyckel eller länk, 30 spec-skrivningar/timme per länk (600 per fotografnyckel) och ett globalt tak på 1200 anrop/min. `/healthz` och `/metrics` räknas inte.

## 3. Statusflöde

```
draft ──(första länken)──► proposed ◄──(ändring av spec, av någon part)── approved / rendered
                              │
                       (godkänn revision N)
                              ▼
                           approved ──(alla MP4 för revision N uppladdade)──► rendered
```

- Varje övergång skriver en rad i `events` (roll, id på nyckel/länk, ingen adress, namn eller IP).
- En spec-ändring som gör en ny revision sätter alla köade och hämtade renderjobb till `superseded` och tar objektet tillbaka till `proposed`. En MP4 som laddas upp för ett ersatt jobb ger 409 `superseded` och kastas. Tidigare renderingar står kvar som "tidigare version" (`current: false`).
- Godkännande är idempotent: samma revision en gång till ger `changed: false` och inga nya jobb.
- Gallring: `purge_after` = senaste skrivande aktivitet + 90 dagar (rendering räknas). Daglig gallring kl. 03:30 (även `node src/cli.ts purge`) raderar objektet med alla rader, bildfiler som ingen annan refererar och MP4. `DELETE /objects/{id}` gör samma sak direkt.

## 4. Spec på servern

Specen är ReelSpec v1 (`docs/reel-spec-v1.md`), validerad med samma `parseReelSpec` som webben. Därtill:

- `id` måste vara objektets `reelId`. `assets[].sha256` måste finnas i objektets pool (annars 422). Bildmåtten skrivs över av poolens.
- `assets[].sources` skrivs alltid om till `[{"kind":"store","key":"img/<sha256>"}]`. Lokala sökvägar lagras aldrig.
- Servern äger `revision`, `updatedAt`, `updatedBy.role` (`photographer` eller `agent`), `property` (adress/sessionID/kind ur objektet) och `status` (speglar objektets status vid läsning). Okända fält bevaras.
- Högst 30 klipp, högst 40 bilder, klipplängd 0,5–10 s, högst 4 utbildsprofiler (≤ 4096 px, 1–60 fps, unika id). Mäklaren får inte ändra `outputs`.
- `content_hash` = sha256 över kanonisk JSON utan `revision`, `updatedAt`, `updatedBy` och `status`. Samma innehåll som aktuell revision ger 200 med `changed: false` och ingen ny revision (idempotent omförsök, även med föråldrad `If-Match`).
- Till webben levereras `sources` som `[{"kind":"url","url":"/media/…"}]` (signerade, 1 timme) och poolbilder som saknas i specen läggs till i `assets` så att mäklaren kan lägga till dem.

## 5. Fotografens API (scope `photographer`)

`ETag` är alltid `"<revision>"`.

| Metod och väg | Beskrivning |
|---|---|
| `GET /api/v1/me` | `{apiVersion, scope, keyId, photographer{id,name}, serverTime}`. Funkar för båda scopen. Testar anslutningen. |
| `PUT /api/v1/objects/by-reel/{reelId}` | Idempotent upsert. Kropp `{address, sessionID?, kind?}` → 201/200 `{objectId, status, currentRevision}`. 409 `reel_taken` om id:t tillhör en annan fotograf. |
| `POST /api/v1/assets/check` | `{sha256:[…]}` (≤ 500) → `{missing:[…]}`. En hash är "saknad" tills både `w1600` och `w480` finns. |
| `PUT /api/v1/assets/{sha256}/{variant}` | `variant` = `w1600` eller `w480`, `Content-Type: image/jpeg`, ≤ 4 MB. `sha256` är **originalets**. Servern läser JPEG-huvudet (mått ≤ 2000 resp. 700 px på längsta sidan), vägrar bilder med GPS-EXIF (422 `gps_in_image`) och svarar `{sha256, variant, variantSha256, bytes, width, height}`. |
| `PUT /api/v1/objects/{id}/pool` | `{assets:[{assetId, sha256, width, height, analysis?}]}` (≤ 40). Ersätter hela poolen. |
| `GET /api/v1/objects/{id}` | Objekt, aktuell spec (`store`), pool, länkar, renderingar (med signerade `url`) och jobb. |
| `PUT /api/v1/objects/{id}/spec` | `If-Match: "<rev>"` (obligatorisk; första gången `"0"`). 200 `{objectId, revision, status, changed, spec}` eller 412 med aktuell spec. |
| `POST /api/v1/objects/{id}/links` | `{label?, expiresInDays?}` (standard 30, högst 90) → 201 `{linkId, url, archiveUrl, expiresAt, status}`. Token visas bara här. Kräver en spec (409 `no_spec`). Första länken flyttar `draft → proposed`. |
| `DELETE /api/v1/links/{id}` | Återkallar länken (därefter 410). |
| `POST /api/v1/objects/{id}/approve` | `{revision}` — fotografen godkänner för mäklarens räkning (loggas som `actor=photographer`, syns i `/share` som `approval.by`). |
| `DELETE /api/v1/objects/{id}` | Hård radering. |
| `GET /api/v1/objects?status=&since=` | Lista `{objects:[{objectId, reelId, address, status, currentRevision, approvedRevision, updatedAt, purgeAfter, renderCount}]}`; `since` är ISO-datum (uppdaterade efter). |

## 6. Mäklarens API (`Authorization: Link <token>`)

| Metod och väg | Beskrivning |
|---|---|
| `GET /api/v1/share` | `{object{address,status,currentRevision,approvedRevision,updatedAt}, link{expiresAt,label}, approval{by,at}|null, spec (med url-källor), pool[{assetId,sha256,width,height,analysis,url(w1600),thumbUrl(w480)}], renders[{renderId,revision,outputId,bytes,width,height,duration,createdAt,current,url}]}` + `ETag`. |
| `PUT /api/v1/share/spec` | `If-Match: "<rev>"`. Kropp: hela specen. 200 `{revision,status,changed}`; 412 `revision_conflict` (UI: "Fotografen har ändrat, ladda om"); 422 vid valideringsfel (t.ex. bild utanför poolen, längd utanför 0,5–10 s, ändrade utbildsprofiler). |
| `POST /api/v1/share/approve` | `{revision}` måste vara aktuell revision, annars 409 `revision_mismatch`. Skapar ett renderjobb per `outputs[]`. → `{status, revision, changed, jobs}`. |
| `GET /api/v1/share/renders/{id}` | MP4 med `Range`-stöd, `Content-Disposition: inline; filename="Objektfilm.mp4"` (ingen adress i filnamnet). |

## 7. Renderkön (scope `render`)

| Metod och väg | Beskrivning |
|---|---|
| `POST /api/v1/render-jobs/claim?wait=25` | Long-poll, `wait` 0–25 s (klampas). 200 `{jobId, objectId, reelId, revision, outputId, spec (store), leaseUntil}` eller 204. Uppdaterar `workers.last_seen_at` även vid 204. Lease är 10 min; ett jobb med utgången lease går tillbaka i kön, efter 3 försök blir det `failed`. |
| `POST /api/v1/render-jobs/{id}/heartbeat` | Förlänger leasen till +10 min → `{leaseUntil}`. 409 `superseded` om jobbet ersatts: avbryt renderingen. |
| `PUT /api/v1/render-jobs/{id}/output` | `Content-Type: video/mp4`, ≤ 300 MB, strömmas till disk. Valfria query-parametrar `width`, `height`, `duration` (annars ur specen). 201 `{renderId, status}` där `status` är objektets nya status (`rendered` när alla utbildsprofiler är klara). 409 `superseded` om revisionen inte längre är godkänd (filen kastas). |
| `POST /api/v1/render-jobs/{id}/fail` | `{message}`. Tillbaka i kön, eller `failed` efter 3 försök. → `{status}`. |

## 8. Sidor, media och drift

| Väg | Beskrivning |
|---|---|
| `GET /` | Landningssida (200). |
| `GET /m` | Mäklarredigeraren (token i fragmentet). Utan fragment: lokalt reservläge. |
| `GET /a` | Arkivet (token i fragmentet). |
| `GET /media/{exp}/{sig}/{key}` | HMAC-signerad URL (1 timme). `key` är `img/<sha256>/<w1600|w480>` eller `render/<renderId>`. Fel signatur 403, utgången 410. `Range` stöds (206/416) och `HEAD`. `Cache-Control: private`. |
| `GET /healthz` | 200 med fast kropp `objektfilm ok` och `X-Objektfilm: 1` om databasen svarar, `data/` är skrivbar och minst 5 GB är ledigt, annars 503 `objektfilm fel: <vad>`. |
| `GET /robots.txt` | `Disallow: /`. |
| `GET /metrics` (**separat port**, standard 9471) | Prometheus: `objektfilm_render_queue_oldest_seconds`, `objektfilm_worker_last_seen_seconds`, `objektfilm_invalid_auth_total`, `objektfilm_uploads_bytes_total`, `objektfilm_objects{status}`, `objektfilm_purge_overdue`, `objektfilm_render_jobs_failed`, `objektfilm_rate_limited_total`, `objektfilm_http_requests_total{route,status}`. |
