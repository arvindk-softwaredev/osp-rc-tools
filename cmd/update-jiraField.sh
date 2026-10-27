#!/usr/bin/env bash
#
# update-jiraField.sh — Update Jira issues.
#
# Closes every issue in a fixVersion or a JSON key list, or applies
# add/remove/set to a field on issues listed in a JSON file.
#
# Usage:
#   ./update-jiraField.sh --close -v "Pipelines 1.23.3"
#   ./update-jiraField.sh --close -f jiras.json
#   ./update-jiraField.sh --close -v "Pipelines 1.23.3" --resolution "Done" --dry-run
#   ./update-jiraField.sh --close -f jiras.json --dry-run
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
#   --close           Close issues via the Closed workflow transition.
#                     Pass -v <fixVersion> or -f <jiras.json>, not both.
#                     Resolution defaults to "Done" (required by that transition).
#   --resolution      Resolution name used with --close (default: Done)
#   -f, --file        JSON file of issue keys. With --close, closes those keys.
#                     Otherwise required for a field update.
#   -k, --key         Jira field name, e.g. fixVersions, labels, priority (required unless --close)
#   -v, --value       Field value, or the fixVersion name when closing by version.
#                     Required unless --close -f is used.
#   -o, --operation   Operation: add, remove, or set (required unless --close)
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
#

set -euo pipefail

# --- Defaults ---
JIRA_URL="${JIRA_URL:-https://redhat.atlassian.net}"
DRY_RUN=false
CLOSE=false
FILE=""
FIELD_KEY=""
FIELD_VALUE=""
OPERATION=""
RESOLUTION="Done"
NAMED=false

# --- Parse arguments ---
usage() {
    cat <<'EOF'
Usage: update-jiraField.sh --close -v <fixVersion> [--resolution <name>] [--dry-run]
       update-jiraField.sh --close -f <jiras.json> [--resolution <name>] [--dry-run]
       update-jiraField.sh -f <jiras.json> -k <field> -v <value> -o <operation> [--named] [--dry-run]

Options:
  --close           Close issues (Closed transition). Use -v or -f, not both.
  --resolution      Resolution for --close (default: Done)
  -f, --file        JSON file of issue keys. Closes those keys when used with --close.
  -k, --key         Jira field name (required unless --close)
  -v, --value       Field value, or fixVersion name for --close -v
  -o, --operation   Operation: add, remove, or set (required unless --close)
  --named           Wrap value as {"name":"<value>"} (for fixVersions, components, etc.)
  --dry-run         Print what would happen without making changes
  -h, --help        Show this help message

Examples:
  # Close every issue in a fixVersion:
  ./update-jiraField.sh --close -v "Pipelines 1.23.3" --dry-run

  # Close the issues listed in a JSON file:
  ./update-jiraField.sh --close -f jiras.json --dry-run

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
        -f|--file)       FILE="$2"; shift 2 ;;
        -k|--key)        FIELD_KEY="$2"; shift 2 ;;
        -v|--value)      FIELD_VALUE="$2"; shift 2 ;;
        -o|--operation)  OPERATION="$2"; shift 2 ;;
        --close)         CLOSE=true; shift ;;
        --resolution)    RESOLUTION="$2"; shift 2 ;;
        --named)         NAMED=true; shift ;;
        --dry-run)       DRY_RUN=true; shift ;;
        -h|--help)       usage ;;
        *)              echo "Unknown option: $1"; usage ;;
    esac
done

if $CLOSE; then
    if [[ -n "$FIELD_KEY" || -n "$OPERATION" ]] || $NAMED; then
        echo "Error: --close does not accept -k, -o, or --named."
        usage
    fi
    if [[ -n "$FILE" && -n "$FIELD_VALUE" ]]; then
        echo "Error: --close accepts either -f or -v, not both."
        usage
    fi
    if [[ -z "$FILE" && -z "$FIELD_VALUE" ]]; then
        echo "Error: --close requires -f <jiras.json> or -v <fixVersion>."
        usage
    fi
    [[ -z "$RESOLUTION" ]] && { echo "Error: --resolution cannot be empty."; exit 1; }
