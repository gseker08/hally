# iPhone builds with Codemagic (no Mac)

`codemagic.yaml` at the repository root builds a signed iPhone app on Codemagic's cloud Mac and uploads it to
TestFlight. You start each build by hand from the Codemagic dashboard.

## Once

1. **App Store Connect → Apps → +**: new app, platform iOS, bundle id `app.hally`, SKU `hally`. The name must be unique
   in the App Store (it can differ from the icon name).
2. **App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys → +**: name
   `Codemagic`, access **App Manager**. Download the `.p8` (only once) to `C:\src\keys`, note the Key ID and the
   Issuer ID shown above the list.
3. **codemagic.io**: sign in with GitHub, add the `hally` repository (Flutter App, "codemagic.yaml" mode).
4. **Team settings → Integrations → Developer Portal → Connect**: name it exactly `Hally App Store Connect`,
   enter the Issuer ID, Key ID and upload the `.p8`.
5. **Team settings → Code signing identities → iOS certificates → Generate certificate** (Apple Distribution), using
   that integration. Codemagic keeps the private key; download the `.p12` backup to `C:\src\keys` too.
6. **App → Environment variables**, group `hally_ios`, variable `GOOGLE_SERVICE_INFO_PLIST` (marked Secret): the plist
   as base64. PowerShell:
   `[Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\src\keys\GoogleService-Info.plist')) | Set-Clipboard`

The Google iOS client id and its URL scheme are not secret and sit in `codemagic.yaml` itself.

## Each build

Codemagic → the app → **Start new build** → workflow **iPhone → TestFlight**, branch `main`. After about 20–30 minutes
the build appears in App Store Connect → TestFlight (Apple processes it for a few more minutes). Install the
**TestFlight** app on the iPhone and accept the invitation.
