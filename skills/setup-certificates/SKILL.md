---
name: setup-certificates
description: >-
  Installs and configures automatic course-completion certificates in Moodle 5.3 LTS (Amazon Linux 2023, PHP 8.4, RDS MariaDB 11.8) using mod_coursecertificate + tool_certificate, with PDF delivery by email through Amazon SES SMTP and public verification by code/QR. Use when a student must automatically receive a downloadable and emailed certificate once they complete a course and reach a minimum course grade, or when the user needs to design certificate templates, configure verification, or troubleshoot certificates that are not issued or not emailed. Triggers: "certificados", "certificates", "certificate on completion", "certificado automático", "verificación QR", "verify certificate", "course certificate", "tool_certificate", "mod_coursecertificate", "certificado por correo".
---

# Setup Course Certificates (Moodle 5.3 LTS)

## Instructions

### Context

This skill delivers:
- **Automatic issuance** when a student is approved: course completion AND course total >= minimum grade (default 70 %).
- **PDF by email** through Amazon SES SMTP (TLS, port 587), plus download from the activity page and *Profile > My certificates*.
- **Public verification** by code and QR (`/admin/tool/certificate/index.php`).

Plugins (Moodle HQ / Workplace):
| Plugin | Role | Path (5.1+ layout) |
|--------|------|--------------------|
| `tool_certificate` | Template designer, issue storage, verification page | `public/admin/tool/certificate` |
| `mod_coursecertificate` | Course activity, automatic sending | `public/mod/coursecertificate` |

How issuance works: the scheduled task `\mod_coursecertificate\task\issue_certificates_task` ("Issue course certificates") runs from cron, finds participants with `mod/coursecertificate:receive` who satisfy the activity's access restrictions, issues the certificate and emails the PDF when *Automatic sending* is enabled.

### Required prerequisites

- Moodle **5.3** installed (`scripts/03-install-moodle.sh`), branch `MOODLE_503_STABLE`, PHP 8.4 with `sodium`.
- Moodle cron running **every minute** (`/etc/cron.d/moodle`).
- Amazon SES: domain verified, **out of sandbox** (`aws ses get-account` → `ProductionAccessEnabled: true`), SMTP credentials stored in SSM Parameter Store as `SecureString`.
- EC2 instance role allowed to `ssm:GetParameter` (+ `kms:Decrypt`) on those two parameters only.
- Terraform option: `enable_ses_smtp = true` (`terraform/ses.tf`) creates the SES identity (Easy DKIM), DNS records (Route 53 or `ses_dns_records_manual` output), least-privilege IAM SMTP user, SSM `SecureString` params and the EC2 read grant. Take `SMTP_*`/`NOREPLY_ADDRESS` from its `ses_*` outputs (password is never output). It stores the SMTP password in Terraform state: require the encrypted S3 backend. Sandbox exit stays manual.
- Rotation: bump `ses_smtp_key_version` → `terraform apply` → immediately re-run `scripts/08-setup-certificates.sh` (mail fails in between) → *Test outgoing mail*.
- Variables in `/root/moodle-config.env`:

```bash
CERT_MIN_GRADE_PERCENT=70                 # informative; applied per course in restrictions
CERT_PUBLIC_VERIFICATION=true
CERT_PLUGIN_TOOLCERT_VERSION=""           # git tag/branch; empty = default branch
CERT_PLUGIN_COURSECERT_VERSION=""
SMTP_HOST="email-smtp.us-east-1.amazonaws.com:587"
SMTP_USER_SSM_PARAM="/{proyecto}/ses/smtp-user"
SMTP_PASS_SSM_PARAM="/{proyecto}/ses/smtp-password"
NOREPLY_ADDRESS="noreply@example.edu.co"   # must be a verified SES identity
```

### Step 1 – Compatibility check (MANDATORY)

At the time of writing, the plugins directory lists `mod_coursecertificate` for 3.9–5.3 but **`tool_certificate` only up to 5.2**.

1. Open https://moodle.org/plugins/tool_certificate and https://moodle.org/plugins/mod_coursecertificate and confirm a release for **Moodle 5.3**.
2. Pick the matching git tag/branch and set `CERT_PLUGIN_*_VERSION`.
3. After cloning, check `$plugin->supported` / `$plugin->requires` in each `version.php` (the script warns if the range ends below 503).
4. Test on a staging copy first if 5.3 is not officially listed.

**Plan B – `mod_customcert` 5.3.5+** (supports 5.3):
- Issues the certificate **only when the student views the activity** (issue-on-view), unless you enable its scheduled task.
- Required settings: *Email students* = Yes on each activity, and the scheduled task `\mod_customcert\task\issue_certificates_task` enabled (*Site admin > Server > Scheduled tasks*).
- Same access restrictions (completion + grade) apply. Verification via its own verify page and QR element.
- Moodle 5.3 is the last version with mod_customcert's legacy element API; Moodle 6.0 removes it.

### Step 2 – Install and configure (automated)

```bash
sudo scripts/08-setup-certificates.sh
```