else
    [[ -z "$FILE" ]]        && { echo "Error: --file is required."; usage; }
    [[ -z "$FIELD_KEY" ]]   && { echo "Error: --key is required."; usage; }
    [[ -z "$FIELD_VALUE" ]] && { echo "Error: --value is required."; usage; }
    [[ -z "$OPERATION" ]]   && { echo "Error: --operation is required."; usage; }
    case "$OPERATION" in
        add|remove|set) ;;
        *) echo "Error: --operation must be 'add', 'remove', or 'set'."; usage ;;
    esac
fi

[[ -z "${JIRA_EMAIL:-}" ]] && { echo "Error: Set JIRA_EMAIL environment variable."; exit 1; }
[[ -z "${JIRA_TOKEN:-}" ]] && { echo "Error: Set JIRA_TOKEN environment variable."; exit 1; }

# --- Check dependencies ---
for cmd in jq curl; do
    command -v "$cmd" &>/dev/null || { echo "Error: '$cmd' is required but not found."; exit 1; }
done

# HTTP call. Prints the status code. Response body is written to outfile.
# data may be empty for requests with no body.
jira_curl() {
    local method="$1" url="$2" data="$3" outfile="$4"
    if [[ -n "$data" ]]; then
        curl -sS -o "$outfile" -w "%{http_code}" \
            -X "$method" \
            -u "${JIRA_EMAIL}:${JIRA_TOKEN}" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            --data "$data" \
            "$url" || true
    else
        curl -sS -o "$outfile" -w "%{http_code}" \
            -X "$method" \
            -u "${JIRA_EMAIL}:${JIRA_TOKEN}" \
            -H "Accept: application/json" \
            "$url" || true
    fi
}

# Move one issue to Status=Closed. Resolution is required by that transition.
# Already-Closed issues are skipped. Issues with no Closed transition are failures.
close_one() {
    local key="$1" status="$2" body http tid names payload

    if [[ "$status" == "Closed" ]]; then
        echo "  $key — already Closed"
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi

    body=$(mktemp)
    http=$(jira_curl GET "${JIRA_URL}/rest/api/3/issue/${key}/transitions" "" "$body")
    if [[ "$http" != "200" ]]; then
        echo "  $key — HTTP $http reading transitions: $(tr '\n' ' ' < "$body")"
        FAILED=$((FAILED + 1))
        rm -f "$body"
        return 0
    fi

    tid=$(jq -r 'first(.transitions[]? | select(.to.name == "Closed") | .id) // empty' "$body")
    if [[ -z "$tid" ]]; then
        names=$(jq -r '[.transitions[]?.name] | join(", ")' "$body")
        [[ -z "$names" ]] && names="none"
        echo "  $key — no Closed transition from '$status' (available: $names)"
        FAILED=$((FAILED + 1))
        rm -f "$body"
        return 0
    fi
    rm -f "$body"

    if $DRY_RUN; then
        echo "  [DRY RUN] $key — would set Status to Closed from '$status' (resolution '$RESOLUTION')"
        SUCCESS=$((SUCCESS + 1))
        return 0
    fi

    payload=$(jq -n --arg id "$tid" --arg res "$RESOLUTION" \
        '{transition: {id: $id}, fields: {resolution: {name: $res}}}')
    body=$(mktemp)
    http=$(jira_curl POST "${JIRA_URL}/rest/api/3/issue/${key}/transitions" "$payload" "$body")
    if [[ "$http" == "204" ]]; then
        echo "  $key — Status set to Closed (resolution '$RESOLUTION')"
        SUCCESS=$((SUCCESS + 1))
    else
        echo "  $key — HTTP $http: $(tr '\n' ' ' < "$body")"
        FAILED=$((FAILED + 1))
    fi
    rm -f "$body"
}

