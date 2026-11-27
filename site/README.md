# Hally web pages (privacy policy, KVKK, account deletion)

Static pages published to GitHub Pages by `.github/workflows/pages.yml`. Both stores ask for these links:

| Page | Store field |
|---|---|
| `gizlilik.html` (TR) / `privacy.html` (EN) | Play Console → App content → Privacy policy; App Store Connect → App Privacy → Privacy Policy URL |
| `hesap-silme.html` | Play Console → App content → Data safety → "Delete account URL" |
| `kvkk.html` | Linked from the policy; KVKK aydınlatma metni |

The API's `PRIVACY_POLICY_URL` should point at `gizlilik.html`, so the in-app privacy screen links to it.

## Before publishing: fill in the placeholders

Every value to fill in is marked `<span class="todo">[...]</span>` (and `mailto:[E-POSTA]` in two links). Replace the whole
span with plain text, for example `<span class="todo">[E-POSTA]</span>` → `destek@hally.app`.
In Visual Studio / VS Code: Find in Files (`Ctrl+Shift+F`) for `class="todo"` in `site/`.

| Placeholder | What to write |
|---|---|
| `[AD SOYAD / ŞİRKET UNVANI]`, `[NAME / COMPANY]` | Who publishes the app (the data controller). Your own name for an individual developer account. |
| `[ADRES]`, `[ADDRESS]` | A postal address for KVKK requests. |
| `[E-POSTA]`, `[EMAIL]` | A support address you read. |
| `[AI SAĞLAYICISI]`, `[AI PROVIDER]` | The AI company in `AI_BASE_URL`, e.g. "OpenAI (ABD)". |
| `[BARINDIRMA SAĞLAYICISI, ÜLKE]` | Where the API runs, e.g. "Hetzner (Almanya)". |
| `[YEDEK SAKLAMA SÜRESİ]`, `[BACKUP DAYS]` | How long database backups are kept, e.g. 30. |
| `[YAYIN TARİHİ]`, `[RELEASE DATE]` | Today's date when you publish. |

The Pages workflow publishes nothing (and shows a warning) while any `class="todo"` is left.

This text is a careful starting point, not legal advice. Because the app stores children's health data, a short review by a
KVKK lawyer before launch is worthwhile.

## One-time GitHub setup

Settings → Pages → Build and deployment → Source: **GitHub Actions**. The site appears at
`https://<github-user>.github.io/hally/` (for example `.../hally/gizlilik.html`).

Custom domain (used now): DNS `CNAME hally → gseker08.github.io.` at the registrar (Natro), then Settings → Pages →
Custom domain `hally.lusnikaapps.com` → Save, and tick **Enforce HTTPS** once the certificate is ready. The API's
`PRIVACY_POLICY_URL` is `https://hally.lusnikaapps.com/gizlilik.html`.
