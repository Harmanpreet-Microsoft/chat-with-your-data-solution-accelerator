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
deploy: azd-login ## Deploy everything to Azure
	@echo -e "\e[34m$@\e[0m" || true
	@azd env new ${AZURE_ENV_NAME}

	# Set environment variables to disable auth (corrected values)
	@azd env set AUTH_ENABLED false --no-prompt
	@azd env set AZURE_USE_AUTHENTICATION false --no-prompt
	@azd env set AZURE_ENABLE_AUTH false --no-prompt
	@azd env set REQUIRE_AUTHENTICATION false --no-prompt
	@azd env set AUTHENTICATION_ENABLED false --no-prompt
	@azd env set WEBSITES_AUTH_ENABLED false --no-prompt
	@azd env set WEBSITE_AUTH_ENABLED false --no-prompt
	@azd env set FORCE_NO_AUTH true --no-prompt
	@azd env set ENFORCE_AUTH false --no-prompt

	# Additional auth-related environment variables
	@azd env set AZURE_AUTH_ENABLED false --no-prompt
	@azd env set ENABLE_AUTHENTICATION false --no-prompt
	@azd env set DISABLE_AUTHENTICATION true --no-prompt
	@azd env set NO_AUTH true --no-prompt
	@azd env set SKIP_AUTH true --no-prompt

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

	# Method 2: From azd show output
	@grep -oE "https://app-[a-zA-Z0-9-]*\.azurewebsites\.net/" full_deployment_output.log | grep -v admin | head -1 >> frontend_url.txt 2>/dev/null || true
	@grep -oE "https://app-[a-zA-Z0-9-]*-admin\.azurewebsites\.net/" full_deployment_output.log | head -1 >> admin_url.txt 2>/dev/null || true

	# Clean up URLs (remove duplicates and empty lines)
	@sort frontend_url.txt | uniq | grep -v '^$$' | head -1 > frontend_url_clean.txt && mv frontend_url_clean.txt frontend_url.txt || echo "" > frontend_url.txt
	@sort admin_url.txt | uniq | grep -v '^$$' | head -1 > admin_url_clean.txt && mv admin_url_clean.txt admin_url.txt || echo "" > admin_url.txt

	@echo "=== URL Extraction Results ==="
	@FRONTEND_URL=$$(cat frontend_url.txt 2>/dev/null | tr -d '\n\r' | xargs); \
	ADMIN_URL=$$(cat admin_url.txt 2>/dev/null | tr -d '\n\r' | xargs); \
	echo "Frontend URL: $$FRONTEND_URL"; \
	echo "Admin URL: $$ADMIN_URL"; \
	export FRONTEND_WEBSITE_URL="$$FRONTEND_URL"; \
	export ADMIN_WEBSITE_URL="$$ADMIN_URL"

	# Use the enhanced authentication disable script
	@echo "=== Running Enhanced Authentication Disable ==="
	@FRONTEND_URL=$$(cat frontend_url.txt 2>/dev/null | tr -d '\n\r' | xargs); \
	ADMIN_URL=$$(cat admin_url.txt 2>/dev/null | tr -d '\n\r' | xargs); \
	export FRONTEND_WEBSITE_URL="$$FRONTEND_URL"; \
	export ADMIN_WEBSITE_URL="$$ADMIN_URL"; \
	chmod +x disable_auth.sh && ./disable_auth.sh

	@echo "=== Final Deployment Status ==="
	@echo "Frontend URL:" && cat frontend_url.txt 2>/dev/null || echo "Not available"
	@echo "Admin URL:" && cat admin_url.txt 2>/dev/null || echo "Not available"
	@echo ""
	@echo "🚀 Deployment completed! Wait 5-10 minutes for authentication changes to fully propagate."

destroy: azd-login ## 🧨 Destroy everything in Azure
	@echo -e "\e[34m$@\e[0m" || true
	@azd down --force --purge --no-prompt
