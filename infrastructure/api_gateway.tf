# ------------------------------------------------------------------------------
# API Gateway HTTP API — Chat endpoint for Tool Action Lambda
# ------------------------------------------------------------------------------
resource "aws_apigatewayv2_api" "chat" {
  name          = "${local.prefix}-chat-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["POST", "GET", "OPTIONS"]
    allow_headers = ["Content-Type"]
    max_age       = 300
  }
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.chat.id
  name        = "$default"
  auto_deploy = true
}

# POST /chat → Tool Action Lambda
resource "aws_apigatewayv2_integration" "tool_action" {
  api_id                 = aws_apigatewayv2_api.chat.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.tool_action.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "chat_post" {
  api_id    = aws_apigatewayv2_api.chat.id
  route_key = "POST /chat"
  target    = "integrations/${aws_apigatewayv2_integration.tool_action.id}"
}

# GET / → Chat UI Lambda (serves HTML)
resource "aws_apigatewayv2_integration" "chat_ui" {
  api_id                 = aws_apigatewayv2_api.chat.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.chat_ui.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "chat_get" {
  api_id    = aws_apigatewayv2_api.chat.id
  route_key = "GET /"
  target    = "integrations/${aws_apigatewayv2_integration.chat_ui.id}"
}

# Lambda permissions for API Gateway
resource "aws_lambda_permission" "apigw_tool_action" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.tool_action.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.chat.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw_chat_ui" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chat_ui.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.chat.execution_arn}/*/*"
}

# ------------------------------------------------------------------------------
# Lambda — Chat UI (serves the HTML page)
# ------------------------------------------------------------------------------
data "archive_file" "chat_ui" {
  type        = "zip"
  source_dir  = "${path.module}/../src/chat_ui_lambda"
  output_path = "${path.module}/.build/chat_ui_lambda.zip"
}

resource "aws_lambda_function" "chat_ui" {
  function_name    = "${local.prefix}-chat-ui"
  role             = aws_iam_role.lambda_chat_ui.arn
  handler          = "index.handler"
  runtime          = "nodejs22.x"
  timeout          = 5
  memory_size      = 128
  filename         = data.archive_file.chat_ui.output_path
  source_code_hash = data.archive_file.chat_ui.output_base64sha256
  # No environment variables needed: API URL is derived from window.location.origin in the HTML
}

# ------------------------------------------------------------------------------
# Outputs
# ------------------------------------------------------------------------------
output "chat_url" {
  description = "Open this URL in your browser to use the helpdesk chat"
  value       = trimsuffix(aws_apigatewayv2_stage.default.invoke_url, "/")
}

output "chat_api_endpoint" {
  description = "POST to this endpoint with JSON payload"
  value       = "${trimsuffix(aws_apigatewayv2_stage.default.invoke_url, "/")}/chat"
}

