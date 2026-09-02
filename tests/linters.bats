#!/usr/bin/env bats

setup() {
  export PATH="${BATS_TEST_DIRNAME}/../:${PATH}"
  TEST_DIR=$(mktemp -d)
  cd "${TEST_DIR}"
}

teardown() {
  rm -rf "${TEST_DIR}"
}

# `linters` re-execs itself under a newer bash when the ambient one predates 4.0
# (macOS ships 3.2), so these tests don't care which bash is first on PATH -- only
# that a modern one exists somewhere for the re-exec to land on.
skip_unless_bash4() {
  for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash; do
    # shellcheck disable=SC2016
    if [ -x "${candidate}" ] && [ "$("${candidate}" -c 'echo ${BASH_VERSINFO[0]}')" -ge 4 ]; then
      return 0
    fi
  done

  skip "bash 4+ required (none found for linters to re-exec into)"
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
  skip_unless_bash4
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
  skip_unless_bash4
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
  skip_unless_bash4
  touch .markdownlint-cli2.yaml

  function markdownlint-cli2() { echo "markdownlint invoked: $*"; }
  export -f markdownlint-cli2

  run linters
  [ "$status" -eq 0 ]
  [[ "$output" == *"markdownlint invoked"* ]]
  [[ "$output" == *"Checking Markdown"* ]]
}

@test "bootstraps npm before installing markdownlint-cli2 on Linux" {
  skip_unless_bash4
  touch .markdownlint-cli2.yaml

  export HOME="${TEST_DIR}/home"
  mkdir -p "${HOME}/bin"
  ln -s "$(command -v bash)" "${HOME}/bin/bash"
  export PATH="${BATS_TEST_DIRNAME}/../:${HOME}/bin:/usr/bin:/bin"

  function uname() { echo "Linux"; }

  # npm deliberately absent. The old `elif command -v npm` shape silently skipped
  # the install here and then failed on the missing binary; npm_install must
  # bootstrap npm through apt instead.
  # markdownlint-cli2 is deliberately NOT stubbed up front: the install branch only
  # runs when the binary is absent. apt drops in npm, npm drops in the linter.
  function sudo() {
    echo "sudo invoked: $*"

    if [[ "$*" == *"install"*"npm"* ]]; then
      cat > "${HOME}/bin/npm" <<'NPM'
#!/usr/bin/env bash
echo "npm invoked: $*"

if [[ "$*" == *"markdownlint-cli2"* ]]; then
  cat > "${HOME}/bin/markdownlint-cli2" <<'MDL'
#!/usr/bin/env bash
echo "markdownlint invoked: $*"
MDL
  chmod 0755 "${HOME}/bin/markdownlint-cli2"
fi
NPM
      chmod 0755 "${HOME}/bin/npm"
    fi
  }

  export -f uname sudo

  run linters
  [ "$status" -eq 0 ]
  [[ "$output" == *"install --no-install-recommends npm"* ]]
  [[ "$output" == *"npm invoked: install -g markdownlint-cli2"* ]]
  [[ "$output" == *"markdownlint invoked"* ]]
}

@test "installs bandit under its apt package name on Linux" {
  skip_unless_bash4
  touch .bandit

  export HOME="${TEST_DIR}/home"
  mkdir -p "${HOME}/bin"
  ln -s "$(command -v bash)" "${HOME}/bin/bash"
  export PATH="${BATS_TEST_DIRNAME}/../:${HOME}/bin:/usr/bin:/bin"

  function uname() { echo "Linux"; }

  function sudo() {
    echo "sudo invoked: $*"
    cat > "${HOME}/bin/bandit" <<'BANDIT'
#!/usr/bin/env bash
echo "bandit invoked: $*"
BANDIT
    chmod 0755 "${HOME}/bin/bandit"
  }

  export -f uname sudo

  run linters
  [ "$status" -eq 0 ]
  # brew name is bandit, apt name is python3-bandit -- the override must be used.
  [[ "$output" == *"install --no-install-recommends python3-bandit"* ]]
  [[ "$output" == *"bandit invoked"* ]]
}

