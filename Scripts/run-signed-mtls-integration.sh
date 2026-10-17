#!/bin/bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_directory="$(mktemp -d "${TMPDIR:-/tmp}/beakrnet-mtls-run.XXXXXX")"
destination="${1:-platform=macOS}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
test_plan_path="${repository_root}/Apps/BeakrNetIntegrationTests.xctestplan"
test_plan_backup="${fixture_directory}/BeakrNetIntegrationTests.xctestplan"

cleanup() {
    if [[ -f "${test_plan_backup}" ]]; then
        cp "${test_plan_backup}" "${test_plan_path}"
    fi
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
export SWIFTPM_CUSTOM_CACHE_PATH="${fixture_directory}/SwiftPMCache"

mkdir -p "${SWIFTPM_CUSTOM_CACHE_PATH}"
cp "${test_plan_path}" "${test_plan_backup}"

# Device and Simulator test processes do not inherit arbitrary variables from
# the xcodebuild shell. Inject disposable Base64 fixtures into the plan for this
# run, then restore the original plan in cleanup.
ruby -rjson -e '
path = ARGV.fetch(0)
names = %w[
  BEAKRNET_RUN_SIGNED_MTLS_INTEGRATION
  BEAKRNET_TEST_PKCS12_PASSWORD
  BEAKRNET_TEST_CLIENT_PKCS12_BASE64
  BEAKRNET_TEST_SERVER_PKCS12_BASE64
  BEAKRNET_TEST_EXPIRED_SERVER_PKCS12_BASE64
  BEAKRNET_TEST_AUTHORITY_DER_BASE64
  BEAKRNET_TEST_WRONG_AUTHORITY_DER_BASE64
]
plan = JSON.parse(File.read(path))
options = plan["defaultOptions"] ||= {}
existing = options.fetch("environmentVariableEntries", [])
options["environmentVariableEntries"] = existing.reject { |entry| names.include?(entry["key"]) } +
  names.map { |name| { "key" => name, "value" => ENV.fetch(name) } }
File.write(path, JSON.pretty_generate(plan) + "\n")
' "${test_plan_path}"

cd "${repository_root}"
echo "Using $(xcodebuild -version | head -n 1) from ${DEVELOPER_DIR}"
xcodebuild test \
    -project Apps/BeakrNetIntegrationHost.xcodeproj \
    -scheme BeakrNetIntegrationHost \
    -testPlan BeakrNetIntegrationTests \
    -destination "${destination}" \
    -derivedDataPath "${fixture_directory}/DerivedData" \
    -clonedSourcePackagesDirPath "${fixture_directory}/SourcePackages" \
    -packageCachePath "${fixture_directory}/PackageCache" \
    -only-testing:BeakrNetIntegrationTests
