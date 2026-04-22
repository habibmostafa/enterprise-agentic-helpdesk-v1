#!/usr/bin/env python3
"""
Associate a phone number with a Connect Contact Flow.
This script is called by Terraform's null_resource provisioner.

Usage:
    python3 associate_phone_flow.py <phone_id> <flow_id> <instance_id> <region>
"""

import sys
import boto3

def associate_phone_flow(phone_id, flow_id, instance_id, region):
    """Associate a phone number with a contact flow."""
    try:
        client = boto3.client('connect', region_name=region)

        response = client.associate_phone_number_contact_flow(
            PhoneNumberId=phone_id,
            ContactFlowId=flow_id,
            InstanceId=instance_id
        )

        print(f"Successfully associated phone {phone_id} with flow {flow_id}")
        return 0
    except Exception as e:
        print(f"Error: {str(e)}", file=sys.stderr)
        return 1

if __name__ == "__main__":
    if len(sys.argv) != 5:
        print("Usage: associate_phone_flow.py <phone_id> <flow_id> <instance_id> <region>")
        sys.exit(1)

    phone_id = sys.argv[1]
    flow_id = sys.argv[2]
    instance_id = sys.argv[3]
    region = sys.argv[4]

    sys.exit(associate_phone_flow(phone_id, flow_id, instance_id, region))

