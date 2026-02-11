#!/usr/bin/env bash
set -euo pipefail

results_file="$1"

# Values emitted by the fixture after it runs `patch_binaries`.
interpreter=""
expected_interpreter=""
rpath_multiarch=""
rpath_x86_64=""
rpath_amd64=""
rpath_lib64=""
expected_rpath_two_up=""
expected_rpath_one_up=""
expected_runtime_stdout=""
run_usrbin_rc=""
run_usrbin_stdout=""
run_usrbin_stderr=""
run_multiarch_rc=""
run_multiarch_stdout=""
run_multiarch_stderr=""
run_x86_64_rc=""
run_x86_64_stdout=""
run_x86_64_stderr=""
run_amd64_rc=""
run_amd64_stdout=""
run_amd64_stderr=""
run_lib64_rc=""
run_lib64_stdout=""
run_lib64_stderr=""

# Parse key/value outputs produced by the fixture repository rule.
while IFS='=' read -r key value; do
  case "${key}" in
    interpreter) interpreter="${value}" ;;
    interpreter_expected) expected_interpreter="${value}" ;;
    rpath_multiarch) rpath_multiarch="${value}" ;;
    rpath_x86_64) rpath_x86_64="${value}" ;;
    rpath_amd64) rpath_amd64="${value}" ;;
    rpath_lib64) rpath_lib64="${value}" ;;
    expected_rpath_two_up) expected_rpath_two_up="${value}" ;;
    expected_rpath_one_up) expected_rpath_one_up="${value}" ;;
    expected_runtime_stdout) expected_runtime_stdout="${value}" ;;
    run_usrbin_rc) run_usrbin_rc="${value}" ;;
    run_usrbin_stdout) run_usrbin_stdout="${value}" ;;
    run_usrbin_stderr) run_usrbin_stderr="${value}" ;;
    run_multiarch_rc) run_multiarch_rc="${value}" ;;
    run_multiarch_stdout) run_multiarch_stdout="${value}" ;;
    run_multiarch_stderr) run_multiarch_stderr="${value}" ;;
    run_x86_64_rc) run_x86_64_rc="${value}" ;;
    run_x86_64_stdout) run_x86_64_stdout="${value}" ;;
    run_x86_64_stderr) run_x86_64_stderr="${value}" ;;
    run_amd64_rc) run_amd64_rc="${value}" ;;
    run_amd64_stdout) run_amd64_stdout="${value}" ;;
    run_amd64_stderr) run_amd64_stderr="${value}" ;;
    run_lib64_rc) run_lib64_rc="${value}" ;;
    run_lib64_stdout) run_lib64_stdout="${value}" ;;
    run_lib64_stderr) run_lib64_stderr="${value}" ;;
  esac
done < "${results_file}"

# Assert fixture output is complete before evaluating specific expectations.
if [[ -z "${interpreter}" || -z "${expected_interpreter}" || -z "${expected_rpath_two_up}" || -z "${expected_rpath_one_up}" || -z "${expected_runtime_stdout}" ]]; then
  echo "Missing required keys in ${results_file}"
  cat "${results_file}"
  exit 1
fi

failed=0

# Assert interpreter rewrite: binaries should point to the sysroot loader.
if [[ "${interpreter}" != "${expected_interpreter}" ]]; then
  echo "Interpreter was not rewritten to sysroot loader path."
  echo "expected: ${expected_interpreter}"
  echo "actual:   ${interpreter}"
  failed=1
fi

# Assert RPATH rewrites for each placeholder expansion path.
if [[ "${rpath_multiarch}" != *"${expected_rpath_two_up}"* ]]; then
  echo "RPATH was not rewritten for an ELF under lib/x86_64-linux-gnu."
  echo "expected fragment: ${expected_rpath_two_up}"
  echo "actual rpath:      ${rpath_multiarch}"
  failed=1
fi

if [[ "${rpath_x86_64}" != *"${expected_rpath_two_up}"* ]]; then
  echo "RPATH was not rewritten for an ELF under lib/x86_64."
  echo "expected fragment: ${expected_rpath_two_up}"
  echo "actual rpath:      ${rpath_x86_64}"
  failed=1
fi

if [[ "${rpath_amd64}" != *"${expected_rpath_two_up}"* ]]; then
  echo "RPATH was not rewritten for an ELF under lib/amd64."
  echo "expected fragment: ${expected_rpath_two_up}"
  echo "actual rpath:      ${rpath_amd64}"
  failed=1
fi

if [[ "${rpath_lib64}" != *"${expected_rpath_one_up}"* ]]; then
  echo "RPATH was not rewritten for an ELF under lib64."
  echo "expected fragment: ${expected_rpath_one_up}"
  echo "actual rpath:      ${rpath_lib64}"
  failed=1
fi

# Assert runtime behavior: each patched binary must execute and resolve libs via patched paths.
if [[ "${run_usrbin_rc}" != "0" || "${run_usrbin_stdout}" != "${expected_runtime_stdout}" ]]; then
  echo "Patched executable under usr/bin did not run with sysroot RPATH."
  echo "rc:     ${run_usrbin_rc}"
  echo "stdout: ${run_usrbin_stdout}"
  echo "stderr: ${run_usrbin_stderr}"
  failed=1
fi

if [[ "${run_multiarch_rc}" != "0" || "${run_multiarch_stdout}" != "${expected_runtime_stdout}" ]]; then
  echo "Patched executable under lib/x86_64-linux-gnu did not run with sysroot RPATH."
  echo "rc:     ${run_multiarch_rc}"
  echo "stdout: ${run_multiarch_stdout}"
  echo "stderr: ${run_multiarch_stderr}"
  failed=1
fi

if [[ "${run_x86_64_rc}" != "0" || "${run_x86_64_stdout}" != "${expected_runtime_stdout}" ]]; then
  echo "Patched executable under lib/x86_64 did not run with sysroot RPATH."
  echo "rc:     ${run_x86_64_rc}"
  echo "stdout: ${run_x86_64_stdout}"
  echo "stderr: ${run_x86_64_stderr}"
  failed=1
fi

if [[ "${run_amd64_rc}" != "0" || "${run_amd64_stdout}" != "${expected_runtime_stdout}" ]]; then
  echo "Patched executable under lib/amd64 did not run with sysroot RPATH."
  echo "rc:     ${run_amd64_rc}"
  echo "stdout: ${run_amd64_stdout}"
  echo "stderr: ${run_amd64_stderr}"
  failed=1
fi

if [[ "${run_lib64_rc}" != "0" || "${run_lib64_stdout}" != "${expected_runtime_stdout}" ]]; then
  echo "Patched executable under lib64 did not run with sysroot RPATH."
  echo "rc:     ${run_lib64_rc}"
  echo "stdout: ${run_lib64_stdout}"
  echo "stderr: ${run_lib64_stderr}"
  failed=1
fi

# Fail if any assertion above did not hold.
exit "${failed}"
