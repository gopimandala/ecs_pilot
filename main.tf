terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ============================================================
# AWS PROVIDER
# ============================================================

provider "aws" {
  region = "ap-south-1"
}

# ============================================================
# EXISTING DEFAULT VPC
# ============================================================

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ============================================================
# EXISTING ECR IMAGES
#
# ECR is ALREADY SET UP.
# Terraform does not create or modify ECR.
# ============================================================

locals {
  main_api_image = "224350923820.dkr.ecr.ap-south-1.amazonaws.com/gopi/main-api:latest"
  uc1_image      = "224350923820.dkr.ecr.ap-south-1.amazonaws.com/gopi/uc1:latest"
  uc2_image      = "224350923820.dkr.ecr.ap-south-1.amazonaws.com/gopi/uc2:latest"
}

# ============================================================
# CLOUDWATCH LOG GROUP
# ============================================================

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/gopi-logs"
  retention_in_days = 1
}

# ============================================================
# SQS QUEUES FOR EACH USECASE
# ============================================================

resource "aws_sqs_queue" "uc1_requests" {
  name                       = "gopi-uc1-requests"
  visibility_timeout_seconds = 30
  message_retention_seconds  = 1209600
  receive_wait_time_seconds  = 10
}

resource "aws_sqs_queue" "uc2_requests" {
  name                       = "gopi-uc2-requests"
  visibility_timeout_seconds = 30
  message_retention_seconds  = 1209600
  receive_wait_time_seconds  = 10
}

# ============================================================
# ECS CLUSTER
# ============================================================

resource "aws_ecs_cluster" "gopi_cluster" {
  name = "gopi-cluster"
}

# ============================================================
# SECURITY GROUP
# ============================================================

resource "aws_security_group" "ecs_sg" {
  name        = "gopi-ecs-security-group"
  description = "Security group for Gopi ECS workloads"
  vpc_id      = data.aws_vpc.default.id

  # Main API port
  ingress {
    description = "Main API port 8000"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Outbound internet access
  egress {
    description = "Allow outbound internet"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ============================================================
# IAM ROLE - ECS TASK EXECUTION ROLE
#
# ECS/Fargate uses this role to:
#   - Pull images from ECR
#   - Send logs to CloudWatch
# ============================================================

resource "aws_iam_role" "ecs_execution" {
  name = "gopi-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ============================================================
# IAM ROLE - ECS TASK ROLE
#
# This role is available INSIDE the containers.
#
# The main-api uses it to call ECS RunTask for UC1 / UC2.
# ============================================================

resource "aws_iam_role" "ecs_task" {
  name = "gopi-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]
  })
}

# ============================================================
# PERMISSION FOR MAIN API TO SEND TO SQS
# ============================================================

resource "aws_iam_policy" "sqs_send" {
  name = "gopi-sqs-send-policy"

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Action = [
          "sqs:SendMessage"
        ]

        Resource = [
          aws_sqs_queue.uc1_requests.arn,
          aws_sqs_queue.uc2_requests.arn
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "sqs_send" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = aws_iam_policy.sqs_send.arn
}

# ============================================================
# EVENTBRIDGE PIPES ROLE
# ============================================================

resource "aws_iam_role" "eventbridge_pipe" {
  name = "gopi-eventbridge-pipe-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "pipes.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_policy" "eventbridge_pipe" {
  name = "gopi-eventbridge-pipe-policy"

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]

        Resource = [
          aws_sqs_queue.uc1_requests.arn,
          aws_sqs_queue.uc2_requests.arn
        ]
      },
      {
        Effect = "Allow"

        Action = [
          "ecs:RunTask"
        ]

        Resource = [
          aws_ecs_task_definition.uc1.arn,
          aws_ecs_task_definition.uc2.arn
        ]
      },
      {
        Effect = "Allow"

        Action = [
          "iam:PassRole"
        ]

        Resource = [
          aws_iam_role.ecs_execution.arn,
          aws_iam_role.ecs_task.arn
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eventbridge_pipe" {
  role       = aws_iam_role.eventbridge_pipe.name
  policy_arn = aws_iam_policy.eventbridge_pipe.arn
}

# ============================================================
# UC1 TASK DEFINITION
# ============================================================

resource "aws_ecs_task_definition" "uc1" {
  family = "uc1-task-def"

  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]

  cpu    = "256"
  memory = "512"

  execution_role_arn = aws_iam_role.ecs_execution.arn
  task_role_arn      = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "worker"
      image     = local.uc1_image
      essential = true

      logConfiguration = {
        logDriver = "awslogs"

        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = "ap-south-1"
          "awslogs-stream-prefix" = "uc1"
        }
      }
    }
  ])
}

# ============================================================
# UC2 TASK DEFINITION
# ============================================================

resource "aws_ecs_task_definition" "uc2" {
  family = "uc2-task-def"

  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]

  cpu    = "256"
  memory = "512"

  execution_role_arn = aws_iam_role.ecs_execution.arn
  task_role_arn      = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "worker"
      image     = local.uc2_image
      essential = true

      logConfiguration = {
        logDriver = "awslogs"

        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = "ap-south-1"
          "awslogs-stream-prefix" = "uc2"
        }
      }
    }
  ])
}

