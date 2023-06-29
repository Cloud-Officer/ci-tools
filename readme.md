# ci-tools [![Build](https://github.com/Cloud-Officer/ci-tools/actions/workflows/build.yml/badge.svg)](https://github.com/Cloud-Officer/ci-tools/actions/workflows/build.yml)

This is a collection of tools to run locally or on a CI pipeline.

### codeowners

This script generates the `codeowners` file. It must be executed from the root of a repository.

Examples:

```bash
codeowners '@default_owner_GitHub****_id'
```

All the build files are by default assigned to `@tlacroix` and `@ydesgagn`.

### cycle-keys

This script reads your `~/.aws/credentials` file, creates a new key if the current one is too old, saves it in
your `credentials` file, and disables and deletes the other one.

Options:

```bash
Usage: cycle-keys options

options
        --profile profile
        --username username
        --force
    -h, --help
```

Examples:

```bash
cycle-keys --profile in --username tommy.lacroix@innodemneurosciences.com
cycle-keys --profile in --username tommy.lacroix@innodemneurosciences.com --force
```

## deploy

Automate the ASG, spot fleet and Lambda deployments on AWS.

### Usage

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

### Examples

```bash
# perform an ami of the betaX-api-standalone instance, create a launch config and update the auto scaling group
deploy --profile in --environment beta --instance api

# create a launch configuration and update the auto scaling group (and spot fleet if existing) from the provided AMI id
deploy --profile ugm --environment prod3 --instance worker --ami ami-09d6e0e85d7fba11d
```

## linters

Detect file types and run the appropriate linter. The linters are installed if not available on the system. The script will stop at the first linter reporting error to ease error fixing.

### Examples

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

## ssh-jump

Ssh to a host by name via when connected to an AWS VPN. You need to have a matching AWS CLI profile with your access keys to retrieve information from EC2.

### Usage

```bash
Usage: ssh-jump.sh [options] hostname
Options:
  -h, --help                 Print this help message
  -p, --profile <profile>    Specify the aws cli profile to use
```

### Examples

```bash
ssh-jump --profile ugm worker-prod3-spot                                              ✔  10:28:30  
1    worker-prod3-spot 10.3.106.201
2    worker-prod3-spot 10.3.105.91
3    worker-prod3-spot 10.3.100.193
Connect to what line ? 
```
