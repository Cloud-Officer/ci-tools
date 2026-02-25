#!/usr/bin/env bats

setup() {
  export PATH="${BATS_TEST_DIRNAME}/../:${PATH}"
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

@test "exits with error when JIRA_BASE_URL is empty" {
  export JIRA_BASE_URL=""

  function jira() { :; }
  function gh() { :; }
  export -f jira gh

  run sync-jira-release tag1 tag2 release1
  [ "$status" -eq 1 ]
  [[ "$output" == *"Required environment variables"* ]]
}