The script (idempotent):
1. Preflight: Moodle branch >= 503, `sodium` loaded, cron present, `git`/`aws` available.
2. Verifies repos with `git ls-remote`, clones/updates:
   - `https://github.com/moodleworkplace/moodle-tool_certificate` → `admin/tool/certificate`
   - `https://github.com/moodleworkplace/moodle-mod_coursecertificate` → `mod/coursecertificate`
3. `chown apache`, runs `admin/cli/upgrade.php --non-interactive` as `apache`.
4. SMTP: `smtphosts`, `smtpsecure=tls`, `smtpauthtype=LOGIN`, `noreplyaddress`, `emailonlyfromnoreplyaddress=1`; `smtpuser`/`smtppass` read from SSM and written via STDIN (never in argv or logs).
5. `enablecompletion=1`, `enableavailability=1`.
6. Public verification: discovers verification settings in the plugin's `settings.php`; grants `tool/certificate:verify` to the not-logged-in role if the capability exists.
7. Ensures the issuing scheduled task is enabled; purges caches.

Manual equivalent for a single setting:
```bash
sudo -u apache php /var/www/html/moodle/admin/cli/cfg.php --name=enablecompletion --set=1
```

### Step 3 – Certificate template (site admin)

*Site administration > Certificates > Manage certificate templates > New certificate template*

Add elements:
| Element | Source |
|---------|--------|
| Full name | User field → Full name |
| ID number / cédula | User field → `idnumber` or a custom profile field (e.g. `cedula`) |
| Course name | Course field → Full name (mod_coursecertificate provides course fields) |
| Completion date | Course completion date |
| Grade | Course grade |
| Verification code | Code element |
| QR code | QR element (links to the verification page) |

Upload a background image (A4/Letter landscape, ≤ 1 MB) and logos. Share the template with the course categories that will use it.

### Step 4 – Per-course recipe (teacher / manager)

1. *Course settings > Completion tracking* = Yes.
2. *Course completion*: criteria (e.g. all graded activities complete, or "Course grade" ≥ pass).
3. Gradebook: course total aggregation correct; set *Grade to pass* if desired.
4. Add activity **Course certificate**:
   - Template: the institutional template.
   - **Automatic sending: Yes**.
   - *Restrict access* (all must be met):
     - **Course completion**: must be marked complete.
     - **Grade**: *Course total* ≥ `CERT_MIN_GRADE_PERCENT` % (e.g. 70 %, or 3.0/5.0 → 60 %).
   - Hide the restriction details from students if preferred.
5. Optional: *Expiry date* for certificates that must be renewed.

### Step 5 – Validation

```bash
# 1. Mail transport works
sudo -u apache php /var/www/html/moodle/admin/cli/cfg.php --name=smtphosts
# Site admin > Server > Email > Test outgoing mail configuration

# 2. With a test student who meets both conditions, force the task
sudo -u apache php /var/www/html/moodle/admin/cli/scheduled_task.php \
  --execute='\mod_coursecertificate\task\issue_certificates_task'

# 3. Check the task is enabled and when it ran last
sudo -u apache php /var/www/html/moodle/admin/cli/scheduled_task.php --list | grep -i certificate
```

Expected:
- The student receives the email with the PDF attached.
- The certificate appears in the activity and in *Profile > My certificates*.
- The code/QR opens the verification page in a private window (not logged in) and shows **Valid**.
- A student below the minimum grade does NOT receive a certificate.

### Troubleshooting

| Symptom | Check |
|---------|-------|
| No certificate issued | Cron running? Task enabled and not failing (*Server > Tasks > Task logs*)? Student meets BOTH restrictions? Completion recalculated (completion is computed by cron `\core\task\completion_regular_task`)? |
| Issued but no email | *Automatic sending* = Yes; `noemailever` not set; SES out of sandbox; `noreplyaddress` is a verified identity; use *Test outgoing mail* (with debugging on) and SES sending statistics/bounces. |
| Grade restriction never met | Course total hidden/locked or not recalculated; regrade via gradebook; check percentage vs. real scale. |
| Verification page asks for login | `tool/certificate:verify` not allowed for the not-logged-in role; `forcelogin` enabled (blocks all anonymous pages). |
| Plugin install fails on upgrade | Version mismatch with 5.3 → see Step 1 / plan B; check `$plugin->requires`. |
| PDF missing fields (cédula) | Profile field shortname wrong, or field empty for the user. |

### Security notes

- Verification page must expose only **name, course, issue date, code/status**. Do not add cédula, email or grades to the public verification output.
- Never hardcode SMTP credentials; keep them in SSM `SecureString`. The script never echoes them.
- Review capabilities after install: `tool/certificate:verify` (guest only, if public verification), `tool/certificate:manage`/`issue`/`viewallcertificates` (managers only), `mod/coursecertificate:receive` (students only).
- Templates with `idnumber`/cédula are personal data (Ley 1581 de 2012, Colombia): inform students in the privacy policy.
- Keep plugins upgraded together with Moodle core (security releases).

## References

- Script: `scripts/08-setup-certificates.sh`
- Guide (ES): `docs/10-certificates.md`
- https://moodle.org/plugins/mod_coursecertificate
- https://moodle.org/plugins/tool_certificate
- https://moodle.org/plugins/mod_customcert (plan B)
