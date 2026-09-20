#!/usr/bin/env bash

set -Eeuo pipefail

CALLS=1
DELAY_S=20

# Route directly through your local Tyk Gateway running on port 8080
API_URL="http://localhost:8080/usecase2?delay_s=${DELAY_S}"
echo "API (via Tyk): $API_URL"
echo "Sending $CALLS UC2 request(s)..."

for ((call_number = 1; call_number <= CALLS; call_number++)); do
    echo "--- request ${call_number}/${CALLS} ---"
    # Added -X GET explicitly for clarity, though curl defaults to GET
    curl -X GET --max-time 5 --fail-with-body --silent --show-error "$API_URL"
    printf '\n'
done
