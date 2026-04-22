"use strict";

const {
  BedrockRuntimeClient,
  ConverseCommand,
} = require("@aws-sdk/client-bedrock-runtime");

const MODEL_ID = process.env.BEDROCK_MODEL_ID || "us.amazon.nova-pro-v1:0";
const GUARDRAIL_ID = process.env.BEDROCK_GUARDRAIL_ID;
const SERVICENOW_API_URL =
  process.env.SERVICENOW_API_URL ||
  "https://mock-servicenow.internal/api/now/table/incident";
const AUTO_ESCALATE_KEYWORDS = (process.env.AUTO_ESCALATE_KEYWORDS ||
  "human agent,real person,speak to someone,escalate,security breach,data loss,outage,billing dispute")
  .split(",")
  .map((k) => k.trim().toLowerCase())
  .filter(Boolean);
const AUTO_ESCALATE_SEVERITY_TERMS = (process.env.AUTO_ESCALATE_SEVERITY_TERMS ||
  "sev1,severity 1,p1,priority 1,critical")
  .split(",")
  .map((k) => k.trim().toLowerCase())
  .filter(Boolean);

const bedrockClient = new BedrockRuntimeClient({
  region: process.env.AWS_REGION || "us-west-2",
});

// ---------------------------------------------------------------------------
// OpenAPI-style tool definitions for Bedrock Converse tool_use
// ---------------------------------------------------------------------------
const TOOL_CONFIG = {
  tools: [
    {
      toolSpec: {
        name: "create_incident",
        description:
          "Creates a new incident ticket in ServiceNow. Use when user reports a problem or requests help.",
        inputSchema: {
          json: {
            type: "object",
            properties: {
              short_description: {
                type: "string",
                description: "Brief summary of the incident (max 160 chars)",
              },
              description: {
                type: "string",
                description: "Full description of the issue",
              },
              urgency: {
                type: "integer",
                enum: [1, 2, 3],
                description: "1=High, 2=Medium, 3=Low",
              },
              category: {
                type: "string",
                enum: ["hardware", "software", "network", "access", "other"],
                description: "Incident category",
              },
              caller_id: {
                type: "string",
                description: "Caller's employee ID or email",
              },
            },
            required: ["short_description", "urgency", "category"],
          },
        },
      },
    },
    {
      toolSpec: {
        name: "get_incident_status",
        description:
          "Retrieves the current status of a ServiceNow incident by ticket number.",
        inputSchema: {
          json: {
            type: "object",
            properties: {
              incident_number: {
                type: "string",
                description: "The INC number, e.g. INC0012345",
              },
            },
            required: ["incident_number"],
          },
        },
      },
    },
    {
      toolSpec: {
        name: "update_incident",
        description:
          "Adds a work note or changes state on an existing ServiceNow incident.",
        inputSchema: {
          json: {
            type: "object",
            properties: {
              incident_number: {
                type: "string",
                description: "The INC number to update",
              },
              work_notes: {
                type: "string",
                description: "Note to append to the ticket",
              },
              state: {
                type: "string",
                enum: ["in_progress", "on_hold", "resolved", "closed"],
                description: "New state for the incident",
              },
            },
            required: ["incident_number"],
          },
        },
      },
    },
    {
      toolSpec: {
        name: "escalate_to_agent",
        description:
          "Escalates the conversation to a human IT support agent. Use when the user explicitly asks for a human, agent, or person, or when the issue is too complex, involves data loss, security breach, or outage affecting multiple users.",
        inputSchema: {
          json: {
            type: "object",
            properties: {
              reason: {
                type: "string",
                description: "Why this is being escalated to a human agent",
              },
              incident_number: {
                type: "string",
                description: "Related incident number if one exists",
              },
            },
            required: ["reason"],
          },
        },
      },
    },
  ],
};

// ---------------------------------------------------------------------------
// Lambda Handler — Lex V2 Fulfillment
// ---------------------------------------------------------------------------
exports.handler = async (event) => {
  console.log("Tool Action Lambda invoked:", JSON.stringify(event));

  // Detect if this is an API Gateway proxy event
  if (event.requestContext?.http || event.requestContext?.apiId) {
    return handleApiGatewayEvent(event);
  }

  // Extract user utterance from Lex V2 event
  const userMessage = extractUserMessage(event);
  const sessionAttrs = event.sessionState?.sessionAttributes || {};

  // Build conversation history from session (supports multi-turn)
  const messages = buildMessageHistory(sessionAttrs, userMessage);

  // Deterministic fast-path escalation before model call.
  const preEscalation = detectEscalation(userMessage);
  if (preEscalation.shouldEscalate) {
    const escalation = mockEscalateToAgent({ reason: preEscalation.reason });
    return buildLexResponse(
      event,
      escalation.message,
      messages,
      { escalated: true, escalationReason: escalation.reason }
    );
  }

  // Invoke Bedrock with tool definitions (agentic loop)
  const { text: assistantResponse, escalated, escalationReason } = await runAgenticLoop(messages);

  // Return Lex V2 response
  return buildLexResponse(event, assistantResponse, messages, { escalated, escalationReason });
};

