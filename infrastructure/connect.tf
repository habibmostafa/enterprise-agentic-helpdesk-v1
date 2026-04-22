# ------------------------------------------------------------------------------
# Amazon Connect Instance
# ------------------------------------------------------------------------------
resource "aws_connect_instance" "helpdesk" {
  identity_management_type  = "CONNECT_MANAGED"
  instance_alias            = var.connect_instance_alias
  inbound_calls_enabled     = true
  outbound_calls_enabled    = true
  contact_flow_logs_enabled = true
}

# ------------------------------------------------------------------------------
# Customer Profiles Domain (for CRM integration)
# ------------------------------------------------------------------------------
resource "aws_customerprofiles_domain" "helpdesk" {
  domain_name             = "${local.prefix}-profiles"
  default_expiration_days = 365
}

# ------------------------------------------------------------------------------
# Customer Profiles Integration — Mock CRM (S3-based)
# ------------------------------------------------------------------------------
resource "aws_s3_bucket" "crm_mock" {
  bucket        = "${local.prefix}-crm-mock-${local.account_id}"
  force_destroy = true
}

# Customer Profiles domain association is handled via the Connect console or
# aws_connect_instance_storage_config. The S3 bucket remains for future CRM mock data.
# To associate: aws customer-profiles put-integration --domain-name <domain> --uri <connect-instance-arn>

# ------------------------------------------------------------------------------
# Contact Flow — Simple test flow
# ----------------------------------------------------------------------
resource "aws_connect_contact_flow" "main" {
  instance_id = aws_connect_instance.helpdesk.id
  name        = "${local.prefix}-main-flow"
  description = "Basic contact flow for testing"
  type        = "CONTACT_FLOW"

  content = jsonencode({
    Version = "2019-10-30"
    StartAction = "PlayMessage"
    Actions = [
      {
        Identifier = "PlayMessage"
        Type = "MessageParticipant"
        Parameters = {
          Text = "Welcome to the IT Helpdesk! Your call has been connected successfully. Thank you for calling."
        }
        Transitions = {
          NextAction = "Disconnect"
          Errors = [
            {
              ErrorType = "NoMatchingError"
              NextAction = "Disconnect"
            }
          ]
        }
      },
      {
        Identifier = "Disconnect"
        Type = "DisconnectParticipant"
        Parameters = {}
        Transitions = {}
      }
    ]
  })
}

# ------------------------------------------------------------------------------
# CTR Export — Kinesis Data Stream + Firehose → S3 (Parquet)
# ------------------------------------------------------------------------------
resource "aws_kinesis_stream" "ctr" {
  name             = "${local.prefix}-ctr-stream"
  shard_count      = 1
  retention_period = 24
}

resource "aws_connect_instance_storage_config" "ctr_kinesis" {
  instance_id   = aws_connect_instance.helpdesk.id
  resource_type = "CONTACT_TRACE_RECORDS"

  storage_config {
    storage_type = "KINESIS_STREAM"

    kinesis_stream_config {
      stream_arn = aws_kinesis_stream.ctr.arn
    }
  }
}

resource "aws_s3_bucket" "ctr_analytics" {
  bucket        = "${var.ctr_s3_bucket_name}-${local.account_id}"
  force_destroy = true
}

resource "aws_kinesis_firehose_delivery_stream" "ctr" {
  name        = "${local.prefix}-ctr-firehose"
  destination = "extended_s3"

  kinesis_source_configuration {
    kinesis_stream_arn = aws_kinesis_stream.ctr.arn
    role_arn           = aws_iam_role.firehose.arn
  }

  extended_s3_configuration {
    role_arn            = aws_iam_role.firehose.arn
    bucket_arn          = aws_s3_bucket.ctr_analytics.arn
    prefix              = "ctr/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "errors/"
    buffering_size      = 64
    buffering_interval  = 60

    data_format_conversion_configuration {
      enabled = true

      input_format_configuration {
        deserializer {
          open_x_json_ser_de {}
        }
      }

      output_format_configuration {
        serializer {
          parquet_ser_de {
            compression = "SNAPPY"
          }
        }
      }

      schema_configuration {
        database_name = aws_glue_catalog_database.ctr.name
        table_name    = aws_glue_catalog_table.ctr.name
        role_arn      = aws_iam_role.firehose.arn
      }
    }
  }
}

# Glue catalog for Parquet schema
resource "aws_glue_catalog_database" "ctr" {
  name = "${replace(local.prefix, "-", "_")}_ctr_db"
}

