#!/usr/bin/env bats

setup() {
  export PATH="${BATS_TEST_DIRNAME}/../:${PATH}"
  TEST_DIR=$(mktemp -d)
  cd "${TEST_DIR}"
}

teardown() {
  rm -rf "${TEST_DIR}"
}

@test "exits with error when build files owners argument is empty" {
  run generate-codeowners "" "default-owner"
  [ "$status" -eq 1 ]
  [[ "$output" == *"build files owners cannot be empty"* ]]
}

@test "exits with error when default owners argument is empty" {
  run generate-codeowners "build-owner" ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"default owners cannot be empty"* ]]
}

@test "exits with error when no arguments provided" {
  run generate-codeowners
  [ "$status" -eq 1 ]
}

@test "creates CODEOWNERS file with header and default owner" {
  mkdir -p .github
  generate-codeowners "@build-team" "@default-team"
  [ -f .github/CODEOWNERS ]
  grep -q "code-owners" .github/CODEOWNERS
  grep -q "@default-team" .github/CODEOWNERS
}

@test "includes build files that exist" {
  mkdir -p .github
  touch .gitignore
  generate-codeowners "@build-team" "@default-team"
  grep -q ".gitignore" .github/CODEOWNERS
  grep -q "@build-team" .github/CODEOWNERS
}

@test "skips build files that do not exist" {
  mkdir -p .github
  generate-codeowners "@build-team" "@default-team"
  ! grep -q ".golangci.yml" .github/CODEOWNERS
}

@test "preserves custom lines between markers" {
  mkdir -p .github
  cat > .github/CODEOWNERS << 'EOF'
# header
* @default

# custom start
/special-file @special-team
# custom end
EOF
  generate-codeowners "@build-team" "@default-team"
  grep -q "/special-file @special-team" .github/CODEOWNERS
  grep -q "# custom start" .github/CODEOWNERS
  grep -q "# custom end" .github/CODEOWNERS
}
