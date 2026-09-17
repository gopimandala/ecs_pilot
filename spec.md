# Terraform Specification — AWS ECS/Fargate

##  Testing Exceptions
1. update uc1 as follows:
- it iterates 5 times.
- receives delay_s (int) (it sleeps for that many seconds in each iteration). if value is > 20s, set it to 20s.
- in each iteration it prints a log msg including iteration count, 'before it sleeps'
- in the end, it prints 'job completed successfully'.
Ensure outputs are unbuffered so they immediately hit CloudWatch.

2. Create an AWS Step Functions Standard State Machine using the aws_sfn_state_machine resource.
Requirements:
A. The workflow should start an ECS Task using the synchronous runTask.sync pattern.
B. Add a Retry block for 'ECS.AmazonECSException' or container failures, with a max_attempts of 2.
C. Add a Catch block that routes the execution payload to an SQS Dead Letter Queue (DLQ) if all retries fail.
D. Update my EventBridge Pipe to target this Step Function instead of targeting ECS directly.
E. Set time out of 30s. If it takes longer than this, the task must be killed and retry attempted if not exceeded the retry limits.

## Change
1. Create SQS
2. main_api.py should insert requests into separate SQS queue for each usecase.
3. Create eventbridge pipes, 1 for each usecase, that triggers ecs fargate tasks. No filters in pipes.

## Purpose
Provision the AWS ECS infrastructure for a main API and two on-demand worker workloads (UC1/UC2).

## Infrastructure
- AWS region: `ap-south-1`
- Existing default VPC and first subnet
- ECS cluster: `gopi-cluster`
- Launch type: Fargate
- CloudWatch log group: `/ecs/gopi-logs`
- Log retention: 1 day

## Workloads
### Main API
- ECS service: `main-api-service`
- Desired count: 1
- CPU: 256
- Memory: 512 MB
- Container port: 8000
- Public IP enabled
- Runs continuously

### UC1 / UC2
- Fargate task definitions
- CPU: 256
- Memory: 512 MB each
- No ECS service
- Started on demand by the Main API using `ecs:RunTask`
- Intended as ephemeral workers

## Container Images
Existing ECR images are used:
- `gopi/main-api:latest`
- `gopi/uc1:latest`
- `gopi/uc2:latest`

Terraform does not create or modify ECR.

## Security
- ECS security group
- TCP port 8000 inbound from `0.0.0.0/0`
- Outbound internet access allowed

## IAM
- ECS execution role: image pull + CloudWatch logging
- ECS task role: available to containers
- Main API task role can:
  - Run UC1/UC2 tasks
  - Pass required IAM roles

## Logging
All workloads send container logs to CloudWatch using the same log group, with prefixes:
- `api`
- `uc1`
- `uc2`

## Outputs
Terraform outputs:
- ECS cluster name
- Security group ID
- Subnet ID
- Main API task definition
- UC1 task definition
- UC2 task definition
