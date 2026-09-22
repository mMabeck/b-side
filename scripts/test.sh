#!/usr/bin/env bash
# Runs the test suite.
#
# The CommandLineTools toolchain does not put Testing.framework on the default
# search path, so a bare `swift test` fails to link and load.
#
# DYLD_FRAMEWORK_PATH does not help: SIP strips DYLD_* when swiftpm spawns
# swiftpm-testing-helper, so the framework has to be baked in as an rpath on
# the test bundle itself.
set -euo pipefail

export DEVELOPER_DIR=/Library/Developer/CommandLineTools
CLT_FRAMEWORKS="$DEVELOPER_DIR/Library/Developer/Frameworks"
CLT_LIBS="$DEVELOPER_DIR/Library/Developer/usr/lib"

exec swift test \
  -Xswiftc -F -Xswiftc "$CLT_FRAMEWORKS" \
  -Xlinker -F -Xlinker "$CLT_FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$CLT_LIBS" \
  "$@"
