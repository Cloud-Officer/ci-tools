#!/usr/bin/env bats

setup() {
  INSTALLER="${BATS_TEST_DIRNAME}/../ssm-jump.install.bat"
}

# cmd.exe is not available on the Linux/macOS CI runners, so these tests assert
# the generated batch script is written defensively (quoted expansions and
# non-empty input validation) via static checks (see issue #509).

@test "validates SHORTCUT_NAME is non-empty before use" {
  # The empty check must appear before the shortcut is written to disk.
  guard_line="$(grep -niE 'IF[[:space:]]+"%SHORTCUT_NAME%"==""' "${INSTALLER}" | head -n 1 | cut -d: -f1)"
  [ -n "${guard_line}" ]
  use_line="$(grep -niE 'EXIST[[:space:]]+"%SHORTCUT_NAME%\.bat"' "${INSTALLER}" | head -n 1 | cut -d: -f1)"
  [ -n "${use_line}" ]
  [ "${guard_line}" -lt "${use_line}" ]
}

@test "rejects an empty SHORTCUT_NAME with a clear message and non-zero exit" {
  grep -qiE 'Desktop shortcut name cannot be empty' "${INSTALLER}"
  grep -qiE 'EXIT[[:space:]]+/B[[:space:]]+1' "${INSTALLER}"
}

@test "quotes %SHORTCUT_NAME% in the IF EXIST test" {
  grep -qiE 'IF[[:space:]]+NOT[[:space:]]+EXIST[[:space:]]+"%SHORTCUT_NAME%\.bat"' "${INSTALLER}"
}

@test "quotes %SHORTCUT_NAME% in the redirection target" {
  grep -qiE '>"%SHORTCUT_NAME%\.bat"' "${INSTALLER}"
}

@test "does not redirect into an unquoted %SHORTCUT_NAME%.bat target" {
  ! grep -qiE '>[[:space:]]*%SHORTCUT_NAME%\.bat' "${INSTALLER}"
}

@test "does not use an unquoted %SHORTCUT_NAME% in the IF EXIST test" {
  ! grep -qiE 'EXIST[[:space:]]+%SHORTCUT_NAME%\.bat' "${INSTALLER}"
}

@test "quotes %AWS_INSTANCE% in the generated helper" {
  grep -qiE '"%AWS_INSTANCE%"' "${INSTALLER}"
}

@test "quotes %FORWARD_HOST% in the generated helper" {
  grep -qiE '"%FORWARD_HOST%"' "${INSTALLER}"
}
