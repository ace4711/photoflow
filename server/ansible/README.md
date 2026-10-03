# Driftsättning av Objektfilm-servern (server3)

Steg B1 (förberedelse) i `docs/plan-objektfilm-backend.md`. Inget av detta har körts skarpt än: B2 körs av Fredrik.

## Filer

| Fil | Vad |
|---|---|
| `inventory.yml` | Eget inventarie: `server3` = 10.0.0.37, användare `fredrike`. Eget (inte EriksvikSites) så att repot går att driftsätta utan EriksvikSite utcheckat |
| `ansible.cfg` | Gäller när du står i `server/ansible/` |
| `deploy.yml` | Driftsättning (B2) |
| `firewall-tasks.yml`, `objektfilm-firewall.sh.j2`, `objektfilm-firewall.service` | Valfri `DOCKER-USER`-regel, **av som standard** |
| `backup.yml`, `backup-recipient.txt` | Databasbackup, age-krypterad, **ej körd**. `backup-recipient.txt` är den publika nyckeln |
| `../.sops.yaml`, `../secrets/film.sops.env` | sops+age. Mottagare: samma age-nyckel som AssetCores `secrets/*.sops.env`, så Macens befintliga nyckel dekrypterar |

Ansible körs med EriksvikSites venv (ansible-core 2.17, `ansible.posix` ingår i paketet `ansible`). Förkortning: `A=/Users/fredrik/Developer/EriksvikSite/ansible/.venv/bin/ansible-playbook`.

## B2: kommandon

```sh
cd /Users/fredrik/Developer/photo-preprocesser/server/ansible
A=/Users/fredrik/Developer/EriksvikSite/ansible/.venv/bin/ansible-playbook
$A deploy.yml --check --diff      # valfritt, ändrar inget (compose, symlänkar och healthz hoppas över i check-läge)
$A deploy.yml                     # skarp
```

Den skarpa körningen gör, i ordning:
1. Kontrollerar att `film.sops.env` och `docker compose` finns.
2. Skapar `~/objektfilm`, `~/objektfilm/src` (0750) och `~/objektfilm/data` (ägare 10470:10470, via sudo).
3. rsync av `server/` och `web/reel/` (utan `node_modules`, `dist`, `data`, `.env`, `secrets`, `ansible`) och `.dockerignore` till `~/objektfilm/src`.
4. `sops -d` **lokalt på Macen** och skriver `~/objektfilm/.env` (0600). Den privata age-nyckeln lämnar aldrig Macen. Utskrift av .env är avstängd (`no_log`).
5. Symlänkar `src/server/.env -> ../../.env` och `src/server/data -> ../../data` (compose.yaml läser `env_file` och `./data` relativt sig själv).
6. `docker compose -f compose.yaml config --quiet`, därefter `docker compose -f compose.yaml up -d --build` i `~/objektfilm/src/server`. Compose återskapar containern om image eller konfiguration (inklusive `.env`) ändrats. Portar binds till `10.0.0.37:8470` och `10.0.0.37:9471`.
7. Väntar (högst 90 s) på `http://10.0.0.37:8470/healthz` med status 200, kroppen `objektfilm ok` och headern `X-Objektfilm: 1`. Anropet görs från server3 själv, så det fungerar även med brandväggen på.

Därefter: skapa nycklar (visas en gång):
```sh
ssh fredrike@10.0.0.37 'cd ~/objektfilm/src/server && docker compose exec app node src/cli.ts create-key --name "Fredrik" --scope photographer --label "Macen"'
# och en med --scope render --label "Renderworker"
```

### Brandvägg (valfri, separat steg)
Docker kringgår ufw, och `DOCKER-USER` är tom på server3. `-e objektfilm_firewall=true` lägger kedjan `OBJEKTFILM-IN` (släpper bara in 10.0.0.5 cheetah, 10.0.0.37 värden själv och 10.0.0.153 Macen till 8470; allt annat DROP) och en hopp-regel i `DOCKER-USER`, via en systemd-unit (`After=docker.service`) som läggs upp igen vid varje boot. AssetCores regler och Dockers egna kedjor rörs inte, och inget extra paket (iptables-persistent) behövs.

Valet av källor: hela 10.0.0.0/22 hade gjort regeln meningslös (cheetah ligger i den). Macens LAN-IP kommer från DHCP, så ändra `objektfilm_allowed_sources` i `deploy.yml` om den byts. Mac via Tailscale går via cheetahs RP och påverkas inte. **Varning:** fel lista låser ute RP:n. Ta bort regeln med `ssh fredrike@10.0.0.37 sudo /usr/local/sbin/objektfilm-firewall.sh remove`. Port 9471 (mätvärden) omfattas inte. Rekommendation: kör B2 först utan brandvägg, testa, slå på den efteråt (`$A deploy.yml -e objektfilm_firewall=true`).

### Backup
`$A backup.yml` gör `node src/cli.ts backup` i containern, age-krypterar till mottagaren i `backup-recipient.txt` på värden, raderar klartexten, `scp -O` till `cheetah:/volume1/backups/objektfilm/` (två SSH-anslutningar, DSM Auto Block) och gallrar efter 30 dagar. Den privata identiteten `objektfilm-backup` ligger **inte** i repot eller på server3: den ligger på Macen i `~/.config/objektfilm/objektfilm-backup.agekey` (0600) och ska flyttas till lösenordshanteraren. Återställning: `age -d -i <identitet> objektfilm-….db.age > x.db`, sedan `node src/cli.ts verify-backup` / `restore`.

## Rulla tillbaka

```sh
ssh fredrike@10.0.0.37 'cd ~/objektfilm/src/server && docker compose -f compose.yaml down'
ssh fredrike@10.0.0.37 'sudo /usr/local/sbin/objektfilm-firewall.sh remove; sudo systemctl disable --now objektfilm-firewall.service; sudo rm -f /usr/local/sbin/objektfilm-firewall.sh /etc/systemd/system/objektfilm-firewall.service'  # bara om brandväggen lades
ssh fredrike@10.0.0.37 'sudo rm -rf ~/objektfilm'   # RADERAR DATABASEN. Ta backup först. Sudo behövs: data ägs av uid 10470
ssh fredrike@10.0.0.37 'docker image rm objektfilm-app:local'
```
Inget annat på värden (AssetCore, promtail-system) berörs.

## Kvar efter B2 (EriksvikSite, se planens avsnitt 2 och 7)

- **B3** `ansible/vars/vhosts.yml` (film.eriksvik.site till 10.0.0.37:8470), `pihole_hosts.yml`, `godaddy_omit_fqdns`. `deploy-entrypoints.yml` startar om DSM nginx och kräver Fredriks OK.
- **B4** Prometheus-skrapmål (10.0.0.37:9471), telegraf-probelista, heartbeat-watchdogens EXPECT-lista.
- **B5** Rundeck-jobb: backup (`backup.yml`), heartbeat och veckovis återställningsbevis. Dokumentation: `hosts/server3.md`, `network/entrypoints.md`, `services/what-runs-where.md`, ny `runbooks/objektfilm.md`.
- **C1-C2** Publikt: ta bort namnet ur `godaddy_omit_fqdns` och kör `deploy-godaddy-dns.yml` (`--check` först), verifiera med `dig`.
