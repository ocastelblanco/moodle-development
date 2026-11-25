<!-- Header block for project -->
<hr>

<div align="center">

<h1 align="center">Moodle 5.3 LTS on AWS: Deployment Skills</h1>

**English** | [Español](README.es.md)

</div>

<pre align="center">Terraform, scripts and AI agent skills to deploy, run and scale a single-server Moodle 5.3 LTS virtual classroom on AWS, with automatic course certificates.</pre>

<!-- Header block for project -->

[![AI-assisted: written by a human with help from AI tools](https://img.shields.io/static/v1?label=&message=AI-assisted&color=gold)](https://nasa-ammos.github.io/slim/?search=Badges) [![Best Practices from SLIM: this project follows SLIM best practices](https://img.shields.io/badge/Best%20Practices%20from-SLIM-blue)](https://nasa-ammos.github.io/slim/) [![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue)](LICENSE) ![Moodle 5.3 LTS](https://img.shields.io/badge/Moodle-5.3%20LTS-orange) ![PHP 8.4](https://img.shields.io/badge/PHP-8.4-777bb4) ![MariaDB 11.8](https://img.shields.io/badge/MariaDB-11.8%20LTS-003545) ![Amazon Linux 2023](https://img.shields.io/badge/Amazon%20Linux-2023-ff9900)

This repository is a toolkit for standing up a production Moodle on AWS with the longest support window available: Moodle 5.3 LTS, PHP 8.4, RDS MariaDB 11.8 and Amazon Linux 2023 on Graviton (ARM64). It is meant for people who run virtual classrooms and for AI agents (Claude Code and similar) that execute the deployment through the bundled skills.

[Docs](docs/) | [Skills](skills/) | [Issue Tracker](https://github.com/ocastelblanco/moodle-development/issues) | [Pull Requests](https://github.com/ocastelblanco/moodle-development/pulls)

## Features

* **Infrastructure as Code:** Terraform for EC2, RDS, EBS, CloudFront, CloudWatch and security groups.
* **Numbered deployment scripts (01-09):** from provisioning to scaling.
* **11 AI agent skills:** an orchestrator plus one skill per phase (see [Skills](#skills)).
* **Automatic course certificates:** issued when a student completes the course and reaches a minimum grade, emailed as PDF through Amazon SES, with public verification by code/QR (`mod_coursecertificate` + `tool_certificate`).
* **SES SMTP credentials with Terraform (opt-in):** least-privilege IAM user, password stored in SSM Parameter Store, rotation by bumping one variable.
* **Vertical scaling, manual and automatic:** a metrics report with recommendations, EC2/RDS/EBS resizing, EBS auto-growth, SNS alerts and AWS Budgets.
* **HTTPS, backups and monitoring:** Let's Encrypt, 3-2-1 backups, CloudWatch dashboards and alarms.

## Contents

* [Quick Start](#quick-start)
* [Version Matrix](#version-matrix)
* [Skills](#skills)
* [Estimated Costs](#estimated-costs)
* [Changelog](#changelog)
* [FAQ](#frequently-asked-questions-faq)
* [Contributing Guide](#contributing)
* [License](#license)
* [Support](#support)

## Quick Start

This is the short path. The step-by-step guides live in [docs/](docs/).

### Requirements

* AWS account with administrator permissions and AWS CLI configured (`aws configure`).
* Terraform >= 1.4.
* An EC2 key pair in the target region.
* A registered domain (needed for SSL and for SES email).
* Amazon SES out of the sandbox before sending real email. AWS approves this in 24-72 hours and it needs a manual request.

### Setup Instructions

1. Clone the repository and enter it.

   ```bash
   git clone https://github.com/ocastelblanco/moodle-development.git
   cd moodle-development
   ```

2. Create your variable files from the examples and fill them in.

   ```bash
   cp config/variables.sh.example config/variables.sh
   cp terraform/terraform.tfvars.example terraform/terraform.tfvars
   ```

3. Provision the infrastructure from your machine.

   ```bash
   cd scripts && ./01-provision-infrastructure.sh
   ```

### Run Instructions

Scripts 02 to 08 run **on the EC2 instance** as root, in order:

```bash
./02-setup-server.sh        # Apache, PHP 8.4, MariaDB client
./03-install-moodle.sh      # Moodle 5.3 LTS (MOODLE_503_STABLE), DocumentRoot /public
./04-configure-ssl.sh       # Let's Encrypt
./05-optimize-system.sh     # PHP-FPM and system tuning
./06-setup-backups.sh
./07-setup-monitoring.sh
./08-setup-certificates.sh  # needs SES SMTP configured
```

Script 09 runs **from your machine** and is meant for day-two operations:

```bash
./09-scale-infrastructure.sh report
```

### Usage Examples

* **Let an AI agent do it:** `claude "Deploy Moodle 5.3 LTS on AWS following the skills in skills/"`. Start from the `moodle-deployment` skill.
* **Check whether the server needs more capacity:** `./scripts/09-scale-infrastructure.sh report`.
* **Enable automatic scaling:** set `enable_compute_autoresize` and `scaling_alert_emails` in `terraform.tfvars`. It starts in `notify` mode, which only emails recommendations. See [docs/11-scaling.md](docs/11-scaling.md).
* **Manage SES SMTP credentials with Terraform:** set `enable_ses_smtp = true`. Enable the encrypted S3 backend first, because the SMTP password is kept in Terraform state. See [docs/10-certificates.md](docs/10-certificates.md).

## Version Matrix

| Component | Version | Support |
| ----------- | --------- | --------- |
| Moodle | 5.3 LTS (`MOODLE_503_STABLE`) | General support to ~Oct 2027, security to ~Oct 2029 |
| PHP | 8.4 (`php8.4-*` on AL2023) | Security to 31 Dec 2028. Moodle 5.3 needs >= 8.3 and does not support 8.5 |
| Database | RDS for MariaDB 11.8 (LTS) | Moodle 5.3 requires MariaDB >= 11.4 |
| OS | Amazon Linux 2023 (ARM64) | End of support 30 Jun 2029 |

## Skills

Each skill is a folder with a `SKILL.md`. Copy them to `~/.claude/skills/` (all projects) or `.claude/skills/` (one project).

| Skill | Purpose |
| ------- | --------- |
| [moodle-deployment](skills/moodle-deployment/SKILL.md) | Orchestrates the whole deployment |
| [provision-infrastructure](skills/provision-infrastructure/SKILL.md) | AWS resources with Terraform |
| [setup-moodle-server](skills/setup-moodle-server/SKILL.md) | LAMP stack on Amazon Linux 2023 |
| [install-moodle](skills/install-moodle/SKILL.md) | Moodle install, cron, SMTP |
| [configure-ssl](skills/configure-ssl/SKILL.md) | HTTPS and security headers |
| [optimize-system](skills/optimize-system/SKILL.md) | PHP-FPM, Apache and OS tuning |
| [setup-backups](skills/setup-backups/SKILL.md) | Automated 3-2-1 backups |
| [setup-monitoring](skills/setup-monitoring/SKILL.md) | CloudWatch metrics and alarms |
| [setup-certificates](skills/setup-certificates/SKILL.md) | Automatic certificates with QR verification |
| [scale-infrastructure](skills/scale-infrastructure/SKILL.md) | Diagnosis and vertical scaling |
| [troubleshoot-moodle](skills/troubleshoot-moodle/SKILL.md) | Diagnosis of common problems |

Technical guides: [docs/01 to docs/11](docs/) (architecture, prerequisites, EC2, installation, optimization, SSL, backups, monitoring, maintenance, certificates, scaling).

## Estimated Costs

Approximate monthly figures for us-east-1, 2026. Check the AWS pricing pages before budgeting.

| Setup | EC2 | RDS | Storage + IP + alarms | Total |
|-------|-----|-----|-----------------------|-------|
| Basic | t4g.medium ~$24 | db.t4g.micro ~$12 | ~$8.60 | **~$45** |
| Improved | t4g.large ~$48 | db.t4g.small ~$24 | ~$11 | **~$83** |

**Free tier changed.** Since 15 July 2025, new accounts choose a Free plan (up to 6 months or until credits run out, only some services) or a Paid plan. Credits are USD 100 on sign-up plus up to USD 100 for completing activities, and they expire 12 months after account creation. EC2 plus RDS burns through them fast, so set up AWS Budgets (`monthly_budget_usd`). See [AWS Free Tier FAQs](https://aws.amazon.com/free/faqs/) and [docs/02-prerequisites.md](docs/02-prerequisites.md).

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for the full history of changes (in Spanish). Details of each change are in the [pull requests](https://github.com/ocastelblanco/moodle-development/pulls).

Latest release: **v2.0.0 (2026-11-25)**, which brings Moodle 5.3 LTS, PHP 8.4, RDS MariaDB 11.8, automatic certificates, scaling and SES SMTP credentials with Terraform.

## Frequently Asked Questions (FAQ)

1. **Why not Ubuntu 26.04?**
   * It ships PHP 8.5, which Moodle 5.3 does not support. Amazon Linux 2023 lets you pin PHP 8.4.
2. **Why not keep MariaDB 10.11?**
   * Moodle 5.3 raised the minimum to MariaDB 11.4.0, so 10.11 no longer installs.
3. **Is `tool_certificate` compatible with Moodle 5.3?**
   * At the time of writing the plugins directory lists it up to 5.2, while `mod_coursecertificate` covers 5.3. The certificates skill makes you check this before installing and describes a plan B (`mod_customcert`).
4. **What happens to Terraform after an automatic resize?**
   * Update `instance_type`, `db_instance_class` or `data_volume_size` in `terraform.tfvars` before the next `terraform apply`. Otherwise Terraform tries to revert the change.
5. **Is it tested on a real AWS account?**
   * Not yet. Scripts and Terraform pass syntax checks (`bash -n`, `shellcheck`, `terraform validate`). Run `terraform plan` in a test account first.
6. **Does it scale horizontally?**
   * No. It is a single-server design with vertical scaling. Auto Scaling with a load balancer, EFS and Valkey is planned for a later phase.

## Contributing

1. Never commit to `main`. Create a branch such as `feature/short-kebab-description`.
2. Run `bash -n` and `shellcheck` on any script you touch, and `terraform fmt` plus `terraform validate` on Terraform changes.
3. Commit specific files (no `git add .`), with messages in Spanish: `type(scope): description`.
4. Open a pull request against `main`. Nobody merges their own pull request.

Code and comments are in English. Documentation is in Spanish, and the READMEs are bilingual. AWS resources are named `{project}-{service}-{purpose}`.

**Working on your first pull request?** See guide: [How to Contribute to an Open Source Project on GitHub](https://kcd.im/pull-request)

## License

Distributed under the [Apache License 2.0](LICENSE).

## Support

Maintainer: [@ocastelblanco](https://github.com/ocastelblanco). Open an [issue](https://github.com/ocastelblanco/moodle-development/issues) for questions or bugs.
