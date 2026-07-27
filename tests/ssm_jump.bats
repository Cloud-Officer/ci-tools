#!/usr/bin/env bats

setup() {
  export PATH="${BATS_TEST_DIRNAME}/../:${PATH}"
  SSM_JUMP="${BATS_TEST_DIRNAME}/../ssm-jump"
}

@test "exits with error when no profile specified" {
  run ssm-jump target
  [ "$status" -eq 1 ]
  [[ "$output" == *"No profile specified"* ]]
}

@test "exits with error when no target specified" {
  run ssm-jump -p myprofile
  [ "$status" -eq 1 ]
  [[ "$output" == *"No target specified"* ]]
}

@test "exits with error for invalid document name" {
  run ssm-jump -p myprofile -d "invalid doc name!" target
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid document name"* ]]
}

@test "accepts valid document name with alphanumeric, dash, and underscore" {
  # Will fail at AWS lookup but should not fail on document validation
  run ssm-jump -p myprofile -d "My-Valid_Doc123" target
  [[ "$output" != *"Invalid document name"* ]]
}

@test "exits with error for forward string with wrong number of parts" {
  run ssm-jump -p myprofile -f "host:port" target
  [ "$status" -eq 1 ]
  [[ "$output" == *"needs exactly 3 parts"* ]]
}

@test "exits with error for forward string with too many parts" {
  run ssm-jump -p myprofile -f "host:1:2:3" target
  [ "$status" -eq 1 ]
  [[ "$output" == *"needs exactly 3 parts"* ]]
}

@test "accepts forward string with exactly 3 parts" {
  # Forward validation runs before target lookup, so an invalid target proves
  # the 3-part forward string was accepted without reaching AWS.
  run ssm-jump -p myprofile -f "host:1234:5678" "INVALID_TARGET!"
  [ "$status" -eq 1 ]
  [[ "$output" != *"needs exactly 3 parts"* ]]
  [[ "$output" == *"Invalid target"* ]]
}

@test "skips forward validation when no forward string is given" {
  run ssm-jump -p myprofile "INVALID_TARGET!"
  [ "$status" -eq 1 ]
  [[ "$output" != *"needs exactly 3 parts"* ]]
}

@test "skips forward validation when the forward string is empty" {
  run ssm-jump -p myprofile -f "" "INVALID_TARGET!"
  [ "$status" -eq 1 ]
  [[ "$output" != *"needs exactly 3 parts"* ]]
  [[ "$output" == *"Invalid target"* ]]
}

@test "exits with error for invalid target format" {
  run ssm-jump -p myprofile "INVALID_TARGET!"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid target"* ]]
}

@test "accepts instance ID target format" {
  # Will fail at AWS call but should pass target validation
  run ssm-jump -p myprofile i-1234567890abcdef
  [[ "$output" == *"using instance ID"* ]]
}

@test "exits with error when the lookup returns no instance" {
  # Stub the AWS CLI with a no-op so describe-instances yields nothing; exported
  # into the `run` subshell so ssm-jump picks it up instead of the real binary.
  function aws() { :; }
  export -f aws

  run ssm-jump -p myprofile some-host
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unable to detect any instance for target some-host"* ]]
}

@test "prints help message" {
  run ssm-jump -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: ssm-jump"* ]]
}

@test "prints help with --help flag" {
  run ssm-jump --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: ssm-jump"* ]]
}

# ssm-jump is extensionless, so the house shell lint (which only scans *.sh)
# never sees it. These guards pin the file's formatting conventions instead
# (see issue #524).

@test "is indented with spaces only (no literal tab characters)" {
  run grep -n "$(printf '\t')" "${SSM_JUMP}"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "uses [ -n ] rather than [ ! -z ] for non-empty string tests" {
  run grep -nF '! -z' "${SSM_JUMP}"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}
