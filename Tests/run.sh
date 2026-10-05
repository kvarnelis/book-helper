#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$PWD/build/DerivedData/EPUBTests"
mkdir -p "$test_dir/Fixtures" "$test_dir/ModuleCache"
python3 Tests/make_fixtures.py "$test_dir/Fixtures"
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path "$test_dir/ModuleCache" \
    -framework AppKit -framework PDFKit -framework SwiftUI -lz \
    BookHelper/Models/*.swift BookHelper/Services/*.swift BookHelper/Views/*.swift \
    Tests/RegressionTests.swift -o "$test_dir/RegressionTests"
"$test_dir/RegressionTests" "$test_dir/Fixtures" "$test_dir"
