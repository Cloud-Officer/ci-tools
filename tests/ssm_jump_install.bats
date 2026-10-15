#!/usr/bin/env bats

setup() {
  INSTALLER="${BATS_TEST_DIRNAME}/../ssm-jump.install.bat"
}

# cmd.exe is not available on the Linux/macOS CI runners, so these tests assert
# the batch script's behaviour via static checks (see issue #509).

@test "does not configure AWS or set environment variables" {
  ! grep -qiE 'aws[[:space:]]+(--profile|configure|sts|ec2)' "${INSTALLER}"
  ! grep -qiE 'SET[[:space:]]+/P|setx' "${INSTALLER}"
}

@test "installs every ssm-jump and query-db prerequisite" {
  for id in Amazon.AWSCLI Amazon.SessionManagerPlugin Git.Git jqlang.jq Oracle.MySQL; do
    grep -qE "winget install --exact --id ${id} " "${INSTALLER}"
  done
}

@test "installs ssm-jump without an extension into the user bin folder" {
  grep -qE -- '--output "%BIN_DIR%\\ssm-jump"' "${INSTALLER}"
  grep -qE 'SET "BIN_DIR=%USERPROFILE%\\bin"' "${INSTALLER}"
}

@test "does not write anything to the desktop" {
  ! grep -qiE 'Desktop' "${INSTALLER}"
}

@test "writes an ssm-jump.cmd wrapper that runs ssm-jump through Git bash" {
  grep -qE '^>"%BIN_DIR%\\ssm-jump\.cmd" ECHO @"%GIT_BASH%" "%%~dp0ssm-jump" %%\*$' "${INSTALLER}"
}

@test "checks the ssm-jump.cmd wrapper runs" {
  grep -qE '^CALL "%BIN_DIR%\\ssm-jump\.cmd" --help' "${INSTALLER}"
}
