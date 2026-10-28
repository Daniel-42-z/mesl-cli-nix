#!/usr/bin/env bash
set -euo pipefail
suite=${1:?suite required}
artifactDir=${2:?candidate directory required}
evidenceDir=${3:?evidence directory required}
python3 scripts/ci.py verify --artifact-dir "$artifactDir"
case "$suite" in
  amd64|arm64)
    system=x86_64-linux
    if [[ "$suite" == arm64 ]]; then system=aarch64-linux; fi
    nix build ".#checks.$system.package" ".#checks.$system.module" ".#checks.$system.automation" --no-link -L
    if [[ "$suite" == amd64 ]]; then
      nix fmt -- --fail-on-change
      nix flake check --no-build --all-systems
    fi
    ;;
  vm)
    test -r /dev/kvm && test -w /dev/kvm
    python3 - <<'PY'
import fcntl
import os
with open('/dev/kvm', 'rb+', buffering=0) as kvmFile:
    vmFd = fcntl.ioctl(kvmFile, 0xAE01, 0)
    os.close(vmFd)
PY
    # Run fresh VMs even when the Nix build/test result is cached.
    for testName in service user-service; do
      driverPath=$(nix build ".#checks.x86_64-linux.$testName.driver" --no-link --print-out-paths)
      mkdir -p "${RUNNER_TEMP:?}/vm-results/$testName" "$RUNNER_TEMP/vm-work/$testName"
      (
        cd "$RUNNER_TEMP/vm-work/$testName"
        "$driverPath/bin/nixos-test-driver" -o "$RUNNER_TEMP/vm-results/$testName" \
          --junit-xml "$RUNNER_TEMP/vm-results/$testName/junit.xml"
      ) 2>&1 | tee "$RUNNER_TEMP/vm-results/$testName/driver.log"
    done
    ;;
  *) echo 'Unknown suite' >&2; exit 1 ;;
esac
python3 scripts/ci.py record --artifact-dir "$artifactDir" --evidence-dir "$evidenceDir" --suite "$suite"
