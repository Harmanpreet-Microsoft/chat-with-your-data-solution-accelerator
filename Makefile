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

	@if [ ! -s frontend_url.txt ]; then azd env get-values | grep FRONTEND_WEBSITE_URL | cut -d'=' -f2- > frontend_url.txt; fi
	@if [ ! -s admin_url.txt ]; then azd env get-values | grep ADMIN_WEBSITE_URL | cut -d'=' -f2- > admin_url.txt; fi

	@RESOURCE_GROUP=$$(azd env get-values | grep AZURE_RESOURCE_GROUP | cut -d'=' -f2); \
	FRONTEND_APP=$$(cat frontend_url.txt | sed 's|https://||;s|\.azurewebsites\.net.*||'); \
	ADMIN_APP=$$(cat admin_url.txt | sed 's|https://||;s|\.azurewebsites\.net.*||'); \
	echo "Resource Group: $$RESOURCE_GROUP"; \
	echo "Frontend App: $$FRONTEND_APP"; \
	echo "Admin App: $$ADMIN_APP"; \
	echo "$$RESOURCE_GROUP" > resource_group.txt; \
	echo "$$FRONTEND_APP" > frontend_app.txt; \
	echo "$$ADMIN_APP" > admin_app.txt; \
	for app in $$FRONTEND_APP $$ADMIN_APP; do \
		echo "=== Disabling auth for $$app ==="; \
		az webapp auth update --name "$$app" --resource-group "$$RESOURCE_GROUP" --enabled false; \
		az webapp config set --name "$$app" --resource-group "$$RESOURCE_GROUP" --generic-configurations '{"unauthenticatedClientAction":"AllowAnonymous"}'; \
		az webapp config appsettings set --name "$$app" --resource-group "$$RESOURCE_GROUP" --settings \
		  WEBSITES_AUTH_ENABLED=false \
		  WEBSITE_AUTH_ENABLED=false \
		  AUTH_ENABLED=false \
		  AZURE_USE_AUTHENTICATION=false \
		  AZURE_ENABLE_AUTH=false \
		  REQUIRE_AUTHENTICATION=false \
		  AUTHENTICATION_ENABLED=false \
		  WEBSITE_RUN_FROM_PACKAGE=1; \
		az webapp cors add --name "$$app" --resource-group "$$RESOURCE_GROUP" --allowed-origins "*" || echo "CORS already configured"; \
	done; \
	az webapp restart --name "$$FRONTEND_APP" --resource-group "$$RESOURCE_GROUP"; \
	az webapp restart --name "$$ADMIN_APP" --resource-group "$$RESOURCE_GROUP"; \
	sleep 180; \
	FRONTEND_AUTH=$$(az webapp auth show --name $$FRONTEND_APP --resource-group $$RESOURCE_GROUP --query "enabled" --output tsv || echo "false"); \
	ADMIN_AUTH=$$(az webapp auth show --name $$ADMIN_APP --resource-group $$RESOURCE_GROUP --query "enabled" --output tsv || echo "false"); \
	echo "Frontend Auth Enabled: $$FRONTEND_AUTH"; \
	echo "Admin Auth Enabled: $$ADMIN_AUTH"; \
	if [ "$$FRONTEND_AUTH" = "false" ] && [ "$$ADMIN_AUTH" = "false" ]; then echo "✅ Authentication disabled"; fi

	@echo "=== Final Deployment Status ==="
	@echo "Frontend URL:" && cat frontend_url.txt
	@echo "Admin URL:" && cat admin_url.txt

destroy: azd-login ## 🧨 Destroy everything in Azure
	@echo -e "\e[34m$@\e[0m" || true
	@azd down --force --purge --no-prompt
