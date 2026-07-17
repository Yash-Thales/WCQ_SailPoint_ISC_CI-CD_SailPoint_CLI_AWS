#!/bin/bash
# scripts/deploy.sh
# Tokenizes configuration files, merges them, deploys branding, and imports SailPoint configuration.

set -eo pipefail

echo "========================================="
echo "Starting SailPoint ISC Config Deployment"
echo "========================================="

# Determine target environment from environment files or branch name
TARGET_ENV="${ENV_NAME:-DEV}"
TARGET_ENV_LOWER=$(echo "$TARGET_ENV" | tr '[:upper:]' '[:lower:]')
ENV_FILE="environments/${TARGET_ENV_LOWER}.json"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ Error: Environment file '$ENV_FILE' not found."
  exit 1
fi

echo "Target Environment: $TARGET_ENV"
echo "Using variables from: $ENV_FILE"

# Validate secrets
if [[ -z "$SAIL_BASE_URL" || -z "$SAIL_CLIENT_ID" || -z "$SAIL_CLIENT_SECRET" ]]; then
  echo "❌ Error: Missing credentials. Ensure SAIL_BASE_URL, SAIL_CLIENT_ID, and SAIL_CLIENT_SECRET are set."
  exit 1
fi

# Clean trailing slash from base URL
SAIL_BASE_URL="${SAIL_BASE_URL%/}"

echo "Authenticating with SailPoint ISC..."
HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${SAIL_BASE_URL}/oauth/token" \
  -d "grant_type=client_credentials" \
  -d "client_id=${SAIL_CLIENT_ID}" \
  -d "client_secret=${SAIL_CLIENT_SECRET}")

HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')
HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tail -n1)

if [[ "$HTTP_STATUS" -ne 200 ]]; then
  echo "❌ Error: Authentication failed with HTTP status $HTTP_STATUS"
  echo "Response: $HTTP_BODY"
  exit 1
fi

ACCESS_TOKEN=$(echo "$HTTP_BODY" | jq -r '.access_token')

if [[ -z "$ACCESS_TOKEN" || "$ACCESS_TOKEN" == "null" ]]; then
  echo "❌ Error: Could not extract access token from response."
  exit 1
fi
echo "✔ Authentication successful."

# 1. Deploy Branding Configurations
if [[ -f "config/branding/branding-meta.json" && -s "config/branding/branding-meta.json" ]]; then
  echo "Deploying Branding Config..."
  
  CURL_ARGS=()
  # Build form parameters from branding-meta.json
  while IFS= read -r key; do
    val=$(jq -r ".[\"$key\"]" config/branding/branding-meta.json)
    if [[ "$val" != "null" ]]; then
      CURL_ARGS+=("-F" "$key=$val")
    fi
  done < <(jq -r 'keys[]' config/branding/branding-meta.json)
  
  # Check if logo exists
  if [[ -f "config/branding/logo.png" ]]; then
    echo "Attaching logo file config/branding/logo.png"
    CURL_ARGS+=("-F" "fileStandard=@config/branding/logo.png")
  fi
  
  # Perform PUT request to branding endpoint
  BRANDING_DEP_URL="${SAIL_BASE_URL}/v3/brandings/default"
  BRANDING_RESP=$(curl -s -X PUT "$BRANDING_DEP_URL" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "X-SailPoint-Experimental: true" \
    "${CURL_ARGS[@]}")
    
  if echo "$BRANDING_RESP" | grep -q "Error"; then
    echo "❌ Error deploying branding: $BRANDING_RESP"
    exit 1
  fi
  echo "✔ Branding configuration deployed."
else
  echo "ℹ No branding configuration found or file is empty. Skipping."
fi

