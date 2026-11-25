#!/bin/bash
################################################################################
# Moodle 5.3 LTS - Automatic Course Certificates Setup
# Version: 1.0.0
# Date: 2026-11-25
# Description: Installs tool_certificate + mod_coursecertificate (Moodle HQ),
#              configures Amazon SES SMTP, completion tracking, conditional
#              access, public verification and the issuing scheduled task.
# Usage:       sudo scripts/08-setup-certificates.sh   (run on the EC2 host)
# Idempotent:  safe to re-run; existing plugin checkouts are updated in place.
################################################################################

# shellcheck disable=SC2016  # single quotes intentionally hold literal PHP/regex
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging (secrets are never echoed, so the log is safe to keep)
LOG_FILE="/var/log/moodle-certificates-setup.log"
exec > >(tee -a "$LOG_FILE")
exec 2>&1

fail() {
    echo -e "${RED}ERROR: $*${NC}"
    exit 1
}
warn() {
    echo -e "${YELLOW}WARNING: $*${NC}"
}
ok() {
    echo -e "${GREEN}✓${NC} $*"
}

echo "======================================================================"
echo "Moodle 5.3 LTS - Course Certificates Setup"
echo "Started: $(date)"
echo "======================================================================"

if [ "$EUID" -ne 0 ]; then
    fail "Please run as root or with sudo"
fi

################################################################################
# [1/8] Load configuration
################################################################################

echo -e "\n${BLUE}[1/8] Loading configuration...${NC}"

if [ -f /root/moodle-config.env ]; then
    # shellcheck disable=SC1091
    source /root/moodle-config.env
    ok "Configuration loaded from /root/moodle-config.env"
else
    fail "/root/moodle-config.env not found (it should have been created by Terraform)"
fi

MOODLE_DIR="${MOODLE_DIR:-/var/www/html/moodle}"
PHP_BIN="${PHP_BIN:-/usr/bin/php}"
AWS_REGION="${AWS_REGION:-us-east-1}"

CERT_MIN_GRADE_PERCENT="${CERT_MIN_GRADE_PERCENT:-70}"
CERT_PUBLIC_VERIFICATION="${CERT_PUBLIC_VERIFICATION:-true}"
CERT_PLUGIN_COURSECERT_VERSION="${CERT_PLUGIN_COURSECERT_VERSION:-}"
CERT_PLUGIN_TOOLCERT_VERSION="${CERT_PLUGIN_TOOLCERT_VERSION:-}"

SMTP_HOST="${SMTP_HOST:-email-smtp.${AWS_REGION}.amazonaws.com:587}"
SMTP_USER_SSM_PARAM="${SMTP_USER_SSM_PARAM:-}"
SMTP_PASS_SSM_PARAM="${SMTP_PASS_SSM_PARAM:-}"
NOREPLY_ADDRESS="${NOREPLY_ADDRESS:-${DOMAIN_NAME:+noreply@${DOMAIN_NAME}}}"

TOOLCERT_REPO="https://github.com/moodleworkplace/moodle-tool_certificate.git"
COURSECERT_REPO="https://github.com/moodleworkplace/moodle-mod_coursecertificate.git"
ISSUE_TASK='\mod_coursecertificate\task\issue_certificates_task'

for var in SMTP_USER_SSM_PARAM SMTP_PASS_SSM_PARAM NOREPLY_ADDRESS; do
    if [ -z "${!var}" ]; then
        fail "Required variable $var is not set (add it to /root/moodle-config.env)"
    fi
done

