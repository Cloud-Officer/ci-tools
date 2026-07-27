#!/usr/bin/env bats

setup() {
  README="${BATS_TEST_DIRNAME}/../README.md"
}

# The README is published publicly (GitHub, Docker Hub, Homebrew), so its
# examples must only ever contain placeholder data. Real addresses, instance
# ids and hostnames are personal-data exposure and give attackers
# reconnaissance hints about client infrastructure (see issue #503).

@test "README contains no non-placeholder email addresses" {
  run bash -c "grep -oE '[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}' '${README}' | grep -vE '@(example|company)\.com$' || true"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "README contains no real EC2 instance ids" {
  run bash -c "grep -oE '\bi-[[:xdigit:]]{17}\b' '${README}' | grep -vE '^i-0123456789abcdef[[:digit:]]$' || true"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "README contains no real private IP addresses" {
  run bash -c "grep -oE '\b([[:digit:]]{1,3}\.){3}[[:digit:]]{1,3}\b' '${README}' | grep -vE '^(10\.0\.0\.[[:digit:]]+|127\.0\.0\.1)$' || true"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "README ssm-jump forward example targets a placeholder hostname" {
  run bash -c "grep -E '^ssm-jump .*--forward' '${README}'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"db.example.com:6033:6033"* ]]
}

@test "README contains no production hostnames in examples" {
  run bash -c "grep -inE '(portablenorthpole|innodemneurosciences)\.com' '${README}' || true"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
