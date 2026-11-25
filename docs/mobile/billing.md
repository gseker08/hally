# Billing setup (Family Plus)

**One plan per family, one payment (decided 2026-11-25).** One parent buys Family Plus (monthly or yearly) and the whole
family is covered: every parent, caregiver and paired child phone. The `subscriptions` table has one row per family.

- Only parents can buy (caregivers and child phones cannot reach the purchase endpoint).
- While a parent's renewing subscription covers the family, the others see "Family Plus · Aile planı · Ayşe ödüyor" and
  no buy button (`canPurchase: false`); the server also refuses a second purchase with 409 `billing.family_already_plus`.
- The payer leaving keeps the paid time with the family (`purchasedByInFamily: false`, the app shows "Ödeyen kişi aileden
  ayrıldı" and "Planı ben devralayım"). The payer can restore the same purchase into their new family; the old family then
  drops to Free. Nobody else can move a purchase that unlocks another family (409 `billing.purchase_in_use`).

The server decides who has Family Plus. The app only shows the paywall, asks the store to sell, and sends the
store's purchase id to `POST /families/{id}/subscription/purchases`, where the server asks the store itself.

## Products

Create the same two auto-renewing subscriptions in App Store Connect and Google Play Console:

| Product id | Period | Note |
|---|---|---|
| `hally_plus_monthly` | 1 month | |
| `hally_plus_yearly` | 1 year | about 2 months free compared to monthly |

Ids are configurable with `Billing:Products` (each `{ Id, Period, FallbackPrices }`). Prices are set in the stores, per country;
the paywall shows the store's localized price. **Türkiye prices (decided 2026-11-24): ₺79,99 a month, ₺599,99 a year.**
`FallbackPrices` (default TRY values above) is only for display before the store answers.

In Play Console each subscription needs one auto-renewing **base plan** (monthly: `monthly`, yearly: `yearly`).

## 7-day free trial (once per family)

The trial is the **store's free-trial offer**: the parent enters a card in the store, uses Plus free for 7 days, and on day 8
the chosen monthly/yearly package starts by itself unless they cancel in the store.

- **Google Play:** on each base plan add an offer: eligibility "New customer acquisition / never had this subscription",
  one phase **Free trial, 7 days**, offer id `ucretsiz-7-gun`, **tag `free-trial`**. The app buys this offer only when the
  server says `trialAvailable`; otherwise it buys the plain base plan, so a second parent is never offered a second week.
- **App Store:** an **Introductory Offer → Free, 1 week** on both products (same subscription group). Apple decides
  eligibility per Apple ID and the app cannot hide it.

Hally counts the trial per family **and** per parent. When a store purchase arrives in its free-trial phase
(`offerPhase.freeTrial` / the `free-trial` tag on Play, `offerType 1` on Apple) for a family that already had its trial,
or from a parent who had one in another family, the server records it but gives **no Plus until the first paid period**:
state `TrialDenied`, the app shows "Ücretsiz deneme bu ailede kullanıldı", and the analytics event `trial_denied` is
recorded. When the store reports the first paid period the family gets Plus as usual.

The older card-less server trial (`POST /subscription/trial`) still exists for old app builds but the app no longer calls it.

## App Store

1. App Store Connect → Users and Access → Integrations → In-App Purchase: create a key. Set
   `APPLE_IAP_ISSUER_ID`, `APPLE_IAP_KEY_ID`, `APPLE_IAP_PRIVATE_KEY` (the .p8 content, a secret) and `APPLE_BUNDLE_ID`.
   Use `APPLE_IAP_ENVIRONMENT=Sandbox` for TestFlight.
2. App Store Server Notifications V2 URL: `https://<api>/api/v1/billing/notifications/apple`.
3. The app sends the StoreKit 2 `transactionId` as the purchase token.

## Google Play

1. Create a service account with "View financial data" and "Manage orders and subscriptions" in Play Console,
   and set `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` (a secret) and `GOOGLE_PLAY_PACKAGE_NAME`.
2. Real-time developer notifications: a Pub/Sub topic with a push subscription to
   `https://<api>/api/v1/billing/notifications/google?token=<GOOGLE_PLAY_NOTIFICATION_TOKEN>`.
3. The app sends the Play `purchaseToken`. The server acknowledges new purchases (Google refunds unacknowledged ones after 3 days).

## App side

`InAppPurchaseStoreGateway` (`lib/features/billing/store_gateway_iap.dart`) implements `StoreGateway` with the official
`in_app_purchase` plugin (Play Billing, StoreKit 2). It is used on Android and iPhone; tests and desktop get
`UnavailableStoreGateway`.

- Prices: `queryProductDetails`; on Play the base plan's price (the free-trial offer is kept apart). Buy: `buyNonConsumable`
  (auto-renewing subscriptions use the same call) with the trial offer only when `withTrial` is set.
- Token sent to the server: the Play `purchaseToken` on Android, the StoreKit 2 transaction id on iPhone.
- Every purchased/restored update is `completePurchase`d (StoreKit re-delivers unfinished ones; Play ones are also
  acknowledged by the server).
- A Google Play "pending" payment shows "Ödemen onay bekliyor"; when it clears, the update arrives on
  `backgroundPurchases` and `storePurchaseSyncProvider` (watched in `app.dart`) registers it with the server.
- "Satın alımları geri yükle" calls `restorePurchases` and sends what comes back within 2 seconds.

While `Billing:FreeLaunch` is on the paywall never opens, so none of this runs for users.

### Testing on a device

- Android: the build must be signed with the upload key and uploaded once to a testing track, and your Google account
  must be a **license tester** (Play Console → Settings → License testing). Test cards are free; subscriptions renew every
  few minutes. Set `BILLING_FREE_LAUNCH=false` on a test server to see the paywall.
- iPhone: a Sandbox tester (App Store Connect → Users and Access → Sandbox) on a TestFlight build.

## Local testing

With `Billing:SandboxPurchases=true` in Development, tokens like `sandbox:hally_plus_monthly:any-ref` are accepted without a store
(`sandbox-cancelled:` will not renew, `sandbox-expired:` has already expired, `sandbox-trial:` is in a 7-day free trial). This is ignored in Production.
