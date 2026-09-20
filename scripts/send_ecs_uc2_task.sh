#!/usr/bin/env bash

set -Eeuo pipefail

AWS_REGION="ap-south-1"
CLUSTER="gopi-cluster"
SERVICE="main-api-service"
CALLS=3
DELAY_S=1

TASK_ARN=$(aws ecs list-tasks \
    --cluster "$CLUSTER" \
    --service-name "$SERVICE" \
    --desired-status RUNNING \
    --region "$AWS_REGION" \
    --query 'taskArns[0]' \
    --output text)

if [[ -z "$TASK_ARN" || "$TASK_ARN" == "None" ]]; then
    echo "No running API task found for service $SERVICE" >&2
    exit 1
fi

ENI_ID=$(aws ecs describe-tasks \
    --cluster "$CLUSTER" \
    --tasks "$TASK_ARN" \
    --region "$AWS_REGION" \
    --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' \
    --output text)

PUBLIC_IP=$(aws ec2 describe-network-interfaces \
    --network-interface-ids "$ENI_ID" \
    --region "$AWS_REGION" \
    --query 'NetworkInterfaces[0].Association.PublicIp' \
    --output text)

if [[ -z "$PUBLIC_IP" || "$PUBLIC_IP" == "None" ]]; then
    echo "No public IP found for network interface $ENI_ID" >&2
    exit 1
fi

API_URL="http://${PUBLIC_IP}:8000/usecase2?delay_s=${DELAY_S}"
echo "API: $API_URL"
echo "Sending $CALLS UC2 request(s)..."

for ((call_number = 1; call_number <= CALLS; call_number++)); do
    echo "--- request ${call_number}/${CALLS} ---"
    curl --fail-with-body --silent --show-error "$API_URL"
    printf '\n'
done
