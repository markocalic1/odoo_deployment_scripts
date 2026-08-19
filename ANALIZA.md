# Analiza repozitorija: odoo_deployment_scripts

> Interni dokument za onoga tko će održavati ovaj sustav. Fokus je na **stvarnom ponašanju
> skripti** (pročitanih redom, ne samo na README-u), pretpostavkama o serveru i mjestima
> gdje se lako može nešto pokvariti.

---

## 1. Što ovaj alat radi

Ovo je skup bash skripti za instalaciju, deploy, backup/restore i uklanjanje Odoo instanci
na **golom Linux serveru (Ubuntu), bez Dockera**. Sve radi preko:

- **systemd** servisa (jedan po instanci Odoo-a),
- **PostgreSQL-a** instaliranog lokalno na istom serveru,
- **Python virtualenv-a** po instanci (`$OE_HOME/venv`),
- **git repozitorija** za custom module (`$OE_HOME/src`) i sam Odoo core (`$OE_HOME/odoo`),
- `.env` datoteka u `/etc/odoo_deploy/` koje opisuju svaku instancu.

Tipičan scenarij: jedan server hosta više neovisnih Odoo instanci (npr. `prod19`,
`staging19`, `odoo20-test`), svaka sa svojim Linux userom, portom, servisom i bazom.
Nema kontejnerizacije, nema Docker mreža, nema orkestracije — sve je "flat" na razini OS-a.

Ulazna točka za svakodnevni rad je **`odooctl.sh`** (`odoo_deployment_scripts/odooctl.sh`),
koji je tanka omotnica (dispatcher) oko svih ostalih skripti.

---

## 2. Popis skripti i njihova uloga

| Skripta | Uloga | Pokreće se |
|---|---|---|
| `odooctl.sh` | Unificirani CLI, samo prosljeđuje na ostale skripte | ručno / CI |
| `odoo_install.sh` | Interaktivna puna instalacija jedne Odoo instance | jednom po instanci |
| `deploy_odoo.sh` | "Zero-downtime" deploy: backup → git reset → pip install → restart → health check → rollback | CI/CD, `odooctl deploy` |
| `odoo-git-update.sh` | Sličan deploy, ali s `git pull` + stash umjesto `reset --hard`, plus opcionalni module update | `odooctl git-update` |
| `odoo-update-modules.sh` | Samo `-u module1,module2 --stop-after-init` na lokalnoj bazi | `odooctl modules` |
| `odoo-sync.sh` | Prod → staging sync (DB + filestore), preko SSH-a na prod | `odoo-backup-restore.sh`, `odooctl backup-restore` |
| `odoo-backup-restore.sh` | Tanka omotnica oko `odoo-sync.sh` s minimalnim argumentima (čita `/etc/odoo_deploy/prod<N>.env` i `staging<N>.env`) | `odooctl backup-restore` |
| `odoo-sync-env-create.sh` | Generira `prod<N>.env` / `staging<N>.env` iz postojećih instance env-ova | `odooctl backup-restore-env` |
| `odoo-neutralize.sh` | Pokreće Odoo CLI `neutralize` (onemogući cron/mail/webhookove) + opcionalno postavi `web.base.url` | `odooctl neutralize`, poziva ga i `odoo-sync.sh` |
| `odoo-remove-instance.sh` | Uklanjanje instance (servis, config, env, opcionalno DB/home/user) | `odooctl remove` |
| `odoo-shell.sh` | Otvara `odoo-bin shell` uz auto-detekciju servisa/configa | `odooctl shell` |
| `odoo-venv.sh` | Samo `source /opt/odoo/venv/bin/activate` (hardkodiran path!) | `odooctl venv` |
| `odoo_deploy_mini.sh` | Minimalni deploy bez backupa/rollbacka, sve hardkodirano (`/opt/odoo`) | `odooctl mini-deploy` |
| `install_ngnix_ssl.sh` | Nginx reverse proxy + Let's Encrypt + UFW firewall | jednom po domeni |
| `cloudflare_dns.sh` | Kreira Cloudflare A-record za domenu | poziva ga nginx skripta ili ručno |
| `ssh_key_create.sh` | Generira SSH deploy key (ed25519/RSA) za GitHub Actions | jednom |
| `odooctl-link.sh` | Simlinka `odooctl.sh` u `/usr/local/bin/odooctl` | jednom |
| `odooctl-completion.bash` | Bash autocomplete (čita imena instanci iz `/etc/odoo_deploy/*.env`) | source u `~/.bashrc` |
| `docs.html` | Statični HTML mirror README-a | — |