# ============================================================
# MAIN API TASK DEFINITION
# ============================================================

resource "aws_ecs_task_definition" "main_api" {
  family = "main-api-task"

  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]

  cpu    = "256"
  memory = "512"

  execution_role_arn = aws_iam_role.ecs_execution.arn
  task_role_arn      = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "main-api"
      image     = local.main_api_image
      essential = true

      portMappings = [
        {
          containerPort = 8000
          hostPort      = 8000
          protocol      = "tcp"
        }
      ]

      environment = [
        {
          name  = "ECS_CLUSTER_NAME"
          value = aws_ecs_cluster.gopi_cluster.name
        },

        {
          name  = "ECS_SUBNET_ID"
          value = data.aws_subnets.default.ids[0]
        },

        {
          name  = "ECS_SG_ID"
          value = aws_security_group.ecs_sg.id
        },

        {
          name  = "UC1_SQS_QUEUE_URL"
          value = aws_sqs_queue.uc1_requests.url
        },

        {
          name  = "UC2_SQS_QUEUE_URL"
          value = aws_sqs_queue.uc2_requests.url
        },

        {
          name  = "UC1_TASK_DEFINITION"
          value = aws_ecs_task_definition.uc1.family
        },

        {
          name  = "UC2_TASK_DEFINITION"
          value = aws_ecs_task_definition.uc2.family
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"

        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = "ap-south-1"
          "awslogs-stream-prefix" = "api"
        }
      }
    }
  ])
}

# ============================================================
# MAIN API ECS SERVICE
#
# Only main-api runs continuously.
# UC1 and UC2 are ephemeral workers launched using RunTask.
# ============================================================

resource "aws_ecs_service" "main_api" {
  name            = "main-api-service"
  cluster         = aws_ecs_cluster.gopi_cluster.id
  task_definition = aws_ecs_task_definition.main_api.arn

  desired_count = 1
  launch_type   = "FARGATE"

  network_configuration {
    subnets = [
      data.aws_subnets.default.ids[0]
    ]

    security_groups = [
      aws_security_group.ecs_sg.id
    ]

    assign_public_ip = true
  }

  depends_on = [
    aws_iam_role_policy_attachment.ecs_execution
  ]
}

# ============================================================
# EVENTBRIDGE PIPES TRIGGERING UC1 / UC2 FARGATE TASKS
# ============================================================

resource "aws_pipes_pipe" "uc1" {
  name     = "gopi-uc1-pipe"
  role_arn = aws_iam_role.eventbridge_pipe.arn
  source   = aws_sqs_queue.uc1_requests.arn
  target   = aws_ecs_cluster.gopi_cluster.arn

  source_parameters {
    sqs_queue_parameters {
      batch_size = 1
    }
  }

  target_parameters {
    ecs_task_parameters {
      task_definition_arn = aws_ecs_task_definition.uc1.arn
      launch_type         = "FARGATE"
      task_count          = 1
      platform_version    = "LATEST"

      network_configuration {
        aws_vpc_configuration {
          subnets          = [data.aws_subnets.default.ids[0]]
          security_groups  = [aws_security_group.ecs_sg.id]
          assign_public_ip = "ENABLED"
        }
      }
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.eventbridge_pipe
  ]
}

resource "aws_pipes_pipe" "uc2" {
  name     = "gopi-uc2-pipe"
  role_arn = aws_iam_role.eventbridge_pipe.arn
  source   = aws_sqs_queue.uc2_requests.arn
  target   = aws_ecs_cluster.gopi_cluster.arn

  source_parameters {
    sqs_queue_parameters {
      batch_size = 1
    }
  }

  target_parameters {
    ecs_task_parameters {
      task_definition_arn = aws_ecs_task_definition.uc2.arn
      launch_type         = "FARGATE"
      task_count          = 1
      platform_version    = "LATEST"

      network_configuration {
        aws_vpc_configuration {
          subnets          = [data.aws_subnets.default.ids[0]]
          security_groups  = [aws_security_group.ecs_sg.id]
          assign_public_ip = "ENABLED"
        }
      }
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.eventbridge_pipe
  ]
}

# ============================================================
# OUTPUTS
# ============================================================

output "ecs_cluster_name" {
  value       = aws_ecs_cluster.gopi_cluster.name
  description = "ECS cluster"
}

output "ecs_security_group_id" {
  value       = aws_security_group.ecs_sg.id
  description = "Security group used by ECS"
}

output "ecs_subnet_id" {
  value       = data.aws_subnets.default.ids[0]
  description = "Subnet used by ECS"
}

output "main_api_task_definition" {
  value       = aws_ecs_task_definition.main_api.family
  description = "Main API task definition"
}

output "uc1_task_definition" {
  value       = aws_ecs_task_definition.uc1.family
  description = "UC1 task definition"
}

output "uc2_task_definition" {
  value       = aws_ecs_task_definition.uc2.family
  description = "UC2 task definition"
}

