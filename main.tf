terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-south-1"
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

locals {
  uc1_image_tag      = "1.2.1"
  uc2_image_tag      = "1.2.1"
  main_api_image_tag = "1.1.0"
  monitor_image_tag  = "1.2.1"
  main_api_image     = "224350923820.dkr.ecr.ap-south-1.amazonaws.com/gopi/main-api:${local.main_api_image_tag}"
  uc1_image          = "224350923820.dkr.ecr.ap-south-1.amazonaws.com/gopi/uc1:${local.uc1_image_tag}"
  uc2_image          = "224350923820.dkr.ecr.ap-south-1.amazonaws.com/gopi/uc2:${local.uc2_image_tag}"
  monitor_image      = "224350923820.dkr.ecr.ap-south-1.amazonaws.com/gopi/monitor:${local.monitor_image_tag}"
}

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/gopi-logs"
  retention_in_days = 1
}

resource "aws_sqs_queue" "uc1_requests" {
  name                       = "gopi-uc1-requests"
  visibility_timeout_seconds = 300
  message_retention_seconds  = 1209600
  receive_wait_time_seconds  = 20
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.usecase_dlq.arn
    maxReceiveCount     = 2  # This enforces: 1 Original Try + 1 Retry Max
  })
}

resource "aws_sqs_queue" "uc2_requests" {
  name                       = "gopi-uc2-requests"
  visibility_timeout_seconds = 300
  message_retention_seconds  = 1209600
  receive_wait_time_seconds  = 20
}

resource "aws_sqs_queue" "usecase_dlq" {
  name = "gopi-usecase-dlq"
}

resource "aws_dynamodb_table" "message_dedup" {
  name         = "gopi-message-dedup"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "message_id"

  attribute {
    name = "message_id"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
}

resource "aws_ecs_cluster" "gopi_cluster" {
  name = "gopi-cluster"
}

resource "aws_security_group" "ecs_sg" {
  name        = "gopi-ecs-security-group"
  description = "Security group for Gopi ECS workloads"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Main API port 8000"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow outbound internet"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "ecs_execution" {
  name = "gopi-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task" {
  name = "gopi-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_policy" "api_sqs_send" {
  name = "gopi-sqs-send-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sqs:SendMessage"
      Resource = [aws_sqs_queue.uc1_requests.arn, aws_sqs_queue.uc2_requests.arn]
    }]
  })
}

resource "aws_iam_policy" "monitor" {
  name = "gopi-monitor-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:ChangeMessageVisibility",
          "sqs:GetQueueAttributes",
          "sqs:SendMessage"
        ]
        Resource = [
          aws_sqs_queue.uc1_requests.arn,
          aws_sqs_queue.uc2_requests.arn,
          aws_sqs_queue.usecase_dlq.arn
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.message_dedup.arn
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:DeleteItem"]
        Resource = aws_dynamodb_table.message_dedup.arn
      },
      {
        Effect   = "Allow"
        Action   = ["ecs:RunTask", "ecs:DescribeTasks", "ecs:StopTask"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = [aws_iam_role.ecs_execution.arn, aws_iam_role.ecs_task.arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "api_sqs_send" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = aws_iam_policy.api_sqs_send.arn
}

resource "aws_iam_role_policy_attachment" "monitor" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = aws_iam_policy.monitor.arn
}

resource "aws_ecs_task_definition" "uc1" {
  family                   = "uc1-task-def"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
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
  }])
}

resource "aws_ecs_task_definition" "uc2" {
  family                   = "uc2-task-def"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
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
  }])
}

resource "aws_ecs_task_definition" "monitor" {
  for_each = {
    uc1 = {
      queue_url            = aws_sqs_queue.uc1_requests.url
      task_definition      = aws_ecs_task_definition.uc1.family
      max_tasks            = 2                     # Changed to numeric integer
      task_timeout_seconds = 120                  
      log_prefix           = "uc1-monitor"
    }
    uc2 = {
      queue_url            = aws_sqs_queue.uc2_requests.url
      task_definition      = aws_ecs_task_definition.uc2.family
      max_tasks            = 1                     # Changed to numeric integer
      task_timeout_seconds = 120                  
      log_prefix           = "uc2-monitor"
    }
  }

  family                   = "${each.key}-monitor-task-def"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "monitor"
    image     = local.monitor_image
    essential = true
    environment = [
      { name = "QUEUE_URL", value = each.value.queue_url },
      { name = "DLQ_URL", value = aws_sqs_queue.usecase_dlq.url },
      { name = "ECS_CLUSTER", value = aws_ecs_cluster.gopi_cluster.name },
      { name = "TASK_DEFINITION", value = each.value.task_definition },
      { name = "MAX_TASKS", value = tostring(each.value.max_tasks) }, # Explicitly cast to string for ECS env specs
      { name = "MAX_ATTEMPTS", value = "2" },
      { name = "TASK_TIMEOUT_SECONDS", value = tostring(each.value.task_timeout_seconds) }, # Explicitly cast to string for ECS env specs
      { name = "DEDUP_TABLE", value = aws_dynamodb_table.message_dedup.name },
      { name = "SUBNET_ID", value = data.aws_subnets.default.ids[0] },
      { name = "SECURITY_GROUP_ID", value = aws_security_group.ecs_sg.id }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
        "awslogs-region"        = "ap-south-1"
        "awslogs-stream-prefix" = each.value.log_prefix
      }
    }
  }])
}


resource "aws_ecs_task_definition" "main_api" {
  family                   = "main-api-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "main-api"
    image     = local.main_api_image
    essential = true
    portMappings = [{
      containerPort = 8000
      hostPort      = 8000
      protocol      = "tcp"
    }]
    environment = [
      { name = "UC1_SQS_QUEUE_URL", value = aws_sqs_queue.uc1_requests.url },
      { name = "UC2_SQS_QUEUE_URL", value = aws_sqs_queue.uc2_requests.url }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
        "awslogs-region"        = "ap-south-1"
        "awslogs-stream-prefix" = "api"
      }
    }
  }])
}

locals {
  common_network = {
    subnets          = [data.aws_subnets.default.ids[0]]
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = true
  }
}

resource "aws_ecs_service" "main_api" {
  name            = "main-api-service"
  cluster         = aws_ecs_cluster.gopi_cluster.id
  task_definition = aws_ecs_task_definition.main_api.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = local.common_network.subnets
    security_groups  = local.common_network.security_groups
    assign_public_ip = local.common_network.assign_public_ip
  }

  depends_on = [aws_iam_role_policy_attachment.ecs_execution]
}

resource "aws_ecs_service" "monitor" {
  for_each = toset(["uc1", "uc2"])

  name            = "${each.key}-monitor-service"
  cluster         = aws_ecs_cluster.gopi_cluster.id
  task_definition = aws_ecs_task_definition.monitor[each.key].arn
  desired_count   = 1
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  network_configuration {
    subnets          = local.common_network.subnets
    security_groups  = local.common_network.security_groups
    assign_public_ip = local.common_network.assign_public_ip
  }

  depends_on = [aws_iam_role_policy_attachment.monitor]
}

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
