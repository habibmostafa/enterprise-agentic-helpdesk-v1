"use strict";

const {
  CustomerProfilesClient,
  SearchProfilesCommand,
} = require("@aws-sdk/client-customer-profiles");

const DOMAIN = process.env.CUSTOMER_PROFILES_DOMAIN;
const REGION = process.env.AWS_REGION || "us-west-2";

const profilesClient = new CustomerProfilesClient({ region: REGION });

/**
 * Lambda handler invoked by Amazon Connect Contact Flow.
 * Authenticates the caller by phone number lookup in Customer Profiles,
 * then returns attributes for the contact flow to consume.
 */
exports.handler = async (event) => {
  console.log("Orchestrator invoked:", JSON.stringify(event));

  const phoneNumber =
    event.Details?.ContactData?.CustomerEndpoint?.Address || "";

  if (!phoneNumber) {
    console.warn("No phone number found in contact data");
    return buildResponse("Unknown", "UNKNOWN", "standard");
  }

  try {
    const searchResult = await profilesClient.send(
      new SearchProfilesCommand({
        DomainName: DOMAIN,
        KeyName: "_phone",
        Values: [phoneNumber],
        MaxResults: 1,
      })
    );

    const profile = searchResult.Items?.[0];

    if (profile) {
      console.log(`Authenticated caller: ${profile.FirstName} ${profile.LastName}`);
      return buildResponse(
        `${profile.FirstName} ${profile.LastName}`,
        profile.AccountNumber || "N/A",
        profile.Attributes?.accountTier || "standard"
      );
    }

    console.log("No profile match — returning defaults");
    return buildResponse("Unknown Caller", "UNKNOWN", "standard");
  } catch (err) {
    console.error("Customer Profiles lookup failed:", err);
    return buildResponse("Unknown Caller", "ERROR", "standard");
  }
};

function buildResponse(customerName, customerId, accountTier) {
  return {
    customerName,
    customerId,
    accountTier,
  };
}

