#!/usr/bin/env bats

setup() {
  export PATH="${BATS_TEST_DIRNAME}/../:${PATH}"
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