# 2. Tokenize and Compile Configurations
echo "Compiling and tokenizing configuration files..."
TEMP_IMPORT_DIR="exports/temp_build"
mkdir -p "$TEMP_IMPORT_DIR"
rm -rf "${TEMP_IMPORT_DIR:?}"/*

# Read environment replacements to key-value pairs
declare -A REPLACEMENTS
while IFS="=" read -r key val; do
  if [[ -n "$key" ]]; then
    REPLACEMENTS["$key"]="$val"
  fi
done < <(jq -r 'to_entries[] | "\(.key)=\(.value)"' "$ENV_FILE")

# Combine all JSON configurations into a temporary format
MERGED_OBJECTS_FILE="exports/merged_objects.json"
echo '{"objects":[]}' > "$MERGED_OBJECTS_FILE"

# Collect config files (excluding branding)
CONFIG_FILES=$(find config -type f -name "*.json" ! -path "config/branding/*")

for FILE in $CONFIG_FILES; do
  echo "Processing $FILE..."
  # Read file content
  FILE_CONTENT=$(cat "$FILE")
  
  # Perform replacement of environment tokens
  for KEY in "${!REPLACEMENTS[@]}"; do
    VAL="${REPLACEMENTS[$KEY]}"
    # Replace both {{KEY}} and ${KEY} placeholders
    FILE_CONTENT="${FILE_CONTENT//\{\{$KEY\}\}/$VAL}"
    FILE_CONTENT="${FILE_CONTENT//\$\{$KEY\}/$VAL}"
  done
  
  # Append to merged objects array
  # We validate if it contains "self" and "object" structure
  if jq -e '.self and .object' <<< "$FILE_CONTENT" >/dev/null 2>&1; then
    echo "$FILE_CONTENT" > temp_object.json
    jq --slurpfile new_obj temp_object.json '.objects += $new_obj' "$MERGED_OBJECTS_FILE" > "${MERGED_OBJECTS_FILE}.tmp"
    mv "${MERGED_OBJECTS_FILE}.tmp" "$MERGED_OBJECTS_FILE"
    rm -f temp_object.json
  else
    echo "⚠️ Warning: File $FILE does not match standard sp-config structure. Skipping."
  fi
done

OBJECT_COUNT=$(jq '.objects | length' "$MERGED_OBJECTS_FILE")
if [[ $OBJECT_COUNT -eq 0 ]]; then
  echo "ℹ No objects to deploy. Deployment complete."
  exit 0
fi

echo "✔ Compiled $OBJECT_COUNT objects to deploy."

# 3. Perform sp-config import
echo "Submitting import package to SailPoint..."
IMPORT_INIT=$(curl -s -f -H "Authorization: Bearer $ACCESS_TOKEN" \
  -F "data=@${MERGED_OBJECTS_FILE}" \
  -X POST "${SAIL_BASE_URL}/beta/sp-config/import")

IMPORT_JOB_ID=$(echo "$IMPORT_INIT" | jq -r '.jobId')
echo "Import Job ID: $IMPORT_JOB_ID"

# Poll status
IMPORT_STATUS="PENDING"
echo "Polling import job status..."
while [[ "$IMPORT_STATUS" == "PENDING" || "$IMPORT_STATUS" == "IN_PROGRESS" || "$IMPORT_STATUS" == "NOT_STARTED" ]]; do
  sleep 5
  IMPORT_STATUS_RESP=$(curl -s -f -H "Authorization: Bearer $ACCESS_TOKEN" \
    "${SAIL_BASE_URL}/beta/sp-config/import/${IMPORT_JOB_ID}")
  IMPORT_STATUS=$(echo "$IMPORT_STATUS_RESP" | jq -r '.status')
  echo "Job status: $IMPORT_STATUS"
done

if [[ "$IMPORT_STATUS" != "COMPLETE" ]]; then
  echo "❌ Error: Import job failed with status $IMPORT_STATUS"
  echo "Fetching detailed error results..."
  curl -s -H "Authorization: Bearer $ACCESS_TOKEN" "${SAIL_BASE_URL}/beta/sp-config/import/${IMPORT_JOB_ID}/download" | jq . || true
  exit 1
fi

echo "✔ Import job completed successfully."

# Save import results snapshot
mkdir -p dr-snapshots
curl -s -f -H "Authorization: Bearer $ACCESS_TOKEN" \
  "${SAIL_BASE_URL}/beta/sp-config/import/${IMPORT_JOB_ID}" \
  -o "dr-snapshots/import-result-${TARGET_ENV}-${IMPORT_JOB_ID}.json"

echo "✔ Results logged to dr-snapshots/import-result-${TARGET_ENV}-${IMPORT_JOB_ID}.json."
echo "========================================="
echo "Deployment Completed Successfully!"
echo "========================================="
