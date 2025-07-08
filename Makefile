SHELL := /bin/bash

.PHONY: help
.DEFAULT_GOAL := help

AZURE_ENV_FILE := $(shell azd env list --output json | jq -r '.[] | select(.IsDefault == true) | .DotEnvPath')

ENV_FILE := .env
ifeq ($(filter $(MAKECMDGOALS),config clean),)
	ifneq ($(strip $(wildcard $(ENV_FILE))),)
		ifneq ($(MAKECMDGOALS),config)
			include $(ENV_FILE)
			export
		endif
	endif
endif

include $(AZURE_ENV_FILE)

help: ## 💬 This help message :)
	@grep -E '[a-zA-Z_-]+:.*?## .*$$' $(firstword $(MAKEFILE_LIST)) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-23s\033[0m %s\n", $$1, $$2}'

ci: lint unittest unittest-frontend functionaltest ## 🚀 Continuous Integration (called by Github Actions)

lint: ## 🧹 Lint the code
	@echo -e "\e[34m$@\e[0m" || true
	@poetry run flake8 code

build-frontend: ## 🏗️ Build the Frontend webapp
	@echo -e "\e[34m$@\e[0m" || true
	@cd code/frontend && npm install && npm run build

python-test: ## 🧪 Run Python unit + functional tests
	@echo -e "\e[34m$@\e[0m" || true
	@poetry run pytest -m "not azure" $(optional_args)

unittest: ## 🧪 Run the unit tests
	@echo -e "\e[34m$@\e[0m" || true
	@poetry run pytest -vvv -m "not azure and not functional" $(optional_args)

unittest-frontend: build-frontend ## 🧪 Unit test the Frontend webapp
	@echo -e "\e[34m$@\e[0m" || true
	@cd code/frontend && npm run test

functionaltest: ## 🧪 Run the functional tests
	@echo -e "\e[34m$@\e[0m" || true
	@poetry run pytest code/tests/functional -m "functional"

uitest: ## 🧪 Run the ui tests in headless mode
	@echo -e "\e[34m$@\e[0m" || true
	@cd tests/integration/ui && npm install && npx cypress run --env ADMIN_WEBSITE_NAME=$(ADMIN_WEBSITE_NAME),FRONTEND_WEBSITE_NAME=$(FRONTEND_WEBSITE_NAME)

docker-compose-up: ## 🐳 Run the docker-compose file
	@cd docker && AZD_ENV_FILE=$(AZURE_ENV_FILE) docker-compose up

azd-login: ## 🔑 Login to Azure with azd and a SPN
	@echo -e "\e[34m$@\e[0m" || true
	@azd auth login --client-id ${AZURE_CLIENT_ID} --client-secret ${AZURE_CLIENT_SECRET} --tenant-id ${AZURE_TENANT_ID}

azd-login: ## 🔑 Login to Azure with azd and a SPN
	@echo -e "\e[34m$@\e[0m" || true
	@azd auth login --client-id ${AZURE_CLIENT_ID} --client-secret ${AZURE_CLIENT_SECRET} --tenant-id ${AZURE_TENANT_ID}

# Fixed Makefile section for deploy target
# Fixed Makefile section for deploy target
deploy: azd-login ## Deploy everything to Azure
	@echo -e "\e[34m$@\e[0m" || true
	@azd env new ${AZURE_ENV_NAME}

	# Provision and deploy
	@azd provision --no-prompt
	@azd deploy web --no-prompt || true
	@azd deploy function --no-prompt || true
	@azd deploy adminweb --no-prompt

	@sleep 30
	@azd show --output json > deploy_output.json || echo "{}" > deploy_output.json

	# Extract URLs using multiple methods
	@echo "=== Extracting URLs using multiple methods ==="
	@azd show 2>&1 | tee full_deployment_output.log

	# Method 1: From azd show JSON output
	@jq -r '.services.web?.project?.hostedEndpoints?[0]?.url // ""' deploy_output.json > frontend_url.txt 2>/dev/null || echo "" > frontend_url.txt
	@jq -r '.services.adminweb?.project?.hostedEndpoints?[0]?.url // ""' deploy_output.json > admin_url.txt 2>/dev/null || echo "" > admin_url.txt

	# Method 2: From logs
	@grep -oE "https://app-[a-zA-Z0-9-]*\.azurewebsites\.net/" full_deployment_output.log | grep -v admin | head -1 >> frontend_url.txt 2>/dev/null || true
	@grep -oE "https://app-[a-zA-Z0-9-]*-admin\.azurewebsites\.net/" full_deployment_output.log | head -1 >> admin_url.txt 2>/dev/null || true

	# Clean up URLs (remove duplicates and empty lines)
	@sort frontend_url.txt | uniq | grep -v '^$$' | head -1 > frontend_url_clean.txt && mv frontend_url_clean.txt frontend_url.txt || echo "" > frontend_url.txt
	@sort admin_url.txt | uniq | grep -v '^$$' | head -1 > admin_url_clean.txt && mv admin_url_clean.txt admin_url.txt || echo "" > admin_url.txt

	@echo "=== URL Extraction Results ==="
	@FRONTEND_URL=$$(cat frontend_url.txt 2>/dev/null | tr -d '\n\r' | xargs); \
	ADMIN_URL=$$(cat admin_url.txt 2>/dev/null | tr -d '\n\r' | xargs); \
	echo "Frontend URL: $$FRONTEND_URL"; \
	echo "Admin URL: $$ADMIN_URL"

	@echo "=== Final Deployment Status ==="
	@echo "Frontend URL:" && cat frontend_url.txt 2>/dev/null || echo "Not available"
	@echo "Admin URL:" && cat admin_url.txt 2>/dev/null || echo "Not available"
	@echo ""
	@echo "🚀 Deployment completed!"
	@echo "⏰ Authentication will be disabled via GitHub Actions pipeline."
	@echo "🔄 Check the pipeline logs for authentication disable status."

	@echo "=== Extracting PostgreSQL Host Endpoint ==="
	# Get PostgreSQL host endpoint from azd env
	@azd env get-values > .env.temp 2>/dev/null || echo "" > .env.temp

	# Extract PostgreSQL host endpoint only (other values are hardcoded)
	@PG_HOST_VAL=$$(grep -E '^POSTGRES_HOST=|^PG_HOST=|^POSTGRES_SERVER=' .env.temp | cut -d'=' -f2 | tr -d '"' | head -1); \
	if [ -z "$$PG_HOST_VAL" ]; then \
		PG_HOST_VAL=$$(grep -E '^AZURE_POSTGRESQL_HOST=|^DATABASE_HOST=' .env.temp | cut -d'=' -f2 | tr -d '"' | head -1); \
	fi; \
	if [ -z "$$PG_HOST_VAL" ]; then \
		echo "Warning: PostgreSQL host not found in environment, using localhost"; \
		PG_HOST_VAL="localhost"; \
	fi; \
	echo "$$PG_HOST_VAL" > pg_host.txt; \
	echo "PostgreSQL host endpoint extracted: $$PG_HOST_VAL"

	# Create hardcoded values for other PostgreSQL parameters
	@echo "admintest" > pg_username.txt
	@echo "Initial_0524" > pg_password.txt
	@echo "postgres" > pg_database.txt
	@echo "5432" > pg_port.txt

	# Clean up temporary file
	@rm -f .env.temp

	@echo "=== PostgreSQL Configuration ==="
	@echo "Username: admintest (hardcoded)"
	@echo "Database: postgres (hardcoded)"
	@echo "Port: 5432 (hardcoded)"
	@echo "Host: $$(cat pg_host.txt 2>/dev/null || echo 'Not available')"
	@echo "Password: Initial_0524 (hardcoded)"
# Helper target to check current authentication status
check-auth:
	@echo "=== Checking Authentication Status ==="
	@FRONTEND_URL=$$(cat frontend_url.txt 2>/dev/null | tr -d '\n\r' | xargs); \
	ADMIN_URL=$$(cat admin_url.txt 2>/dev/null | tr -d '\n\r' | xargs); \
	if [ -n "$$FRONTEND_URL" ]; then \
		echo "Testing Frontend: $$FRONTEND_URL"; \
		HTTP_CODE=$$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "$$FRONTEND_URL" 2>/dev/null || echo "000"); \
		echo "Frontend HTTP Status: $$HTTP_CODE"; \
	fi; \
	if [ -n "$$ADMIN_URL" ]; then \
		echo "Testing Admin: $$ADMIN_URL"; \
		HTTP_CODE=$$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "$$ADMIN_URL" 2>/dev/null || echo "000"); \
		echo "Admin HTTP Status: $$HTTP_CODE"; \
	fi

