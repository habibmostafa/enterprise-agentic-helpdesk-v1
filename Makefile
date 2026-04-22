.PHONY: deploy validate test logs destroy

deploy:
	cd infrastructure && terraform init -upgrade && terraform apply -auto-approve

plan:
	cd infrastructure && terraform init -upgrade && terraform plan

validate:
	bash validate.sh

test:
	bash test_suite.sh

logs:
	aws logs tail /aws/lambda/enterprise-agentic-helpdesk-dev-tool-action --follow

destroy:
	cd infrastructure && terraform destroy -auto-approve