# Find every issue with fixVersion $FIELD_VALUE and close it.
close_by_fixversion() {
    local list body payload next="" page_count is_last seen="" http
    local key status total

    list=$(mktemp)
    echo "FixVersion: $FIELD_VALUE"
    echo "Transition: Closed | Resolution: $RESOLUTION"
    echo "Jira URL: $JIRA_URL"
    $DRY_RUN && echo "*** DRY RUN — no changes will be made ***"
    echo "--------------------------------------------------"

    while true; do
        payload=$(jq -n --arg v "$FIELD_VALUE" --arg token "$next" '
            {
                jql: ("fixVersion = \"" + ($v | gsub("\\\\"; "\\\\\\\\") | gsub("\""; "\\\\\"")) + "\""),
                fields: ["status"],
                maxResults: 100
            }
            + (if $token == "" then {} else {nextPageToken: $token} end)
        ')
        body=$(mktemp)
        http=$(jira_curl POST "${JIRA_URL}/rest/api/3/search/jql" "$payload" "$body")
        if [[ "$http" != "200" ]]; then
            echo "Search failed — HTTP $http: $(tr '\n' ' ' < "$body")"
            rm -f "$body" "$list"
            return 1
        fi

        jq -r '.issues[]? | [.key, (.fields.status.name // "")] | @tsv' "$body" >> "$list"
        page_count=$(jq '.issues | length' "$body")
        next=$(jq -r '.nextPageToken // empty' "$body")
        is_last=$(jq -r 'if .isLast == true then "true" else "false" end' "$body")
        rm -f "$body"

        if [[ "$page_count" -eq 0 || -z "$next" || "$is_last" == "true" ]]; then
            break
        fi
        if [[ "$next" == "$seen" ]]; then
            echo "Search pagination repeated a page token; stopping."
            rm -f "$list"
            return 1
        fi
        seen=$next
    done

    total=$(wc -l < "$list" | tr -d ' ')
    if [[ "$total" -eq 0 ]]; then
        echo "No issues found with fixVersion '$FIELD_VALUE'."
        echo "--------------------------------------------------"
        echo "Done. Success: 0, Failed: 0, Skipped: 0"
        rm -f "$list"
        return 0
    fi

    echo "Found $total issue(s)"
    SUCCESS=0
    FAILED=0
    SKIPPED=0
    while IFS=$'\t' read -r key status; do
        [[ -z "$key" ]] && continue
        close_one "$key" "$status"
    done < "$list"
    rm -f "$list"

    echo "--------------------------------------------------"
    echo "Done. Success: $SUCCESS, Failed: $FAILED, Skipped: $SKIPPED"
    [[ "$FAILED" -eq 0 ]]
}

# Close the issue keys listed in $FILE.
close_from_file() {
    local key status body http

    if [[ ! -f "$FILE" ]]; then
        echo "Error: File '$FILE' not found."
        return 1
    fi

    mapfile -t KEYS < <(jq -r '.[]' "$FILE")
    if [[ ${#KEYS[@]} -eq 0 ]]; then
        echo "Error: No issue keys found in '$FILE'."
        return 1
    fi

    echo "File: $FILE"
    echo "Loaded ${#KEYS[@]} issue(s)"
    echo "Transition: Closed | Resolution: $RESOLUTION"
    echo "Jira URL: $JIRA_URL"
    $DRY_RUN && echo "*** DRY RUN — no changes will be made ***"
    echo "--------------------------------------------------"

    SUCCESS=0
    FAILED=0
    SKIPPED=0
    for key in "${KEYS[@]}"; do
        [[ -z "$key" ]] && continue
        body=$(mktemp)
        http=$(jira_curl GET "${JIRA_URL}/rest/api/3/issue/${key}?fields=status" "" "$body")
        if [[ "$http" != "200" ]]; then
            echo "  $key — HTTP $http: $(tr '\n' ' ' < "$body")"
            FAILED=$((FAILED + 1))
            rm -f "$body"
            continue
        fi
        status=$(jq -r '.fields.status.name // empty' "$body")
        rm -f "$body"
        close_one "$key" "$status"
    done

    echo "--------------------------------------------------"
    echo "Done. Success: $SUCCESS, Failed: $FAILED, Skipped: $SKIPPED"
    [[ "$FAILED" -eq 0 ]]
}

if $CLOSE; then
    if [[ -n "$FILE" ]]; then
        close_from_file
    else
        close_by_fixversion
    fi
    exit $?
fi

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
