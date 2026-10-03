#!/bin/bash
# Runs the test suite.
#
# Without a full Xcode this machine has no importable Swift Testing module, so the package
# pulls swift-testing in as a dependency. That build still links against the toolchain's
# lib_TestingInterop.dylib, which lives outside the default search and rpath, hence the flags.
set -euo pipefail

cd "$(dirname "$0")/.."
CLT_LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib

if [ -f "$CLT_LIB/lib_TestingInterop.dylib" ]; then
    exec swift test \
        -Xlinker -L"$CLT_LIB" \
        -Xlinker -rpath -Xlinker "$CLT_LIB" \
        "$@"
fi

exec swift test "$@"
