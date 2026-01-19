# ci-tools [![Build](https://github.com/Cloud-Officer/ci-tools/actions/workflows/build.yml/badge.svg)](https://github.com/Cloud-Officer/ci-tools/actions/workflows/build.yml)

## Table of Contents

* [Introduction](#introduction)
* [Installation](#installation)
* [Usage](#usage)
  * [codeowners](#codeowners)
    * [Examples](#examples)
  * [cycle-keys](#cycle-keys)
    * [Usage cycle-keys](#usage-cycle-keys)
    * [Examples cycle-keys](#examples-cycle-keys)
  * [deploy](#deploy)
    * [Usage deploy](#usage-deploy)
    * [Examples deploy](#examples-deploy)
  * [linters](#linters)
    * [Examples linters](#examples-linters)
  * [ssh-jump](#ssh-jump)
    * [Usage ssh-jump](#usage-ssh-jump)
    * [Examples ssh-jump](#examples-ssh-jump)
  * [ssm-jump](#ssm-jump)
    * [Usage ssm-jump](#usage-ssm-jump)
    * [Examples ssm-jump](#examples-ssm-jump)
  * [sync-jira-release](#sync-jira-release)
    * [Usage sync-jira-release](#usage-sync-jira-release)
    * [Examples sync-jira-release](#examples-sync-jira-release)
* [Contributing](#contributing)

## Introduction

This is a collection of tools to run locally or on a CI pipeline.

## Installation

You can run `bundle install` and then run the commands.

You can install via [Homebrew](https://github.com/Cloud-Officer/homebrew-ci).

You can use the [Docker images](https://hub.docker.com/r/ydesgagne/ci-tools).

## Usage

### codeowners

This script generates the `codeowners` file. It must be executed from the root of a repository.

#### Examples

```bash
codeowners '@default_owner_GitHub****_id'
```

All the build files are by default assigned to `@tlacroix` and `@ydesgagn`.

### cycle-keys

This script reads your `~/.aws/credentials` file, creates a new key if the current one is too old, saves it in
your `credentials` file, and disables and deletes the other one.

#### Usage cycle-keys

```bash
Usage: cycle-keys options

options
        --profile profile
        --username username
        --force
    -h, --help
```

#### Examples cycle-keys

```bash
cycle-keys --profile in --username tommy.lacroix@innodemneurosciences.com
cycle-keys --profile in --username tommy.lacroix@innodemneurosciences.com --force
```

### deploy

Automate the ASG, spot fleet and Lambda deployments on AWS.

#### Usage deploy

```bash
Usage: deploy options

options
        --ami ami
        --environment environment
        --instance instance
        --type instance_type
        --lambda_publish_version function_name
        --profile profile
        --preserve_desired_capacity
        --skip_scale_down
    -h, --help
```

#### Examples deploy

```bash
# perform an ami of the betaX-api-standalone instance, create a launch config and update the auto scaling group
deploy --profile in --environment beta --instance api

# create a launch configuration and update the auto scaling group (and spot fleet if existing) from the provided AMI id
deploy --profile ugm --environment prod3 --instance worker --ami ami-09d6e0e85d7fba11d
```

### linters

Detect file types and run the appropriate linter. The linters are installed if not available on the system. The script will stop at the first linter reporting error to ease error fixing.

#### Examples linters

```bash
Checking GitHub Actions workflow files...
Checking Markdown...
Checking YAML...
Checking Ruby...
Inspecting 2 files
..

2 files inspected, no offenses detected

All checks passed.
```

### ssh-jump

Ssh to a host by name via when connected to an AWS VPN. You need to have a matching AWS CLI profile with your access keys to retrieve information from EC2.

#### Usage ssh-jump

```bash
Usage: ssh-jump.sh [options] hostname
Options:
  -h, --help                 Print this help message
  -p, --profile <profile>    Specify the aws cli profile to use
```

#### Examples ssh-jump

```bash
ssh-jump --profile ugm worker-prod3-spot
1    worker-prod3-spot 10.3.106.201
2    worker-prod3-spot 10.3.105.91
3    worker-prod3-spot 10.3.100.193
Connect to what line ?
```

### ssm-jump

Open an SSM connection to an EC2 instance, which can be specified by either:

* an EC2 internal IP address
* an EC2 instance ID
* an EC2 instance name (defined by the `Name` tag) (if multiple instances matches that name, the first one in the list will be chosen if `--autoselect-first` is set)

A VPN connection is not required. You need to have a matching AWS CLI profile with your access keys to retrieve information from EC2.

#### Usage ssm-jump

```bash
Usage: ssm-jump.sh [options] internal-ip|instance-id|instance-name
Options:
  -h, --help                                   Print this help message
  -p, --profile <profile>                      Specify the aws cli profile to use
  -a, --autoselect-first                       Automatically select first matching instance without prompting
  -f, --forward <host:remote_port:local_port>  Create a TCP tunnel to a host inside the VPC
  -c, --proxy-command <remote_port>            Establish an SSH session to be used as ProxyCommand
  -d, --document <ssm-document-name>           AWS Systems Manager document name (default: AWS-StartPortForwardingSessionToRemoteHost)
```

#### Examples ssm-jump

```bash
ssm-jump --profile ugm worker-prod3-spot
1     i-05a1299ac6942915a    10.3.150.60     worker-prod3-spot
2     i-0767bc8d4f0505ef8    10.3.114.146    worker-prod3-spot
3     i-08faa37782eb6a279    10.3.126.153    worker-prod3-spot
4     i-091454d577ed6c632    10.3.127.49     worker-prod3-spot
5     i-09adac7717d3122f9    10.3.159.203    worker-prod3-spot
6     i-0a3ed31cc89a39e4d    10.3.114.233    worker-prod3-spot
7     i-0a9c1e2d785dcc596    10.3.151.75     worker-prod3-spot
8     i-0c94fdc1b712d263d    10.3.158.156    worker-prod3-spot
9     i-0dcf7c304f2683112    10.3.113.9      worker-prod3-spot
Connect to what line ?
```

```bash
ssm-jump --profile ugm worker-prod3-standalone --forward "api-db-slave-prod3.portablenorthpole.com:6033:6033"
```

##### Use as an SSH ProxyCommand

The following snippet is a example of what could be added to your `~/.ssh/config`, which will let you use `ssh 10.1.x.x`, `ssh i-abcd1234`, or `ssh api-beta1-standalone`:

```ssh-config
Host 10.1.* 10.5.* 10.3.* i-* api-* grpc-* worker-*
    User                  ubuntu
    StrictHostKeyChecking no
    UserKnownHostsFile    /dev/null
    ProxyCommand          ssm-jump --profile myprofile --autoselect-first --proxy-command %p %h
```

You could also combine with subshells to manipulate the target name, for example if you want to have a specific prefix:

```ssh-config
Host myclient-api-* myclient-i-*
    User                  ubuntu
    StrictHostKeyChecking no
    UserKnownHostsFile    /dev/null
    ProxyCommand          ssm-jump --profile myprofile --autoselect-first --proxy-command %p $(echo "%h" | sed -E 's/^myclient-//')
```

That way, using `ssh myclient-api-rc5-standalone` will strip the `myclient-` prefix before trying to match an EC2 instance with that name.

### sync-jira-release

Synchronize Jira releases with GitHub pull requests. This tool automatically identifies all Jira issues mentioned in pull requests between two git tags and updates them with the specified Jira release version.

#### Usage sync-jira-release

```bash
sync-jira-release <tag1> <tag2> <jira_release>

Arguments:
  tag1          Git tag marking the start of the release range (older tag)
  tag2          Git tag marking the end of the release range (newer tag)
  jira_release  Name of the Jira release to associate with the issues

Required environment variables:
  JIRA_USER_EMAIL  Email address of the Jira user account
  JIRA_API_TOKEN   API token for Jira authentication
  JIRA_BASE_URL    Base URL of your Jira instance (e.g., https://company.atlassian.net)
  GITHUB_TOKEN     GitHub personal access token for authentication
```

Prerequisites:

* Both git tags must exist in the repository
* The Jira release must already exist in Jira
* Repository must have a `.github/pull_request_template.md` file containing the Jira project key pattern (e.g., `[DEV-XXXX]`)
* Pull request descriptions should contain Jira issue keys in the format `PROJECT-NUMBER`

The tool will:

1. Auto-install the Jira CLI if not present (arm64 macOS/Linux only)
2. Extract the Jira project key from your PR template
3. Find all pull requests between the two tags
4. Extract Jira issue keys from PR descriptions
5. Update each issue to add the release fix version
6. Open the Jira release report in your browser

#### Examples sync-jira-release

```bash
# Set up environment variables
export JIRA_USER_EMAIL="developer@company.com"
export JIRA_API_TOKEN="your_api_token_here"
export JIRA_BASE_URL="https://company.atlassian.net"
export GITHUB_TOKEN="your_github_token"

# Sync issues from all PRs between v1.0.0 and v1.1.0 to Jira release "Release 1.1.0"
sync-jira-release v1.0.0 v1.1.0 "Release 1.1.0"

# Sync issues from all PRs between two recent tags
sync-jira-release v2023.10.01 v2023.11.01 "November 2023 Release"
```

## Contributing

We love your input! We want to make contributing to this project as easy and transparent as possible, whether it's:

* Reporting a bug
* Discussing the current state of the code
* Submitting a fix
* Proposing new features
* Becoming a maintainer

Pull requests are the best way to propose changes to the codebase. We actively welcome your pull requests:

1. Fork the repo and create your branch from `master`.
2. If you've added code that should be tested, add tests. Ensure the test suite passes.
3. Update the documentation.
4. Make sure your code lints.
5. Issue that pull request!

When you submit code changes, your submissions are understood to be under the same [License](license) that covers the
project. Feel free to contact the maintainers if that's a concern.
