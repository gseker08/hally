# Production deployment and store builds

## 1. API server

`deploy/docker-compose.prod.yml` runs everything on one Linux server with Docker:

| Service | What it does |
|---|---|
| `caddy` | The only public service (ports 80/443). Gets and renews the HTTPS certificates for `API_DOMAIN` and `SITE_DOMAIN` automatically, forwards `API_DOMAIN` to the API and serves the `site/` pages (privacy policy, KVKK, account deletion) on `SITE_DOMAIN`. Blocks `/api/v1/admin/*` from the internet. |
| `api` | The .NET API, `ASPNETCORE_ENVIRONMENT=Production`, dev sign-in off, migrations on start. |
| `postgres` | PostgreSQL 16, data in the `pgdata` volume. No published port. |
| `backup` | `pg_dump` once a day into the `backups` volume, keeps `BACKUP_KEEP_DAYS` (30) days. |

A small VPS is enough to start (2 vCPU, 4 GB RAM, for example Hetzner CX22 in Germany, about €5/month).
EU hosting keeps the data close to Türkiye and under GDPR.

### First start

1. Server: Ubuntu 24.04, then install Docker: `curl -fsSL https://get.docker.com | sh`.
2. Domain: create `A` records for the API (e.g. `api.example.com`) and the web pages (e.g. `hally.example.com`, `SITE_DOMAIN`) pointing at the server's IP. Wait until `ping api.example.com` shows that IP.
3. Firewall: allow only 22, 80, 443 (`ufw allow OpenSSH && ufw allow 80 && ufw allow 443 && ufw enable`).
4. Code and settings:
   ```bash
   git clone https://github.com/gseker08/hally.git && cd hally/deploy
   cp .env.prod.example .env && nano .env      # fill in; random values: openssl rand -base64 48
   docker compose -f docker-compose.prod.yml up -d --build
   ```
5. Check: `curl https://api.example.com/health/ready` returns `Healthy`.

Keep a copy of `deploy/.env` somewhere safe (a password manager). `STORAGE_ENCRYPTION_KEY` in particular: stored photos
cannot be decrypted without it.

### Updating

```bash
cd hally && git pull && cd deploy && docker compose -f docker-compose.prod.yml up -d --build
```

### Backups

- List: `docker compose -f docker-compose.prod.yml exec backup ls -lh /backups`
- Copy one to your computer: `scp root@SERVER:/var/lib/docker/volumes/hally_backups/_data/hally-2026-12-01.sql.gz .`
- Restore (into an empty database): `gunzip -c hally-….sql.gz | docker compose -f docker-compose.prod.yml exec -T postgres psql -U hally -d hally`
- Copy backups off the server regularly (or enable the hosting provider's snapshots): a backup on the same disk is lost with the server.
  Photos live in the `hally_documents` volume; provider snapshots cover them too.

### Logs and metrics

- `docker compose -f docker-compose.prod.yml logs -f api`
- Metrics are blocked at Caddy. From the server:
  `docker compose -f docker-compose.prod.yml exec caddy wget -qO- --header "X-Admin-Key: <ADMIN_API_KEY>" http://api:8080/api/v1/admin/metrics`

## 2. Store builds

Store builds read their settings from `mobile/release.json` (git-ignored). Copy `mobile/release.example.json` and fill in
`HALLY_API_URL` (`https://` + `API_DOMAIN`) and the Google client ids. Release builds never show the developer sign-in,
even without `HALLY_DEV_SIGN_IN=false`.

### Android (Play Console)

1. Upload key, once (keep the file and passwords safe; losing them means asking Google to reset the key):
   ```
   keytool -genkey -v -keystore C:\src\keys\hally-upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
   ```
2. `mobile/android/key.properties` (git-ignored):
   ```
   storeFile=C:\\src\\keys\\hally-upload.jks
   storePassword=...
   keyAlias=upload
   keyPassword=...
   ```
3. Build: `cd mobile && flutter build appbundle --release --dart-define-from-file=release.json`
   → `build/app/outputs/bundle/release/app-release.aab`
4. Raise `version:` in `pubspec.yaml` (the number after `+` must grow with every upload).

### iOS

Needs an Apple Developer account and a Mac or a cloud build service (Codemagic). See `docs/mobile/ios.md`.

## 3. Store listing checklist

- Privacy policy URL: `site/gizlilik.html` on GitHub Pages (`site/README.md`). Same URL in `PRIVACY_POLICY_URL`.
- Play → Data safety: collected = name, email, user IDs, photos, messages, health info (child trackers), app interactions,
  crash logs (if Sentry); encrypted in transit; users can request deletion; deletion URL = `site/hesap-silme.html`.
- Play → Target audience: 18+ (the app is for parents, not children). Do not join the Families programme.
- App Store → App Privacy: the same data, "not used for tracking". Age rating questionnaire: no objectionable content.
- Both: a reviewer account. Sign-in is Google or Apple only, so create a separate Google account for review, sign in
  with it once, add a sample family, and put its email and password in the review notes.
