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

	# Set environment variables to disable auth
	@azd env set AUTH_ENABLED false --no-prompt
	@azd env set AZURE_USE_AUTHENTICATION false --no-prompt
	@azd env set AZURE_ENABLE_AUTH false --no-prompt
	@azd env set REQUIRE_AUTHENTICATION false --no-prompt
	@azd env set AUTHENTICATION_ENABLED false --no-prompt
	@azd env set WEBSITES_AUTH_ENABLED false --no-prompt
	@azd env set WEBSITE_AUTH_ENABLED false --no-prompt

	# Provision and deploy
	@azd provision --no-prompt
	@azd deploy web --no-prompt || true
	@azd deploy function --no-prompt || true
	@azd deploy adminweb --no-prompt

	@sleep 30
	@azd show --output json > deploy_output.json || echo "{}" > deploy_output.json

	# Extract URLs using multiple methods
	@echo "=== Extracting URLs using multiple methods ==="

	# Method 1: From azd show JSON output
	@jq -r '.services.web?.project?.hostedEndpoints?[0]?.url // ""' deploy_output.json > frontend_url.txt 2>/dev/null || echo "" > frontend_url.txt
	@jq -r '.services.adminweb?.project?.hostedEndpoints?[0]?.url // ""' deploy_output.json > admin_url.txt 2>/dev/null || echo "" > admin_url.txt

	# Method 2: From azd env get-values
	@if [ ! -s frontend_url.txt ]; then \
		azd env get-values | grep -E "(FRONTEND_WEBSITE_URL|WEB_URL)" | cut -d'=' -f2- | tr -d '"' | head -1 > frontend_url.txt 2>/dev/null || echo "" > frontend_url.txt; \
	fi
	@if [ ! -s admin_url.txt ]; then \
		azd env get-values | grep -E "(ADMIN_WEBSITE_URL|ADMINWEB_URL)" | cut -d'=' -f2- | tr -d '"' | head -1 > admin_url.txt 2>/dev/null || echo "" > admin_url.txt; \
	fi

	# Method 3: From deployment logs with better patterns
	@azd show 2>&1 | tee full_deployment_output.log
	@if [ ! -s frontend_url.txt ]; then \
		grep -oE "https://app-[a-zA-Z0-9-]*\.azurewebsites\.net/" full_deployment_output.log | grep -v admin | head -1 > frontend_url.txt 2>/dev/null || echo "" > frontend_url.txt; \
	fi
	@if [ ! -s admin_url.txt ]; then \
		grep -oE "https://app-[a-zA-Z0-9-]*-admin\.azurewebsites\.net/" full_deployment_output.log | head -1 > admin_url.txt 2>/dev/null || echo "" > admin_url.txt; \
	fi

	@echo "=== URL Extraction Results ==="
	@FRONTEND_URL=$$(cat frontend_url.txt 2>/dev/null | tr -d '\n\r' | xargs); \
	ADMIN_URL=$$(cat admin_url.txt 2>/dev/null | tr -d '\n\r' | xargs); \
	echo "Frontend URL: $$FRONTEND_URL"; \
	echo "Admin URL: $$ADMIN_URL"

	# Enhanced resource discovery with multiple approaches
	@echo "=== Enhanced Resource Discovery ==="
	@FRONTEND_URL=$$(cat frontend_url.txt 2>/dev/null | tr -d '\n\r' | xargs); \
	ADMIN_URL=$$(cat admin_url.txt 2>/dev/null | tr -d '\n\r' | xargs); \
	RESOURCE_GROUP=""; \
	FRONTEND_APP=""; \
	ADMIN_APP=""; \
	if [ -n "$$FRONTEND_URL" ] && [ "$$FRONTEND_URL" != "" ]; then \
		FRONTEND_APP=$$(echo "$$FRONTEND_URL" | sed 's|https://||;s|\.azurewebsites\.net.*||'); \
		echo "✅ Extracted frontend app: $$FRONTEND_APP"; \
	fi; \
	if [ -n "$$ADMIN_URL" ] && [ "$$ADMIN_URL" != "" ]; then \
		ADMIN_APP=$$(echo "$$ADMIN_URL" | sed 's|https://||;s|\.azurewebsites\.net.*||'); \
		echo "✅ Extracted admin app: $$ADMIN_APP"; \
	fi; \
	if [ -n "$$FRONTEND_APP" ]; then \
		echo "=== Finding resource group for $$FRONTEND_APP ==="; \
		RESOURCE_GROUP=$$(az webapp list --query "[?name=='$$FRONTEND_APP'].resourceGroup" -o tsv 2>/dev/null | head -1); \
		if [ -n "$$RESOURCE_GROUP" ]; then \
			echo "✅ Found resource group via app lookup: $$RESOURCE_GROUP"; \
		fi; \
	fi; \
	if [ -z "$$RESOURCE_GROUP" ] && [ -n "$$ADMIN_APP" ]; then \
		echo "=== Finding resource group for $$ADMIN_APP ==="; \
		RESOURCE_GROUP=$$(az webapp list --query "[?name=='$$ADMIN_APP'].resourceGroup" -o tsv 2>/dev/null | head -1); \
		if [ -n "$$RESOURCE_GROUP" ]; then \
			echo "✅ Found resource group via admin app lookup: $$RESOURCE_GROUP"; \
		fi; \
	fi; \
	if [ -z "$$RESOURCE_GROUP" ]; then \
		echo "=== Fallback: Using azd environment resource group ==="; \
		RESOURCE_GROUP=$$(azd env get-values 2>/dev/null | grep -E "(AZURE_RESOURCE_GROUP|RESOURCE_GROUP)" | cut -d'=' -f2 | tr -d '"' | head -1); \
		if [ -n "$$RESOURCE_GROUP" ]; then \
			echo "✅ Found resource group from azd env: $$RESOURCE_GROUP"; \
		fi; \
	fi; \
	if [ -z "$$RESOURCE_GROUP" ]; then \
		echo "=== Final fallback: List all resource groups ==="; \
		RESOURCE_GROUP=$$(az group list --query "[?contains(name, 'rg-') || contains(name, '${AZURE_ENV_NAME}')].name" -o tsv 2>/dev/null | head -1); \
		if [ -n "$$RESOURCE_GROUP" ]; then \
			echo "✅ Found resource group via list: $$RESOURCE_GROUP"; \
		fi; \
	fi; \
	if [ -n "$$RESOURCE_GROUP" ] && [ -n "$$FRONTEND_APP" ]; then \
		echo "=== Disabling Authentication ==="; \
		echo "Resource Group: $$RESOURCE_GROUP"; \
		echo "Frontend App: $$FRONTEND_APP"; \
		echo "Admin App: $$ADMIN_APP"; \
		for app in $$FRONTEND_APP $$ADMIN_APP; do \
			if [ -n "$$app" ] && [ "$$app" != "" ]; then \
				echo "=== Processing $$app ==="; \
				if az webapp show --name "$$app" --resource-group "$$RESOURCE_GROUP" >/dev/null 2>&1; then \
					echo "✅ App $$app found in $$RESOURCE_GROUP"; \
					echo "Disabling Easy Auth..."; \
					az webapp auth update --name "$$app" --resource-group "$$RESOURCE_GROUP" --enabled false 2>/dev/null || echo "Auth update failed"; \
					echo "Setting app settings to disable auth..."; \
					az webapp config appsettings set --name "$$app" --resource-group "$$RESOURCE_GROUP" --settings \
					  "WEBSITES_AUTH_ENABLED=false" \
					  "WEBSITE_AUTH_ENABLED=false" \
					  "AUTH_ENABLED=false" \
					  "AZURE_USE_AUTHENTICATION=false" \
					  "AZURE_ENABLE_AUTH=false" \
					  "REQUIRE_AUTHENTICATION=false" \
					  "AUTHENTICATION_ENABLED=false" 2>/dev/null || echo "Failed to set some app settings"; \
					echo "Setting unauthenticated action..."; \
					az resource update --resource-group "$$RESOURCE_GROUP" --name "$$app/authsettings" --resource-type "Microsoft.Web/sites/config" --set properties.enabled=false properties.unauthenticatedClientAction="AllowAnonymous" 2>/dev/null || echo "Direct auth config update failed"; \
					echo "Restarting $$app..."; \
					az webapp restart --name "$$app" --resource-group "$$RESOURCE_GROUP" 2>/dev/null || echo "Restart failed for $$app"; \
					echo "✅ Completed processing $$app"; \
				else \
					echo "❌ App $$app not found in resource group $$RESOURCE_GROUP"; \
					echo "Searching across all resource groups..."; \
					ACTUAL_RG=$$(az webapp list --query "[?name=='$$app'].resourceGroup" -o tsv 2>/dev/null | head -1); \
					if [ -n "$$ACTUAL_RG" ]; then \
						echo "✅ Found $$app in resource group: $$ACTUAL_RG"; \
						echo "Disabling auth in correct resource group..."; \
						az webapp auth update --name "$$app" --resource-group "$$ACTUAL_RG" --enabled false 2>/dev/null || echo "Auth update failed"; \
						az webapp config appsettings set --name "$$app" --resource-group "$$ACTUAL_RG" --settings \
						  "WEBSITES_AUTH_ENABLED=false" \
						  "WEBSITE_AUTH_ENABLED=false" \
						  "AUTH_ENABLED=false" \
						  "AZURE_USE_AUTHENTICATION=false" \
						  "AZURE_ENABLE_AUTH=false" \
						  "REQUIRE_AUTHENTICATION=false" \
						  "AUTHENTICATION_ENABLED=false" 2>/dev/null || echo "Failed to set some app settings"; \
						az resource update --resource-group "$$ACTUAL_RG" --name "$$app/authsettings" --resource-type "Microsoft.Web/sites/config" --set properties.enabled=false properties.unauthenticatedClientAction="AllowAnonymous" 2>/dev/null || echo "Direct auth config update failed"; \
						az webapp restart --name "$$app" --resource-group "$$ACTUAL_RG" 2>/dev/null || echo "Restart failed"; \
						echo "✅ Completed processing $$app in $$ACTUAL_RG"; \
					else \
						echo "❌ Could not find $$app in any resource group"; \
					fi; \
				fi; \
			fi; \
		done; \
		echo "Waiting 120 seconds for changes to propagate..."; \
		sleep 120; \
	else \
		echo "❌ Cannot disable authentication - missing resource group or app names"; \
		echo "Resource Group: $$RESOURCE_GROUP"; \
		echo "Frontend App: $$FRONTEND_APP"; \
		echo "Admin App: $$ADMIN_APP"; \
	fi

	@echo "=== Final Deployment Status ==="
	@echo "Frontend URL:" && cat frontend_url.txt 2>/dev/null || echo "Not available"
	@echo "Admin URL:" && cat admin_url.txt 2>/dev/null || echo "Not available"

destroy: azd-login ## 🧨 Destroy everything in Azure
	@echo -e "\e[34m$@\e[0m" || true
	@azd down --force --purge --no-prompt
