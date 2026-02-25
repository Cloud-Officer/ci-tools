#!/usr/bin/env bats

setup() {
  export PATH="${BATS_TEST_DIRNAME}/../:${PATH}"
  TEST_DIR=$(mktemp -d)
  cd "${TEST_DIR}"
}

teardown() {
  rm -rf "${TEST_DIR}"
}

@test "passes when no config files are present" {
  # shopt -s globstar requires bash 4+; skip if system bash is older
  if ! bash -c 'shopt -s globstar' 2>/dev/null; then
    skip "bash 4+ required for globstar support"
  fi

  run linters
  [ "$status" -eq 0 ]
  [[ "$output" == *"All checks passed"* ]]
}

@test "reports swiftlint unsupported on non-Darwin" {
  if uname -s | grep -q Darwin; then
    skip "swiftlint is supported on macOS"
  fi

  touch .swiftlint.yml
  run linters
  [ "$status" -eq 1 ]
  [[ "$output" == *"only supported on MacOS"* ]]
}
