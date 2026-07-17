#!/bin/bash
# scripts/export.sh
# Connects to SailPoint ISC, exports configurations and branding, and splits them into Git-friendly folder structures.

set -eo pipefail

echo "========================================="
echo "Starting SailPoint ISC Config Export"
echo "========================================="

# Validate environments/variables
if [[ -z "$SAIL_BASE_URL" || -z "$SAIL_CLIENT_ID" || -z "$SAIL_CLIENT_SECRET" ]]; then
  echo "❌ Error: Missing required env variables: SAIL_BASE_URL, SAIL_CLIENT_ID, or SAIL_CLIENT_SECRET."
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

# 1. Export Branding Configuration
echo "Exporting Branding Configuration..."
mkdir -p config/branding
BRANDING_URL="${SAIL_BASE_URL}/v3/brandings/default"

# Fetch default branding info
BRANDING_RESPONSE=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" -H "X-SailPoint-Experimental: true" "$BRANDING_URL" || echo "")

if [[ -n "$BRANDING_RESPONSE" && ! "$BRANDING_RESPONSE" =~ "Error" && "$BRANDING_RESPONSE" != "" ]]; then
  echo "$BRANDING_RESPONSE" | jq 'del(.id, .created, .modified)' > config/branding/branding-meta.json
  echo "✔ Exported default branding metadata to config/branding/branding-meta.json."
else
  echo "⚠️ Warning: Failed to retrieve default branding. Continuing with general configs."
fi

# 2. Trigger configuration export job
echo "Triggering SailPoint sp-config export job..."
EXPORT_PAYLOAD='{
  "description": "GitOps automated export",
  "includeTypes": [
    "ACCESS_PROFILE",
    "CAMPAIGN_FILTER",
    "CONNECTOR_RULE",
    "FORM_DEFINITION",
    "GOVERNANCE_GROUP",
    "IDENTITY_PROFILE",
    "ROLE",
    "RULE",
    "SOD_POLICY",
    "SOURCE",
    "TRANSFORM",
    "TRIGGER_SUBSCRIPTION",
    "WORKFLOW"
  ]
}'

EXPORT_RESPONSE=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "${SAIL_BASE_URL}/beta/sp-config/export" \
  -d "$EXPORT_PAYLOAD")

EXPORT_BODY=$(echo "$EXPORT_RESPONSE" | sed '$d')
EXPORT_STATUS=$(echo "$EXPORT_RESPONSE" | tail -n1)

if [[ "$EXPORT_STATUS" -ne 200 && "$EXPORT_STATUS" -ne 202 ]]; then
  echo "❌ Error: Triggering export job failed with HTTP status $EXPORT_STATUS"
  echo "Response: $EXPORT_BODY"
  exit 1
fi

JOB_ID=$(echo "$EXPORT_BODY" | jq -r '.jobId')
echo "Export Job ID: $JOB_ID"

# Poll status
STATUS="PENDING"
echo "Polling export job status..."
while [[ "$STATUS" == "PENDING" || "$STATUS" == "IN_PROGRESS" || "$STATUS" == "NOT_STARTED" ]]; do
  sleep 5
  JOB_STATUS_RESP=$(curl -s -f -H "Authorization: Bearer $ACCESS_TOKEN" \
    "${SAIL_BASE_URL}/beta/sp-config/export/${JOB_ID}")
  STATUS=$(echo "$JOB_STATUS_RESP" | jq -r '.status')
  echo "Job status: $STATUS"
done

if [[ "$STATUS" != "COMPLETE" ]]; then
  echo "❌ Error: Export job failed with status $STATUS"
  exit 1
fi

# Download configuration
echo "Downloading export configuration package..."
EXPORT_FILE="exports/sp-config-export.json"
mkdir -p exports
curl -s -f -H "Authorization: Bearer $ACCESS_TOKEN" \
  "${SAIL_BASE_URL}/beta/sp-config/export/${JOB_ID}/download" \
  -o "$EXPORT_FILE"

echo "✔ Export package downloaded to $EXPORT_FILE"

# 3. Parse and Split JSON Configuration
echo "Splitting configuration objects..."

# Define type-to-folder mapping
declare -A FOLDER_MAP
FOLDER_MAP["ACCESS_PROFILE"]="access-profiles"
FOLDER_MAP["CAMPAIGN_FILTER"]="policies"
FOLDER_MAP["CONNECTOR_RULE"]="rules"
FOLDER_MAP["FORM_DEFINITION"]="applications"
FOLDER_MAP["GOVERNANCE_GROUP"]="identity-profiles"
FOLDER_MAP["IDENTITY_PROFILE"]="identity-profiles"
FOLDER_MAP["ROLE"]="roles"
FOLDER_MAP["RULE"]="rules"
FOLDER_MAP["SOD_POLICY"]="policies"
FOLDER_MAP["SOURCE"]="sources"
FOLDER_MAP["TRANSFORM"]="transforms"
FOLDER_MAP["TRIGGER_SUBSCRIPTION"]="workflows"
FOLDER_MAP["WORKFLOW"]="workflows"

# Clean old JSON config files except gitkeep files
find config -type f -name "*.json" ! -name "branding-meta.json" -delete

# Read objects array and write each object to its file
OBJECTS_COUNT=$(jq '.objects | length' "$EXPORT_FILE")
echo "Total objects exported: $OBJECTS_COUNT"

for ((i=0; i<OBJECTS_COUNT; i++)); do
  OBJ_TYPE=$(jq -r ".objects[$i].self.type" "$EXPORT_FILE")
  OBJ_NAME=$(jq -r ".objects[$i].self.name" "$EXPORT_FILE")
  
  # Clean name for filename compatibility
  CLEAN_NAME=$(echo "$OBJ_NAME" | sed 's/[^a-zA-Z0-9_-]/_/g')
  
  DIR_NAME=${FOLDER_MAP[$OBJ_TYPE]}
  if [[ -z "$DIR_NAME" ]]; then
    DIR_NAME="others"
  fi
  
  mkdir -p "config/${DIR_NAME}"
  
  # Write individual object
  jq ".objects[$i]" "$EXPORT_FILE" > "config/${DIR_NAME}/${CLEAN_NAME}.json"
done

echo "✔ Successfully split configuration objects into config/ subfolders."
echo "========================================="
echo "Export Completed Successfully!"
echo "========================================="
