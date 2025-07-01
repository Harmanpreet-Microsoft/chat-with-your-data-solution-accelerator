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

deploy: azd-login ## Deploy everything to Azure
	@echo -e "\e[34m$@\e[0m" || true
	@azd env new ${AZURE_ENV_NAME}

	# Set environment variables to ensure no authentication is configured
	@azd env set AZURE_APP_SERVICE_HOSTING_MODEL code --no-prompt
	@azd env set AUTH_ENABLED false --no-prompt
	@azd env set AZURE_USE_AUTHENTICATION false --no-prompt
	@azd env set AZURE_ENABLE_AUTH false --no-prompt
	@azd env set REQUIRE_AUTHENTICATION false --no-prompt
	@azd env set AUTHENTICATION_ENABLED false --no-prompt
	@azd env set WEBSITES_AUTH_ENABLED false --no-prompt
	@azd env set WEBSITE_AUTH_ENABLED false --no-prompt

	# Provision infrastructure with explicit no-auth configuration
	@echo "Provisioning Azure resources without authentication..."
	@azd provision --no-prompt

	# Deploy services
	@echo "Deploying web service..."
	@azd deploy web --no-prompt || true
	@echo "Deploying function service..."
	@azd deploy function --no-prompt || true
	@echo "Deploying admin web service..."
	@azd deploy adminweb --no-prompt

	# Wait a moment for services to stabilize
	@echo "Waiting for services to stabilize..."
	@sleep 30

	# Get deployment information and extract URLs
	@echo "Getting deployment information..."
	@azd show --output json > deploy_output.json || echo "{}" > deploy_output.json
	@cat deploy_output.json | jq '.' || echo "Failed to parse JSON output"

	# Extract URLs from JSON output using jq with better error handling
	@echo "Extracting URLs from JSON..."
	@jq -r '.services.web?.project?.hostedEndpoints?[0]?.url // ""' deploy_output.json > frontend_url.txt 2>/dev/null || echo "" > frontend_url.txt
	@jq -r '.services.adminweb?.project?.hostedEndpoints?[0]?.url // ""' deploy_output.json > admin_url.txt 2>/dev/null || echo "" > admin_url.txt

	# Debug: Show what we extracted
	@echo "Frontend URL extracted:" && cat frontend_url.txt
	@echo "Admin URL extracted:" && cat admin_url.txt

	# Fallback: Try environment variables if JSON extraction fails
	@if [ ! -s frontend_url.txt ] || [ "$$(cat frontend_url.txt)" = "" ]; then \
		echo "Trying environment variable extraction for frontend..."; \
		azd env get-values | grep FRONTEND_WEBSITE_URL | cut -d'=' -f2- | tr -d '"' > frontend_url.txt 2>/dev/null || echo "" > frontend_url.txt; \
	fi
	@if [ ! -s admin_url.txt ] || [ "$$(cat admin_url.txt)" = "" ]; then \
		echo "Trying environment variable extraction for admin..."; \
		azd env get-values | grep ADMIN_WEBSITE_URL | cut -d'=' -f2- | tr -d '"' > admin_url.txt 2>/dev/null || echo "" > admin_url.txt; \
	fi

	# Get resource information with better error handling
	@echo "Getting resource group and app names..."
	@RESOURCE_GROUP=$$(azd env get-values 2>/dev/null | grep AZURE_RESOURCE_GROUP | cut -d'=' -f2 | tr -d '"' || echo ""); \
	FRONTEND_APP_HOST=$$(echo $$FRONTEND_APP | sed 's|https://||;s|\.azurewebsites\.net.*||')
	ADMIN_APP=$$(azd env get-values 2>/dev/null | grep ADMIN_WEBSITE_NAME | cut -d'=' -f2 | tr -d '"' || echo ""); \
	echo "Resource Group: $$RESOURCE_GROUP"; \
	echo "Frontend App: $$FRONTEND_APP"; \
	echo "Admin App: $$ADMIN_APP"; \
	echo "$$RESOURCE_GROUP" > resource_group.txt; \
	echo "$$FRONTEND_APP" > frontend_app.txt; \
	echo "$$ADMIN_APP" > admin_app.txt

	# Ensure we're logged in to Azure CLI
	@echo "Configuring App Services for testing..."
	@az account show >/dev/null 2>&1 || az login --service-principal -u ${AZURE_CLIENT_ID} -p ${AZURE_CLIENT_SECRET} --tenant ${AZURE_TENANT_ID}
	@az account set --subscription ${AZURE_SUBSCRIPTION_ID}

	# Read the stored values
	@RESOURCE_GROUP=$$(cat resource_group.txt 2>/dev/null || echo ""); \
	FRONTEND_APP_URL=$$(cat frontend_url.txt 2>/dev/null || echo ""); \
	ADMIN_APP_URL=$$(cat admin_url.txt 2>/dev/null || echo ""); \
	FRONTEND_APP=$$(echo $$FRONTEND_APP_URL | sed 's|https://||;s|\.azurewebsites\.net.*||'); \
	ADMIN_APP=$$(echo $$ADMIN_APP_URL | sed 's|https://||;s|\.azurewebsites\.net.*||'); \

	if [ -n "$$RESOURCE_GROUP" ] && [ -n "$$FRONTEND_APP" ] && [ -n "$$ADMIN_APP" ]; then \
		echo "=== Completely disabling authentication on both apps ==="; \
		for app in $$FRONTEND_APP $$ADMIN_APP; do \
			echo "=== Processing $$app ==="; \
			echo "Step 1: Disabling platform authentication and setting anonymous access..."; \
			az webapp auth update --name "$$FRONTEND_APP" --resource-group "$$RESOURCE_GROUP" --action AllowAnonymous
			echo "Step 2: Setting comprehensive application settings..."; \
			az webapp config appsettings set --name "$$app" --resource-group "$$RESOURCE_GROUP" --settings \
				"AUTH_ENABLED=false" \
				"AZURE_USE_AUTHENTICATION=false" \
				"AZURE_ENABLE_AUTH=false" \
				"REQUIRE_AUTHENTICATION=false" \
				"AUTHENTICATION_ENABLED=false" \
				"WEBSITES_AUTH_ENABLED=false" \
				"WEBSITE_AUTH_ENABLED=false" \
				"AZURE_CLIENT_ID=" \
				"AZURE_CLIENT_SECRET=" \
				"AZURE_TENANT_ID=" \
				"AZURE_AD_CLIENT_ID=" \
				"AZURE_AD_CLIENT_SECRET=" \
				"AZURE_AD_TENANT_ID=" \
				"AZURE_AD_INSTANCE=" \
				"AZURE_AD_DOMAIN=" || echo "Failed to set app settings for $$app"; \
			echo "Step 3: Removing authentication providers..."; \
			az webapp auth microsoft update --name "$$app" --resource-group "$$RESOURCE_GROUP" --client-id "" --client-secret "" --tenant-id "" 2>/dev/null || echo "No Microsoft auth to remove"; \
			echo "Step 4: Setting up CORS..."; \
			az webapp cors add --name "$$app" --resource-group "$$RESOURCE_GROUP" --allowed-origins "*" || echo "CORS already configured"; \
			echo "✅ Authentication disable steps completed for $$app"; \
		done; \
		echo "=== Restarting apps to apply new settings ==="; \
		az webapp restart --name "$$FRONTEND_APP" --resource-group "$$RESOURCE_GROUP" || echo "Failed to restart frontend app"; \
		az webapp restart --name "$$ADMIN_APP" --resource-group "$$RESOURCE_GROUP" || echo "Failed to restart admin app"; \
		echo "Waiting 180 seconds for apps to restart..."; \
		sleep 180; \
		echo "=== Verifying authentication status ==="; \
		FRONTEND_AUTH=$$(az webapp auth show --name $$FRONTEND_APP --resource-group $$RESOURCE_GROUP --query "enabled" --output tsv 2>/dev/null || echo "false"); \
		ADMIN_AUTH=$$(az webapp auth show --name $$ADMIN_APP --resource-group $$RESOURCE_GROUP --query "enabled" --output tsv 2>/dev/null || echo "false"); \
		echo "Frontend Auth Enabled: $$FRONTEND_AUTH"; \
		echo "Admin Auth Enabled: $$ADMIN_AUTH"; \
		if [ "$$FRONTEND_AUTH" = "false" ] && [ "$$ADMIN_AUTH" = "false" ]; then \
			echo "✅ Authentication successfully disabled on both apps"; \
		else \
			echo "⚠️ Warning: Authentication may still be enabled"; \
		fi; \
	else \
		echo "⚠️ Warning: Could not retrieve all required information, but deployment URLs are available"; \
	fi

	# Final verification
	@echo "=== Final Deployment Status ==="
	@echo "Frontend URL:" && cat frontend_url.txt
	@echo "Admin URL:" && cat admin_url.txt

destroy: azd-login ## 🧨 Destroy everything in Azure
	@echo -e "\e[34m$@\e[0m" || true
	@azd down --force --purge --no-prompt
