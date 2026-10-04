#!/bin/sh
# Compiles the app's Foundation-only files (group client, session, voice protocol) with their tests against the real
# TripCore, on Linux. Run from test-app-logic.ps1 inside a swift container (repository mounted read-only on /repo).
# These tests also run on the iPhone simulator in the iOS build; this is the 10-second version.
set -e
cd /build
rm -rf chk && mkdir -p chk/Sources/MotoTrip chk/Tests/MotoTripTests chk/core-pkg
cp -r /repo/core/Sources /repo/core/Package.swift chk/core-pkg/
cp /repo/app/Sources/Networking/GroupBackend.swift /repo/app/Sources/Networking/SupabaseBackend.swift \
   /repo/app/Sources/Adapters/VoiceRoom.swift /repo/app/Sources/Features/Group/GroupSession.swift chk/Sources/MotoTrip/
cp /repo/app/Tests/GroupBackendTests.swift /repo/app/Tests/GroupSessionTests.swift chk/Tests/MotoTripTests/
cp /repo/scripts/app-logic/CombineShim.swift chk/Sources/MotoTrip/     # no Combine on Linux: same names, no publishing
cat > chk/Package.swift <<'EOF'
// swift-tools-version:5.10
import PackageDescription
let package = Package(
    name: "AppLogic",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "core-pkg")],
    targets: [
        .target(name: "MotoTrip", dependencies: [.product(name: "TripCore", package: "core-pkg")]),
        .testTarget(name: "MotoTripTests", dependencies: ["MotoTrip"]),
    ]
)
EOF
cd chk
swift test ${FILTER:+--filter "$FILTER"} 2>&1 | grep -E "error|failed|Executed|Build complete|XCTAssert|Fatal" | tail -60
