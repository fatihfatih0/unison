#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
driver="$PWD/build/UnisonAudio.driver"
mkdir -p "$driver/Contents/MacOS" "$driver/Contents/Resources" build/driver-objects
headers=(Vendor/libASPL/include/**/*(.) Vendor/libASPL/src/*.hpp(.N) Vendor/libASPL/src/*.h(.N))
for source in Vendor/libASPL/src/*.cpp; do
    object="$PWD/build/driver-objects/${source:t:r}.o"
    rebuild=false
    if [[ ! -f "$object" || "$source" -nt "$object" || "$0" -nt "$object" ]]; then
        rebuild=true
    else
        for header in "${headers[@]}"; do
            if [[ "$header" -nt "$object" ]]; then rebuild=true; break; fi
        done
    fi
    if $rebuild; then
        clang++ -Wno-reorder-init-list -std=c++17 -O2 -fblocks -fPIC -mmacosx-version-min=14.4 -I Vendor/libASPL/include -c "$source" -o "$object"
    fi
done
clang++ -Wno-reorder-init-list -std=c++17 -O2 -fblocks -bundle -mmacosx-version-min=14.4 -I Vendor/libASPL/include Driver/UnisonAudio.cpp build/driver-objects/*.o -framework CoreFoundation -framework CoreAudio -o "$driver/Contents/MacOS/UnisonAudio"
cp Driver/Info.plist "$driver/Contents/Info.plist"
cp Vendor/libASPL/LICENSE "$driver/Contents/Resources/libASPL-LICENSE.txt"
cp Vendor/libASPL/LICENSE.apple2012 "$driver/Contents/Resources/libASPL-LICENSE.apple2012.txt"
cp Vendor/libASPL/LICENSE.apple2020 "$driver/Contents/Resources/libASPL-LICENSE.apple2020.txt"
cp LICENSE "$driver/Contents/Resources/Unison-LICENSE.txt"
signing_identity="${UNISON_SIGN_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    signing_identity=$(security find-identity -v -p codesigning | awk '/"Apple Development:/ { print $2; exit }')
fi
codesign --force --sign "${signing_identity:--}" "$driver"
codesign --verify --strict "$driver"
echo "Ses sürücüsü hazır: $driver"