---

## 3. Kako se koristi — sve naredbe s primjerima

Sve `odooctl` naredbe koje mijenjaju sustav (deploy, git-update, modules, remove,
backup-restore, backup-restore-env, neutralize, mini-deploy) automatski se pokreću preko
`sudo` ako trenutni user nije root (`run_root()` u `odooctl.sh:144-150`).

### 3.1 Instalacija nove instance
```bash
sudo bash odoo_install.sh
```
Interaktivno pita za: Linux usera, install dir, git repo custom modula, granu, PostgreSQL
usera, Odoo verziju, ime config datoteke, ime systemd servisa, port, naziv instance i
default ime baze. Na kraju kreira:
- `/etc/<conf_name>` (Odoo config),
- `/etc/odoo_deploy/<instance>.env` (deploy config),
- `/etc/systemd/system/<service>.service`,
- `/etc/logrotate.d/<service>`.

### 3.2 Deploy (safe, s rollbackom)
```bash
odooctl deploy staging19
odooctl deploy prod19 --verbose
odooctl deploy prod19 --no-db-backup   # preskoči DB backup (brže, rizičnije)
```
Radi: backup DB-a (pg_dump ili Odoo HTTP endpoint) → backup koda (tar.gz) → `git fetch` +
`git reset --hard origin/<BRANCH>` → `pip install -r requirements.txt` → `systemctl restart`
→ health check na `/web/login` → auto-rollback na prethodni commit ako bilo koji korak
padne.

### 3.3 Git update (blaži od deploya, s stashem)
```bash
odooctl git-update staging19
odooctl git-update staging19 update -all
odooctl git-update staging19 update sale,stock,account
odooctl git-update staging19 --verbose
```
Radi: DB backup → auto-stash lokalnih izmjena → `git fetch` → provjeri ima li razlike
prema `origin/<BRANCH>` (ako nema, izlazi bez daljnjih koraka) → `git pull` → `stash pop`
→ pip install (samo ako se `requirements.txt` promijenio) → `py_compile` sintaktička
provjera svih `.py` datoteka → opcionalni module update (`-u all` ili lista modula, uz
stop/start servisa) → restart servisa.

### 3.4 Update modula bez deploya
```bash
odooctl modules staging19 sale,stock,account
```
Stopira servis → `odoo-bin -u sale,stock,account --stop-after-init` → pokreće servis.

### 3.5 Backup/restore (prod → staging)
```bash
# priprema env datoteka (jednom)
sudo bash odoo-sync-env-create.sh 19 --with-sync-env

# uredi /etc/odoo_deploy/odoo-sync.env (PROD_HOST, master password, metode)

# svakodnevna sinkronizacija
odooctl backup-restore 19
```
Ili direktno, s punom kontrolom:
```bash
sudo bash odoo-sync.sh \
  --prod-env /etc/odoo_deploy/prod19.env \
  --staging-env /etc/odoo_deploy/staging19.env \
  --prod-host 23.88.117.155 \
  --prod-ssh root \
  --backup-method odoo \
  --method odoo \
  --drop-method auto \
  --neutralize
```

### 3.6 Neutralizacija (nakon restorea, ručno)
```bash
odooctl neutralize staging19
```
Zaustavlja Odoo, pokreće `odoo-bin neutralize -c <config> -d <db>` (ugrađeni Odoo CLI koji
gasi cron/mail/webhookove), opcionalno upisuje `web.base.url` preko `psql`, pokreće Odoo.