if ! [[ "$CERT_MIN_GRADE_PERCENT" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    fail "CERT_MIN_GRADE_PERCENT must be a number (got '$CERT_MIN_GRADE_PERCENT')"
fi

echo "  Moodle dir:          $MOODLE_DIR"
echo "  SMTP host:           $SMTP_HOST"
echo "  No-reply address:    $NOREPLY_ADDRESS"
echo "  Min grade (%):       $CERT_MIN_GRADE_PERCENT"
echo "  Public verification: $CERT_PUBLIC_VERIFICATION"

################################################################################
# [2/8] Preflight checks
################################################################################

echo -e "\n${BLUE}[2/8] Running preflight checks...${NC}"

[ -f "$MOODLE_DIR/config.php" ] || fail "$MOODLE_DIR/config.php not found. Run 03-install-moodle.sh first"

# Since Moodle 5.1 web files (incl. plugin dirs) live under public/; detect layout.
if [ -d "$MOODLE_DIR/public/mod" ]; then
    CODE_ROOT="$MOODLE_DIR/public"
else
    CODE_ROOT="$MOODLE_DIR"
fi
if [ -f "$MOODLE_DIR/admin/cli/upgrade.php" ]; then
    CLI_DIR="$MOODLE_DIR/admin/cli"
elif [ -f "$CODE_ROOT/admin/cli/upgrade.php" ]; then
    CLI_DIR="$CODE_ROOT/admin/cli"
else
    fail "Cannot find admin/cli/upgrade.php under $MOODLE_DIR"
fi
VERSION_FILE="$MOODLE_DIR/version.php"
[ -f "$VERSION_FILE" ] || VERSION_FILE="$CODE_ROOT/version.php"
[ -f "$VERSION_FILE" ] || fail "Cannot find Moodle version.php"

ok "Plugin root: $CODE_ROOT"
ok "CLI dir:     $CLI_DIR"

# Moodle branch must be >= 503 (5.3)
MOODLE_BRANCH=$(grep -E '^\$branch' "$VERSION_FILE" | grep -oE "[0-9]+" | head -n1 || true)
MOODLE_RELEASE=$(grep -E '^\$release' "$VERSION_FILE" | cut -d"'" -f2 || true)
if [ -z "$MOODLE_BRANCH" ] || [ "$MOODLE_BRANCH" -lt 503 ]; then
    fail "Moodle 5.3+ required (found branch '${MOODLE_BRANCH:-unknown}', release '${MOODLE_RELEASE:-unknown}')"
fi
ok "Moodle release: $MOODLE_RELEASE (branch $MOODLE_BRANCH)"

# PHP sodium extension (mandatory for Moodle 5.3)
if ! "$PHP_BIN" -m | grep -qi '^sodium$'; then
    fail "PHP extension 'sodium' not loaded (install php8.4-sodium)"
fi
ok "PHP sodium extension loaded"

# Cron every minute (certificates are issued by a scheduled task)
if grep -qs 'admin/cli/cron.php' /etc/cron.d/moodle || crontab -u apache -l 2>/dev/null | grep -q 'admin/cli/cron.php'; then
    ok "Moodle cron is configured"
else
    fail "Moodle cron not found (/etc/cron.d/moodle). Certificates will never be issued without cron"
fi

for bin in git aws sudo; do
    command -v "$bin" >/dev/null 2>&1 || fail "Required command '$bin' not found"
done
ok "git, aws and sudo available"

if grep -qE '^\s*\$CFG->noemailever\s*=\s*(true|1)' "$MOODLE_DIR/config.php"; then
    warn "\$CFG->noemailever is enabled in config.php: certificate emails will NOT be sent"
fi

################################################################################
# Helpers
################################################################################

# Run a Moodle CLI script as the web server user
moodle_cli() {
    sudo -u apache "$PHP_BIN" "$CLI_DIR/$1" "${@:2}"
}

# Set a core/plugin config value (non-secret values only; args are visible in ps)
set_cfg() {
    local name="$1" value="$2" component="${3:-}"
    if [ -n "$component" ]; then
        moodle_cli cfg.php --component="$component" --name="$name" --set="$value" >/dev/null
    else
        moodle_cli cfg.php --name="$name" --set="$value" >/dev/null
    fi
}

# Run a PHP snippet inside Moodle as apache. Snippet is passed via a temp file
# so that secrets can be piped through STDIN instead of argv.
moodle_php() {
    local snippet="$1" tmp
    tmp=$(mktemp /tmp/moodle-cert-XXXXXX.php)
    chmod 644 "$tmp"
    {
        echo '<?php'
        echo 'define("CLI_SCRIPT", true);'
        echo "require('$MOODLE_DIR/config.php');"
        echo "$snippet"
    } > "$tmp"
    local rc=0
    sudo -u apache "$PHP_BIN" "$tmp" || rc=$?
    rm -f "$tmp"
    return "$rc"
}

# Clone or update a plugin repository; optional ref (tag or branch)
install_plugin() {
    local repo="$1" dest="$2" ref="$3" name="$4"

    echo "  -> $name"
    if ! git ls-remote --exit-code "$repo" HEAD >/dev/null 2>&1; then
        fail "Repository not reachable: $repo (check network/URL; see moodle.org/plugins/$name)"
    fi
    if [ -n "$ref" ] && ! git ls-remote --exit-code "$repo" "refs/tags/$ref" "refs/heads/$ref" >/dev/null 2>&1; then
        fail "Ref '$ref' not found in $repo"
    fi

    if [ -d "$dest/.git" ]; then
        git -c safe.directory='*' -C "$dest" fetch --tags --prune origin
        if [ -n "$ref" ]; then
            git -c safe.directory='*' -C "$dest" checkout -q "$ref"
            # Fast-forward when the ref is a branch
            if git -c safe.directory='*' -C "$dest" symbolic-ref -q HEAD >/dev/null; then
                git -c safe.directory='*' -C "$dest" pull -q --ff-only origin "$ref"
            fi
        else
            git -c safe.directory='*' -C "$dest" pull -q --ff-only
        fi
        ok "$name updated ($(git -c safe.directory='*' -C "$dest" describe --tags --always))"
    elif [ -d "$dest" ]; then
        warn "$dest exists but is not a git checkout (installed from ZIP?). Leaving it untouched"
    else
        if [ -n "$ref" ]; then
            git clone -q --branch "$ref" "$repo" "$dest"
        else
            git clone -q "$repo" "$dest"
        fi
        ok "$name installed ($(git -c safe.directory='*' -C "$dest" describe --tags --always))"
    fi

    # Validate plugin declares Moodle 5.3 support when it uses $plugin->supported
    local supported
    supported=$(grep -E '^\s*\$plugin->supported' "$dest/version.php" 2>/dev/null || true)
    if [ -n "$supported" ]; then
        local max
        max=$(echo "$supported" | grep -oE '[0-9]+' | tail -n1)
        if [ -n "$max" ] && [ "$max" -lt "$MOODLE_BRANCH" ]; then
            warn "$name declares supported range '$supported' (< $MOODLE_BRANCH). Verify compatibility on moodle.org/plugins before going to production"
        else
            ok "$name declares: $supported"
        fi
    fi
}

################################################################################
# [3/8] Install plugins
################################################################################

echo -e "\n${BLUE}[3/8] Installing certificate plugins...${NC}"

# tool_certificate must be present before mod_coursecertificate (dependency)
install_plugin "$TOOLCERT_REPO" "$CODE_ROOT/admin/tool/certificate" "$CERT_PLUGIN_TOOLCERT_VERSION" "tool_certificate"
install_plugin "$COURSECERT_REPO" "$CODE_ROOT/mod/coursecertificate" "$CERT_PLUGIN_COURSECERT_VERSION" "mod_coursecertificate"

chown -R apache:apache "$CODE_ROOT/admin/tool/certificate" "$CODE_ROOT/mod/coursecertificate"
ok "Ownership set to apache:apache"

################################################################################
# [4/8] Run Moodle upgrade
################################################################################

echo -e "\n${BLUE}[4/8] Running Moodle upgrade (plugin installation)...${NC}"

moodle_cli upgrade.php --non-interactive
ok "Upgrade completed"

################################################################################
# [5/8] Configure outgoing mail (Amazon SES SMTP)
################################################################################

echo -e "\n${BLUE}[5/8] Configuring Amazon SES SMTP...${NC}"

SMTP_USER=$(aws ssm get-parameter --region "$AWS_REGION" --name "$SMTP_USER_SSM_PARAM" \
    --with-decryption --query 'Parameter.Value' --output text) \
    || fail "Cannot read SSM parameter $SMTP_USER_SSM_PARAM (check the instance IAM role)"
SMTP_PASS=$(aws ssm get-parameter --region "$AWS_REGION" --name "$SMTP_PASS_SSM_PARAM" \
    --with-decryption --query 'Parameter.Value' --output text) \
    || fail "Cannot read SSM parameter $SMTP_PASS_SSM_PARAM (check the instance IAM role)"

set_cfg smtphosts "$SMTP_HOST"
set_cfg smtpsecure "tls"
set_cfg smtpauthtype "LOGIN"
set_cfg noreplyaddress "$NOREPLY_ADDRESS"
# SES only accepts verified senders: always send from the no-reply address
set_cfg emailonlyfromnoreplyaddress "1"

# Secrets go through STDIN, never argv or logs
printf '%s\n%s' "$SMTP_USER" "$SMTP_PASS" | moodle_php '
$lines = explode("\n", stream_get_contents(STDIN), 2);
set_config("smtpuser", trim($lines[0]));
set_config("smtppass", trim($lines[1] ?? ""));
'
unset SMTP_USER SMTP_PASS
ok "SMTP configured (credentials loaded from SSM, not displayed)"

################################################################################
# [6/8] Completion tracking, conditional access, public verification
################################################################################

echo -e "\n${BLUE}[6/8] Configuring completion, availability and verification...${NC}"

set_cfg enablecompletion "1"
ok "Completion tracking enabled (enablecompletion=1)"
set_cfg enableavailability "1"
ok "Conditional access enabled (enableavailability=1)"

if [ "$CERT_PUBLIC_VERIFICATION" = "true" ]; then
    SETTINGS_FILE="$CODE_ROOT/admin/tool/certificate/settings.php"
    # Discover verification-related setting names from the plugin instead of guessing
    VERIFY_SETTINGS=$(grep -oE "tool_certificate/[a-zA-Z0-9_]*verif[a-zA-Z0-9_]*" "$SETTINGS_FILE" 2>/dev/null | sort -u || true)
    if [ -n "$VERIFY_SETTINGS" ]; then
        for setting in $VERIFY_SETTINGS; do
            set_cfg "${setting#tool_certificate/}" "1" tool_certificate
            ok "Enabled $setting"
        done
    else
        echo "  No verification setting found in tool_certificate settings.php (access is capability-based)"
    fi

    # Allow the not-logged-in (guest) role to use the verification page, if capability exists
    moodle_php '
$cap = "tool/certificate:verify";
if (!get_capability_info($cap)) {
    echo "  Capability $cap not defined by this plugin version: review verification access manually\n";
    exit(0);
}
$roleid = (int)$CFG->notloggedinroleid;
assign_capability($cap, CAP_ALLOW, $roleid, context_system::instance()->id, true);
echo "  Granted $cap to not-logged-in role (id $roleid)\n";
'
    ok "Public verification configured"
else
    echo "  CERT_PUBLIC_VERIFICATION=$CERT_PUBLIC_VERIFICATION: verification limited to authenticated users"
fi

################################################################################
# [7/8] Ensure issuing scheduled task is enabled
################################################################################

echo -e "\n${BLUE}[7/8] Checking scheduled task ${ISSUE_TASK}...${NC}"

moodle_php '
$classname = "\\mod_coursecertificate\\task\\issue_certificates_task";
$task = \core\task\manager::get_scheduled_task($classname);
if (!$task) {
    fwrite(STDERR, "Scheduled task $classname not found\n");
    exit(1);
}
if ($task->get_disabled()) {
    $task->set_disabled(false);
    \core\task\manager::configure_scheduled_task($task);
    echo "  Task was disabled: enabled now\n";
} else {
    echo "  Task is enabled\n";
}
' || fail "Issue certificates scheduled task not available (is mod_coursecertificate installed?)"
ok "Scheduled task ready"

################################################################################
# [8/8] Purge caches and summary
################################################################################

echo -e "\n${BLUE}[8/8] Purging caches...${NC}"
moodle_cli purge_caches.php
ok "Caches purged"

echo ""
echo "======================================================================"
echo -e "${GREEN}Certificates setup completed${NC}"
echo "Finished: $(date)"
echo "======================================================================"
echo ""
echo "Installed:"
echo "  - tool_certificate       -> $CODE_ROOT/admin/tool/certificate"
echo "  - mod_coursecertificate  -> $CODE_ROOT/mod/coursecertificate"
echo ""
echo "Manual next steps (see docs/10-certificates.md):"
echo "  1. Site admin > Certificates > Manage certificate templates: create a template"
echo "     with full name, course name, completion date, grade, ID number (cédula),"
echo "     verification code and QR code elements."
echo "  2. Per course: enable completion tracking and define completion criteria."
echo "  3. Per course: add a 'Course certificate' activity with the template and"
echo "     'Automatic sending' = Yes."
echo "  4. Access restrictions on that activity:"
echo "     - Course completion: must be marked complete"
echo "     - Grade: Course total >= ${CERT_MIN_GRADE_PERCENT}%"
echo "  5. Test end-to-end with a test student, then force the task:"
echo "     sudo -u apache $PHP_BIN $CLI_DIR/scheduled_task.php --execute='${ISSUE_TASK}'"
echo "  6. Verify a code at: https://${DOMAIN_NAME:-<your-domain>}/admin/tool/certificate/index.php"
echo ""
echo "Log file: $LOG_FILE"
