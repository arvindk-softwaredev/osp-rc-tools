#!/usr/bin/env bash
#
# update-jiraField.sh — Update a field on a list of Jira issues.
#
# A generic Jira field updater that applies add/remove/set operations
# to any field on issues listed in a JSON file.
#
# Usage:
#   ./update-jiraField.sh -f jiras.json -k fixVersions -v "openshift-pipelines-1.16" -o add --named
#   ./update-jiraField.sh -f jiras.json -k labels -v "release-blocker" -o add
#   ./update-jiraField.sh -f jiras.json -k labels -v "stale" -o remove
#   ./update-jiraField.sh -f jiras.json -k priority -v "Critical" -o set --named
#   ./update-jiraField.sh -f jiras.json -k summary -v "New title" -o set
#   ./update-jiraField.sh -f jiras.json -k fixVersions -v "openshift-pipelines-1.16" -o add --named --dry-run
#
# JSON file format (jiras.json):
#   ["SRVKP-1234", "SRVKP-5678", "SRVKP-9012"]
#
# Options:
#   -f, --file        Path to JSON file containing issue keys (required)
#   -k, --key         Jira field name, e.g. fixVersions, labels, priority (required)
#   -v, --value       Value to add/remove/set (required)
#   -o, --operation   Operation: add, remove, or set (required)
#   --named           Wrap value as {"name":"<value>"} for fields like
#                     fixVersions, components, priority. Without this flag
#                     the plain string value is used (for labels, summary, etc.)
#   --dry-run         Print what would happen without making changes
#   -h, --help        Show this help message
#
# Environment variables:
#   JIRA_EMAIL   — Atlassian account email (required)
#   JIRA_TOKEN   — Atlassian Cloud API token (required)
#   JIRA_URL     — Jira server URL (default: https://redhat.atlassian.net)
#                  JIRA_URL is accepted as a fallback
#

set -euo pipefail

# --- Defaults ---
JIRA_URL="${JIRA_URL:-${JIRA_URL:-https://redhat.atlassian.net}}"
DRY_RUN=false
FILE=""
FIELD_KEY=""
FIELD_VALUE=""
OPERATION=""
NAMED=false

# --- Parse arguments ---
usage() {
    cat <<'EOF'
Usage: update-jiraField.sh -f <jiras.json> -k <field> -v <value> -o <operation> [--named] [--dry-run]

Options:
  -f, --file        Path to JSON file containing issue keys (required)
  -k, --key         Jira field name (required)
  -v, --value       Value to add/remove/set (required)
  -o, --operation   Operation: add, remove, or set (required)
  --named           Wrap value as {"name":"<value>"} (for fixVersions, components, etc.)
  --dry-run         Print what would happen without making changes
  -h, --help        Show this help message

Examples:
  # Add a fixVersion (named object):
  ./update-jiraField.sh -f jiras.json -k fixVersions -v "openshift-pipelines-1.16" -o add --named

  # Add a label (plain string):
  ./update-jiraField.sh -f jiras.json -k labels -v "release-blocker" -o add

  # Remove a label:
  ./update-jiraField.sh -f jiras.json -k labels -v "stale" -o remove

  # Set priority (named object):
  ./update-jiraField.sh -f jiras.json -k priority -v "Critical" -o set --named

  # Set summary (plain string):
  ./update-jiraField.sh -f jiras.json -k summary -v "New title" -o set
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--file)      FILE="$2"; shift 2 ;;
        -k|--key)       FIELD_KEY="$2"; shift 2 ;;
        -v|--value)     FIELD_VALUE="$2"; shift 2 ;;
        -o|--operation) OPERATION="$2"; shift 2 ;;
        --named)        NAMED=true; shift ;;
        --dry-run)      DRY_RUN=true; shift ;;
        -h|--help)      usage ;;
        *)              echo "Unknown option: $1"; usage ;;
    esac
done