### 3.7 Uklanjanje instance
```bash
odooctl remove staging19 --dry-run
odooctl remove staging19 --drop-db --delete-home --yes
```
Bez ijedne destruktivne zastavice briše samo servis/config/env. `--dry-run` samo ispisuje
naredbe. Bez `--yes` traži da se upiše točno ime instance kao potvrda.

### 3.8 Ostalo
```bash
odooctl shell                 # auto-detektira servis i otvara odoo-bin shell
odooctl venv                  # source /opt/odoo/venv/bin/activate (hardkodiran path)
odooctl mini-deploy           # git pull + pip install + restart, bez backupa/rollbacka
odooctl describe deploy       # objašnjava koje env varijable naredba koristi
odooctl --help
```

### 3.9 Nginx + SSL + DNS (jednom po domeni)
```bash
bash install_ngnix_ssl.sh
```
Auto-detektira Odoo servis/config/port, pita za domenu, opcionalno kreira Cloudflare
DNS A-record (`cloudflare_dns.sh domain.com`), izdaje Let's Encrypt certifikat, piše nginx
config s upstreamom za HTTP i websocket, otvara UFW portove 22/80/443.

### 3.10 SSH ključ za CI/CD
```bash
bash ssh_key_create.sh
```
Generira `~/.ssh/id_ed25519[.pub]`, javni ključ ide u GitHub Deploy Keys, privatni u
GitHub Actions secret `SSH_PRIVATE_KEY` (koristi se u `.github/workflows/deploy.yml`
primjeru iz README-a).

---

## 4. Gdje se drži konfiguracija

**Sve instance-specifične konfiguracije su u `/etc/odoo_deploy/<naziv>.env`.** To je
jedini "izvor istine" koji sve skripte čitaju preko `source`. Primjer
(`example staging19.env`):

```bash
INSTANCE_NAME="staging19"
OE_USER="odoo"
OE_HOME="/opt/odoo"
SERVICE_NAME="odoo"
BRANCH="19.0-staging"
DB_NAME="staging19"
DB_USER="odoo"
DB_HOST="localhost"
DB_PORT="5432"
ODOO_PORT="8069"
STAGING_BASE_URL="https://staging.example.com"
```

Dodatne varijable koje pojedine skripte prepoznaju (nisu sve dokumentirane na jednom
mjestu — treba paziti pri izmjenama):

| Varijabla | Koristi je | Svrha |
|---|---|---|
| `REPO_DIR` | deploy, git-update | ako custom repo nije u `$OE_HOME/src` |
| `FIX_REPO_PERMS` | deploy, git-update | auto-chown repoa na `OE_USER` ako nije writable (default `true`) |
| `BACKUP_METHOD` | deploy, git-update, odoo-sync | `pg` \| `odoo` \| `auto` |
| `DB_PASSWORD` / `DB_PASS` | deploy, git-update, neutralize | lozinka za `pg_dump`/`psql` ako nije peer-auth |
| `MASTER_PASS` / `ODOO_MASTER_PASS` | deploy, git-update, odoo-sync | Odoo master password za HTTP backup/restore/drop |
| `PROD_ODOO_PORT`, `STAGING_ODOO_PORT` | odoo-sync | portovi za HTTP backup/restore (default 8069) |

**Odoo config datoteka** (`/etc/<conf_name>`, npr. `/etc/odoo.conf`) je odvojena od
`.env`-a. Skripte je **ne čitaju direktno po imenu** — nalaze je tako da parsiraju
`ExecStart=` liniju iz `/etc/systemd/system/<service>.service` (ili
`/lib/systemd/system/...`, `/usr/lib/systemd/system/...`) tražeći `-c`/`--config` flag
(funkcija `detect_odoo_config()`, duplicirana u minimalno 6 skripti). Iz te datoteke se
onda čitaju `db_user`, `db_host`, `db_port`, `db_password`, `http_port` kao fallback ako
`.env` ne specificira te vrijednosti.

