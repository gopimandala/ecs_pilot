#!/bin/bash

START=$(date +%s)

terraform apply -auto-approve
STATUS=$?

END=$(date +%s)
ELAPSED=$((END - START))

echo
echo "========================================"
echo "Terraform apply completed"
echo "Exit code : $STATUS"
echo "Total time: ${ELAPSED}s"
echo "========================================"

exit $STATUS