@test "taps the protolint formula on macOS before installing" {
  skip_unless_bash4

  if [ "$(uname -s)" != "Darwin" ]; then
    skip "protolint tap only applies on macOS"
  fi

  touch .protolint.yaml

  export HOME="${TEST_DIR}/home"
  mkdir -p "${HOME}/bin"
  ln -s "$(command -v bash)" "${HOME}/bin/bash"
  export PATH="${BATS_TEST_DIRNAME}/../:${HOME}/bin:/usr/bin:/bin"

  function brew() {
    echo "brew invoked: $*"
    cat > "${HOME}/bin/protolint" <<'PROTO'
#!/usr/bin/env bash
echo "protolint invoked: $*"
PROTO
    chmod 0755 "${HOME}/bin/protolint"
  }

  export -f brew

  run linters
  [ "$status" -eq 0 ]
  [[ "$output" == *"brew invoked: tap yoheimuta/protolint"* ]]
  [[ "$output" == *"brew invoked: install protolint"* ]]
}

@test "find_lintable excludes generated and vendored directories" {
  skip_unless_bash4
  touch .hadolint.yaml
  # One Dockerfile in each directory the canonical ghb:excluded-dirs list covers
  # but the old 12-entry filter missed, plus a real one that must still be found.
  mkdir -p coverage .bundle __pycache__ .gradle .yarn env node_modules
  touch coverage/Dockerfile .bundle/Dockerfile __pycache__/Dockerfile \
    .gradle/Dockerfile .yarn/Dockerfile env/Dockerfile node_modules/Dockerfile Dockerfile

  function hadolint() { echo "hadolint invoked: $*"; }
  export -f hadolint

  run linters
  [ "$status" -eq 0 ]
  [[ "$output" == *"hadolint invoked: ./Dockerfile"* ]]
  [[ "$output" != *"coverage/Dockerfile"* ]]
  [[ "$output" != *".bundle/Dockerfile"* ]]
  [[ "$output" != *"__pycache__/Dockerfile"* ]]
  [[ "$output" != *".gradle/Dockerfile"* ]]
  [[ "$output" != *".yarn/Dockerfile"* ]]
  [[ "$output" != *"env/Dockerfile"* ]]
  [[ "$output" != *"node_modules/Dockerfile"* ]]
}

@test "runs yamllint when its config is present" {
  skip_unless_bash4
  touch .yamllint.yml

  function yamllint() { echo "yamllint invoked: $*"; }
  export -f yamllint

  run linters
  [ "$status" -eq 0 ]
  [[ "$output" == *"yamllint invoked"* ]]
  [[ "$output" == *"Checking YAML"* ]]
}

@test "installs golangci-lint from the v2 module path on Linux" {
  skip_unless_bash4
  touch .golangci.yml

  # Isolate HOME so the install branch writes into the temp dir, and trim PATH
  # to system dirs so a host-installed golangci-lint can't satisfy `command -v`
  # and skip the auto-install branch we want to exercise. Symlink the current
  # interpreter into a private bin dir that holds no golangci-lint so the trimmed
  # PATH still resolves a bash for the script's shebang.
  export HOME="${TEST_DIR}/home"
  mkdir -p "${HOME}/go/bin" "${HOME}/bin"
  ln -s "$(command -v bash)" "${HOME}/bin/bash"
  export PATH="${BATS_TEST_DIRNAME}/../:${HOME}/bin:/usr/bin:/bin"

  # Force the non-Darwin (Linux) install branch.
  function uname() { echo "Linux"; }
  export -f uname

  # Capture the module path `go install` is asked to fetch, and drop a runnable
  # golangci-lint into HOME/go/bin so the subsequent `golangci-lint run` succeeds.
  function go() {
    echo "go invoked: $*"
    cat > "${HOME}/go/bin/golangci-lint" <<'EOF'
#!/usr/bin/env bash
echo "golangci-lint invoked: $*"
EOF
    chmod +x "${HOME}/go/bin/golangci-lint"
  }
  export -f go

  run linters
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checking Go..."* ]]
  [[ "$output" == *"github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest"* ]]
  [[ "$output" == *"golangci-lint invoked: run"* ]]
}

