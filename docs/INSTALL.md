# Installation / Kurulum

## Requirements

Apple Silicon Mac, macOS 14.4 or newer. Local builds need Xcode 26 or newer with the macOS 26 SDK; the resulting app targets macOS 14.4+. Intel has not been validated. The app interface is Turkish.

## Install a release

1. Open this repository's **Releases** page. If no binary is available, use the source build below.
2. Download `Unison-Audio.pkg` and open it. The package installs `/Applications/Unison.app` and `/Library/Audio/Plug-Ins/HAL/UnisonAudio.driver`.
3. Approve the macOS administrator prompt. The installer closes Unison, briefly restarts the audio service, then opens the installed app.
4. If macOS blocks an unnotarized package/app, review its origin and use **System Settings → Privacy & Security → Open Anyway**, if offered. See [Apple's guidance](https://support.apple.com/102445). Current builds are not Apple-notarized; do not disable Gatekeeper or SIP.
5. Allow Unison under **Privacy & Security → Accessibility** for volume-key interception. Allow system audio capture when macOS requests it (its settings label varies by OS version). The app needs captured audio for HDMI and simultaneous outputs.
6. Open the U menu icon, select physical outputs and play audio. Unison switches to its named system output after a real signal is detected.

Local builds prefer an available Apple Development identity, otherwise use ad-hoc signing. That is not a Developer ID notarized distribution. Rebuilding with a different signing identity may require regranting permissions.

## Build from source

Clone or download this repository, open Terminal in its root, then:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
./Scripts/build-installer.sh
open "$(cat build/latest-installer-path.txt)"
```

No certificate or paid developer account is needed for a local build. To omit the driver:

```sh
./Scripts/build.sh
open build/Products.noindex/Unison.app
```

The driver is needed for the **Unison** system output name, not for basic app operation. Without it, the shared system control may display a physical speaker's name.

## Troubleshooting

- **“Ses bekleniyor” / Waiting for audio:** play audio and check capture permission. The engine deliberately waits for a real signal before changing routing.
- **No sound with Unison selected:** keep the app running. If it crashed, reopen it or choose a physical speaker in macOS Sound settings.
- **External brightness dims pixels:** your display may not answer DDC. This fallback does not lower backlight power; DDC compatibility depends on the monitor and connection.
- **Volume keys only affect the Mac:** check Accessibility permission, selected outputs and whether the audio engine has become active. Plain F-keys and actual media keys differ.
- **Installer says the package changed:** close that installer window and open a freshly generated package. Package builds now use separate files rather than replacing an open archive.

## Remove Unison

Quit Unison normally and choose a physical output in **System Settings → Sound**. Disable its start-at-login setting. Move `/Applications/Unison.app` to Trash. To remove the optional driver, remove only `/Library/Audio/Plug-Ins/HAL/UnisonAudio.driver` in Finder, approving the administrator prompt, then restart the Mac. Leave other audio drivers in that directory alone.

Preferences may be retained by macOS. The app does not install a kernel extension, background privileged helper, recording service or network service.

## Türkçe hızlı kurulum

**Releases** sayfasından paket indir; yoksa yukarıdaki komutlarla kaynak koddan derle. Paketi açıp yönetici onayını ver. **Gizlilik ve Güvenlik → Erişilebilirlik** bölümünde Unison'u aç; sistem sesini yakalama iznini de ver. U simgesinden fiziksel çıkışları seç ve bir ses çal. Sanal çıkış kullanılırken uygulama açık kalmalıdır.

Paketin Apple noter onayı yoktur. macOS engellerse kaynağı kontrol et ve sunuluyorsa **Yine de Aç** seçeneğini kullan. Kaldırırken uygulamadan çık, fiziksel hoparlöre dön, yalnızca Unison uygulamasını ve `UnisonAudio.driver` dosyasını kaldırıp Mac'i yeniden başlat.