**Dodatne konfiguracijske datoteke izvan `/etc/odoo_deploy/`:**
- `/etc/odoo_deploy/odoo-sync.env` — globalni defaulti za sync (master passwordi, metode)
- `/etc/cloudflare/api_token` (chmod 600) — Cloudflare API token, plaintext
- `/etc/logrotate.d/<service>` — log rotacija (14 dana, copytruncate)

---

## 5. Kako radi backup i restore (detaljno)

### 5.1 Backup unutar deploya (`deploy_odoo.sh`, `odoo-git-update.sh`)
Prije svake promjene koda radi se **lokalni** backup baze i koda, ne šalje se nikamo:
- baza: `pg_dump -F c -b -f $OE_HOME/backups/<instance>/<timestamp>/<db>.dump`
  (ili Odoo HTTP `/web/database/backup` endpoint ako je `BACKUP_METHOD=odoo`),
- kod: `tar czf code.tar.gz` nad `$OE_HOME/odoo` + `$OE_HOME/src` (ili `$REPO_DIR`).

Ovaj backup **nije automatski iskorišten za restore** ako deploy padne — deploy skripta
radi rollback samo git commita i restarta servisa; DB backup ostaje na disku kao
sigurnosna kopija koju admin ručno vraća ako zatreba (`pg_restore`). Nema retencije/čišćenja
— direktoriji `$OE_HOME/backups/<instance>/<timestamp>/` se gomilaju zauvijek.

Redoslijed pokušaja DB backupa (auto mode): `pg_dump` kao trenutni user s lozinkom iz env-a
→ `pg_dump` kao `$OE_USER`/Odoo config user → interaktivni prompt za lozinku → Odoo HTTP
backup kao zadnja opcija.

### 5.2 Prod → staging sync (`odoo-sync.sh`)
Ovo je jedini mehanizam koji **prenosi podatke preko mreže** (SSH), i pokreće se **na
staging serveru** (ne na produ):

1. **Backup na produkciji** (preko SSH-a, komanda se sastavlja kao string i šalje
   `ssh "$PROD_SSH" "..."`):
   - `pg` metoda: `pg_dump -Fc` + `tar czf` filestore direktorija na prod serveru,
   - `odoo` metoda: poziva `POST /web/database/backup` na `127.0.0.1:<PROD_ODOO_PORT>`
     **na samom prod serveru** (dakle Odoo mora imati taj endpoint dostupan lokalno).
2. **Download** preko `scp` s prod servera na staging (`.dump` + `_filestore.tar.gz`,
   ili `.zip` kod Odoo metode).
3. **Drop postojeće staging baze**: `odoo` (preko `/web/database/drop` endpointa),
   `pg` (`pg_terminate_backend` + `dropdb`), ili `auto` (prvo Odoo pa fallback na pg).
4. **Restore**: `pg_restore` ili `POST /web/database/restore` (`copy=true`).
5. **Filestore restore** (samo kod pg metode): briše `$STAGING_FS/$STAGING_DB`, raspakira
   tar, preimenuje direktorij ako se ime baze razlikuje od prod imena, `chown -R odoo:odoo`.
6. **Opcionalna neutralizacija** (`RUN_NEUTRALIZE=true`): zaustavi Odoo → `odoo-bin
   neutralize` → upiši `STAGING_BASE_URL` u `ir_config_parameter` → pokreni Odoo.
7. **Start Odoo servisa** na staging.

### 5.3 Neutralizacija (`odoo-neutralize.sh`)
Koristi ugrađenu Odoo CLI naredbu `neutralize` (ne custom SQL) — ona onemogućava
odlazeće mailove, cron poslove i webhookove nakon što se prod baza kopira na staging.
Skripta dodatno (opcionalno) upisuje `web.base.url` preko `psql`, pokušavajući prvo s
kredencijalima iz env-a, pa fallback na `sudo -u postgres psql`.

---

## 6. Pretpostavke o serveru

- **OS**: Ubuntu 20.04/22.04/24.04, `apt`-based. Nema podrške za RHEL/CentOS/Debian
  varijacije paketa.
