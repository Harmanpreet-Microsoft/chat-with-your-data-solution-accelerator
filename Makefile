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

deploy: azd-login ## 🚀 Deploy everything to Azure
	@echo -e "\e[34m$@\e[0m" || true
	@azd env new ${AZURE_ENV_NAME}
	@azd env set AZURE_APP_SERVICE_HOSTING_MODEL code --no-prompt
	@azd provision --no-prompt
	@azd deploy web --no-prompt || true
	@azd deploy function --no-prompt || true
	@azd deploy adminweb --no-prompt
	@azd env set AUTH_ENABLED false
	@azd show --output json | jq

	# Get environment values and extract URLs
	@azd env get-values > azd.env
	@echo "Contents of azd.env:" && cat azd.env

	# Extract URLs and write to files in current directory (not /tmp)
	@grep -oP '^FRONTEND_WEBSITE_URL=\K.*' azd.env > frontend_url.txt || (echo "" > frontend_url.txt)
	@grep -oP '^ADMIN_WEBSITE_URL=\K.*' azd.env > admin_url.txt || (echo "" > admin_url.txt)

	# Debug: Show what we extracted
	@echo "Frontend URL extracted:" && cat frontend_url.txt || echo "No frontend_url.txt"
	@echo "Admin URL extracted:" && cat admin_url.txt || echo "No admin_url.txt"

	# Also try alternative extraction method if the first one fails
	@if [ ! -s frontend_url.txt ]; then \
		echo "Trying alternative frontend URL extraction..."; \
		azd env get-value FRONTEND_WEBSITE_URL > frontend_url.txt 2>/dev/null || echo "" > frontend_url.txt; \
	fi
	@if [ ! -s admin_url.txt ]; then \
		echo "Trying alternative admin URL extraction..."; \
		azd env get-value ADMIN_WEBSITE_URL > admin_url.txt 2>/dev/null || echo "" > admin_url.txt; \
	fi


destroy: azd-login ## 🧨 Destroy everything in Azure
	@echo -e "\e[34m$@\e[0m" || true
	@azd down --force --purge --no-prompt
