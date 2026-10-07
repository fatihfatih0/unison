#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
./Scripts/build.sh
./Scripts/build-driver.sh
staging="$PWD/build/NamedAudioInstallerRoot.noindex"
mkdir -p "$staging/Applications" "$staging/Library/Audio/Plug-Ins/HAL"
ditto build/Products.noindex/Unison.app "$staging/Applications/Unison.app"
ditto build/UnisonAudio.driver "$staging/Library/Audio/Plug-Ins/HAL/UnisonAudio.driver"
# Installer caches the package digest when opened. Never overwrite a package
# that the user may still have open while a new app build is prepared.
mkdir -p "$PWD/build/installer-releases"
release_directory=$(mktemp -d "$PWD/build/installer-releases/Unison-XXXXXX")
package_path="$release_directory/Unison-Audio.pkg"
pkgbuild --root "$staging" --component-plist Driver/InstallerComponents.plist --scripts Driver/InstallerScripts --identifier org.unison.audio.install --version 1.0.0 --install-location / "$package_path"
pkgutil --payload-files "$package_path" > "$release_directory/payload.txt"
printf '%s\n' "$package_path" > "$PWD/build/latest-installer-path.txt"
echo "Kurulum paketi hazır: $package_path"