- **Bez Dockera, bez kontejnerskih mreža** — sve je bare-metal/VM proces preko systemd.
  Nema pojma o Docker networks/compose; ako se ikad doda kontejnerizacija, cijeli sustav
  detekcije (`detect_odoo_config` preko systemd unit datoteka) treba redizajnirati.
- **Jedan PostgreSQL server po hostu**, `localhost:5432` po defaultu, više baza
  (jedna po instanci) na istom clusteru. `db_host`/`db_port` konfigurabilni ali svugdje
  se defaultira na lokalni.
- **PostgreSQL autentikacija**: instalacijska skripta radi
  `createuser -s $PG_USER` — **Odoo-ov PG user dobiva `SUPERUSER`** rolu (vidi §7).
  Zbog toga velik dio pg_dump/psql poziva radi bez lozinke (peer/trust auth), a lozinka je
  fallback opcija.
- **Standardni direktorijski layout** po instanci ispod `$OE_HOME` (obično `/opt/<user>`
  ili `/opt/odoo`):
  - `$OE_HOME/odoo` — Odoo core git repo
  - `$OE_HOME/src` — custom moduli git repo (ili `$REPO_DIR` ako je drukčije)
  - `$OE_HOME/venv` — Python virtualenv
  - `$OE_HOME/log` — logovi
  - `$OE_HOME/backups/<instance>/<timestamp>` — lokalni backupi
  - `$OE_HOME/.local/share/Odoo/filestore/<db>` — Odoo filestore (koristi se kao default
    i za prod i za staging u `odoo-sync.sh`)
- **Portovi**: `8069` (HTTP) i `8072` (longpolling/gevent websocket) su defaulti posvuda
  gdje port nije eksplicitno konfiguriran. Nginx skripta traži `gevent_port` pa
  `longpolling_port` u configu.
- **Jedan systemd servis po instanci**, ime servisa = ključ preko kojeg se sve ostalo
  (config path, DB kredencijali, port) auto-detektira parsiranjem `ExecStart=`.
- **Firewall**: `install_ngnix_ssl.sh` instalira i **prisilno uključuje UFW**
  (`ufw --force enable`) — mijenja mrežnu sigurnost hosta bez potvrde, otvarajući samo
  22/80/443 (i opcionalno Odoo/websocket port).
- **DNS/SSL**: pretpostavlja Cloudflare kao DNS provajdera (opcionalno) i Let's Encrypt
  preko `certbot --nginx`, znači domena mora javno rezolvirati na server prije izdavanja
  certifikata.
- **CI/CD**: GitHub Actions primjer u README-u pretpostavlja push na grane `19.0-staging`
  i `19.0`, SSH pristup do servera i da su `deploy_odoo.sh` te `.env` datoteke već na
  serveru (skripta se poziva s apsolutnim putem `/opt/odoo/deploy_odoo.sh`).

---

## 7. Slabe točke i rizici

Poredano približno po ozbiljnosti za produkcijsku upotrebu:

1. **PostgreSQL superuser rola za Odoo usera** (`odoo_install.sh:123`,
   `sudo -u postgres createuser -s $PG_USER`). Odoo-ov DB user može čitati/brisati
   **bilo koju** bazu na tom PostgreSQL clusteru, uključujući baze drugih instanci na
   istom hostu. Ako se Odoo ikad kompromitira (npr. preko ranjivog modula), napadač ima
   pun pristup svim bazama na serveru, ne samo svojoj. Preporuka: dati ownera samo nad
   vlastitom bazom, ne `SUPERUSER`.