@test "installs cfn-lint via pipx (not bare pip3) on Linux" {
  skip_unless_bash4
  touch .cfnlintrc

  # Isolate HOME and trim PATH (same rationale as the golangci-lint test) so the
  # auto-install branch runs and a host-installed cfn-lint/pipx can't short-circuit it.
  export HOME="${TEST_DIR}/home"
  mkdir -p "${HOME}/.local/bin" "${HOME}/bin"
  ln -s "$(command -v bash)" "${HOME}/bin/bash"
  export PATH="${BATS_TEST_DIRNAME}/../:${HOME}/bin:/usr/bin:/bin"

  # Force the non-Darwin (Linux) install branch.
  function uname() { echo "Linux"; }
  export -f uname

  # Stub pipx: record the install request and drop a runnable cfn-lint into the
  # pipx bin dir so the subsequent `cfn-lint ...` call succeeds. Its presence as
  # a function also satisfies `command -v pipx`, so the apt bootstrap is skipped.
  function pipx() {
    echo "pipx invoked: $*"
    cat > "${HOME}/.local/bin/cfn-lint" <<'EOF'
#!/usr/bin/env bash
echo "cfn-lint invoked: $*"
EOF
    chmod +x "${HOME}/.local/bin/cfn-lint"
  }
  export -f pipx

  run linters
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checking CloudFormation templates..."* ]]
  [[ "$output" == *"pipx invoked: install cfn-lint"* ]]
  [[ "$output" == *"cfn-lint invoked: --non-zero-exit-code error"* ]]
  [[ "$output" != *"pip3 install"* ]]
}

