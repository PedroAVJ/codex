# Expo iOS release contract

The iPhone pairing companion remains a normal Expo/React Native app. `index.js`
loads `App.js`, Metro creates the JavaScript bundle, `expo-camera` scans the
pairing QR, and `expo-updates` installs compatible over-the-air updates.

The committed `ios/` project is intentional because it also embeds the native
watchOS app and complication. CocoaPods links Expo and React Native into the
checked-in iPhone target without replacing the Apple targets.

## Binary or JavaScript update

Production uses Expo's fingerprint runtime policy and the `production` update
channel. CI publishes the EAS Update after every applicable merge without
waiting for a compatible binary. Expo gives that update the source tree's
fingerprint runtime, so only a binary with the same runtime can load it. If the
fingerprint is unchanged, existing compatible binaries receive the update. If
it changed, the update remains published for the new runtime while the signed
binary is compiled separately on the operator's Mac.

Typical JavaScript-only changes in `App.js` or `index.js` use EAS Update. A
change to native Swift or Objective-C, the Watch app, complication, shared
device protocol, entitlements, Podfile, native dependency, or native app
configuration requires a binary. Relay-only, Mac-bridge, plugin, test, and
documentation changes do not spend Mac build time.

OTA updates do not consume or change an Apple build number. `eas.json` keeps
`cli.appVersionSource` set to `remote` and production `autoIncrement` enabled,
so only a new binary advances the App Store build number.

## Production release

OTA deployment and native delivery are intentionally separate:

1. `.github/workflows/codex-voice-ci.yml` validates the final `main` source and
   runs `npm run eas:update`. That command publishes the production EAS Update
   unconditionally; it never queries, creates, cancels, or submits a build.
2. After that deployment, run `npm run eas:plan` on the operator's Mac. It
   computes the same production fingerprint and checks Expo's finished binary
   inventory without changing it.
3. If a compatible binary already exists, no native work is needed. Otherwise,
   run `npm run eas:build:local` on that Mac. It creates one signed IPA with
   `eas build --local`, verifies the embedded fingerprint, and sends the local
   path to EAS Submit for TestFlight.
4. After submission succeeds, the command registers that IPA and fingerprint
   with `eas upload` for future compatibility checks.

`npm run eas:release` remains an alias for the OTA-only update command. It does
not compile native code. The local native command never publishes an OTA update
and never alters another build or submission.

Expo records uploaded local IPAs as uploaded/internal build records. That is
why compatibility lookup uses the production fingerprint without cloud-only
build-profile, distribution, or channel filters. The signed IPA itself still
uses the App Store production profile and production update channel.

GitHub Actions owns only validation and EAS Update publication. It has no
self-hosted runner and no native build, submit, or upload step. There is no
production EAS cloud-build workflow. The remaining
`.eas/workflows/submit-existing-build.yml` can resubmit an older EAS artifact
by build ID, but it cannot create a build.

## Mac setup

The Mac needs the Xcode and watchOS versions required by the checked-in project,
plus Node 22 or newer, CocoaPods, and fastlane. Keep Xcode selected with
`xcode-select`, accept its license, install dependencies with `npm ci`, and log
in with `eas login` or provide `EXPO_TOKEN` in the local shell.

GitHub Actions uses the repository's `EXPO_TOKEN` only for EAS Update. Local
Expo authentication covers the fingerprint check, managed Apple credentials,
EAS Submit, and local-build registration. Apple signing material stays in
Expo's credential service and is downloaded only for the local build; it is
never committed. Local working files live under ignored `.eas-local-build/`
and are deleted when the command finishes.

## Local checks

Run conservatively and serially on this Mac:

```sh
npm ci
npm ci --prefix relay
npm run export:ios
npm run fingerprint:ios
node --test tests/*.test.mjs
swift test --disable-keychain --jobs 1
npm --prefix relay run typecheck
npm --prefix relay run build
npm run eas:validate
(cd ios && pod install)
```

Use `npm start` with a development build or `npm run ios` for local iPhone
development. Those commands are separate from the production release path.

The EAS project ID remains `6fc127b3-71fb-4809-ada2-e4d8ffca36f4`, and the App
Store Connect app ID remains `6804499620`.
