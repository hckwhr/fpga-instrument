# FPGAvedio Android 1.1.3

2026-10-27. Package `cn.xingzhewujiang.mineradio`, versionCode 104.

The APK uses the actual Mineradio player and the shared FPGA workbench. Android-specific navigation provides a side drawer, persistent search, a current-song card and a direct import button. The button snapshots the audio source and song name, opens the workbench, waits for readiness and requires its import acknowledgement. It does not automatically upload or play on hardware.

NetEase native requests use the desktop dependency's weapi encoding. QR authorization and account status use official endpoints; session cookies remain in Android CookieManager. Search, lyrics, authorized audio download, personal playlists and paginated playlist tracks use that session. Cover URLs use HTTPS. No credentials, signing keys or phone account screenshots are included here.

## Evidence

- `node tools/app-smoke.mjs --player`: passed. Actual player entry, drawer navigation, search hit testing with queue open, QR rendering/save/expiry/authorization/logout states, media time advancement, cold-workbench current-song import, real transcription model, arrangement and upload protocol. Native provider/BLE/FPGA are mocked in this browser test; see `app-smoke.json`.
- `npm run test:app`: existing alternate-entry regression passed before the subsequent phone-shell changes; the old entry was not changed by those changes.
- `node --test tests/provider-login-state-recovery.test.js`: 10 passed, 0 failed.
- APK Java compilation and APK signature verification passed with the existing signing identity.
- Actual network probes returned search results and a playable URL via weapi. The previously used public GET search endpoint returned an encrypted string rather than the expected result object.
- USB installation returned `Success`. Device package query confirmed versionCode 104 / versionName 1.1.3 at 18:26:49. Existing app data were retained with `install -r`.
- APK copied to phone `/sdcard/Download/FPGAvedio-Android.apk`.
- Automated Android instrumentation did not produce a passing result; attempts were stopped, not counted as successful physical playback tests. A bounded optional device runner is included under `android/tests`. Actual speaker output and physical BLE/FPGA communication remain separate tests.

APK SHA256: `2c351461c38b331f186885cf31027057d1f577e4ef7f8a481eb98e91889c9f82`.

The screenshots in this folder used for delivery are browser test images with test-song metadata, not screenshots of a real account.

## Upstream check

Checked https://github.com/XxHuberrr/Mineradio-paused on 2026-10-27. README describes a Windows Electron app; the inspected release list includes Windows and macOS packages. The complete main-branch tree contained no Android/Gradle/Capacitor/Flutter project or APK. The previous `XxHuberrr/Mineradio` API URL resolves to this repository. No official Android implementation was found in those inspected sources.

## Scope limits

This Android port does not supply all desktop Node provider backends, Windows Wallpaper Engine hosting, a USB serial transport or a background playback service. Automated provider authorization is mocked; real login is performed by the user in NetEase. Membership and copyright restrictions are not bypassed.