// ---------------------------------------------------------------------------
// API Gateway Handler (HTTP chat endpoint)
// ---------------------------------------------------------------------------
async function handleApiGatewayEvent(event) {
  try {
    const body = JSON.parse(event.body || "{}");
    const userMessage = body.inputTranscript || body.text || "Hello";
    const sessionAttrs = body.sessionState?.sessionAttributes || {};

    const messages = buildMessageHistory(sessionAttrs, userMessage);

    // Same deterministic escalation fast-path as the Lex handler — must run
    // before hitting Bedrock so the guardrail never sees the conversation history.
    const preEscalation = detectEscalation(userMessage);
    if (preEscalation.shouldEscalate) {
      const escalation = mockEscalateToAgent({ reason: preEscalation.reason });
      const lexResponse = buildLexResponse(
        { sessionState: { sessionAttributes: sessionAttrs, intent: { name: body.sessionState?.intent?.name || "HelpDeskIntent" } } },
        escalation.message,
        messages,
        { escalated: true, escalationReason: escalation.reason }
      );
      return {
        statusCode: 200,
        headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
        body: JSON.stringify(lexResponse),
      };
    }

    const { text: assistantResponse, escalated, escalationReason } = await runAgenticLoop(messages);
    const lexResponse = buildLexResponse(
      { sessionState: { sessionAttributes: sessionAttrs, intent: { name: body.sessionState?.intent?.name || "HelpDeskIntent" } } },
      assistantResponse,
      messages,
      { escalated, escalationReason }
    );

    return {
      statusCode: 200,
      headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
      body: JSON.stringify(lexResponse),
    };
  } catch (err) {
    console.error("API Gateway handler error:", err);
    return {
      statusCode: 500,
      headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
      body: JSON.stringify({ error: err.message }),
    };
  }
}

// ---------------------------------------------------------------------------
// Agentic loop: keeps calling Bedrock until no more tool_use requests
// ---------------------------------------------------------------------------
async function runAgenticLoop(messages) {
  const MAX_ITERATIONS = 5;
  let escalated = false;
  let escalationReason = null;

  for (let i = 0; i < MAX_ITERATIONS; i++) {
    const params = {
      modelId: MODEL_ID,
      messages,
      toolConfig: TOOL_CONFIG,
      system: [
        {
          text: `You are an enterprise IT helpdesk agent. You help employees create, check, and update ServiceNow incidents. Be concise and professional. Never ask for or repeat SSNs or account numbers.

AUTO-ESCALATE to a human agent (use escalate_to_agent tool) when:
- User asks for "human", "agent", "person", "speak to someone", "transfer me", or "real person"
- Issue involves a security breach, data loss, or outage affecting multiple users
- User expresses frustration (e.g., "this is urgent", "critical system down")
- You cannot resolve the issue after 2 attempts`,
        },
      ],
    };

    if (GUARDRAIL_ID) {
      params.guardrailConfig = {
        guardrailIdentifier: GUARDRAIL_ID,
        guardrailVersion: "DRAFT",
      };
    }

    const response = await bedrockClient.send(new ConverseCommand(params));
    const stopReason = response.stopReason;
    const output = response.output?.message;

    if (!output) break;

    // If guardrail blocked this turn, redact the triggering user message from
    // history so PII doesn't persist and block every subsequent turn.
    if (stopReason === "guardrail_intervened") {
      const lastUserIdx = [...messages].map(m => m.role).lastIndexOf("user");
      if (lastUserIdx !== -1) {
        messages[lastUserIdx] = {
          role: "user",
          content: [{ text: "[message blocked by guardrail]" }],
        };
      }
    }

    // Append assistant message to history
    messages.push(output);

    // Check if model wants to call tools
    const toolUseBlocks = (output.content || []).filter(
      (block) => block.toolUse
    );

    if (toolUseBlocks.length === 0) {
      // No tool calls — return final text
      const textBlock = (output.content || []).find((block) => block.text);
      return {
        text: textBlock?.text || "I'm sorry, I couldn't process your request.",
        escalated,
        escalationReason,
      };
    }

    // Execute each tool and feed results back
    const toolResults = [];
    for (const block of toolUseBlocks) {
      const result = await executeTool(
        block.toolUse.name,
        block.toolUse.input
      );
      if (block.toolUse.name === "escalate_to_agent" && result?.success) {
        escalated = true;
        escalationReason = result.reason || "Escalated by policy";
      }
      toolResults.push({
        toolResult: {
          toolUseId: block.toolUse.toolUseId,
          content: [{ json: result }],
        },
      });
    }

    messages.push({ role: "user", content: toolResults });
  }

  return {
    text: "I've completed processing your request.",
    escalated,
    escalationReason,
  };
}

