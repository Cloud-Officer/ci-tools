#!/usr/bin/env bats

setup() {
  export PATH="${BATS_TEST_DIRNAME}/../:${PATH}"
  export JIRA_USER_EMAIL="test@example.com"
  export JIRA_API_TOKEN="test-token"
  export GITHUB_TOKEN="test-token"
  export JIRA_BASE_URL="https://test.atlassian.net"
}

@test "exits with error when wrong number of arguments" {
  # Mock jira and gh as available
  function jira() { :; }
  function gh() { :; }
  export -f jira gh

  run sync-jira-release tag1 tag2
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "exits with error when no arguments provided" {
  function jira() { :; }
  function gh() { :; }
  export -f jira gh

  run sync-jira-release
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "exits with error when JIRA_USER_EMAIL is empty" {
  export JIRA_USER_EMAIL=""

  function jira() { :; }
  function gh() { :; }
  export -f jira gh

  run sync-jira-release tag1 tag2 release1
  [ "$status" -eq 1 ]
  [[ "$output" == *"Required environment variables"* ]]
}

@test "exits with error when JIRA_API_TOKEN is empty" {
  export JIRA_API_TOKEN=""

  function jira() { :; }
  function gh() { :; }
  export -f jira gh

  run sync-jira-release tag1 tag2 release1
  [ "$status" -eq 1 ]
  [[ "$output" == *"Required environment variables"* ]]
}

@test "exits with error when GITHUB_TOKEN is empty" {
  export GITHUB_TOKEN=""

  function jira() { :; }
  function gh() { :; }
  export -f jira gh

  run sync-jira-release tag1 tag2 release1
  [ "$status" -eq 1 ]
  [[ "$output" == *"Required environment variables"* ]]
}

@test "exits with error for unsupported architecture" {
  # Override uname to return unsupported architecture
  function uname() {
    if [ "${1}" = "-s" ]; then echo "Linux"; elif [ "${1}" = "-m" ]; then echo "ppc64le"; else command uname "$@"; fi
  }
  export -f uname

  # Make jira unavailable to trigger auto-install path
  function jira() { return 1; }
  function command() {
    if [ "${1}" = "-v" ] && [ "${2}" = "jira" ]; then return 1; fi
    builtin command "$@"
  }
  export -f jira command

  run sync-jira-release tag1 tag2 release1
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unsupported architecture"* ]]
}

@test "exits with error when JIRA_BASE_URL is empty" {
  export JIRA_BASE_URL=""

  function jira() { :; }
  function gh() { :; }
  export -f jira gh

  run sync-jira-release tag1 tag2 release1
  [ "$status" -eq 1 ]
  [[ "$output" == *"Required environment variables"* ]]
}

@test "exits with error when checksum verification fails on jira CLI download" {
  # Force the auto-install path: pretend jira is not installed.
  function command() {
    if [ "${1}" = "-v" ] && [ "${2}" = "jira" ]; then return 1; fi
    builtin command "$@"
  }
  export -f command

  # Stub curl: first call returns a release-list JSON, second writes a junk
  # archive, third writes a checksum file pointing at a known-wrong sha256.
  CURL_CALL_FILE=$(mktemp)
  export CURL_CALL_FILE
  echo 0 > "${CURL_CALL_FILE}"

  function curl() {
    local call_number
    call_number=$(cat "${CURL_CALL_FILE}")
    call_number=$((call_number + 1))
    echo "${call_number}" > "${CURL_CALL_FILE}"

    # Find the -o argument (output file) if present
    local out_file=""
    while [ "$#" -gt 0 ]; do
      if [ "${1}" = "-o" ]; then
        out_file="${2}"
        shift 2
        continue
      fi
      shift
    done

    case "${call_number}" in
      1)
        # Release-list JSON (sed -E '...' will extract v1.5.0)
        echo '"tag_name": "v1.5.0"'
        ;;
      2)
        # The archive — junk bytes; its real sha256 will not match what we
        # publish in the checksum file below.
        printf 'tampered bytes' > "${out_file}"
        ;;
      3)
        # Checksum file claiming a sha256 that does NOT match `printf 'tampered bytes'`.
        printf '0000000000000000000000000000000000000000000000000000000000000000  jira_1.5.0_linux_x86_64.tar.gz\n' > "${out_file}"
        ;;
    esac
  }
  export -f curl

  # Architecture/OS detection: force a supported pair so we reach the checksum step.
  function uname() {
    if [ "${1}" = "-s" ]; then echo "Linux"
    elif [ "${1}" = "-m" ]; then echo "x86_64"
    else builtin uname "$@"
    fi
  }
  export -f uname

  run sync-jira-release tag1 tag2 release1
  rm -f "${CURL_CALL_FILE}"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Checksum verification failed"* ]]
}

@test "validates arguments before running the jira CLI install" {
  # jira absent, so the bootstrap would run -- but bad arguments must stop the
  # script first. Previously the 88-line download ran before any validation.
  function command() {
    if [ "${1}" = "-v" ] && [ "${2}" = "jira" ]; then return 1; fi
    builtin command "$@"
  }

  function curl() { echo "curl invoked: $*"; }
  export -f command curl

  run sync-jira-release tag1 tag2
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" != *"jira CLI not found"* ]]
  [[ "$output" != *"curl invoked"* ]]
}

@test "validates the environment before running the jira CLI install" {
  export JIRA_BASE_URL=""

  function command() {
    if [ "${1}" = "-v" ] && [ "${2}" = "jira" ]; then return 1; fi
    builtin command "$@"
  }

  function curl() { echo "curl invoked: $*"; }
  export -f command curl

  run sync-jira-release tag1 tag2 release1
  [ "$status" -eq 1 ]
  [[ "$output" == *"Required environment variables"* ]]
  [[ "$output" != *"curl invoked"* ]]
}

@test "succeeds on a host with no xdg-open once every issue is updated" {
  # A headless Linux box has no xdg-open. Every Jira issue has already been
  # updated by the time the report is opened, so this must not fail the run.
  function uname() { echo "Linux"; }

  function jira() {
    case "${1}" in
      release) printf 'header\n10001\trelease1\n' ;;
      *) : ;;
    esac
  }

  function gh() { echo "octocat/hello"; }
  function git() {
    case "${1}" in
      rev-parse) return 0 ;;
      log) echo "abc1234 Some change (#42)" ;;
      *) builtin command git "$@" ;;
    esac
  }

  function xdg-open() { return 127; }
  function command() {
    if [ "${1}" = "-v" ] && [ "${2}" = "xdg-open" ]; then return 1; fi
    builtin command "$@"
  }

  export -f uname jira gh git xdg-open command

  cd "${BATS_TEST_TMPDIR}"
  mkdir -p .github
  printf '[DEV-XXXX](https://x.atlassian.net/browse/DEV-XXXX)\n' > .github/pull_request_template.md

  run sync-jira-release tag1 tag2 release1
  [ "$status" -eq 0 ]
  [[ "$output" == *"No xdg-open on this host"* ]]
  [[ "$output" == *"release-report-all-issues"* ]]
}