2. **Slomljena detekcija porta u `deploy_odoo.sh:446` i `odoo-git-update.sh:194`.**
   Sed izraz koristi doubleslash `\\([0-9]\\+\\)` unutar single-quoted stringa — to
   sed-u šalje literalni `\(` umjesto grupe za capture, pa regex **nikad ne pogađa**
   `http_port = 8069` u configu. Ispada da `CONF_PORT` uvijek ostaje prazan i skripta
   tiho pada na hardkodirani default `8069`. Ako neka instanca stvarno koristi drugi
   port i `ODOO_PORT` nije eksplicitno postavljen u `.env`, health-check i deploy pucaju
   na krivi port bez jasne poruke o uzroku. Usporedi s ispravnom verzijom u
   `install_ngnix_ssl.sh:60` (`\([0-9]\+\)`, jedan backslash) — treba popraviti prve dvije
   skripte da odgovaraju.

3. **Command injection preko interpolacije u SSH stringovima** (`odoo-sync.sh`,
   `perform_pg_backup()` i `perform_odoo_backup()`). `PROD_DB`, `PROD_BACKUP_DIR`,
   `PROD_FS`, `PROD_DB_USER` itd. se ubacuju direktno u string koji se šalje `ssh
   "$PROD_SSH" "..."` uz samo pojedinačne navodnike oko vrijednosti. Ako bilo koja od tih
   vrijednosti (npr. ime baze iz `.env` datoteke koju je netko uredio) sadrži `'` ili
   shell metaznakove, moguće je izvršavanje proizvoljnih naredbi na produkcijskom
   serveru preko SSH-a. Rizik je nizak dok `.env` datoteke uređuju samo povjerljivi
   administratori, ali je arhitekturno krhko — nema sanitizacije unosa nigdje u pipelineu.

4. **Hardkodirani `odoo:odoo` umjesto `$OE_USER`/`$OE_HOME`** u više mjesta:
   - `odoo-sync.sh:384` — `chown -R odoo:odoo "$STAGING_FS/$STAGING_DB"` ignorira
     stvarni `OE_USER` iz `staging<N>.env` ako je drukčiji od `odoo`.
   - `odoo-venv.sh` i `odoo_deploy_mini.sh` imaju **potpuno hardkodiran** `/opt/odoo` i
     ne čitaju `/etc/odoo_deploy/*.env` uopće — rade samo ako se instanca zove baš tako.
   Ovo je u suprotnosti s inače "instance-agnostic" dizajnom ostatka sustava i lako
   zavede novog admina koji drugačije imenuje instance.

5. **Rollback ne obuhvaća bazu.** `deploy_odoo.sh` i `odoo-git-update.sh` rade DB backup
   prije promjena, ali ako health-check ili module-update padne, rollback vraća samo git
   commit i restart servisa — **baza se ne vraća automatski** iz `.dump` datoteke. Ako je
   `-u all`/module update već zapisao shemu promjene prije pada, kod i baza mogu ostati
   nesinkronizirani dok admin ručno ne pokrene `pg_restore`.

6. **Health check je slab.** `curl -s "$HEALTH_URL" | grep -qi "odoo"` (deploy_odoo.sh:460)
   prolazi čim stranica sadrži riječ "odoo" bilo gdje (title, meta tag), bez provjere HTTP
   statusa. Custom error stranica koja i dalje sadrži riječ "Odoo" u naslovu (npr. 500
   error page brandirana kao Odoo) prošla bi kao "healthy" i deploy bi se proglasio
   uspješnim iako je aplikacija zapravo srušena.

7. **Nema retencije backupova.** Direktoriji ispod `$OE_HOME/backups/<instance>/` rastu
   bez granice — svaki deploy/git-update ostavlja novi timestamp direktorij zauvijek.
   Nema cron/logrotate mehanizma za brisanje starih backupova → rizik popunjavanja diska
   na produkciji tijekom vremena.

8. **Tajne u plaintext `.env` datotekama** (`DB_PASSWORD`, `MASTER_PASS`,
   `ODOO_MASTER_PASS`) uz `chmod 640` i Cloudflare token u `/etc/cloudflare/api_token`
   (chmod 600). Prihvatljivo za root-only pristup, ali nema enkripcije/vaulta — svatko s
   root pristupom (ili s pristupom backupu tog servera) vidi sve lozinke u čistom tekstu.

