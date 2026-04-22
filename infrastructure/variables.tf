variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-west-2"
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "enterprise-agentic-helpdesk"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "dev"
}

variable "connect_instance_alias" {
  description = "Alias for the Amazon Connect instance"
  type        = string
  default     = "agentic-helpdesk"
}

variable "ctr_s3_bucket_name" {
  description = "S3 bucket name for CTR Parquet files"
  type        = string
  default     = "agentic-helpdesk-ctr-analytics"
}

