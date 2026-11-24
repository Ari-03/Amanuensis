# Release signing

Nightly and stable releases are ad-hoc signed until this repository has the five secrets below. After that, the release workflows sign the app and its helper with Developer ID and the hardened runtime, notarize and staple the app and the DMG, and then sign the DMG for the in-app updater. Local builds, pull requests and manual runs stay ad-hoc, and never see the secrets.

With no secrets set, releases are built as before. With only some set, the release fails and names the missing ones. A rejected notarization also fails the release.

## Set it up

You need the Account Holder's Apple Developer account and the [GitHub CLI](https://cli.github.com). Work in a private directory outside the repository:

```sh
mkdir -m 700 ~/amanuensis-signing
cd ~/amanuensis-signing
umask 077
```

### 1. Developer ID Application certificate

Make a private key and a certificate request:

```sh
/usr/bin/openssl req -new -newkey rsa:2048 -nodes -keyout developer-id.key \
    -out developer-id.csr -subj '/CN=Amanuensis Developer ID'
```

At [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/add), choose **Developer ID Application**, then **G2 Sub-CA**, and upload `developer-id.csr`. Download `developerID_application.cer` and move it into this directory.

Pack the certificate and key with a generated password. Use `/usr/bin/openssl`, because some macOS versions cannot import what newer OpenSSL writes.

```sh
/usr/bin/openssl rand -hex 24 > certificate-password
/usr/bin/openssl x509 -inform DER -in developerID_application.cer -out developer-id.pem
/usr/bin/openssl pkcs12 -export -inkey developer-id.key -in developer-id.pem \
    -out developer-id.p12 -passout file:certificate-password
base64 < developer-id.p12 > developer-id.p12.base64
```

### 2. App Store Connect API key

In App Store Connect, open [Users and Access → Integrations → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api) and choose **Team Keys**. Request access if asked. Generate a key with the **Developer** role and download its `AuthKey_<key ID>.p8`, which Apple offers only once. Move it into this directory; it must be the only `AuthKey_` file there.

```sh
basename AuthKey_*.p8 .p8 | sed 's/^AuthKey_//' > notary-key-id
```

Copy the **Issuer ID** shown above the list of keys, then run:

```sh
pbpaste > notary-issuer-id
```

### 3. Check the key, then set the secrets

```sh
xcrun notarytool history --key AuthKey_*.p8 --key-id "$(cat notary-key-id)" --issuer "$(cat notary-issuer-id)"
```

An empty history is fine. An authentication error means the key ID or issuer ID is wrong. Then set all five secrets; a release that starts with only some of them fails.

```sh
gh secret set AMANUENSIS_SIGNING_CERTIFICATE --repo Ari-03/Amanuensis < developer-id.p12.base64
gh secret set AMANUENSIS_SIGNING_CERTIFICATE_PASSWORD --repo Ari-03/Amanuensis < certificate-password
gh secret set AMANUENSIS_NOTARY_KEY --repo Ari-03/Amanuensis < AuthKey_*.p8
gh secret set AMANUENSIS_NOTARY_KEY_ID --repo Ari-03/Amanuensis < notary-key-id
gh secret set AMANUENSIS_NOTARY_ISSUER_ID --repo Ari-03/Amanuensis < notary-issuer-id
```

Back up the directory somewhere encrypted and keep it off shared disks. If you lose the key, revoke the certificate and make another for the same team. Keep the old certificate valid otherwise: revoking it stops macOS from opening builds already signed with it.

### 4. Check the first notarized nightly

Merge to `main`, or rerun the newest `main` build. Apple can hold a new team's first submission for longer than the 20 minutes a release waits. If that fails the build, wait and rerun it. Then download the nightly DMG in a browser on a Mac and check:

```sh
spctl --assess --type open --context context:primary-signature -vv ~/Downloads/Amanuensis-*-arm64.dmg
spctl --assess --type execute -vv /Applications/Amanuensis.app
```

Both should report `source=Notarized Developer ID`. After two notarized nightlies, confirm that updating from the first to the second keeps Accessibility access.

When it works, remove the sentences in the README that call releases ad-hoc signed.

## How it works

[`Scripts/sign-release.sh`](../Scripts/sign-release.sh) runs after the ad-hoc build and replaces its output. The certificate is imported into a temporary keychain that the script deletes on exit, whether or not signing worked. [`Scripts/sign-app.sh`](../Scripts/sign-app.sh) signs the helper first and the app last. Only the app has an entitlement, microphone input. Speech and cleanup need no JIT or library exceptions because their code is statically linked and Metal compiles shaders outside the process. System audio capture is a macOS permission, not an entitlement.

The app is stapled before it goes into the DMG, so the installed copy carries its own ticket. The updater signature comes last because stapling changes the DMG.

To check the hardened runtime without a certificate, sign a local build ad hoc, then run the packaged checks:

```sh
Scripts/build.sh
Scripts/sign-app.sh artifacts/Amanuensis.app -
```

## Updating existing installs

The in-app updater checks the Ed25519 signature, the bundle identifier and version, and that the code signature is intact. It does not compare signing identities, so an ad-hoc install can update to a Developer ID build.

macOS ties Accessibility, microphone, screen recording and Keychain access to the app's designated requirement. An ad-hoc build's requirement is the hash of that one build, so any update can lose access. Moving to the first Developer ID build is one more such update: grant Accessibility once more, and choose **Always Allow** if macOS asks about a saved API key. If the Amanuensis entry in System Settings is already on but pasting does not work, remove it with **−** and add the app again.

A Developer ID build's requirement names the bundle identifier, Apple's Developer ID authority and the team. Every later build from the same team meets it, so later updates keep access, including after the certificate is renewed. Removing the secrets, or changing the team or bundle identifier, breaks that chain.
