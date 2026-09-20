#!/usr/bin/env bash

set -Eeuo pipefail

AWS_REGION="ap-south-1"
AWS_REGISTRY="224350923820.dkr.ecr.${AWS_REGION}.amazonaws.com"
UC1_IMAGE_TAG="1.2.1"
UC2_IMAGE_TAG="1.2.1"
MAIN_API_IMAGE_TAG="1.1.0"
MONITOR_IMAGE_TAG="1.2.1"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

TARGETS=("uc1" "uc2" "main_api" "monitor")
REPO_NAMES=("gopi/uc1" "gopi/uc2" "gopi/main-api" "gopi/monitor")
IMAGE_TAGS=("$UC1_IMAGE_TAG" "$UC2_IMAGE_TAG" "$MAIN_API_IMAGE_TAG" "$MONITOR_IMAGE_TAG")

for command_name in aws docker; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Error: required command not found: $command_name" >&2
        exit 1
    fi
done

echo "Logging in to AWS ECR..."
aws ecr get-login-password --region "$AWS_REGION" \
    | docker login --username AWS --password-stdin "$AWS_REGISTRY"

for repo_name in "${REPO_NAMES[@]}"; do
    if ! aws ecr describe-repositories \
        --repository-names "$repo_name" \
        --region "$AWS_REGION" \
        >/dev/null 2>&1; then
        echo "Creating ECR repository: $repo_name"
        aws ecr create-repository \
            --repository-name "$repo_name" \
            --region "$AWS_REGION" \
            >/dev/null
    fi
done

for i in "${!TARGETS[@]}"; do
    target="${TARGETS[$i]}"
    repo_name="${REPO_NAMES[$i]}"
    image_tag="${IMAGE_TAGS[$i]}"
    ecr_image="${AWS_REGISTRY}/${repo_name}:${image_tag}"

    echo "Building Docker target ${target} as ${ecr_image}..."
    docker build \
        --file "${SCRIPT_DIR}/Dockerfile" \
        --target "$target" \
        --tag "$ecr_image" \
        "$SCRIPT_DIR"

    echo "Pushing ${ecr_image}..."
    docker push "$ecr_image"
done

echo "All images were built, tagged, and pushed successfully."
