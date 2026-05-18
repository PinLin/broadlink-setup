# broadlink-setup

A no-cloud Flutter Android app that **joins a factory-reset BroadLink
RM mini 3 to your home Wi-Fi without a BroadLink account**.

## What it does

After the RM mini 3 is in AP configuration mode (slow-blinking LED), the
app:

1. Asks for the Android permissions it needs to scan and join Wi-Fi.
2. Finds the device hotspot (`BroadlinkProv*` / `BroadLink_WiFi_Device*`)
   and auto-joins it.
3. Lets you pick your home 2.4 GHz Wi-Fi from the scan results, or enter
   a hidden SSID manually.
4. Sends the credentials to the device, retrying with a GB2312 fallback
   if the device does not show up on the home network within ~15 s
   (some Chinese-region units only decode that legacy encoding).
5. Confirms the device joined home Wi-Fi by re-discovering it there.

Everything runs on your phone over the LAN. No data goes to BroadLink
servers and no account is created.

## Tested device

- RM mini 3 (China retail unit, devtype `0x27cd`, firmware 55) — the
  version this app has been verified against end-to-end on real
  hardware.

## Build / run

Standard Flutter — see [`app/README.md`](app/README.md).

```
cd app
flutter pub get
flutter run --release        # connected Android device
flutter build apk --release  # produces app-release.apk
```

Requirements: Android 10+ (the app uses `WifiNetworkSpecifier`), Dart
3.4+, Flutter 3.22+.

## License

MIT — see [`LICENSE`](LICENSE). No BroadLink assets are redistributed.
