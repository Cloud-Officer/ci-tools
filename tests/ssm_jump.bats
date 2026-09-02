#!/usr/bin/env bats

setup() {
  export PATH="${BATS_TEST_DIRNAME}/../:${PATH}"
}

# Stubs the AWS CLI so no test reaches the network: describe-instances yields the
# given instance lines, start-session reports what it was asked to connect to.
# This has to be a real executable on PATH rather than a shell function, because
# ssm-jump reaches the session through `exec aws ...` and exec does not run
# functions.
stub_aws() {
  local bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${bin}"
  printf '%s\n' "${@:-i-1234567890abcdef 10.0.0.1 some-host}" > "${BATS_TEST_TMPDIR}/instances"

  cat > "${bin}/aws" <<'AWS'
#!/usr/bin/env bash
for arg in "$@"; do
  case "${arg}" in
    ec2)
      cat "${BATS_TEST_TMPDIR}/instances"
      exit 0
      ;;
    ssm)
      echo "aws stub invoked: $*"
      exit 0
      ;;
  esac
done
AWS

  chmod +x "${bin}/aws"
  export PATH="${bin}:${PATH}"
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
  # `target` matches the tag-name branch, so without a stub this shells out to the
  # real `aws ec2 describe-instances`. Stub it and assert the exit status, rather
  # than asserting only on a substring of whatever the real CLI happened to print.
  stub_aws
  run ssm-jump -p myprofile -d "My-Valid_Doc123" target
  [ "$status" -eq 0 ]
  [[ "$output" != *"Invalid document name"* ]]
  [[ "$output" == *"aws stub invoked:"* ]]
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
  # The instance-ID branch skips the lookup but still execs `aws ssm start-session`.
  stub_aws
  run ssm-jump -p myprofile i-1234567890abcdef
  [ "$status" -eq 0 ]
  [[ "$output" == *"using instance ID"* ]]
  [[ "$output" == *"--target i-1234567890abcdef"* ]]
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

@test "reports a missing option value through fatal, not a bash unbound-variable abort" {
  for flag in -f --forward -c --proxy-command -p --profile -d --document; do
    run ssm-jump "${flag}"
    [ "$status" -eq 1 ]
    # The script's own error, never bash's "$2: unbound variable".
    [[ "$output" == *"requires a value"* ]]
    [[ "$output" != *"unbound variable"* ]]
  done
}

@test "reports a closed stdin instead of dying silently at the selection prompt" {
  # Two instances force the interactive prompt; stdin is closed, so `read` hits EOF.
  stub_aws "i-1111111111111111 10.0.0.1 host-a" "i-2222222222222222 10.0.0.2 host-b"

  run ssm-jump -p myprofile some-host < /dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"stdin closed before a line was chosen"* ]]
  [[ "$output" == *"--autoselect-first"* ]]
}

@test "autoselect-first skips the prompt when several instances match" {
  stub_aws "i-1111111111111111 10.0.0.1 host-a" "i-2222222222222222 10.0.0.2 host-b"

  run ssm-jump -p myprofile --autoselect-first some-host < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"i-1111111111111111"* ]]
  [[ "$output" != *"Connect to what line"* ]]
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

# The two formatting guards that used to live here (tabs, `[ ! -z ]`) are gone:
# `linters` now discovers extensionless shell scripts by shebang, so shellcheck
# and the custom SL rules cover this file directly (issue #524).
