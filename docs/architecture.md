# Architecture Design

## Table of Contents

- [Architecture diagram](#architecture-diagram)
- [Software units](#software-units)
- [Software of Unknown Provenance](#software-of-unknown-provenance)
- [Critical algorithms](#critical-algorithms)
- [Risk controls](#risk-controls)

## Architecture diagram

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                              CI-TOOLS                                       │
│                    Collection of DevOps Automation Tools                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                     Ruby Scripts (AWS SDK)                          │   │
│  │  ┌───────────┐  ┌────────────┐  ┌─────────────┐  ┌───────────────┐  │   │
│  │  │ deploy.rb │  │ cycle-keys │  │encrypt-logs │  │brew-resources │  │   │
│  │  │           │  │    .rb     │  │    .rb      │  │     .rb       │  │   │
│  │  └─────┬─────┘  └─────┬──────┘  └──────┬──────┘  └───────┬───────┘  │   │
│  │        │              │                │                 │          │   │
│  │        └──────────────┴────────────────┴─────────────────┘          │   │
│  │                              │                                      │   │
│  │                     ┌────────▼────────┐                             │   │
│  │                     │   AWS SDK Ruby  │                             │   │
│  │                     │  (EC2, ASG, CF, │                             │   │
│  │                     │  IAM, KMS, SSM, │                             │   │
│  │                     │ Lambda, ELB,CW) │                             │   │
│  │                     └────────┬────────┘                             │   │
│  └──────────────────────────────┼──────────────────────────────────────┘   │
│                                 │                                          │
│  ┌──────────────────────────────┼──────────────────────────────────────┐   │
│  │                     Bash Scripts                                    │   │
│  │  ┌───────────┐  ┌────────────┐  ┌──────────────────┐  ┌──────────┐  │   │
│  │  │  linters  │  │  ssm-jump  │  │sync-jira-release │  │ generate │  │   │
│  │  │           │  │            │  │                  │  │codeowners│  │   │
│  │  └─────┬─────┘  └─────┬──────┘  └────────┬─────────┘  └────┬─────┘  │   │
│  │        │              │                  │                 │        │   │
│  │        ▼              ▼                  ▼                 ▼        │   │
│  │  ┌──────────┐  ┌───────────┐      ┌──────────┐       ┌──────────┐   │   │
│  │  │ External │  │  AWS CLI  │      │ gh CLI + │       │   Bash   │   │
│  │  │ Linters  │  │  + SSM    │      │ jira CLI │       │  Utils   │   │
│  │  └──────────┘  └───────────┘      └──────────┘       └──────────┘   │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                     Distribution Methods                            │   │
│  │  ┌───────────────┐  ┌───────────────┐  ┌───────────────────────┐    │   │
│  │  │    Docker     │  │   Homebrew    │  │   Direct Execution    │    │   │
│  │  │   Container   │  │    Formula    │  │   (bundle install)    │    │   │
│  │  └───────────────┘  └───────────────┘  └───────────────────────┘    │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           AWS Services                                      │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐   │
│  │   EC2   │ │   ASG   │ │CloudForm│ │   IAM   │ │   SSM   │ │  Lambda │   │
│  └─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────┘   │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐                           │
│  │   KMS   │ │CloudFrnt│ │   ELB   │ │CloudWtch│                           │
│  └─────────┘ └─────────┘ └─────────┘ └─────────┘                           │
└─────────────────────────────────────────────────────────────────────────────┘
```

### System Overview

CI-Tools is a collection of DevOps automation tools designed to run locally or within CI/CD pipelines. The toolkit provides utilities for AWS infrastructure deployment, security key management, code linting, and development workflow automation.

### Component Interactions

- **Ruby scripts** interact with AWS services through the official AWS SDK for Ruby
- **Bash scripts** utilize external CLI tools (AWS CLI, GitHub CLI, Jira CLI) for service integration
- **Linters script** orchestrates multiple language-specific linting tools
- **Distribution** is supported via Docker containers, Homebrew formulas, or direct Ruby bundler installation

## Software units

### deploy.rb

**Purpose:** Automates AWS Auto Scaling Group (ASG), spot fleet, and Lambda deployments.

**Location:** `deploy.rb`

**Key Components:**

- `wait_for_healthy_instances`: Polls ELB target group health status until all instances are healthy
- Main deployment logic: Creates AMIs, updates CloudFormation stacks, manages ASG scaling

**Functionality:**

- Creates EC2 AMIs from standalone instances
- Updates CloudFormation stack parameters via SSM
- Manages ASG desired capacity with blue/green deployment pattern
- Publishes Lambda versions and updates CloudFront distributions
- Supports spot instance deployments with mixed instance policies

**Internal Dependencies:** None

**External Dependencies:
** aws-sdk-autoscaling, aws-sdk-cloudformation, aws-sdk-cloudfront, aws-sdk-core, aws-sdk-ec2, aws-sdk-elasticloadbalancingv2, aws-sdk-lambda, aws-sdk-ssm, optparse

### cycle-keys.rb

**Purpose:** Rotates AWS IAM access keys by creating new keys and safely removing old ones.

**Location:** `cycle-keys.rb`

**Key Components:**

- Credentials file parser using IniFile
- Key rotation logic with age-based thresholds

**Functionality:**

- Reads AWS credentials from `~/.aws/credentials`
- Creates new access keys when current keys exceed 80 days (configurable)
- Disables and deletes old keys after successful rotation
- Updates credentials file with new key material

**Internal Dependencies:** None

**External Dependencies:** aws-sdk-iam, inifile, optparse

### encrypt-logs.rb

**Purpose:** Encrypts CloudWatch log groups with KMS keys and sets retention policies.

**Location:** `encrypt-logs.rb`

**Key Components:**

- KMS key discovery by environment prefix
- Log group encryption and retention management

**Functionality:**

- Lists KMS keys and maps them to environments (beta, rc, prod)
- Iterates through CloudWatch log groups
- Associates KMS keys based on environment naming conventions
- Sets log retention policies

**Internal Dependencies:** None

**External Dependencies:** aws-sdk-cloudwatchlogs, aws-sdk-core, aws-sdk-kms, optparse

### linters

**Purpose:** Detects file types in a repository and runs appropriate linters with auto-installation.

**Location:** `linters`

**Key Components:**

- File type detection based on configuration files
- Linter installation for missing tools
- Multi-linter execution with failure tracking

**Supported Linters:**

- actionlint: GitHub Actions workflows
- markdownlint-cli2: Markdown files
- yamllint: YAML files
- shellcheck: Shell scripts
- hadolint: Dockerfiles
- golangci-lint: Go code
- pmd: Java/JS/SQL
- eslint: JavaScript
- ktlint: Kotlin
- bandit: Python security
- flake8: Python style
- protolint: Protocol Buffers
- rubocop: Ruby code
- semgrep: Security scanning
- swiftlint: Swift code

**Internal Dependencies:** None

**External Dependencies:** Various external linting tools (auto-installed)

### ssm-jump

**Purpose:** Opens AWS Systems Manager Session Manager connections to EC2 instances.

**Location:** `ssm-jump`

**Key Components:**

- Instance lookup by IP, instance ID, or Name tag
- Port forwarding and SSH proxy support

**Functionality:**

- Resolves EC2 instances by private IP, instance ID, or Name tag
- Supports TCP tunneling via port forwarding
- Can be used as SSH ProxyCommand for seamless SSH integration
- Interactive instance selection when multiple matches found

**Internal Dependencies:** None

**External Dependencies:** AWS CLI, jq

### ssh-jump (Deprecated)

**Purpose:** SSH to EC2 instances by name (deprecated, replaced by ssm-jump).

**Location:** `ssh-jump`

**Functionality:**

- Queries EC2 instances by Name tag
- Establishes direct SSH connection via private IP
- Requires VPN connectivity

**Internal Dependencies:** None

**External Dependencies:** AWS CLI, jq

### sync-jira-release

**Purpose:** Synchronizes Jira releases with GitHub pull requests by extracting issue keys from PRs.

**Location:** `sync-jira-release`

**Key Components:**

- Git tag comparison for PR discovery
- Jira issue key extraction from PR descriptions
- Jira release version updates

**Functionality:**

- Extracts Jira project key from PR template
- Finds all PRs between two git tags
- Extracts Jira issue keys from PR descriptions
- Updates issues with fix version in Jira
- Opens Jira release report in browser

**Internal Dependencies:** None

**External Dependencies:** GitHub CLI (gh), Jira CLI

### generate-codeowners

**Purpose:** Generates CODEOWNERS file for GitHub repositories.

**Location:** `generate-codeowners`

**Functionality:**

- Creates CODEOWNERS file with default owner assignments
- Assigns build/deploy files to specified maintainers
- Preserves custom sections between markers

**Internal Dependencies:** None

**External Dependencies:** Bash utilities

### brew-resources.rb

**Purpose:** Generates Homebrew formula resource blocks from Gemfile.lock.

**Location:** `brew-resources.rb`

**Functionality:**

- Parses Gemfile.lock for gem specifications
- Downloads gems from RubyGems to compute SHA256 checksums
- Outputs Homebrew formula resource blocks with platform-specific handling

**Internal Dependencies:** None

**External Dependencies:** bundler, httparty

## Software of Unknown Provenance

For the complete and detailed SOUP documentation, see [soup.md](soup.md).

### Summary

| Category                         | Count | Licenses        |
|----------------------------------|-------|-----------------|
| AWS SDK Components               | 14    | Apache-2.0      |
| Ruby Standard Library Extensions | 8     | Ruby            |
| Development Tools (RuboCop)      | 8     | MIT             |
| Utility Libraries                | 10    | MIT, Apache-2.0 |

### Critical Dependencies

| Package                | Version | License    | Purpose                           |
|------------------------|---------|------------|-----------------------------------|
| aws-sdk-core           | 3.241.4 | Apache-2.0 | Core AWS API client functionality |
| aws-sdk-ec2            | 1.591.0 | Apache-2.0 | EC2 instance and AMI management   |
| aws-sdk-autoscaling    | 1.152.0 | Apache-2.0 | Auto Scaling Group operations     |
| aws-sdk-cloudformation | 1.149.0 | Apache-2.0 | CloudFormation stack updates      |
| aws-sdk-iam            | 1.140.0 | Apache-2.0 | IAM key rotation                  |
| aws-sdk-ssm            | 1.210.0 | Apache-2.0 | SSM parameter management          |
| aws-sdk-kms            | 1.121.0 | Apache-2.0 | KMS encryption operations         |
| nokogiri               | 1.19.0  | MIT        | XML/HTML parsing                  |
| httparty               | 0.24.2  | MIT        | HTTP client for API requests      |

### Security-Sensitive Dependencies

| Package     | Version | Purpose                   | Security Consideration               |
|-------------|---------|---------------------------|--------------------------------------|
| aws-sdk-iam | 1.140.0 | IAM key management        | Handles access key creation/deletion |
| aws-sdk-kms | 1.121.0 | Encryption key management | Manages KMS key associations         |
| aws-sigv4   | 1.12.1  | AWS request signing       | Cryptographic signature generation   |
| inifile     | 3.0.0   | INI file parsing          | Reads AWS credentials files          |

## Critical algorithms

### Blue/Green Deployment Algorithm

**Purpose:** Safely deploy new AMIs to Auto Scaling Groups with zero-downtime.

**Location:** `deploy.rb:381-487`

**Implementation:**

1. Scale up ASG to double capacity plus buffer (configurable for production)
2. Wait for new instances to become healthy in target group
3. Allow warm-up period for caches
4. Scale down to original capacity
5. Wait for old instances to terminate

**Parameters:**

- `asg_increase`: Additional instances during deployment (1 for non-prod, 3 for prod)
- `asg_multiplier`: Capacity multiplier (2x default)
- `preserve_desired_capacity`: Skip scaling, only update launch configuration
- `skip_scale_down`: Leave at increased capacity after deployment

### AWS Key Rotation Algorithm

**Purpose:** Safely rotate AWS IAM access keys with automatic cleanup.

**Location:** `cycle-keys.rb:49-164`

**Implementation:**

1. List all access keys for the profile
2. Disable and delete any secondary keys
3. Check age of current key (threshold: 80 days)
4. Create new access key
5. Update credentials file with new key
6. Disable old key
7. Delete old key

**Security Considerations:**

- Validates username matches expected value
- Supports force rotation regardless of key age
- Atomic update to credentials file

### Instance Lookup Algorithm

**Purpose:** Resolve EC2 instances by multiple identifier types.

**Location:** `ssm-jump:85-103`

**Implementation:**

1. If target matches `i-*` pattern, use as instance ID directly
2. If target matches IP address pattern, query by `private-ip-address`
3. Otherwise, query by `tag:Name`
4. Return sorted list of matching instances

**Complexity:** O(n) where n is the number of matching instances

## Risk controls

### Authentication and Authorization

| Control               | Implementation                                     | Location                  |
|-----------------------|----------------------------------------------------|---------------------------|
| AWS Profile Selection | All scripts require explicit `--profile` parameter | All Ruby/Bash scripts     |
| Credential Isolation  | Uses AWS SDK profile-based authentication          | `deploy.rb:69-72`         |
| Username Validation   | Key rotation validates username matches expected   | `cycle-keys.rb:102-105`   |
| Environment Variables | Sensitive tokens passed via environment            | `sync-jira-release:83-86` |

### Input Validation

| Control                 | Implementation                                | Location                    |
|-------------------------|-----------------------------------------------|-----------------------------|
| Required Parameters     | OptionParser with mandatory argument checking | All Ruby scripts            |
| Target Validation       | Regex validation for instance identifiers     | `ssm-jump:86-94`            |
| Git Tag Verification    | Validates tags exist before processing        | `sync-jira-release:104-112` |
| Release Existence Check | Verifies Jira release exists before updates   | `sync-jira-release:90-97`   |

### Error Handling

| Control                | Implementation                            | Location            |
|------------------------|-------------------------------------------|---------------------|
| Exception Wrapping     | Top-level rescue blocks with stack traces | All Ruby scripts    |
| Validation Errors      | CloudFormation validation error handling  | `deploy.rb:335-338` |
| Stack State Monitoring | Checks for failed stack states            | `deploy.rb:342-353` |
| Exit Codes             | Non-zero exit codes on failures           | All scripts         |

### Operational Safety

| Control              | Implementation                                | Location            |
|----------------------|-----------------------------------------------|---------------------|
| Capacity Limits      | Respects ASG max_size constraints             | `deploy.rb:385-412` |
| Health Checks        | Waits for ELB target health before proceeding | `deploy.rb:17-31`   |
| Warm-up Periods      | Configurable sleep times for cache warming    | `deploy.rb:431-438` |
| Deprecation Warnings | Clear warnings for deprecated tools           | `ssh-jump:4-9`      |

### Logging and Monitoring

| Control                | Implementation                             | Location            |
|------------------------|--------------------------------------------|---------------------|
| Progress Output        | Step-by-step status messages               | All scripts         |
| AWS Operation Logging  | Logs SSM parameter updates, stack changes  | `deploy.rb`         |
| Linter Result Tracking | Tracks pass/fail status across all linters | `linters:5,254-257` |

### Failure Modes

| Failure Mode                | Impact                | Mitigation                                          |
|-----------------------------|-----------------------|-----------------------------------------------------|
| AMI creation timeout        | Deployment blocked    | Extended waiter timeout (1024 attempts for workers) |
| Stack update failure        | Partial deployment    | Stack state monitoring with failure detection       |
| Key rotation failure        | Credentials unchanged | Atomic file update, rollback on error               |
| Instance lookup failure     | Connection blocked    | Clear error messages with valid alternatives        |
| Linter installation failure | Build blocked         | Auto-installation with platform detection           |

### Security Considerations

- **No hardcoded credentials**: All authentication via AWS profiles or environment variables
- **Least privilege**: Scripts request only necessary AWS permissions
- **Audit trail**: CloudFormation and SSM operations are logged by AWS
- **Key lifecycle**: Automatic key rotation prevents credential staleness
- **Encryption at rest**: KMS encryption for CloudWatch logs
