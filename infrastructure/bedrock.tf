# ------------------------------------------------------------------------------
# Bedrock Guardrail — Block SSNs and Account Numbers
# ------------------------------------------------------------------------------
resource "aws_bedrock_guardrail" "pii" {
  name                      = "${local.prefix}-pii-guardrail"
  description               = "Blocks SSNs and account numbers from model input/output"
  blocked_input_messaging   = "I cannot process requests containing sensitive information like SSNs or account numbers."
  blocked_outputs_messaging = "The response was blocked because it contained sensitive information."

  sensitive_information_policy_config {
    pii_entities_config {
      type   = "US_SOCIAL_SECURITY_NUMBER"
      action = "BLOCK"
    }
    pii_entities_config {
      type   = "CREDIT_DEBIT_CARD_NUMBER"
      action = "BLOCK"
    }

    regexes_config {
      name        = "AccountNumber"
      description = "Blocks account numbers (8-12 digit patterns)"
      pattern     = "\\b[Aa]ccount\\s*#?\\s*\\d{8,12}\\b"
      action      = "BLOCK"
    }
  }

  content_policy_config {
    filters_config {
      type            = "HATE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "VIOLENCE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
  }
}

