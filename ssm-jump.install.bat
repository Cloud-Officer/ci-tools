@ECHO OFF
SETLOCAL

ECHO Install AWS CLI and session manager plugin
winget install --exact --id Amazon.AWSCLI --accept-package-agreements --accept-source-agreements
winget install --exact --id Amazon.SessionManagerPlugin --accept-package-agreements --accept-source-agreements

ECHO Install git, which provides the bash that runs ssm-jump
winget install --exact --id Git.Git --accept-package-agreements --accept-source-agreements

ECHO Install jq, required by ssm-jump port forwarding
winget install --exact --id jqlang.jq --accept-package-agreements --accept-source-agreements

ECHO Install MySQL, required for the mysql client
winget install --exact --id Oracle.MySQL --accept-package-agreements --accept-source-agreements

SET "AWS_CLI_DIR=%ProgramFiles%\Amazon\AWSCLIV2"
SET "SSM_PLUGIN_DIR=%ProgramFiles%\Amazon\SessionManagerPlugin\bin"
SET "GIT_BASH=%ProgramFiles%\Git\bin\bash.exe"
SET "BIN_DIR=%USERPROFILE%\bin"
SET "MYSQL_BIN_DIR="
FOR /D %%D IN ("%ProgramFiles%\MySQL\MySQL Server *") DO IF EXIST "%%D\bin\mysql.exe" SET "MYSQL_BIN_DIR=%%D\bin"

IF NOT EXIST "%AWS_CLI_DIR%\aws.exe" (
	ECHO .
	ECHO AWS CLI not found in %AWS_CLI_DIR%. Exiting.
	ECHO .
	PAUSE
	EXIT /B 1
)

IF NOT EXIST "%SSM_PLUGIN_DIR%\session-manager-plugin.exe" (
	ECHO .
	ECHO Session Manager plugin not found in %SSM_PLUGIN_DIR%. Exiting.
	ECHO .
	PAUSE
	EXIT /B 1
)

IF NOT EXIST "%GIT_BASH%" (
	ECHO .
	ECHO Git bash not found at %GIT_BASH%. Exiting.
	ECHO .
	PAUSE
	EXIT /B 1
)

IF "%MYSQL_BIN_DIR%"=="" (
	ECHO .
	ECHO mysql client not found under %ProgramFiles%\MySQL. Exiting.
	ECHO .
	PAUSE
	EXIT /B 1
)

SET "PATH=%AWS_CLI_DIR%;%SSM_PLUGIN_DIR%;%MYSQL_BIN_DIR%;%BIN_DIR%;%LOCALAPPDATA%\Microsoft\WinGet\Links;%ProgramFiles%\WinGet\Links;%PATH%"

WHERE /Q jq || (
	ECHO .
	ECHO jq not found. Exiting.
	ECHO .
	PAUSE
	EXIT /B 1
)

ECHO Install ssm-jump script
IF NOT EXIST "%BIN_DIR%" MKDIR "%BIN_DIR%"
curl.exe -SL --fail --progress-bar https://raw.githubusercontent.com/Cloud-Officer/ci-tools/refs/heads/master/ssm-jump --output "%BIN_DIR%\ssm-jump" || (
	ECHO .
	ECHO Failed to download ssm-jump script from GitHub. Exiting.
	ECHO .
	PAUSE
	EXIT /B 1
)

ECHO Install ssm-jump.cmd so PowerShell and cmd can run ssm-jump
>"%BIN_DIR%\ssm-jump.cmd" ECHO @"%GIT_BASH%" "%%~dp0ssm-jump" %%*

ECHO Add ssm-jump and mysql to the user PATH
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$entries = @([Environment]::GetEnvironmentVariable('Path', 'User') -split ';' | Where-Object { $_ }); foreach ($dir in @($env:BIN_DIR, $env:MYSQL_BIN_DIR)) { if ($entries -notcontains $dir) { $entries += $dir } }; [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')" || (
	ECHO .
	ECHO Failed to update the user PATH. Exiting.
	ECHO .
	PAUSE
	EXIT /B 1
)

"%GIT_BASH%" -lc "ssm-jump --help >/dev/null && command -v jq >/dev/null && command -v mysql >/dev/null" || (
	ECHO .
	ECHO ssm-jump, jq or mysql cannot be run from Git bash. Exiting.
	ECHO .
	PAUSE
	EXIT /B 1
)

CALL "%BIN_DIR%\ssm-jump.cmd" --help >NUL || (
	ECHO .
	ECHO ssm-jump cannot be run from PowerShell or cmd. Exiting.
	ECHO .
	PAUSE
	EXIT /B 1
)

ECHO .
ECHO Installation complete.
ECHO Next, configure your AWS profile and the database environment variables:
ECHO https://github.com/Cloud-Officer/ci-tools#windows-installation
ECHO Close and reopen your terminals and Claude Code so the new PATH applies.
ECHO .

PAUSE
