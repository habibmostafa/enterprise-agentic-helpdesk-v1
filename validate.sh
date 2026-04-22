#!/bin/bash

###############################################################################
# Enterprise Agentic Helpdesk - Validation Script
# Usage: bash validate.sh
# Optional env vars:
#   AWS_REGION, STACK_PREFIX, EXPECTED_ACCOUNT_ID
#   CONNECT_INSTANCE_ID (auto-detected from terraform output if not set)
###############################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

success() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; exit 1; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }

REGION="${AWS_REGION:-us-west-2}"
PREFIX="${STACK_PREFIX:-enterprise-agentic-helpdesk-dev}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"

# Auto-detect Connect instance ID from terraform output if not set explicitly
if [ -z "${CONNECT_INSTANCE_ID:-}" ]; then
  CONNECT_INSTANCE_ID=$(cd "$(dirname "$0")/infrastructure" && terraform output -raw connect_instance_id 2>/dev/null || true)
fi

echo "=========================================="
echo "Enterprise Agentic Helpdesk - Validator"
echo "=========================================="
echo ""

# 1) AWS credentials
 echo "[1/8] Checking AWS credentials..."
CURRENT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
if [ -z "$CURRENT_ACCOUNT" ] || [ "$CURRENT_ACCOUNT" = "None" ]; then
  fail "Cannot authenticate with AWS. Check credentials/profile."
fi
if [ -n "$EXPECTED_ACCOUNT_ID" ] && [ "$CURRENT_ACCOUNT" != "$EXPECTED_ACCOUNT_ID" ]; then
  fail "Wrong AWS account. Expected $EXPECTED_ACCOUNT_ID, got $CURRENT_ACCOUNT"
fi
success "AWS credentials OK (account: $CURRENT_ACCOUNT)"

# 2) Lambda functions
 echo ""
 echo "[2/8] Checking Lambda functions..."
for FUNC in orchestrator tool-action chat-ui; do
  FUNC_NAME="${PREFIX}-${FUNC}"
  if aws lambda get-function --function-name "$FUNC_NAME" --region "$REGION" >/dev/null 2>&1; then
    success "Lambda found: $FUNC_NAME"
  else
    fail "Lambda missing: $FUNC_NAME"
  fi
done

# 3) Amazon Connect instance
 echo ""
 echo "[3/8] Checking Amazon Connect instance..."
if [ -n "$CONNECT_INSTANCE_ID" ]; then
  PHONE_NUMBER=$(aws connect list-phone-numbers \
    --instance-id "$CONNECT_INSTANCE_ID" \
    --region "$REGION" \
    --query "PhoneNumberSummaryList[0].PhoneNumber" \
    --output text 2>/dev/null || true)
  if [ -n "$PHONE_NUMBER" ] && [ "$PHONE_NUMBER" != "None" ]; then
    success "Connect instance reachable (phone: $PHONE_NUMBER)"
  else
    warn "Connect instance check failed for CONNECT_INSTANCE_ID=$CONNECT_INSTANCE_ID"
  fi
else
  warn "CONNECT_INSTANCE_ID not set; skipping Connect phone check"
fi

# 4) Lex hookup (validated indirectly via active fulfillment Lambda)
 echo ""
 echo "[4/8] Checking Lex fulfillment readiness..."
TOOL_ACTION_STATE=$(aws lambda get-function \
  --function-name "${PREFIX}-tool-action" \
  --region "$REGION" \
  --query "Configuration.State" \
  --output text 2>/dev/null || true)
if [ "$TOOL_ACTION_STATE" = "Active" ]; then
  success "Tool Action Lambda is active (Lex fulfillment target)"
else
  fail "Tool Action Lambda is not active (state: ${TOOL_ACTION_STATE:-unknown})"
fi

# 5) Bedrock config
 echo ""
 echo "[5/8] Checking Bedrock configuration..."
BEDROCK_MODEL=$(aws lambda get-function-configuration \
  --function-name "${PREFIX}-tool-action" \
  --region "$REGION" \
  --query "Environment.Variables.BEDROCK_MODEL_ID" \
  --output text 2>/dev/null || true)
if [ -n "$BEDROCK_MODEL" ] && [ "$BEDROCK_MODEL" != "None" ]; then
  success "Bedrock model configured: $BEDROCK_MODEL"
else
  fail "BEDROCK_MODEL_ID is not set on ${PREFIX}-tool-action"
fi

# 6) S3 bucket (best effort)
 echo ""
 echo "[6/8] Checking CTR analytics bucket..."
CTR_BUCKET="agentic-helpdesk-ctr-analytics-${CURRENT_ACCOUNT}"
if aws s3 ls "s3://${CTR_BUCKET}/" >/dev/null 2>&1; then
  success "CTR bucket found: s3://${CTR_BUCKET}"
else
  warn "CTR bucket not found: s3://${CTR_BUCKET} (verify naming in Terraform outputs)"
fi

# 7) Orchestrator invocation
 echo ""
 echo "[7/8] Testing Orchestrator Lambda..."
ORCH_OUT=$(aws lambda invoke \
  --function-name "${PREFIX}-orchestrator" \
  --payload '{"Details":{"ContactData":{"CustomerEndpoint":{"Address":"+15551234567"}}}}' \
  --cli-binary-format raw-in-base64-out \
  /tmp/orch-test.json 2>&1 || true)
if grep -q "StatusCode.*200" <<< "$ORCH_OUT" && grep -q "customerName" /tmp/orch-test.json; then
  success "Orchestrator invocation OK"
else
  fail "Orchestrator invocation failed or malformed response"
fi

# 8) Tool Action invocation
 echo ""
 echo "[8/8] Testing Tool Action Lambda..."
TOOL_PAYLOAD='{"inputTranscript":"I need help","sessionState":{"sessionAttributes":{},"intent":{"name":"HelpDeskIntent"}}}'
TOOL_OUT=$(aws lambda invoke \
  --function-name "${PREFIX}-tool-action" \
  --payload "$TOOL_PAYLOAD" \
  --cli-binary-format raw-in-base64-out \
  /tmp/tool-test.json 2>&1 || true)
if grep -q "StatusCode.*200" <<< "$TOOL_OUT" && ! grep -q "FunctionError" <<< "$TOOL_OUT"; then
  success "Tool Action invocation OK"
else
  fail "Tool Action invocation failed"
fi

echo ""
echo "=========================================="
echo "✓ Validation completed"
echo "=========================================="
echo ""
echo "Next:"
echo "  1. Run manual smoke tests from README.md"
echo "  2. Check logs: aws logs tail /aws/lambda/${PREFIX}-tool-action --follow"
echo ""

