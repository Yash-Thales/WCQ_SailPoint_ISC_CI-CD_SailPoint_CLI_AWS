#!/bin/bash
# scripts/validate.sh
# Validates SailPoint ISC GitOps repository configuration structure, JSON syntax, and integrity.

set -eo pipefail

echo "========================================="
echo "Starting SailPoint ISC Config Validation"
echo "========================================="

# 1. Validate Required Directory Structure
REQUIRED_DIRS=(
  "config"
  "config/access-profiles"
  "config/applications"
  "config/branding"
  "config/identity-profiles"
  "config/policies"
  "config/roles"
  "config/rules"
  "config/sources"
  "config/transforms"
  "config/workflows"
  "environments"
  "scripts"
)

echo "Checking folder structure..."
for DIR in "${REQUIRED_DIRS[@]}"; do
  if [[ ! -d "$DIR" ]]; then
    echo "❌ Error: Required directory '$DIR' does not exist."
    exit 1
  fi
done
echo "✔ Folder structure is valid."

# 2. Validate Environment Files
REQUIRED_ENV_FILES=(
  "environments/dev.json"
  "environments/uat.json"
  "environments/prod.json"
)

echo "Checking environment files..."
for FILE in "${REQUIRED_ENV_FILES[@]}"; do
  if [[ ! -f "$FILE" ]]; then
    echo "❌ Error: Required environment file '$FILE' is missing."
    exit 1
  fi
  # Verify JSON syntax
  if ! jq empty "$FILE" >/dev/null 2>&1; then
    echo "❌ Error: Environment file '$FILE' is not valid JSON."
    exit 1
  fi
done
echo "✔ Environment files are valid."

# 3. Validate Configuration JSON Files Syntax & Check for Hardcoded Secrets/URLs
echo "Linting configuration files..."
FAILED=0

# Find all JSON files in the config folder (excluding .gitkeep)
while IFS= read -r -d '' JSON_FILE; do
  # Skip branding-meta.json if it is empty, or validate it if it contains something
  if [[ "$(basename "$JSON_FILE")" == "branding-meta.json" ]]; then
    if [[ ! -s "$JSON_FILE" ]]; then
      # If empty, skip
      continue
    fi
  fi

  # Validate JSON syntax
  if ! jq empty "$JSON_FILE" >/dev/null 2>&1; then
    echo "❌ Error: Invalid JSON syntax in '$JSON_FILE'."
    FAILED=1
    continue
  fi

  # Check for hardcoded tenant URLs
  if grep -E -q "identitynow\.com|sailpoint\.com" "$JSON_FILE"; then
    echo "⚠️ Warning: Found hardcoded tenant/SailPoint URL in '$JSON_FILE'. Recommend tokenization using variables."
  fi

  # Check if there are keys containing secret/password/token whose values are non-null and do not start with $ or { (which indicates variable tokenization)
  HAS_SECRET=$(jq '[paths(scalars) as $p | select($p[-1] | tostring | test("password|secret|token|key"; "i")) | getpath($p)] | map(select(. != null and . != "" and (tostring | test("^(\\$|\\{\\{)") | not))) | length' "$JSON_FILE" 2>/dev/null || echo 0)

  if [[ "$HAS_SECRET" -gt 0 ]]; then
    echo "❌ Error: Potential plaintext hardcoded secret/password detected in '$JSON_FILE'."
    FAILED=1
  fi

done < <(find config -name "*.json" -print0)

if [[ $FAILED -eq 1 ]]; then
  echo "❌ Configuration validation failed."
  exit 1
else
  echo "✔ All configuration files are valid."
  echo "========================================="
  echo "Validation Completed Successfully!"
  echo "========================================="
fi