9. **`wkhtmltopdf` se instalira bez provjere integriteta** (`odoo_install.sh:181-184`):
   `wget` .deb paket s GitHub Releasesa i odmah `apt install -y ./wkhtml.deb`, bez
   provjere checksuma/potpisa. Supply-chain rizik ako GitHub release ikad bude
   kompromitiran ili ako se URL promijeni (verzija je hardkodirana na `0.12.6.1-2`).

10. **UFW se uključuje bez potvrde** (`install_ngnix_ssl.sh:321`,
    `ufw --force enable`) usred inače interaktivnog installera — mijenja stanje
    firewalla na produkcijskom serveru bez eksplicitnog "jeste li sigurni" koraka (iako
    su bar SSH/HTTP/HTTPS portovi otvoreni prije toga).

11. **Značajna duplikacija koda.** Funkcije `detect_odoo_config()`,
    `read_odoo_conf_value()`, `do_pg_dump()`/`do_odoo_backup()` i slične kopirane su
    gotovo identično u `deploy_odoo.sh`, `odoo-git-update.sh`, `odoo-update-modules.sh`,
    `odoo-remove-instance.sh`, `odoo-shell.sh`, `odoo-neutralize.sh`. Bug-fix u jednoj
    kopiji (kao onaj iz točke 2) neće se automatski primijeniti na ostale — svaki popravak
    treba ručno ponoviti na svim mjestima ili refaktorirati u zajedničku shared/lib
    datoteku koju bi sve skripte source-ale.

12. **`eval` u `odoo-remove-instance.sh:113`** (`run_cmd()` koristi `eval "$@"`).
    Sigurno je dokle god ulazi dolaze iz `.env` datoteka pod kontrolom admina, ali je
    generalno krhak pattern — bilo kakav poseban znak u `OE_HOME`/`DB_NAME` mijenja
    ponašanje naredbe koja se stvarno izvršava.

13. **Nema provjere da staging i prod nisu isti host/baza** u `odoo-sync.sh` prije
    drop/restore koraka. Ako se `--staging-env`/`--prod-env` slučajno zamijene ili
    `staging<N>.env` slučajno pokazuje na produkcijsku bazu, skripta bez dodatne potvrde
    briše i prepisuje tu bazu (`dropdb`/`/web/database/drop` izvršavaju se odmah nakon
    prompta za lozinku, bez "type instance name to confirm" kao u `odoo-remove-instance.sh`).

14. **`odoo_install.sh` je čisto interaktivan** (niz `read -p` poziva) — nema
    non-interaktivnog/flag-baziranog moda, pa se ne može lako pozvati iz automatizacije
    (npr. Ansible/Terraform provisioning) bez `expect`-a ili sličnog hacka.

15. **Nekonzistentno rukovanje greškama.** Skripte kombiniraju `set -e` s brojnim
    `|| true` fallbacima (npr. `systemctl disable --now ... || true`,
    `git config ... || true`) što ponekad tiho guta greške koje bi bilo korisno vidjeti,
    dok na drugim mjestima (npr. `run_cmd` u remove skripti) `eval` može propagirati
    greške na neočekivan način.

---

## 8. Preporuke za održavanje (kratko)

- Prije bilo kakve izmjene u `detect_odoo_config`/`read_odoo_conf_value` logici, primijeni
  je na **svih 6 kopija** ili prvo izdvoji u `lib/common.sh` koji se source-a.
- Popravi sed bug iz točke 2 (koristi jedan backslash, kao u `install_ngnix_ssl.sh`).
- Razmisli o cron jobu za čišćenje starih direktorija u `$OE_HOME/backups/*`.
- Prije produkcijske upotrebe `odoo-sync.sh`, razmotri dodavanje eksplicitne potvrde
  (ispis prod/staging hosta i baze + "type YES to continue") prije drop/restore koraka.
- Ako se ikad doda drugi PostgreSQL user model, ukloni `-s` (superuser) iz
  `createuser` poziva i umjesto toga dodijeli ownership samo nad vlastitom bazom.
