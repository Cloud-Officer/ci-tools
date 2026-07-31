#!/usr/bin/env bats

setup() {
  DOCKERFILE="${BATS_TEST_DIRNAME}/../Dockerfile"
}

# The Dockerfile symlinks all tools into /usr/local/bin, so the image must also
# install the runtime dependencies those tools invoke (see issue #500).

@test "installs jq (required by ssm-jump --forward and generate-codeowners)" {
  grep -qE '^[[:space:]]*jq[[:space:]]*\\?$' "${DOCKERFILE}"
}

@test "installs pipx (required by linters cfn-lint/semgrep self-install)" {
  grep -qE '^[[:space:]]*pipx[[:space:]]*\\?$' "${DOCKERFILE}"
}

@test "installs golang (required by linters actionlint/golangci-lint/protolint self-install)" {
  grep -qE '^[[:space:]]*golang[[:space:]]*\\?$' "${DOCKERFILE}"
}

# hadolint 2.15 turned two long-standing spellings in this file into build
# failures, and the Docker Linter job runs at LEVEL=info with FAIL_LEVEL=any, so
# either one reappearing blocks every PR in the repo. These pin the fixed form.

@test "every USER is a numeric uid (hadolint DL3066)" {
  ! grep -qE '^USER[[:space:]]+[^0-9]' "${DOCKERFILE}"
}

@test "the citools uid is pinned so the numeric USER cannot drift" {
  grep -qE 'useradd .*-u 1001' "${DOCKERFILE}"
  grep -qE '^USER 1001$' "${DOCKERFILE}"
}

@test "HEALTHCHECK uses JSON notation (hadolint DL3025)" {
  grep -qE '^HEALTHCHECK .* CMD \[' "${DOCKERFILE}"
}
