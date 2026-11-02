# TrueCloud for iPhone

An iPhone client for [TrueCloud](https://truecloud.in), the cloud-PC service built on Sunshine and Moonlight. It is
[Moonlight for iOS](https://github.com/moonlight-stream/moonlight-ios) with a TrueCloud panel in front: sign in, start your cloud PC,
press Play, and the app pairs and streams "Desktop" by itself.

> Independent prototype made to show TrueCloud, with their permission. Not an official release, not published anywhere.
> "TrueCloud" belongs to its owners. The icon and theme (teal and indigo) are original.

## How it works

- `Sources/Kit` is `TrueCloudKit` (Firebase sign-in, Firestore profile, Server Action resolver, `RigAPI`), copied from the Mac client.
- `Sources/Shared` is the Mac client's session, auth and views. `Sources/iOS` is the iPhone panel, the glass on-screen controls
  (and their editor), the controller check and the stream settings.
- `moonlight-objc.patch` hooks Moonlight's Objective-C (AppDelegate, MainFrameViewController, StreamView, Info.plist) so the app opens into
  the panel, adds the host on Play, pairs and launches "Desktop" in the app.
- `integrate-moonlight.rb` applies the patch to `moonlight-ios/` (a checkout of moonlight-stream/moonlight-ios, ignored by git),
  adds all Swift sources to the Moonlight target and installs the icon and launch assets.

**Pairing.** Moonlight shows its own random PIN and waits for Sunshine. The app catches that PIN and calls TrueCloud's `sendPin`
repeatedly (first after 3 s, then every 3 s, up to 2 minutes) until it is accepted or Moonlight reports that pairing ended.

**Stream address.** `moonlight-a2.truecloud.in:35450` (or the A4 gateway, chosen on the home screen). Moonlight discovers the HTTPS port itself.

## Build

```sh
git clone --recurse-submodules https://github.com/moonlight-stream/moonlight-ios   # into ./moonlight-ios
ruby integrate-moonlight.rb                    # needs the xcodeproj gem
cp scripts/renew.env.example scripts/renew.env # set TEAM_ID and BUNDLE_ID
scripts/renew-and-install.sh --integrate       # build with real signing and install on the iPhone
scripts/renew-and-install.sh --build-only      # build only, no phone needed
scripts/make-ipa.sh                            # unsigned IPA for SideStore/AltStore
scripts/sim-build.sh && scripts/sim-shot.sh home:ready ready   # simulator preview screenshots (Screenshots/)
swift test                                     # TrueCloudKit tests (two read-only live checks)
```

Free Apple ID builds stop opening after 7 days; run `scripts/renew-and-install.sh` again to renew.

## Preview mode (Debug builds)

Launch with `SIMCTL_CHILD_TRUECLOUD_PREVIEW=` `login`, `home:<checking|idle|starting|booting|ready|pairing|streaming|shutting>[:settings|network|controllers|about|sample]`
or `controls[:selected|play|bright|selftest]`. It uses a fake profile and never touches the network.

Moonlight is GPL-3.0 licensed; see `LICENSE`.
