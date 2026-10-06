output "main_queue_url" {
  description = "SQS main queue URL"
  value       = aws_sqs_queue.main.id
}

output "dlq_url" {
  description = "SQS dead-letter queue URL"
  value       = aws_sqs_queue.dlq.id
}

output "ecs_cluster_arn" {
  description = "ECS cluster ARN"
  value       = aws_ecs_cluster.main.arn
}

output "ecs_task_definition_arn" {
  description = "ECS task definition ARN"
  value       = aws_ecs_task_definition.batch.arn
}

output "eventbridge_rule_arn" {
  description = "EventBridge rule ARN"
  value       = aws_cloudwatch_event_rule.batch.arn
}

output "log_group_name" {
  description = "CloudWatch Logs group name for ECS tasks"
  value       = aws_cloudwatch_log_group.ecs.name
}