[[ -z "$FILE" ]]        && { echo "Error: --file is required."; usage; }
[[ -z "$FIELD_KEY" ]]   && { echo "Error: --key is required."; usage; }
[[ -z "$FIELD_VALUE" ]] && { echo "Error: --value is required."; usage; }
[[ -z "$OPERATION" ]]   && { echo "Error: --operation is required."; usage; }

case "$OPERATION" in
    add|remove|set) ;;
    *) echo "Error: --operation must be 'add', 'remove', or 'set'."; usage ;;
esac

[[ -z "${JIRA_EMAIL:-}" ]] && { echo "Error: Set JIRA_EMAIL environment variable."; exit 1; }
[[ -z "${JIRA_TOKEN:-}" ]] && { echo "Error: Set JIRA_TOKEN environment variable."; exit 1; }

# --- Check dependencies ---
for cmd in jq curl; do
    command -v "$cmd" &>/dev/null || { echo "Error: '$cmd' is required but not found."; exit 1; }
done

# --- Load issue keys ---
if [[ ! -f "$FILE" ]]; then
    echo "Error: File '$FILE' not found."
    exit 1
fi

mapfile -t KEYS < <(jq -r '.[]' "$FILE")

if [[ ${#KEYS[@]} -eq 0 ]]; then
    echo "Error: No issue keys found in '$FILE'."
    exit 1
fi

# --- Build JSON payload ---
# Use jq to safely construct the value (no string interpolation in JSON).
if $NAMED; then
    VALUE_JSON=$(jq -n --arg v "$FIELD_VALUE" '{"name": $v}')
else
    VALUE_JSON=$(jq -n --arg v "$FIELD_VALUE" '$v')
fi

if [[ "$OPERATION" == "set" ]]; then
    # "set" uses {"fields": {"key": value}} for plain values,
    # or {"update": {"key": [{"set": value}]}} for consistency.
    PAYLOAD=$(jq -n --arg key "$FIELD_KEY" --argjson val "$VALUE_JSON" \
        '{"update": {($key): [{"set": $val}]}}')
else
    # "add" and "remove" use {"update": {"key": [{"add/remove": value}]}}
    PAYLOAD=$(jq -n --arg key "$FIELD_KEY" --arg op "$OPERATION" --argjson val "$VALUE_JSON" \
        '{"update": {($key): [{($op): $val}]}}')
fi

echo "Loaded ${#KEYS[@]} issue(s) from $FILE"
echo "Field: $FIELD_KEY | Operation: $OPERATION | Value: $FIELD_VALUE"
$NAMED && echo "Value format: named object {\"name\": \"$FIELD_VALUE\"}" || echo "Value format: plain string"
echo "Jira URL: $JIRA_URL"
$DRY_RUN && echo "*** DRY RUN — no changes will be made ***"
echo "--------------------------------------------------"

# --- Update each issue ---
SUCCESS=0
FAILED=0

for KEY in "${KEYS[@]}"; do
    if $DRY_RUN; then
        echo "  [DRY RUN] $KEY — would $OPERATION '$FIELD_VALUE' on field '$FIELD_KEY'"
        SUCCESS=$((SUCCESS + 1))
        continue
    fi

    BODY_FILE=$(mktemp)
    HTTP_CODE=$(curl -sS -o "$BODY_FILE" -w "%{http_code}" \
        -X PUT \
        -u "${JIRA_EMAIL}:${JIRA_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "$PAYLOAD" \
        "${JIRA_URL}/rest/api/3/issue/${KEY}") || true

    if [[ "$HTTP_CODE" == "204" ]]; then
        echo "  $KEY — $OPERATION '$FIELD_VALUE' on '$FIELD_KEY' succeeded"
        SUCCESS=$((SUCCESS + 1))
    else
        echo "  $KEY — HTTP $HTTP_CODE: $(tr '\n' ' ' < "$BODY_FILE")"
        FAILED=$((FAILED + 1))
    fi
    rm -f "$BODY_FILE"
done

echo "--------------------------------------------------"
echo "Done. Success: $SUCCESS, Failed: $FAILED"
