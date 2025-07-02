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
	@jq -r '.services.web?.project?.hostedEndpoints?[0]?.url // ""' deploy_output.json > frontend_url.txt 2>/dev/null || echo "" > frontend_url.txt
	@jq -r '.services.adminweb?.project?.hostedEndpoints?[0]?.url // ""' deploy_output.json > admin_url.txt 2>/dev/null || echo "" > admin_url.txt

	# Fallback: get URLs from azd env if jq failed
	@if [ ! -s frontend_url.txt ]; then azd env get-values | grep FRONTEND_WEBSITE_URL | cut -d'=' -f2- | tr -d '"' > frontend_url.txt 2>/dev/null || echo "" > frontend_url.txt; fi
	@if [ ! -s admin_url.txt ]; then azd env get-values | grep ADMIN_WEBSITE_URL | cut -d'=' -f2- | tr -d '"' > admin_url.txt 2>/dev/null || echo "" > admin_url.txt; fi

	# Alternative fallback: extract from deployment logs
	@if [ ! -s frontend_url.txt ]; then grep -oE "https://app-[a-zA-Z0-9.-]*\.azurewebsites\.net/" deploy_output.log | head -1 > frontend_url.txt 2>/dev/null || echo "" > frontend_url.txt; fi
	@if [ ! -s admin_url.txt ]; then grep -oE "https://app-[a-zA-Z0-9.-]*-admin\.azurewebsites\.net/" deploy_output.log | head -1 > admin_url.txt 2>/dev/null || echo "" > admin_url.txt; fi

	@echo "=== Extracted URLs ==="
	@echo "Frontend URL: $$(cat frontend_url.txt 2>/dev/null || echo 'Not found')"
	@echo "Admin URL: $$(cat admin_url.txt 2>/dev/null || echo 'Not found')"

	# Enhanced extraction with multiple methods
	@echo "Extracting resource information..."
	@i=0; \
	while [ $$i -lt 5 ]; do \
		echo "Attempt $$((i+1))/5 to extract resource information..."; \
		RESOURCE_GROUP=""; \
		FRONTEND_APP=""; \
		ADMIN_APP=""; \
		FRONTEND_URL=$$(cat frontend_url.txt 2>/dev/null | tr -d '\n\r' | xargs); \
		ADMIN_URL=$$(cat admin_url.txt 2>/dev/null | tr -d '\n\r' | xargs); \
		echo "Working with URLs - Frontend: $$FRONTEND_URL, Admin: $$ADMIN_URL"; \
		if [ -n "$$FRONTEND_URL" ] && [ "$$FRONTEND_URL" != "" ]; then \
			FRONTEND_APP=$$(echo "$$FRONTEND_URL" | sed 's|https://||;s|\.azurewebsites\.net.*||'); \
		fi; \
		if [ -n "$$ADMIN_URL" ] && [ "$$ADMIN_URL" != "" ]; then \
			ADMIN_APP=$$(echo "$$ADMIN_URL" | sed 's|https://||;s|\.azurewebsites\.net.*||'); \
		fi; \
		echo "Extracted app names - Frontend: $$FRONTEND_APP, Admin: $$ADMIN_APP"; \
		RESOURCE_GROUP=$$(azd env get-values 2>/dev/null | grep AZURE_RESOURCE_GROUP | cut -d'=' -f2 | tr -d '"' || echo ""); \
		if [ -z "$$RESOURCE_GROUP" ]; then \
			RESOURCE_GROUP=$$(azd env get-values 2>/dev/null | grep RESOURCE_GROUP | cut -d'=' -f2 | tr -d '"' || echo ""); \
		fi; \
		if [ -z "$$RESOURCE_GROUP" ]; then \
			RESOURCE_GROUP=$$(az group list --query "[?contains(name, 'rg-')].name" -o tsv 2>/dev/null | head -1 || echo ""); \
		fi; \
		echo "Found resource group: $$RESOURCE_GROUP"; \
		if [ -n "$$RESOURCE_GROUP" ] && [ -n "$$FRONTEND_APP" ] && [ -n "$$ADMIN_APP" ]; then \
			echo "✅ Successfully extracted all values"; \
			echo "$$RESOURCE_GROUP" > resource_group.txt; \
			echo "$$FRONTEND_APP" > frontend_app.txt; \
			echo "$$ADMIN_APP" > admin_app.txt; \
			break; \
		else \
			echo "⚠️ Missing values - RG: '$$RESOURCE_GROUP', Frontend: '$$FRONTEND_APP', Admin: '$$ADMIN_APP'"; \
			i=$$((i + 1)); \
			if [ $$i -lt 5 ]; then \
				echo "Retrying in 10 seconds..."; \
				sleep 10; \
			fi; \
		fi; \
	done; \
	if [ ! -f resource_group.txt ] || [ ! -s resource_group.txt ]; then \
		echo "❌ Failed to extract resource group after retries"; \
		echo "Attempting direct resource discovery..."; \
		RESOURCE_GROUP=$$(az group list --query "[?contains(name, '$${AZURE_ENV_NAME}') || contains(name, 'rg-')].name" -o tsv 2>/dev/null | head -1); \
		if [ -n "$$RESOURCE_GROUP" ]; then \
			echo "Found resource group via direct discovery: $$RESOURCE_GROUP"; \
			echo "$$RESOURCE_GROUP" > resource_group.txt; \
		else \
			echo "❌ Could not find resource group"; \
			exit 1; \
		fi; \
	fi; \
	RESOURCE_GROUP=$$(cat resource_group.txt); \
	FRONTEND_APP=$$(cat frontend_app.txt 2>/dev/null || echo ""); \
	ADMIN_APP=$$(cat admin_app.txt 2>/dev/null || echo ""); \
	echo "Final values - Resource Group: $$RESOURCE_GROUP, Frontend: $$FRONTEND_APP, Admin: $$ADMIN_APP"; \
	if [ -n "$$RESOURCE_GROUP" ]; then \
		echo "=== Disabling authentication for discovered apps ==="; \
		if [ -z "$$FRONTEND_APP" ] || [ -z "$$ADMIN_APP" ]; then \
			echo "App names missing, discovering from resource group..."; \
			az webapp list --resource-group "$$RESOURCE_GROUP" --query "[].name" -o tsv > discovered_apps.txt 2>/dev/null || echo "" > discovered_apps.txt; \
			while IFS= read -r app_name; do \
				if [ -n "$$app_name" ]; then \
					echo "Found app: $$app_name"; \
					if echo "$$app_name" | grep -q "admin"; then \
						ADMIN_APP="$$app_name"; \
					else \
						FRONTEND_APP="$$app_name"; \
					fi; \
				fi; \
			done < discovered_apps.txt; \
		fi; \
		echo "Processing apps - Frontend: $$FRONTEND_APP, Admin: $$ADMIN_APP"; \
		for app in $$FRONTEND_APP $$ADMIN_APP; do \
			if [ -n "$$app" ] && [ "$$app" != "" ]; then \
				echo "=== Completely disabling authentication for $$app ==="; \
				echo "Disabling Easy Auth..."; \
				az webapp auth update --name "$$app" --resource-group "$$RESOURCE_GROUP" --enabled false 2>/dev/null || echo "Auth update failed, continuing..."; \
				echo "Removing authentication providers..."; \
				az webapp auth microsoft update --name "$$app" --resource-group "$$RESOURCE_GROUP" --client-id "" --client-secret "" --tenant-id "" 2>/dev/null || echo "No Microsoft provider to remove"; \
				echo "Setting unauthenticated action..."; \
				az webapp config set --name "$$app" --resource-group "$$RESOURCE_GROUP" --generic-configurations '{"unauthenticatedClientAction":"AllowAnonymous"}' 2>/dev/null || echo "Failed to set unauthenticated action"; \
				echo "Setting app settings to disable auth..."; \
				az webapp config appsettings set --name "$$app" --resource-group "$$RESOURCE_GROUP" --settings \
				  "WEBSITES_AUTH_ENABLED=false" \
				  "WEBSITE_AUTH_ENABLED=false" \
				  "AUTH_ENABLED=false" \
				  "AZURE_USE_AUTHENTICATION=false" \
				  "AZURE_ENABLE_AUTH=false" \
				  "REQUIRE_AUTHENTICATION=false" \
				  "AUTHENTICATION_ENABLED=false" \
				  "WEBSITE_RUN_FROM_PACKAGE=1" \
				  "AZURE_CLIENT_ID=" \
				  "AZURE_CLIENT_SECRET=" \
				  "AZURE_TENANT_ID=" 2>/dev/null || echo "Failed to set some app settings"; \
				echo "Configuring CORS..."; \
				az webapp cors add --name "$$app" --resource-group "$$RESOURCE_GROUP" --allowed-origins "*" 2>/dev/null || echo "CORS already configured or failed"; \
				echo "Removing any remaining auth configuration..."; \
				az resource update --resource-group "$$RESOURCE_GROUP" --name "$$app/authsettings" --resource-type "Microsoft.Web/sites/config" --set properties.enabled=false properties.unauthenticatedClientAction="AllowAnonymous" 2>/dev/null || echo "Direct auth config update failed"; \
				echo "Restarting $$app..."; \
				az webapp restart --name "$$app" --resource-group "$$RESOURCE_GROUP" 2>/dev/null || echo "Restart failed for $$app"; \
			fi; \
		done; \
		echo "Waiting 180 seconds for changes to propagate..."; \
		sleep 180; \
	else \
		echo "❌ No resource group found, cannot disable authentication"; \
	fi

	@echo "=== Final Deployment Status ==="
	@echo "Frontend URL:" && cat frontend_url.txt 2>/dev/null || echo "Not available"
	@echo "Admin URL:" && cat admin_url.txt 2>/dev/null || echo "Not available"

destroy: azd-login ## 🧨 Destroy everything in Azure
	@echo -e "\e[34m$@\e[0m" || true
	@azd down --force --purge --no-prompt
