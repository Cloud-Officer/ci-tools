@ECHO OFF

SET /P AWS_PROFILE=Enter AWS CLI profile name:
SET /P AWS_INSTANCE=Enter EC2 instance name (e.g. api-prod-standalone):
SET /P FORWARD_HOST=Enter forward host (e.g. db-slave.example.com:3306:3306):
SET /P SSM_DOCUMENT=Enter SSM document name (default: AWS-StartPortForwardingSessionToRemoteHost):
SET /P SHORTCUT_NAME=Enter desktop shortcut name (e.g. my-project-prod):

IF "%SSM_DOCUMENT%"=="" SET SSM_DOCUMENT=AWS-StartPortForwardingSessionToRemoteHost

ECHO Install AWS CLI and session manager
winget install --exact --id Amazon.AWSCLI --accept-package-agreements --accept-source-agreements
winget install --exact --id Amazon.SessionManagerPlugin

ECHO Install git, mainly because bash and other GNU tools are well packaged
winget install --exact --id Git.Git

ECHO Ensure AWS CLI is available in PATH
SET PATH=%PATH%;C:\Program Files\Amazon\AWSCLIV2

ECHO Check AWS authentication
aws --profile %AWS_PROFILE% sts get-caller-identity && (
	ECHO .
	ECHO AWS authentication successful
	ECHO .
) || (
	ECHO .
	ECHO Missing AWS credentials, triggering configuration
	ECHO .

	aws --profile %AWS_PROFILE% configure

	aws --profile %AWS_PROFILE% sts get-caller-identity || (
		ECHO .
		ECHO Failed to authenticate against AWS. Exiting.
		ECHO .
		PAUSE
		EXIT /B 1
	)
)

ECHO Install SSM jump script
IF NOT EXIST "%USERPROFILE%\.ssm-jump" MKDIR "%USERPROFILE%\.ssm-jump"
CD "%USERPROFILE%\.ssm-jump"
curl.exe -SL --fail --progress-bar https://raw.githubusercontent.com/Cloud-Officer/ci-tools/refs/heads/master/ssm-jump --output ssm-jump.sh || (
	ECHO .
	ECHO Failed to download ssm-jump script from GitHub. Exiting.
	ECHO .
	PAUSE
	EXIT /B 1
)

ECHO Generate connect helper on desktop
SET CMD_COMMON="C:\Program Files\Git\bin\bash.exe" "%USERPROFILE%\.ssm-jump\ssm-jump.sh" --profile %AWS_PROFILE% --document %SSM_DOCUMENT%
CD "%USERPROFILE%\Desktop"
IF NOT EXIST %SHORTCUT_NAME%.bat ECHO %CMD_COMMON% %AWS_INSTANCE% --forward %FORWARD_HOST% >%SHORTCUT_NAME%.bat

PAUSE