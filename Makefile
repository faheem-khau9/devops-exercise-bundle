# DevOps Engineering Technical Exercise — Makefile
# Top-level entry points. The candidate fills in the Terraform / ArgoCD / Helm pieces;
# the harness (`make verify`) is shipped as-is.

.PHONY: setup plan apply verify destroy clean help

# Path to the candidate's primary env. Override if your layout differs.
ENV_DIR ?= terraform/envs/local

help:
	@echo "Available targets:"
	@echo "  make setup     - check required tools are installed (does not install)"
	@echo "  make plan      - terraform plan in $(ENV_DIR)"
	@echo "  make apply     - terraform apply in $(ENV_DIR) (full bring-up)"
	@echo "  make verify    - run the full 16-check verification harness"
	@echo "  make destroy   - terraform destroy in $(ENV_DIR)"
	@echo "  make clean     - destroy + remove temp files"

setup:
	@bash verify/preflight.sh
	@echo ""
	@echo "Copying *.example files into place (if absent)..."
	@for env in terraform/envs/local terraform/envs/local-stage; do \
	  if [ ! -f "$$env/backend.hcl" ] && [ -f "$$env/backend.hcl.example" ]; then \
	    cp "$$env/backend.hcl.example" "$$env/backend.hcl"; \
	    echo "  Copied $$env/backend.hcl.example -> $$env/backend.hcl"; \
	  fi; \
	  if [ ! -f "$$env/terraform.tfvars" ] && [ -f "$$env/terraform.tfvars.example" ]; then \
	    cp "$$env/terraform.tfvars.example" "$$env/terraform.tfvars"; \
	    echo "  Copied $$env/terraform.tfvars.example -> $$env/terraform.tfvars"; \
	  fi; \
	done

plan:
	@cd $(ENV_DIR) && terraform init -backend-config=backend.hcl && terraform plan -out=tfplan

apply:
	@cd $(ENV_DIR) && terraform init -backend-config=backend.hcl && terraform apply -auto-approve -parallelism=3

verify:
	@bash verify/verify.sh

destroy:
	@cd $(ENV_DIR) && terraform destroy -auto-approve

clean: destroy
	@find . -name 'tfplan' -delete 2>/dev/null || true
	@find . -name '.terraform' -type d -exec rm -rf {} + 2>/dev/null || true
	@find . -name '.terraform.lock.hcl' -delete 2>/dev/null || true
	@rm -f *.kubeconfig 2>/dev/null || true
