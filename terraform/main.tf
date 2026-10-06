terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags { tags = local.common_tags }
}

locals {
  prefix      = "edb-${var.environment}"
  common_tags = { Project = "EventDrivenBatch", ManagedBy = "Terraform", Environment = var.environment }
}

# ── VPC (minimal: 2 private subnets) ──────────────────────────────────────────
resource "aws_vpc" "main" { cidr_block = "10.0.0.0/16"; enable_dns_hostnames = true; enable_dns_support = true }

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet("10.0.0.0/16", 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
}

data "aws_availability_zones" "available" { state = "available" }

resource "aws_security_group" "ecs_tasks" {
  name   = "${local.prefix}-ecs-sg"
  vpc_id = aws_vpc.main.id
  egress { from_port = 443; to_port = 443; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
}

# ── SQS ───────────────────────────────────────────────────────────────────────
resource "aws_sqs_queue" "dlq" {
  name                       = "${local.prefix}-dlq"
  message_retention_seconds  = 1209600 # 14 days
  sqs_managed_sse_enabled    = true
}

resource "aws_sqs_queue" "main" {
  name                       = "${local.prefix}-queue"
  visibility_timeout_seconds = 900
  message_retention_seconds  = 345600 # 4 days
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({ deadLetterTargetArn = aws_sqs_queue.dlq.arn, maxReceiveCount = 3 })
}

resource "aws_sqs_queue_policy" "main" {
  queue_url = aws_sqs_queue.main.id
  policy    = data.aws_iam_policy_document.sqs_policy.json
}

data "aws_iam_policy_document" "sqs_policy" {
  statement {
    principals { type = "Service"; identifiers = ["events.amazonaws.com"] }
    actions    = ["sqs:SendMessage"]
    resources  = [aws_sqs_queue.main.arn]
    condition { test = "ArnEquals"; variable = "aws:SourceArn"; values = [aws_cloudwatch_event_rule.batch.arn] }
  }
}

# ── EventBridge ───────────────────────────────────────────────────────────────
resource "aws_cloudwatch_event_rule" "batch" {
  name                = "${local.prefix}-rule"
  schedule_expression = var.schedule_expression
}

resource "aws_cloudwatch_event_target" "sqs" {
  rule      = aws_cloudwatch_event_rule.batch.name
  target_id = "SendToSQS"
  arn       = aws_sqs_queue.main.arn
}

# ── IAM ───────────────────────────────────────────────────────────────────────
resource "aws_iam_role" "exec" {
  name               = "${local.prefix}-exec-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}
resource "aws_iam_role_policy_attachment" "exec" {
  role       = aws_iam_role.exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name               = "${local.prefix}-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}
resource "aws_iam_role_policy" "task_sqs" {
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_sqs.json
}

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    principals { type = "Service"; identifiers = ["ecs-tasks.amazonaws.com"] }
    actions = ["sts:AssumeRole"]
  }
}
data "aws_iam_policy_document" "task_sqs" {
  statement {
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.main.arn]
  }
}

# ── ECS ───────────────────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${local.prefix}"
  retention_in_days = 30
}

resource "aws_ecs_cluster" "main" { name = "${local.prefix}-cluster" }

resource "aws_ecs_task_definition" "batch" {
  family                   = "${local.prefix}-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.exec.arn
  task_role_arn            = aws_iam_role.task.arn
  container_definitions = jsonencode([{
    name      = "batch"
    image     = var.container_image
    essential = true
    environment = [{ name = "QUEUE_URL", value = aws_sqs_queue.main.id }]
    logConfiguration = {
      logDriver = "awslogs"
      options   = { "awslogs-group" = aws_cloudwatch_log_group.ecs.name, "awslogs-region" = var.aws_region, "awslogs-stream-prefix" = "batch" }
    }
  }])
}

# ── CloudWatch Alarm (DLQ) ────────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  alarm_name          = "${local.prefix}-dlq-not-empty"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  dimensions          = { QueueName = aws_sqs_queue.dlq.name }
  alarm_description   = "DLQ has messages - batch processing failure detected"
}