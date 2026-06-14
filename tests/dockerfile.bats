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
