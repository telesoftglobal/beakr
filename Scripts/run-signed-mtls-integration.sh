#!/bin/bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_directory="$(mktemp -d "${TMPDIR:-/tmp}/beakrnet-mtls-run.XXXXXX")"
destination="${1:-platform=macOS}"

cleanup() {
    if [[ "${fixture_directory}" == "${TMPDIR:-/tmp}"/beakrnet-mtls-run.* ]]; then
        rm -rf "${fixture_directory}"
    fi
}
trap cleanup EXIT

"${repository_root}/Scripts/generate-lan-tls-test-fixtures.sh" "${fixture_directory}"
source "${fixture_directory}/environment.sh"
export XDG_CACHE_HOME="${fixture_directory}/Caches"
export CLANG_MODULE_CACHE_PATH="${fixture_directory}/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="${fixture_directory}/ModuleCache"

cd "${repository_root}"
xcodebuild test \
    -project Apps/BeakrNetDemo.xcodeproj \
    -scheme BeakrNetDemo \
    -destination "${destination}" \
    -derivedDataPath "${fixture_directory}/DerivedData" \
    -clonedSourcePackagesDirPath "${fixture_directory}/SourcePackages" \
    -only-testing:BeakrNetDemoIntegrationTests