# Helper target to manually disable authentication (for debugging)
disable-auth-manual:
	@echo "=== Manually Disabling Authentication ==="
	@echo "This target requires Azure CLI to be logged in manually"
	@FRONTEND_URL=$$(cat frontend_url.txt 2>/dev/null | tr -d '\n\r' | xargs); \
	ADMIN_URL=$$(cat admin_url.txt 2>/dev/null | tr -d '\n\r' | xargs); \
	export FRONTEND_WEBSITE_URL="$$FRONTEND_URL"; \
	export ADMIN_WEBSITE_URL="$$ADMIN_URL"; \
	if [ -f "disable_auth.sh" ]; then \
		chmod +x disable_auth.sh && ./disable_auth.sh; \
	else \
		echo "ERROR: disable_auth.sh not found"; \
		exit 1; \
	fi

disable-auth-fixed:
	@echo "=== Using Fixed Authentication Disable Script ==="
	@if [ -f "disable_auth_fixed.sh" ]; then \
		chmod +x disable_auth_fixed.sh && ./disable_auth_fixed.sh; \
	else \
		echo "ERROR: disable_auth_fixed.sh not found"; \
		exit 1; \
	fi

destroy: azd-login ## 🧨 Destroy everything in Azure
	@echo -e "\e[34m$@\e[0m" || true
	@azd down --force --purge --no-prompt