// ---------------------------------------------------------------------------
// Mock ServiceNow Tool Execution (sandboxed)
// ---------------------------------------------------------------------------
async function executeTool(toolName, input) {
  console.log(`Executing tool: ${toolName}`, JSON.stringify(input));

  switch (toolName) {
    case "create_incident":
      return mockCreateIncident(input);
    case "get_incident_status":
      return mockGetIncidentStatus(input);
    case "update_incident":
      return mockUpdateIncident(input);
    case "escalate_to_agent":
      return mockEscalateToAgent(input);
    default:
      return { error: `Unknown tool: ${toolName}` };
  }
}

function mockCreateIncident(input) {
  const incNumber = `INC${String(Math.floor(Math.random() * 9999999)).padStart(7, "0")}`;
  return {
    success: true,
    incident_number: incNumber,
    short_description: input.short_description,
    urgency: input.urgency,
    category: input.category,
    state: "new",
    created_at: new Date().toISOString(),
    api_endpoint: `${SERVICENOW_API_URL}/${incNumber}`,
  };
}

function mockGetIncidentStatus(input) {
  return {
    success: true,
    incident_number: input.incident_number,
    state: "in_progress",
    assigned_to: "John Smith",
    priority: "2 - High",
    updated_at: new Date().toISOString(),
    short_description: "Mock incident for demonstration",
  };
}

function mockUpdateIncident(input) {
  return {
    success: true,
    incident_number: input.incident_number,
    state: input.state || "in_progress",
    work_notes_added: !!input.work_notes,
    updated_at: new Date().toISOString(),
  };
}

function mockEscalateToAgent(input) {
  const reason = input.reason || "User requested human support";
  return {
    success: true,
    escalated: true,
    reason,
    queue: "it-helpdesk-tier2",
    eta_minutes: 5,
    message:
      "I have escalated this conversation to a human IT support agent. A specialist will follow up shortly."
  };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function extractUserMessage(event) {
  // Lex V2: inputTranscript is the raw utterance
  // API Gateway / direct invoke: falls back to event.text
  return event.inputTranscript || event.text || "Hello";
}

function buildMessageHistory(sessionAttrs, currentMessage) {
  const history = sessionAttrs._conversationHistory
    ? JSON.parse(sessionAttrs._conversationHistory)
    : [];
  history.push({ role: "user", content: [{ text: currentMessage }] });
  return history;
}

function detectEscalation(userMessage) {
  const text = (userMessage || "").toLowerCase();
  if (!text) return { shouldEscalate: false, reason: null };

  if (AUTO_ESCALATE_KEYWORDS.some((k) => text.includes(k))) {
    return {
      shouldEscalate: true,
      reason: "Matched escalation keyword",
    };
  }

  if (AUTO_ESCALATE_SEVERITY_TERMS.some((k) => text.includes(k))) {
    return {
      shouldEscalate: true,
      reason: "Detected severity/priority indicator",
    };
  }

  return { shouldEscalate: false, reason: null };
}

function buildLexResponse(event, assistantText, messages, meta = {}) {
  // Serialize conversation for multi-turn
  const serializedHistory = JSON.stringify(
    messages.slice(-10) // keep last 10 turns to stay within session limits
  );

  return {
    sessionState: {
      dialogAction: { type: "Close" },
      intent: {
        name: event.sessionState?.intent?.name || "HelpDeskIntent",
        state: "Fulfilled",
      },
      sessionAttributes: {
        ...event.sessionState?.sessionAttributes,
        _conversationHistory: serializedHistory,
        _escalated: meta.escalated ? "true" : "false",
        _escalationReason: meta.escalationReason || "",
      },
    },
    messages: [
      {
        contentType: "PlainText",
        content: assistantText,
      },
    ],
  };
}

