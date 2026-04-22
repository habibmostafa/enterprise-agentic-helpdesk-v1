# ------------------------------------------------------------------------------
# Amazon Lex V2 Bot — Connects voice callers to the same AI helpdesk
# ------------------------------------------------------------------------------
resource "aws_lexv2models_bot" "helpdesk" {
  name        = "${local.prefix}-bot"
  description = "IT Helpdesk bot powered by Bedrock Nova Pro"

  role_arn                 = aws_iam_role.lex_bot.arn
  idle_session_ttl_in_seconds = 300

  data_privacy {
    child_directed = false
  }
}

resource "aws_lexv2models_bot_locale" "en_us" {
  bot_id                           = aws_lexv2models_bot.helpdesk.id
  bot_version                      = "DRAFT"
  locale_id                        = "en_US"
  n_lu_intent_confidence_threshold = 0.4
}

resource "aws_lexv2models_intent" "helpdesk" {
  bot_id      = aws_lexv2models_bot.helpdesk.id
  bot_version = "DRAFT"
  locale_id   = aws_lexv2models_bot_locale.en_us.locale_id
  name        = "HelpDeskIntent"
  description = "Catches all user input and routes to Bedrock via Lambda"

  sample_utterance {
    utterance = "I need help"
  }
  sample_utterance {
    utterance = "Create a ticket"
  }
  sample_utterance {
    utterance = "My computer is broken"
  }
  sample_utterance {
    utterance = "Check my ticket status"
  }
  sample_utterance {
    utterance = "I have a problem"
  }

  fulfillment_code_hook {
    enabled = true
  }
}

# FallbackIntent is auto-created by Lex — no need to define it in Terraform.

# Bot version (built from DRAFT)
resource "aws_lexv2models_bot_version" "v1" {
  bot_id = aws_lexv2models_bot.helpdesk.id

  locale_specification = {
    "en_US" = {
      source_bot_version = "DRAFT"
    }
  }

  depends_on = [
    aws_lexv2models_intent.helpdesk,
  ]
}

# Bot alias is created manually after deploy:
#   /usr/local/bin/aws lexv2-models create-bot-alias ...
# The installed AWS CLI v1 doesn't support lexv2-models.
# After installing AWS CLI v2, run:
#   aws lexv2-models create-bot-alias --bot-id <BOT_ID> --bot-alias-name live \
#     --bot-version <VERSION> --bot-alias-locale-settings '{"en_US":{"enabled":true,...}}'

# Allow Lex to invoke the Tool Action Lambda
resource "aws_lambda_permission" "lex_invoke_tool_action" {
  statement_id  = "AllowLexInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.tool_action.function_name
  principal     = "lexv2.amazonaws.com"
  source_arn    = "arn:aws:lex:${var.aws_region}:${local.account_id}:bot-alias/${aws_lexv2models_bot.helpdesk.id}/*"
}

# ------------------------------------------------------------------------------
# IAM — Lex Bot Service Role
# ------------------------------------------------------------------------------
resource "aws_iam_role" "lex_bot" {
  name = "${local.prefix}-lex-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lexv2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lex_bot_policy" {
  name = "${local.prefix}-lex-policy"
  role = aws_iam_role.lex_bot.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "polly:SynthesizeSpeech"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction"
        ]
        Resource = aws_lambda_function.tool_action.arn
      }
    ]
  })
}

# ------------------------------------------------------------------------------
# Connect Phone Number + Association
# ------------------------------------------------------------------------------
resource "aws_connect_phone_number" "helpdesk" {
  target_arn   = aws_connect_instance.helpdesk.arn
  country_code = "US"
  type         = "TOLL_FREE"
  description  = "Helpdesk toll-free number"
}

output "connect_instance_id" {
  description = "Amazon Connect instance ID (used by validate.sh)"
  value       = aws_connect_instance.helpdesk.id
}

output "phone_number" {
  description = "Call this number to test the voice helpdesk"
  value       = aws_connect_phone_number.helpdesk.phone_number
}

output "lex_bot_id" {
  value = aws_lexv2models_bot.helpdesk.id
}

