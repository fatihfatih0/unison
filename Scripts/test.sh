#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/tests.noindex
swift test
clang -fsanitize=address -I Sources/RealtimeAudio/include Tests/realtime_audio_test.c Sources/RealtimeAudio/RealtimeAudio.c -framework CoreAudio -o build/tests.noindex/dsp-test
build/tests.noindex/dsp-test
clang -fmodules -fsanitize=address -I Vendor/m1ddc/headers Tests/ddc_packet_test.m Vendor/m1ddc/sources/i2c.m Vendor/m1ddc/sources/ioregistry.m -framework CoreDisplay -o build/tests.noindex/ddc-test
build/tests.noindex/ddc-test
./Scripts/build-driver.sh
clang++ -std=c++17 Tests/driver_contract_test.cpp -framework CoreFoundation -framework CoreAudio -o build/tests.noindex/driver-test
build/tests.noindex/driver-test "$PWD/build/UnisonAudio.driver/Contents/MacOS/UnisonAudio"
