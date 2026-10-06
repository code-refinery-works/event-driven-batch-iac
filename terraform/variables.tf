variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "ap-northeast-1"
}

variable "environment" {
  description = "Deployment environment (dev / staging / production)"
  type        = string
  default     = "dev"
  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "environment must be dev, staging, or production."
  }
}

variable "schedule_expression" {
  description = "EventBridge cron/rate expression for triggering batch"
  type        = string
  default     = "rate(1 hour)"
}

variable "container_image" {
  description = "ECS task container image URI (ECR or Docker Hub)"
  type        = string
}