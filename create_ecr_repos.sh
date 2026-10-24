#!/usr/bin/env bash

set -Eeuo pipefail

AWS_REGION="ap-south-1"
REPOSITORIES=("gopi/main-api" "gopi/uc1" "gopi/uc2" "gopi/monitor")

for repo_name in "${REPOSITORIES[@]}"; do
    if aws ecr describe-repositories \
        --repository-names "$repo_name" \
        --region "$AWS_REGION" \
        >/dev/null 2>&1; then
        echo "ECR repository already exists: $repo_name"
    else
        echo "Creating ECR repository: $repo_name"
        aws ecr create-repository \
            --repository-name "$repo_name" \
            --region "$AWS_REGION" \
            >/dev/null
    fi
done
