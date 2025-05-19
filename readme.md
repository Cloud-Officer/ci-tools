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
ssh-jump --profile ugm worker-prod3-spot                                              ✔  10:28:30  
1    worker-prod3-spot 10.3.106.201
2    worker-prod3-spot 10.3.105.91
3    worker-prod3-spot 10.3.100.193
Connect to what line ? 
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
