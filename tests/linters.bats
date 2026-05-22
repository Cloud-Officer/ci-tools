#!/usr/bin/env bats

setup() {
  export PATH="${BATS_TEST_DIRNAME}/../:${PATH}"
  TEST_DIR=$(mktemp -d)
  cd "${TEST_DIR}"
}

teardown() {
  rm -rf "${TEST_DIR}"
}

skip_unless_globstar() {
  if ! bash -c 'shopt -s globstar' 2>/dev/null; then
    skip "bash 4+ required for globstar support"
  fi
}

# Stubs each linter binary as a no-op shell function so the script can be
# exercised without the real tools installed. The stubs are exported into the
# `run` subshell so the linters script sees them on its PATH lookup.
stub_all_linters() {
  for cmd in actionlint markdownlint-cli2 yamllint shellcheck hadolint cfn-lint \
             golangci-lint pmd eslint ktlint bandit flake8 protolint rubocop \
             semgrep trivy swiftlint; do
    eval "function ${cmd}() { :; }; export -f ${cmd}"
  done
}

@test "passes when no config files are present" {
  skip_unless_globstar
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

@test "runs actionlint when workflow files are present" {
  skip_unless_globstar
  mkdir -p .github/workflows
  echo "---" > .github/workflows/build.yml

  function actionlint() { echo "actionlint invoked"; }
  export -f actionlint

  run linters
  [ "$status" -eq 0 ]
  [[ "$output" == *"actionlint invoked"* ]]
  [[ "$output" == *"Checking GitHub Actions workflow files"* ]]
}

@test "runs markdownlint-cli2 when its config is present" {
  skip_unless_globstar
  touch .markdownlint-cli2.yaml

  function markdownlint-cli2() { echo "markdownlint invoked: $*"; }
  export -f markdownlint-cli2

  run linters
  [ "$status" -eq 0 ]
  [[ "$output" == *"markdownlint invoked"* ]]
  [[ "$output" == *"Checking Markdown"* ]]
}

@test "runs yamllint when its config is present" {
  skip_unless_globstar
  touch .yamllint.yml

  function yamllint() { echo "yamllint invoked: $*"; }
  export -f yamllint

  run linters
  [ "$status" -eq 0 ]
  [[ "$output" == *"yamllint invoked"* ]]
  [[ "$output" == *"Checking YAML"* ]]
}

@test "runs rubocop when its config is present" {
  skip_unless_globstar
  touch .rubocop.yml

  function rubocop() { echo "rubocop invoked: $*"; }
  export -f rubocop

  run linters
  [ "$status" -eq 0 ]
  [[ "$output" == *"rubocop invoked"* ]]
  [[ "$output" == *"Checking Ruby"* ]]
}

@test "reports failure when a linter exits non-zero" {
  skip_unless_globstar
  touch .yamllint.yml

  function yamllint() { return 1; }
  export -f yamllint

  run linters
  [ "$status" -eq 1 ]
  [[ "$output" == *"Some checks failed"* ]]
}

@test "runs multiple linters when multiple configs are present" {
  skip_unless_globstar
  mkdir -p .github/workflows
  echo "---" > .github/workflows/build.yml
  touch .yamllint.yml .rubocop.yml

  stub_all_linters

  run linters
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checking GitHub Actions workflow files"* ]]
  [[ "$output" == *"Checking YAML"* ]]
  [[ "$output" == *"Checking Ruby"* ]]
  [[ "$output" == *"All checks passed"* ]]
}

@test "aggregates failures across linters and still reports each" {
  skip_unless_globstar
  touch .yamllint.yml .rubocop.yml

  function yamllint() { return 1; }
  function rubocop() { return 1; }
  export -f yamllint rubocop

  run linters
  [ "$status" -eq 1 ]
  [[ "$output" == *"Checking YAML"* ]]
  [[ "$output" == *"Checking Ruby"* ]]
  [[ "$output" == *"Some checks failed"* ]]
}

@test "runs the built-in shell rules after shellcheck" {
  skip_unless_globstar
  touch .shellcheckrc
  cat > clean.sh <<'SH'
#!/usr/bin/env bash
echo "${ok}"
SH

  function shellcheck() { echo "shellcheck invoked"; }
  export -f shellcheck

  run linters
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checking shell scripts..."* ]]
  [[ "$output" == *"shellcheck invoked"* ]]
  [[ "$output" == *"Checking shell scripts (custom rules)..."* ]]
  [[ "$output" == *"All checks passed"* ]]
}

@test "SL0001 flags an unbraced \$var" {
  skip_unless_globstar
  touch .shellcheckrc
  cat > script.sh <<'SH'
#!/usr/bin/env bash
echo $foo
SH

  function shellcheck() { :; }
  export -f shellcheck

  run linters
  [ "$status" -eq 1 ]
  [[ "$output" == *"SL0001"* ]]
  [[ "$output" == *"script.sh line 2"* ]]
  [[ "$output" == *"Some checks failed"* ]]
}

@test "SL0002 flags a single = inside [ ... ]" {
  skip_unless_globstar
  touch .shellcheckrc
  cat > script.sh <<'SH'
#!/usr/bin/env bash
if [ "${x}" = "y" ]; then :; fi
SH

  function shellcheck() { :; }
  export -f shellcheck

  run linters
  [ "$status" -eq 1 ]
  [[ "$output" == *"SL0002"* ]]
  [[ "$output" == *"Some checks failed"* ]]
}

@test "built-in shell rules ignore quotes, escapes and comments" {
  skip_unless_globstar
  touch .shellcheckrc
  cat > script.sh <<'SH'
#!/usr/bin/env bash
echo '$single'
echo \$escaped
# a $commented var
echo "${braced}"
if [ "${x}" == "y" ]; then :; fi
SH

  function shellcheck() { :; }
  export -f shellcheck

  run linters
  [ "$status" -eq 0 ]
  [[ "$output" != *"SL0001"* ]]
  [[ "$output" != *"SL0002"* ]]
  [[ "$output" == *"All checks passed"* ]]
}

@test "built-in shell rules honor # shellcheck disable=all" {
  skip_unless_globstar
  touch .shellcheckrc
  cat > script.sh <<'SH'
#!/usr/bin/env bash
# shellcheck disable=all
echo $foo
SH

  function shellcheck() { :; }
  export -f shellcheck

  run linters
  [ "$status" -eq 0 ]
  [[ "$output" != *"SL0001"* ]]
  [[ "$output" == *"All checks passed"* ]]
}
