# KOReader patches for the Icarus Illumina E653

Patches that make [KOReader](https://github.com/koreader/koreader) work properly on the
**Icarus Illumina E653**, a 6" E Ink reader from 2014. It runs Android 4.2.2 (API 17),
and the last KOReader release for it is **v2023.06.1**: the Android launcher's `minSdk`
went from 14 to 18 in v2023.08. That version has a few problems on this reader, and
current KOReader can't fix them for API 17, so this repo patches v2023.06.1 directly.

It also documents a firmware setting that stops the reader from waking up every
minute on standby (see [Standby battery drain](#standby-battery-drain-firmware-power-manager)).

This is an unofficial patch set, not affiliated with the KOReader project.

## Devices

The E653 is a rebadged **Boyue T61** (T61B). It has the same Rockchip RK3026 board and
the same Boyue firmware, and the patches only use firmware features (the system bar
flag, the e-ink refresh call, the power manager property). So they should also work on
the **Boyue T61** and other rebadges of it, and possibly on other Boyue readers with the
same firmware. **Only the E653 has been tested.** Later E653s with a Carta screen
(from 2015) run a different firmware, so they're untested too.

| | Tested unit |
|---|---|
| Model | Icarus Illumina E653, 6" E Ink Pearl, 758×1024 |
| OEM hardware | Boyue T61B |
| SoC / PMIC | Rockchip RK3026 / X-Powers AXP22x |
| Android | 4.2.2 (JDQ39), `eng` build |
| Firmware | Icarus-Ereader_V1.0.0-2014081410 (the last one for Pearl-screen units) |

On a genuine Boyue (manufacturer `boeye`), stock KOReader already detects the e-ink
controller, so that patch changes nothing there. The rest still applies.

## What the patches do

### In the APK (`smali/`)

These need a rebuilt APK; see [Building the APK](#building-the-apk).

- **Adds proper E-ink support:** KOReader recognizes the Icarus as a Boyue T61 and uses its e-ink
  driver. Full refreshes really flash the screen, and the "Full refresh rate" setting
  appears.
- **Fixes fullscreen:** the bottom bar (Back, Home, clock) hides while KOReader is in
  front and comes back in other apps. KOReader's Settings → Screen → Fullscreen turns
  it on and off (on by default).

### Lua user patches (`patches/`)

[User patches](https://github.com/koreader/koreader/wiki/User-patches): copy them to
`koreader/patches/` on the reader. No rebuild needed.

- **`2-android-home.lua`:** adds an "Android home" item above "Exit" in the menu. The
  reader has no Home key, and the bar is hidden in fullscreen. Works with any KOReader
  on Android.
- **`2-fullscreen-live.lua`:** toggling Fullscreen takes effect right away instead of
  asking for a restart, and the Fullscreen checkbox shows the right state at startup.
  Use it with the patched APK.
- **`2-kosync-offline-queue.lua`:** closing a book no longer freezes for 30 s waiting
  for Wi-Fi when Progress sync is on. Positions that can't be sent are queued and sent
  later. Backported from upstream
  ([#15324](https://github.com/koreader/koreader/pull/15324),
  [#16153](https://github.com/koreader/koreader/pull/16153)). It isn't device-specific,
  so it should help any KOReader v2023.06.1 install.

Everything works on the E653. Not tested there yet: the "Toggle Fullscreen" gesture,
and sending queued sync positions (that needs a sync account; it's only tested on a PC).

## Installing

KOReader's settings, history and reading positions are on the internal storage in
`koreader/`, and survive uninstalling the app.

1. Build the APK (next section).
2. The patched APK has a different signature, so remove the stock KOReader first, then
   install it:
   ```sh
   adb uninstall org.koreader.launcher
   adb install koreader-v2023.06.1-icarus.apk
   ```
   Later builds signed with the same key install over it with `adb install -r`.
3. Copy the Lua patches to `koreader/patches/` on the internal storage (create the
   folder if needed), over USB storage or with adb:
   ```sh
   adb push patches/*.lua /sdcard/koreader/patches/
   ```
4. Restart KOReader (menu → Exit, then start it again).
5. Leave the system bar on in Android's Settings → User defined → Statusbar.

To leave KOReader, use Back, the "Android home" item or Exit. Android dialogs shown
over KOReader (such as "not responding") bring the bar back while they're open.

KOReader can't read the internal storage while the reader is in USB storage mode, so
switch that off first.

**Undo:** `adb uninstall org.koreader.launcher`, install the
[official APK](https://github.com/koreader/koreader/releases/tag/v2023.06.1), and delete
the patches from `koreader/patches/`.

## Building the APK

`build.sh` takes the official KOReader release APK, disassembles its `classes.dex` with
baksmali, applies the diffs in `smali/`, adds the new classes, reassembles it, and
signs the APK with your key.

**Requirements:** bash, Python 3, `patch`, OpenSSL (tested with 3.6), and a JDK 11 or
newer (`java`, `jarsigner`, `keytool`; tested with 27). Java 8's `keytool` writes
keystores that OpenSSL 3 can't read.

1. Get smali/baksmali 2.5.2 and the official KOReader v2023.06.1 ARM APK:
   ```sh
   mkdir -p tools
   curl -L -o tools/baksmali-2.5.2.jar https://bitbucket.org/JesusFreke/smali/downloads/baksmali-2.5.2.jar
   curl -L -o tools/smali-2.5.2.jar https://bitbucket.org/JesusFreke/smali/downloads/smali-2.5.2.jar
   curl -L -O https://github.com/koreader/koreader/releases/download/v2023.06.1/koreader-android-arm-v2023.06.1.apk
   ```
   The script checks the APK's SHA-256:
   `3b52a2ce39605896e273337dde8b27dae0ec33439ed8df8cd3225b5299ad1a50`.

2. Create a signing key once, and keep it to sign later builds:
   ```sh
   keytool -genkeypair -keystore release.keystore -storetype pkcs12 -alias icarus \
       -keyalg RSA -keysize 2048 -sigalg SHA1withRSA -validity 36500 \
       -dname "CN=KOReader Icarus patch"
   ```

3. Build:
   ```sh
   KEYSTORE=release.keystore KEYSTORE_PASS='your password' \
       ./build.sh koreader-android-arm-v2023.06.1.apk koreader-v2023.06.1-icarus.apk
   ```
   Optional variables: `JAVA_HOME` (if `jarsigner` isn't on `PATH`), `KEY_ALIAS`
   (default `icarus`), `BAKSMALI_JAR` and `SMALI_JAR` (default `tools/`).

The build isn't byte-for-byte reproducible: smali 2.5.2 lays out the dex file a little
differently on every run. The disassembled code is the same, though.

### Why the signing is unusual

- **SHA-1 only.** Android 4.2 accepts only v1 (JAR) signatures, and SHA-256 digests in
  them need API 18.
- **No signed attributes.** Android 4.2 rejects the signature block modern `jarsigner`
  writes (`JarUtils.verifySignature: Incorrect signature`, then
  `INSTALL_PARSE_FAILED_NO_CERTIFICATES`). That block has signed attributes
  (signingTime, CMSAlgorithmProtection). So `build.sh` lets `jarsigner` write
  `MANIFEST.MF` and `ICARUS.SF`, then re-signs the same `.SF` with
  `openssl smime -sign -binary -noattr -md sha1` and swaps the result in.
- **Alignment.** `repack.py align` does what `zipalign -p 4` does, so no Android SDK is
  needed.

### Working on the patches

The diffs are against `baksmali d` output (baksmali 2.5.2, default options) of
`classes.dex` in the official APK. To change them:

```sh
python3 -c 'import zipfile; open("classes.dex", "wb").write(zipfile.ZipFile("koreader-android-arm-v2023.06.1.apk").read("classes.dex"))'
java -jar tools/baksmali-2.5.2.jar d -o out classes.dex
for d in smali/*.diff; do patch -p1 -d out < "$d"; done
cp smali/*.smali out/org/koreader/launcher/
```

The launcher's source for v2023.06.1 is
[android-luajit-launcher](https://github.com/koreader/android-luajit-launcher) commit
`eb0fb50`: `MainActivity.kt` and `device/DeviceInfo.kt`.

## Standby battery drain (firmware power manager)

This isn't a KOReader patch, but it matters on this reader: standby lasted about a day.

**The cause.** The Boyue firmware adds a "short standby" mode to Android's
`PowerManagerService`. Every time the reader goes to sleep, it starts a loop: about
10 s awake, then an RTC wake-up alarm (`idle_wake_action`) 60 s later, then 10 s awake
again, and so on. Nothing else is needed to keep the loop going. In one overnight test
the reader woke 651 times, about every 75 s, for about 9 s each. So with the screen off
the CPU was fully awake about 13% of the time.

**The fix.** The firmware has a property that stops the 60 s alarm. It's read once at
boot, so reboot afterwards:

```sh
adb shell setprop persist.sys.idle-wakeup false
adb reboot
```

On the E653 the adb shell runs as root (it's an `eng` build). On another firmware
`setprop` may need root.

- It's stored in `/data/property/` and survives reboots; a factory reset clears it.
- Check it with `adb shell getprop persist.sys.idle-wakeup`. After the reboot,
  `adb shell dumpsys alarm` should list no `idle_wake_action` alarms.
- Buttons, touch, the charger, the screen timeout and the shutdown delay (Settings →
  User defined) still wake the reader as before.
- **Possible side effect:** on-screen clocks may not advance while the reader sits idle
  on a page; they catch up on the next touch. The manufacturer's reason for the 60 s
  wake-up isn't known.
- The effect on battery life hasn't been measured yet. The battery gauge on this
  reader is too unreliable to show it over one night, and the change was only checked
  on USB: no `idle_wake_action` alarms are set any more.

**Undo:**
```sh
adb shell setprop persist.sys.idle-wakeup true
adb reboot
```

Also look for apps that wake the reader. On the tested unit, Google Play Services
(with no Google account signed in) woke it 28 times in 10 minutes;
`adb shell dumpsys alarm` lists who sets wake-up alarms.

## Files

| Path | What |
|---|---|
| `build.sh` | Builds the patched APK from the official one |
| `repack.py` | Swaps `classes.dex` and the signature block in the APK, and aligns it |
| `smali/*.diff` | Changes to the launcher's `MainActivity` and `DeviceInfo` |
| `smali/*.smali` | New launcher classes (bar update and e-ink refresh runnables) |
| `patches/*.lua` | KOReader user patches |

## License

[AGPL-3.0](LICENSE), the same as KOReader.

- `2-kosync-offline-queue.lua` includes code from upstream KOReader (`KOSyncQueue`).
- The smali patches change KOReader's Android launcher,
  [android-luajit-launcher](https://github.com/koreader/android-luajit-launcher),
  which is MIT-licensed.
