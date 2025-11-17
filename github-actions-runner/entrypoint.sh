#!/usr/bin/env bash

echo "================================================"
echo "GitHub Actions Runner - Ephemeral Mode"
echo "================================================"
echo "APP_ID=$APP_ID"
echo "RUNNER_REGISTRATION_URL=$RUNNER_REGISTRATION_URL"
echo "ACCESS_TOKEN_API_URL=$ACCESS_TOKEN_API_URL"
echo "REGISTRATION_TOKEN_API_URL=$REGISTRATION_TOKEN_API_URL"
echo "labels=$labels"
echo ""

set -e
set -o pipefail

# Generate unique runner name to avoid conflicts
RUNNER_NAME="runner-$(hostname)-$(date +%s)"
echo "Runner name: $RUNNER_NAME"
echo ""

now=$(date +%s)
iat=$((${now} - 60)) # Issued 60 seconds in the past
exp=$((${now} + 600)) # Expires 10 minutes in the future

b64enc() { openssl base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n'; }

echo "Step 1: Generate JWT for GitHub App"
echo "------------------------------------------------"

header_json='{
    "typ":"JWT",
    "alg":"RS256"
}'
header=$(echo -n "${header_json}" | b64enc)

payload_json='{
    "iat":'"${iat}"',
    "exp":'"${exp}"',
    "iss":'"${APP_ID}"'
}'
payload=$(echo -n "${payload_json}" | b64enc)

header_payload="${header}.${payload}"
signature=$(openssl dgst -sha256 -sign <(echo -n "${PEM}") <(echo -n "${header_payload}") | b64enc)

jwt="${header_payload}.${signature}"
echo "✓ JWT generated"
echo ""

echo "Step 2: Get Installation Access Token"
echo "------------------------------------------------"

# Get an access token from the API using the installation ID of the GitHub app.
access_token=$(curl -X POST -fsSL \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $jwt" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "$ACCESS_TOKEN_API_URL" \
  | jq -r '.token')

if [ "$access_token" == "null" ] || [ -z "$access_token" ]; then
    echo "ERROR: Failed to get installation access token"
    exit 1
fi
echo "✓ Access token obtained"
echo ""

echo "Step 3: Get Runner Registration Token"
echo "------------------------------------------------"

# Retrieve a short lived runner registration token using the access token.
registration_token=$(curl -X POST -fsSL \
  -H 'Accept: application/vnd.github.v3+json' \
  -H "Authorization: Bearer $access_token" \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  "$REGISTRATION_TOKEN_API_URL" \
  | jq -r '.token')

if [ "$registration_token" == "null" ] || [ -z "$registration_token" ]; then
    echo "ERROR: Failed to get runner registration token"
    exit 1
fi
echo "✓ Registration token obtained"
echo ""

echo "Step 4: Configure Runner (Ephemeral Mode)"
echo "------------------------------------------------"

# Cleanup function to ensure proper deregistration
cleanup() {
    EXIT_CODE=$?
    echo ""
    echo "================================================"
    echo "Runner Cleanup (exit code: $EXIT_CODE)"
    echo "================================================"
    
    # The --ephemeral flag should auto-deregister, but we'll try manual removal as backup
    if [ -f ".runner" ]; then
        echo "Attempting manual runner removal..."
        ./config.sh remove --token "${registration_token}" 2>/dev/null || echo "Runner already removed (ephemeral)"
    else
        echo "✓ Runner already deregistered (ephemeral mode)"
    fi
    
    exit $EXIT_CODE
}

# Trap EXIT, INT, and TERM signals to ensure cleanup
trap cleanup EXIT INT TERM

# Register the ephemeral runner
# --ephemeral: Auto-deregister after running ONE job
# --disableupdate: Use the runner version in the Docker image
# --name: Unique name to avoid conflicts
./config.sh \
    --url $RUNNER_REGISTRATION_URL \
    --token $registration_token \
    --name "$RUNNER_NAME" \
    --labels $labels \
    --ephemeral \
    --unattended \
    --disableupdate

echo "✓ Runner configured"
echo ""
echo "Step 5: Start Runner"
echo "================================================"
echo "Runner will pick up ONE job and auto-deregister"
echo "================================================"
echo ""

# Run the runner (blocks until job completes)
./run.sh

echo ""
echo "✓ Runner job completed, deregistering..."
