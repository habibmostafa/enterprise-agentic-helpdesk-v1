# ------------------------------------------------------------------------------
# IAM — Lambda Orchestrator Role
# ------------------------------------------------------------------------------
resource "aws_iam_role" "lambda_orchestrator" {
  name = "${local.prefix}-orchestrator-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "orchestrator_policy" {
  name = "${local.prefix}-orchestrator-policy"
  role = aws_iam_role.lambda_orchestrator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${local.account_id}:*"
      },
      {
        Sid    = "CustomerProfiles"
        Effect = "Allow"
        Action = [
          "profile:SearchProfiles",
          "profile:GetProfile"
        ]
        Resource = "arn:aws:profile:${var.aws_region}:${local.account_id}:domains/${aws_customerprofiles_domain.helpdesk.domain_name}"
      },
      {
        Sid    = "BedrockInvoke"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:ApplyGuardrail"
        ]
        Resource = [
          "arn:aws:bedrock:*::foundation-model/amazon.nova-pro-v1:0",
          "arn:aws:bedrock:${var.aws_region}:${local.account_id}:inference-profile/us.amazon.nova-pro-v1:0",
          aws_bedrock_guardrail.pii.guardrail_arn
        ]
      }
    ]
  })
}

# ------------------------------------------------------------------------------
# IAM — Lambda Tool Action Role
# ------------------------------------------------------------------------------
resource "aws_iam_role" "lambda_tool_action" {
  name = "${local.prefix}-tool-action-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "tool_action_policy" {
  name = "${local.prefix}-tool-action-policy"
  role = aws_iam_role.lambda_tool_action.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${local.account_id}:*"
      },
      {
        Sid    = "BedrockInvoke"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:ApplyGuardrail"
        ]
        Resource = [
          "arn:aws:bedrock:*::foundation-model/amazon.nova-pro-v1:0",
          "arn:aws:bedrock:${var.aws_region}:${local.account_id}:inference-profile/us.amazon.nova-pro-v1:0",
          aws_bedrock_guardrail.pii.guardrail_arn
        ]
      }
    ]
  })
}

# ------------------------------------------------------------------------------
# IAM — Lambda Chat UI Role (logs only — this Lambda serves static HTML)
# ------------------------------------------------------------------------------
resource "aws_iam_role" "lambda_chat_ui" {
  name = "${local.prefix}-chat-ui-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "chat_ui_policy" {
  name = "${local.prefix}-chat-ui-policy"
  role = aws_iam_role.lambda_chat_ui.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${local.account_id}:*"
      }
    ]
  })
}

# ------------------------------------------------------------------------------
# IAM — Lambda Firehose Delivery Role
# ------------------------------------------------------------------------------
resource "aws_iam_role" "firehose" {
  name = "${local.prefix}-firehose-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "firehose_policy" {
  name = "${local.prefix}-firehose-policy"
  role = aws_iam_role.firehose.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Access"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetBucketLocation",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.ctr_analytics.arn,
          "${aws_s3_bucket.ctr_analytics.arn}/*"
        ]
      },
      {
        Sid    = "KinesisRead"
        Effect = "Allow"
        Action = [
          "kinesis:DescribeStream",
          "kinesis:GetShardIterator",
          "kinesis:GetRecords",
          "kinesis:ListShards"
        ]
        Resource = aws_kinesis_stream.ctr.arn
      },
      {
        Sid    = "GlueAccess"
        Effect = "Allow"
        Action = [
          "glue:GetTable",
          "glue:GetTableVersion",
          "glue:GetTableVersions"
        ]
        Resource = [
          "arn:aws:glue:${var.aws_region}:${local.account_id}:catalog",
          "arn:aws:glue:${var.aws_region}:${local.account_id}:database/${aws_glue_catalog_database.ctr.name}",
          "arn:aws:glue:${var.aws_region}:${local.account_id}:table/${aws_glue_catalog_database.ctr.name}/${aws_glue_catalog_table.ctr.name}"
        ]
      }
    ]
  })
}

