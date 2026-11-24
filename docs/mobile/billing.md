# Billing setup (Family Plus)

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

In Play Console each subscription needs one auto-renewing **base plan** (monthly: `monthly`, yearly: `yearly`); the app buys
the first base plan the store returns.

Do not configure a store-side free trial: the 7-day trial is handled by the server so it works without a card.

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

- Prices: `queryProductDetails`. Buy: `buyNonConsumable` (auto-renewing subscriptions use the same call).
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
(`sandbox-cancelled:` will not renew, `sandbox-expired:` has already expired). This is ignored in Production.