# Shared scaffolding for the hadolint Linux install branch. Stubs the download so
# no network is touched, and makes any attempt to write under /usr/local fail the
# way it does for a non-root user, so an unprivileged install path is required.
stub_hadolint_download() {
  export HOME="${TEST_DIR}/home"
  mkdir -p "${HOME}/bin"
  ln -s "$(command -v bash)" "${HOME}/bin/bash"
  export PATH="${BATS_TEST_DIRNAME}/../:${HOME}/bin:/usr/bin:/bin"

  # Force the non-Darwin (Linux) install branch. `uname -m` has to answer too:
  # the asset name is now arch-suffixed. STUB_ARCH lets a test pick the machine.
  function uname() {
    if [ "${1}" == "-m" ]; then
      echo "${STUB_ARCH:-x86_64}"
    else
      echo "Linux"
    fi
  }

  # The bytes the fake release download hands back: a runnable hadolint stub.
  function write_hadolint_payload() {
    cat > "${1}" <<'EOF'
#!/usr/bin/env bash
echo "hadolint invoked: $*"
EOF
  }

  function hadolint_payload_sha() {
    local tmp
    tmp=$(mktemp)
    write_hadolint_payload "${tmp}"

    if command -v sha256sum &>/dev/null; then
      sha256sum "${tmp}" | awk '{print $1}'
    else
      shasum -a 256 "${tmp}" | awk '{print $1}'
    fi

    rm -f "${tmp}"
  }

  # `wget -qO <dest> <url>` for the binary, `wget -qO - <url>` for the checksum.
  # The trace goes to stderr (which bats folds into $output) so it can't pollute
  # the checksum the script reads off this stub's stdout.
  function wget() {
    echo "wget invoked: $*" >&2

    if [ "${2}" == "-" ]; then
      local sha="${PUBLISHED_CHECKSUM:-$(hadolint_payload_sha)}"
      # Mirrors the real checksums.sha256: every asset, one per line, "<hash> *<name>".
      echo "${sha} *hadolint-linux-${STUB_ARCH:-x86_64}"
      echo "0000000000000000000000000000000000000000000000000000000000000000 *hadolint-macos-x86_64"

      return 0
    fi

    case "${2}" in
      /usr/local/*)
        echo "wget: ${2}: Permission denied" >&2
        return 1
        ;;
    esac

    write_hadolint_payload "${2}"
  }

  # Record the elevated call and land the binary somewhere writable instead of
  # /usr/local/bin, so the test never needs real root.
  function sudo() {
    echo "sudo invoked: $*"

    if [ "${1}" == "install" ]; then
      cp "${4}" "${HOME}/bin/hadolint"
      chmod 0755 "${HOME}/bin/hadolint"
    fi
  }

  export -f uname write_hadolint_payload hadolint_payload_sha wget sudo
}

@test "installs hadolint via sudo instead of writing to /usr/local/bin directly" {
  skip_unless_bash4
  touch .hadolint.yaml Dockerfile
  stub_hadolint_download

  run linters
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checking Dockerfiles..."* ]]
  # The download must land in a user-writable temp file, never straight into /usr/local/bin.
  [[ "$output" != *"wget invoked: -qO /usr/local/bin/hadolint"* ]]
  [[ "$output" == *"sudo invoked: install -m 0755"* ]]
  [[ "$output" == *"/usr/local/bin/hadolint"* ]]
  [[ "$output" != *"Permission denied"* ]]
  [[ "$output" == *"hadolint invoked: ./Dockerfile"* ]]
  [[ "$output" == *"All checks passed"* ]]
}

@test "aborts the hadolint install when the published checksum does not match" {
  skip_unless_bash4
  touch .hadolint.yaml Dockerfile
  stub_hadolint_download
  export PUBLISHED_CHECKSUM="0000000000000000000000000000000000000000000000000000000000000000"

  run linters
  [ "$status" -eq 1 ]
  [[ "$output" == *"Checksum verification failed for hadolint"* ]]
  [[ "$output" == *"Expected: ${PUBLISHED_CHECKSUM}"* ]]
  # Nothing is elevated or executed once verification fails.
  [[ "$output" != *"sudo invoked: install"* ]]
  [[ "$output" != *"hadolint invoked"* ]]
}

@test "picks the arm64 hadolint asset on an arm64 machine" {
  skip_unless_bash4
  touch .hadolint.yaml Dockerfile
  stub_hadolint_download
  export STUB_ARCH="arm64"

  run linters
  [ "$status" -eq 0 ]
  # The asset name follows the machine, and is never the hardcoded x86_64 one.
  [[ "$output" == *"hadolint-linux-arm64"* ]]
  [[ "$output" != *"hadolint-linux-x86_64"* ]]
  [[ "$output" == *"hadolint invoked: ./Dockerfile"* ]]
}

@test "aborts the hadolint install when the asset has no published checksum" {
  skip_unless_bash4
  touch .hadolint.yaml Dockerfile
  stub_hadolint_download
  # A machine whose asset is absent from checksums.sha256 must stop the install
  # rather than comparing against an empty expected hash.
  export STUB_ARCH="riscv64"

  run linters
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unsupported architecture: riscv64"* ]]
  [[ "$output" != *"sudo invoked: install"* ]]
}

@test "lints extensionless shell scripts, not just *.sh" {
  skip_unless_bash4
  touch .shellcheckrc
  printf '#!/usr/bin/env bash\ncd /tmp\n' > tool-without-extension
  chmod +x tool-without-extension

  function shellcheck() { echo "shellcheck invoked: $*"; }
  export -f shellcheck

  run linters
  # Discovery is by shebang: a file with no suffix is what this repo actually ships.
  [[ "$output" == *"./tool-without-extension"* ]]
}

@test "does not feed non-shell executables to shellcheck" {
  skip_unless_bash4
  touch .shellcheckrc
  printf '#!/usr/bin/env ruby\nputs 1\n' > ruby-tool
  printf '#!/usr/bin/env bats\n@test "x" { true; }\n' > bats-tool
  chmod +x ruby-tool bats-tool

  function shellcheck() { echo "shellcheck invoked: $*"; }
  export -f shellcheck

  run linters
  # shellcheck errors with SC1071 on a non-shell shebang rather than skipping it,
  # so these must never reach it.
  [[ "$output" != *"ruby-tool"* ]]
  [[ "$output" != *"bats-tool"* ]]
}

@test "skips shellcheck instead of failing when no shell scripts exist" {
  skip_unless_bash4
  touch .shellcheckrc

  run linters
  [ "$status" -eq 0 ]
  [[ "$output" == *"No shell scripts found, skipping"* ]]
}

@test "skips hadolint instead of failing when no Dockerfiles exist" {
  skip_unless_bash4
  touch .hadolint.yaml

  run linters
  [ "$status" -eq 0 ]
  [[ "$output" == *"No Dockerfiles found, skipping"* ]]
}

@test "lints Dockerfile variants, not just the exact name" {
  skip_unless_bash4
  touch .hadolint.yaml Dockerfile.ci
  stub_hadolint_download

  run linters
  [ "$status" -eq 0 ]
  [[ "$output" == *"hadolint invoked: ./Dockerfile.ci"* ]]
}

@test "installs trivy from the signed apt repo, never piping a script to a root shell" {
  skip_unless_bash4
  touch .trivyignore

  export HOME="${TEST_DIR}/home"
  mkdir -p "${HOME}/bin"
  ln -s "$(command -v bash)" "${HOME}/bin/bash"
  export PATH="${BATS_TEST_DIRNAME}/../:${HOME}/bin:/usr/bin:/bin"

  # These stubs sit inside a `wget | gpg | sudo tee` pipeline, so every trace goes
  # to stderr (which bats folds into $output); anything echoed to stdout would be
  # eaten by the next stage instead of being asserted on.
  function uname() { echo "Linux"; }
  function curl() { echo "curl invoked: $*" >&2; }
  function wget() { echo "wget invoked: $*" >&2; }
  function gpg() { echo "gpg invoked: $*" >&2; cat > /dev/null; }
  function tee() { echo "tee invoked: $*" >&2; cat > /dev/null; }

  function sudo() {
    echo "sudo invoked: $*" >&2

    # Land a runnable trivy on PATH the way the real apt install would.
    # Matched on the whole argv: this stub is called with 2 args (apt-get update)
    # and with 5, so indexing a fixed position trips `set -u`.
    if [[ "$*" == *"install"*"trivy"* ]]; then
      cat > "${HOME}/bin/trivy" <<'TRIVY'
#!/usr/bin/env bash
echo "trivy invoked: $*"
TRIVY
      chmod 0755 "${HOME}/bin/trivy"
    fi
  }

  export -f uname curl wget gpg tee sudo

  run linters
  [ "$status" -eq 0 ]
  # The old install path piped a remote script from a mutable branch into root.
  [[ "$output" != *"raw.githubusercontent.com"* ]]
  [[ "$output" != *"sudo sh"* ]]
  # The signed apt repository is configured and used instead.
  [[ "$output" == *"get.trivy.dev/deb/public.key"* ]]
  [[ "$output" == *"gpg invoked: --dearmor"* ]]
  [[ "$output" == *"install --no-install-recommends trivy"* ]]
  [[ "$output" == *"trivy invoked:"* ]]
}

@test "installs semgrep via pipx (not bare pip3) on Linux" {
  skip_unless_bash4
  touch .semgrepignore

  export HOME="${TEST_DIR}/home"
  mkdir -p "${HOME}/.local/bin" "${HOME}/bin"
  ln -s "$(command -v bash)" "${HOME}/bin/bash"
  export PATH="${BATS_TEST_DIRNAME}/../:${HOME}/bin:/usr/bin:/bin"

  function uname() { echo "Linux"; }
  export -f uname

  function pipx() {
    echo "pipx invoked: $*"
    cat > "${HOME}/.local/bin/semgrep" <<'EOF'
#!/usr/bin/env bash
echo "semgrep invoked: $*"
EOF
    chmod +x "${HOME}/.local/bin/semgrep"
  }
  export -f pipx

  run linters
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checking with semgrep..."* ]]
  [[ "$output" == *"pipx invoked: install semgrep"* ]]
  [[ "$output" == *"semgrep invoked: scan"* ]]
  [[ "$output" != *"pip3 install"* ]]
}

@test "runs rubocop when its config is present" {
  skip_unless_bash4
  touch .rubocop.yml

  function rubocop() { echo "rubocop invoked: $*"; }
  export -f rubocop

  run linters
  [ "$status" -eq 0 ]
  [[ "$output" == *"rubocop invoked"* ]]
  [[ "$output" == *"Checking Ruby"* ]]
}

@test "reports failure when a linter exits non-zero" {
  skip_unless_bash4
  touch .yamllint.yml

  function yamllint() { return 1; }
  export -f yamllint

  run linters
  [ "$status" -eq 1 ]
  [[ "$output" == *"Some checks failed"* ]]
}

@test "runs multiple linters when multiple configs are present" {
  skip_unless_bash4
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
  skip_unless_bash4
  touch .yamllint.yml .rubocop.yml

  function yamllint() { return 1; }
  # rubocop is probed with `rubocop --version`, not `command -v`, so the stub has
  # to answer that probe before failing the real run -- otherwise linters takes the
  # auto-install branch and shells out to a real `gem install`.
  function rubocop() { [ "${1:-}" == "--version" ] && return 0; return 1; }
  export -f yamllint rubocop

  run linters
  [ "$status" -eq 1 ]
  [[ "$output" == *"Checking YAML"* ]]
  [[ "$output" == *"Checking Ruby"* ]]
  [[ "$output" == *"Some checks failed"* ]]
}

@test "runs the built-in shell rules after shellcheck" {
  skip_unless_bash4
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
  skip_unless_bash4
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
  skip_unless_bash4
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
  skip_unless_bash4
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
  skip_unless_bash4
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