resource "aws_glue_catalog_table" "ctr" {
  database_name = aws_glue_catalog_database.ctr.name
  name          = "contact_trace_records"

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.ctr_analytics.id}/ctr/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    columns {
      name = "contact_id"
      type = "string"
    }
    columns {
      name = "channel"
      type = "string"
    }
    columns {
      name = "initiation_method"
      type = "string"
    }
    columns {
      name = "agent_username"
      type = "string"
    }
    columns {
      name = "queue_name"
      type = "string"
    }
    columns {
      name = "connected_to_system_timestamp"
      type = "timestamp"
    }
    columns {
      name = "disconnect_timestamp"
      type = "timestamp"
    }
    columns {
      name = "customer_endpoint"
      type = "string"
    }
  }
}

# ------------------------------------------------------------------------------
# Lambda — Orchestrator (Contact Flow auth hook)
# ------------------------------------------------------------------------------
data "archive_file" "orchestrator" {
  type        = "zip"
  source_dir  = "${path.module}/../src/orchestrator_lambda"
  output_path = "${path.module}/.build/orchestrator_lambda.zip"
}

resource "aws_lambda_function" "orchestrator" {
  function_name    = "${local.prefix}-orchestrator"
  role             = aws_iam_role.lambda_orchestrator.arn
  handler          = "index.handler"
  runtime          = "nodejs22.x"
  timeout          = 10
  memory_size      = 256
  filename         = data.archive_file.orchestrator.output_path
  source_code_hash = data.archive_file.orchestrator.output_base64sha256

  environment {
    variables = {
      CUSTOMER_PROFILES_DOMAIN = aws_customerprofiles_domain.helpdesk.domain_name
      # BEDROCK_MODEL_ID and BEDROCK_GUARDRAIL_ID intentionally omitted:
      # this Lambda currently only does Customer Profiles lookup.
      # Add them back when NLU enrichment is implemented in this layer.
    }
  }
}

resource "aws_lambda_permission" "connect_invoke_orchestrator" {
  statement_id  = "AllowConnectInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.orchestrator.function_name
  principal     = "connect.amazonaws.com"
  source_arn    = aws_connect_instance.helpdesk.arn
}

resource "aws_lambda_permission" "connect_invoke_tool_action" {
  statement_id  = "AllowConnectInvokeToolAction"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.tool_action.function_name
  principal     = "connect.amazonaws.com"
  source_arn    = aws_connect_instance.helpdesk.arn
}

# ------------------------------------------------------------------------------
# Lambda — Tool Action (Lex fulfillment + Bedrock tool calling)
# ------------------------------------------------------------------------------
data "archive_file" "tool_action" {
  type        = "zip"
  source_dir  = "${path.module}/../src/tool_action_lambda"
  output_path = "${path.module}/.build/tool_action_lambda.zip"
}

resource "aws_lambda_function" "tool_action" {
  function_name    = "${local.prefix}-tool-action"
  role             = aws_iam_role.lambda_tool_action.arn
  handler          = "index.handler"
  runtime          = "nodejs22.x"
  timeout          = 30
  memory_size      = 512
  filename         = data.archive_file.tool_action.output_path
  source_code_hash = data.archive_file.tool_action.output_base64sha256

  environment {
    variables = {
      BEDROCK_MODEL_ID     = "us.amazon.nova-pro-v1:0"
      BEDROCK_GUARDRAIL_ID = aws_bedrock_guardrail.pii.guardrail_id
      SERVICENOW_API_URL   = "https://mock-servicenow.internal/api/now/table/incident"
      AUTO_ESCALATE_KEYWORDS = "human agent,real person,speak to someone,escalate,security breach,data loss,outage,billing dispute"
      AUTO_ESCALATE_SEVERITY_TERMS = "sev1,severity 1,p1,priority 1,critical"
    }
  }
}

# ------------------------------------------------------------------------------
# Phone Number Association
# Note: Requires AWS credentials configured and boto3 or AWS CLI v2
resource "null_resource" "associate_phone_flow" {
  triggers = {
    phone_id  = aws_connect_phone_number.helpdesk.id
    flow_id   = aws_connect_contact_flow.main.contact_flow_id
    instance  = aws_connect_instance.helpdesk.id
    region    = var.aws_region
  }

  provisioner "local-exec" {
    command = "bash -c 'python3 -m pip install -q boto3 2>/dev/null; python3 ${path.module}/associate_phone_flow.py ${self.triggers.phone_id} ${self.triggers.flow_id} ${self.triggers.instance} ${self.triggers.region}'"
  }

  depends_on = [
    aws_connect_phone_number.helpdesk,
    aws_connect_contact_flow.main,
    aws_connect_instance.helpdesk,
    aws_lambda_permission.connect_invoke_orchestrator,
    aws_lambda_permission.connect_invoke_tool_action,
  ]
}

