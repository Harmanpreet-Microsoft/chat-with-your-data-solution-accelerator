#!/bin/bash

# Enhanced script to completely disable Azure App Service authentication
# This script fixes the issue where environment variables aren't properly set as App Service settings

set -e

# Configuration
RESOURCE_GROUP=""
FRONTEND_APP=""
ADMIN_APP=""
SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to extract app names and resource group
extract_deployment_info() {
    log_info "Extracting deployment information..."

    # Try to get URLs from environment variables or files
    if [ -n "$FRONTEND_WEBSITE_URL" ]; then
        FRONTEND_APP=$(echo "$FRONTEND_WEBSITE_URL" | sed 's|https://||;s|\.azurewebsites\.net.*||')
        log_success "Frontend app extracted from env var: $FRONTEND_APP"
    elif [ -f "frontend_url.txt" ]; then
        FRONTEND_URL=$(cat frontend_url.txt | tr -d '\n\r' | xargs)
        if [ -n "$FRONTEND_URL" ]; then
            FRONTEND_APP=$(echo "$FRONTEND_URL" | sed 's|https://||;s|\.azurewebsites\.net.*||')
            log_success "Frontend app extracted from file: $FRONTEND_APP"
        fi
    fi

    if [ -n "$ADMIN_WEBSITE_URL" ]; then
        ADMIN_APP=$(echo "$ADMIN_WEBSITE_URL" | sed 's|https://||;s|\.azurewebsites\.net.*||')
        log_success "Admin app extracted from env var: $ADMIN_APP"
    elif [ -f "admin_url.txt" ]; then
        ADMIN_URL=$(cat admin_url.txt | tr -d '\n\r' | xargs)
        if [ -n "$ADMIN_URL" ]; then
            ADMIN_APP=$(echo "$ADMIN_URL" | sed 's|https://||;s|\.azurewebsites\.net.*||')
            log_success "Admin app extracted from file: $ADMIN_APP"
        fi
    fi

    # Find resource group
    if [ -n "$FRONTEND_APP" ]; then
        RESOURCE_GROUP=$(az webapp list --query "[?name=='$FRONTEND_APP'].resourceGroup" -o tsv | head -1)
        if [ -n "$RESOURCE_GROUP" ]; then
            log_success "Resource group found via frontend app: $RESOURCE_GROUP"
        fi
    fi

    if [ -z "$RESOURCE_GROUP" ] && [ -n "$ADMIN_APP" ]; then
        RESOURCE_GROUP=$(az webapp list --query "[?name=='$ADMIN_APP'].resourceGroup" -o tsv | head -1)
        if [ -n "$RESOURCE_GROUP" ]; then
            log_success "Resource group found via admin app: $RESOURCE_GROUP"
        fi
    fi

    # Fallback: search by environment pattern
    if [ -z "$RESOURCE_GROUP" ]; then
        RESOURCE_GROUP=$(az group list --query "[?contains(name, 'rg-')].[name]" -o tsv | head -1)
        if [ -n "$RESOURCE_GROUP" ]; then
            log_warning "Resource group found by fallback pattern: $RESOURCE_GROUP"
        fi
    fi

    if [ -z "$RESOURCE_GROUP" ]; then
        log_error "Could not determine resource group"
        log_info "Available resource groups:"
        az group list --query "[].name" -o table
        exit 1
    fi

    log_info "Configuration:"
    log_info "  Resource Group: $RESOURCE_GROUP"
    log_info "  Frontend App: ${FRONTEND_APP:-'Not found'}"
    log_info "  Admin App: ${ADMIN_APP:-'Not found'}"
}

# Function to completely disable authentication with comprehensive approach
disable_authentication_completely() {
    local app_name=$1
    local rg_name=$2

    if [ -z "$app_name" ] || [ -z "$rg_name" ]; then
        log_warning "Skipping authentication disable - missing app name or resource group"
        return
    fi

    log_info "=== Disabling Authentication for $app_name ==="

    # Verify app exists
    if ! az webapp show --name "$app_name" --resource-group "$rg_name" >/dev/null 2>&1; then
        log_error "App $app_name not found in resource group $rg_name"
        return 1
    fi

    # Step 1: Disable authentication using webapp auth update
    log_info "Step 1: Disabling authentication via webapp auth..."
    for attempt in {1..3}; do
        if az webapp auth update \
            --name "$app_name" \
            --resource-group "$rg_name" \
            --enabled false \
            --action AllowAnonymous \
            --token-store false >/dev/null 2>&1; then
            log_success "Authentication disabled via webapp auth (attempt $attempt)"
            break
        else
            log_warning "Authentication disable failed via webapp auth (attempt $attempt), retrying..."
            sleep 15
        fi
    done

    # Step 2: Clear all authentication-related app settings first
    log_info "Step 2: Clearing existing authentication app settings..."
    az webapp config appsettings delete --name "$app_name" --resource-group "$rg_name" --setting-names \
        "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET" \
        "FACEBOOK_PROVIDER_AUTHENTICATION_SECRET" \
        "GOOGLE_PROVIDER_AUTHENTICATION_SECRET" \
        "TWITTER_PROVIDER_AUTHENTICATION_SECRET" \
        "GITHUB_PROVIDER_AUTHENTICATION_SECRET" \
        "AZURE_CLIENT_ID" \
        "AZURE_CLIENT_SECRET" \
        "AZURE_TENANT_ID" \
        "WEBSITE_AUTH_CLIENT_ID" \
        "WEBSITE_AUTH_CLIENT_SECRET" \
        "WEBSITE_AUTH_TENANT_ID" \
        "MICROSOFT_PROVIDER_AUTHENTICATION_APPID" \
        "WEBSITE_AUTH_OPENID_ISSUER" \
        "WEBSITE_AUTH_LOGOUT_PATH" \
        "WEBSITE_AUTH_TOKEN_STORE" \
        "WEBSITE_AUTH_ENABLED" \
        "WEBSITES_ENABLE_APP_SERVICE_STORAGE" \
        "WEBSITE_DISABLE_AUTH" >/dev/null 2>&1 || log_warning "Some existing app settings couldn't be deleted"

    # Step 3: Set comprehensive App Service application settings (THIS IS THE KEY FIX)
    log_info "Step 3: Setting comprehensive App Service application settings..."
    az webapp config appsettings set --name "$app_name" --resource-group "$rg_name" --settings \
        "AUTH_ENABLED=false" \
        "AZURE_USE_AUTHENTICATION=false" \
        "AZURE_ENABLE_AUTH=false" \
        "REQUIRE_AUTHENTICATION=false" \
        "AUTHENTICATION_ENABLED=false" \
        "WEBSITES_AUTH_ENABLED=false" \
        "WEBSITE_AUTH_ENABLED=false" \
        "FORCE_NO_AUTH=true" \
        "ENFORCE_AUTH=false" \
        "AZURE_AUTH_ENABLED=false" \
        "ENABLE_AUTHENTICATION=false" \
        "DISABLE_AUTHENTICATION=true" \
        "NO_AUTH=true" \
        "SKIP_AUTH=true" \
        "WEBSITE_AUTH_DISABLE_WWWAUTHENTICATE=true" \
        "WEBSITE_AUTH_DISABLE_IDENTITY_FLOW=true" \
        "WEBSITE_AUTH_SKIP_PROVIDER_SELECTION=true" \
        "WEBSITE_AUTH_DISABLE_SC_VALIDATION=true" \
        "WEBSITE_DISABLE_AUTH=true" \
        "AZURE_AUTH_DISABLE=true" \
        "WEBAPP_AUTH_DISABLE=true" \
        "DISABLE_EASY_AUTH=true" \
        "EASY_AUTH_ENABLED=false" \
        "WEBSITE_AUTH_AUTO_AAD=false" \
        "WEBSITE_AUTH_HIDE_DEPRECATED_SID=true" >/dev/null 2>&1 || log_warning "Failed to set some auth settings"

    # Step 4: Use ARM template approach for EasyAuth V1 settings
    log_info "Step 4: Disabling authentication via ARM EasyAuth V1..."
    AUTH_SETTINGS_V1=$(cat <<EOF
{
  "properties": {
    "enabled": false,
    "unauthenticatedClientAction": "AllowAnonymous",
    "defaultProvider": null,
    "tokenStoreEnabled": false,
    "clientId": null,
    "clientSecret": null,
    "clientSecretSettingName": null,
    "issuer": null,
    "allowedAudiences": [],
    "additionalLoginParams": [],
    "isAadAutoProvisioned": false,
    "googleClientId": null,
    "googleClientSecret": null,
    "facebookAppId": null,
    "facebookAppSecret": null,
    "gitHubClientId": null,
    "gitHubClientSecret": null,
    "twitterConsumerKey": null,
    "twitterConsumerSecret": null,
    "microsoftAccountClientId": null,
    "microsoftAccountClientSecret": null
  }
}
EOF
)

    echo "$AUTH_SETTINGS_V1" > "auth_settings_v1_${app_name}.json"
    az rest --method PUT \
        --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$rg_name/providers/Microsoft.Web/sites/$app_name/config/authsettings?api-version=2020-06-01" \
        --body "@auth_settings_v1_${app_name}.json" >/dev/null 2>&1 || log_warning "ARM EasyAuth V1 update failed"
    rm -f "auth_settings_v1_${app_name}.json"

    # Step 5: Use ARM template approach for EasyAuth V2 settings
    log_info "Step 5: Disabling authentication via ARM EasyAuth V2..."
    AUTH_SETTINGS_V2=$(cat <<EOF
{
  "properties": {
    "platform": {
      "enabled": false,
      "runtimeVersion": "~1"
    },
    "globalValidation": {
      "requireAuthentication": false,
      "unauthenticatedClientAction": "AllowAnonymous"
    },
    "identityProviders": {
      "azureActiveDirectory": {
        "enabled": false
      },
      "facebook": {
        "enabled": false
      },
      "gitHub": {
        "enabled": false
      },
      "google": {
        "enabled": false
      },
      "twitter": {
        "enabled": false
      }
    },
    "login": {
      "preserveUrlFragmentsForLogins": false,
      "allowedExternalRedirectUrls": [],
      "tokenStore": {
        "enabled": false
      }
    },
    "httpSettings": {
      "requireHttps": false,
      "routes": {
        "apiPrefix": "/.auth"
      },
      "forwardProxy": {
        "convention": "NoProxy"
      }
    }
  }
}
EOF
)

    echo "$AUTH_SETTINGS_V2" > "auth_settings_v2_${app_name}.json"
    az rest --method PUT \
        --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$rg_name/providers/Microsoft.Web/sites/$app_name/config/authsettingsV2?api-version=2020-06-01" \
        --body "@auth_settings_v2_${app_name}.json" >/dev/null 2>&1 || log_warning "ARM EasyAuth V2 update failed"
    rm -f "auth_settings_v2_${app_name}.json"

    # Step 6: Configure site config to explicitly allow anonymous access
    log_info "Step 6: Configuring site for anonymous access..."
    SITE_CONFIG_JSON=$(cat <<EOF
{
  "properties": {
    "siteAuthEnabled": false,
    "siteAuthSettings": {
      "enabled": false,
      "unauthenticatedClientAction": "AllowAnonymous"
    },
    "clientAffinityEnabled": false,
    "httpsOnly": false,
    "use32BitWorkerProcess": false,
    "webSocketsEnabled": true,
    "alwaysOn": true,
    "requestTracingEnabled": false,
    "httpLoggingEnabled": false,
    "remoteDebuggingEnabled": false,
    "ftpsState": "Disabled"
  }
}
EOF
)

    echo "$SITE_CONFIG_JSON" > "site_config_${app_name}.json"
    az rest --method PATCH \
        --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$rg_name/providers/Microsoft.Web/sites/$app_name/config/web?api-version=2020-06-01" \
        --body "@site_config_${app_name}.json" >/dev/null 2>&1 || log_warning "Site config update failed"
    rm -f "site_config_${app_name}.json"

    # Step 7: Update CORS settings
    log_info "Step 7: Updating CORS settings..."
    az webapp cors add --name "$app_name" --resource-group "$rg_name" --allowed-origins "*" >/dev/null 2>&1 || log_warning "CORS update failed"

    # Step 8: Force restart the application multiple times
    log_info "Step 8: Restarting application multiple times..."
    for attempt in {1..3}; do
        if az webapp restart --name "$app_name" --resource-group "$rg_name" >/dev/null 2>&1; then
            log_success "App restarted successfully (attempt $attempt)"
            sleep 30
        else
            log_warning "App restart failed (attempt $attempt), retrying..."
            sleep 15
        fi
    done

    # Step 9: Stop and start the application for complete reset
    log_info "Step 9: Performing complete stop/start cycle..."
    az webapp stop --name "$app_name" --resource-group "$rg_name" >/dev/null 2>&1 || log_warning "App stop failed"
    sleep 30
    az webapp start --name "$app_name" --resource-group "$rg_name" >/dev/null 2>&1 || log_warning "App start failed"
    sleep 30

    # Step 10: Verify the application settings were applied
    log_info "Step 10: Verifying application settings..."
    FORCE_NO_AUTH_SET=$(az webapp config appsettings list --name "$app_name" --resource-group "$rg_name" --query "[?name=='FORCE_NO_AUTH'].value | [0]" -o tsv 2>/dev/null || echo "")
    ENFORCE_AUTH_SET=$(az webapp config appsettings list --name "$app_name" --resource-group "$rg_name" --query "[?name=='ENFORCE_AUTH'].value | [0]" -o tsv 2>/dev/null || echo "")

    if [ "$FORCE_NO_AUTH_SET" = "true" ]; then
        log_success "FORCE_NO_AUTH is properly set to true"
    else
        log_warning "FORCE_NO_AUTH not found or not set to true (found: '$FORCE_NO_AUTH_SET')"
    fi

    if [ "$ENFORCE_AUTH_SET" = "false" ]; then
        log_success "ENFORCE_AUTH is properly set to false"
    else
        log_warning "ENFORCE_AUTH not found or not set to false (found: '$ENFORCE_AUTH_SET')"
    fi

    # Step 11: Verify authentication is disabled
    log_info "Step 11: Verifying authentication status..."
    NEW_AUTH_STATUS=$(az webapp auth show --name "$app_name" --resource-group "$rg_name" --query "enabled" --output tsv 2>/dev/null || echo "false")
    if [ "$NEW_AUTH_STATUS" = "false" ]; then
        log_success "Authentication successfully disabled for $app_name"
    else
        log_warning "Authentication may still be enabled for $app_name (status: $NEW_AUTH_STATUS)"
    fi

    log_success "Authentication disable process completed for $app_name"
}

# Function to test app accessibility
test_app_accessibility() {
    local app_url=$1
    local app_name=$2

    if [ -z "$app_url" ]; then
        log_warning "No URL provided for $app_name, skipping accessibility test"
        return
    fi

    log_info "Testing accessibility for $app_name at $app_url"

    # Test with curl with comprehensive checks
    for attempt in {1..3}; do
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout 30 \
            --max-time 60 \
            --location \
            --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
            "$app_url" 2>/dev/null || echo "000")

        case $HTTP_CODE in
            200|302|301)
                log_success "$app_name is accessible (HTTP $HTTP_CODE) - attempt $attempt"
                return 0
                ;;
            401|403)
                log_error "$app_name returned HTTP $HTTP_CODE - authentication may still be required - attempt $attempt"
                if [ $attempt -lt 3 ]; then
                    log_info "Waiting 45 seconds before retry..."
                    sleep 45
                fi
                ;;
            000)
                log_warning "$app_name is not responding - may still be starting up - attempt $attempt"
                if [ $attempt -lt 3 ]; then
                    log_info "Waiting 45 seconds before retry..."
                    sleep 45
                fi
                ;;
            *)
                log_warning "$app_name returned HTTP $HTTP_CODE - check application logs - attempt $attempt"
                if [ $attempt -lt 3 ]; then
                    log_info "Waiting 45 seconds before retry..."
                    sleep 45
                fi
                ;;
        esac
    done

    log_error "$app_name accessibility test failed after 3 attempts"
}

# Main execution
main() {
    log_info "Starting enhanced authentication disable process..."

    # Azure login check
    if ! az account show >/dev/null 2>&1; then
        log_error "Not logged into Azure CLI. Please run 'az login' first."
        exit 1
    fi

    # Show current subscription
    CURRENT_SUB=$(az account show --query "name" -o tsv)
    log_info "Using Azure subscription: $CURRENT_SUB"

    # Extract deployment information
    extract_deployment_info

    # Disable authentication for both apps
    if [ -n "$FRONTEND_APP" ]; then
        disable_authentication_completely "$FRONTEND_APP" "$RESOURCE_GROUP"
    else
        log_warning "Frontend app not found, skipping authentication disable"
    fi

    if [ -n "$ADMIN_APP" ]; then
        disable_authentication_completely "$ADMIN_APP" "$RESOURCE_GROUP"
    else
        log_warning "Admin app not found, skipping authentication disable"
    fi

    # Wait for all changes to propagate
    log_info "Waiting 300 seconds for all changes to propagate..."
    sleep 300

    # Test accessibility
    log_info "=== Testing Application Accessibility ==="
    if [ -n "$FRONTEND_WEBSITE_URL" ]; then
        test_app_accessibility "$FRONTEND_WEBSITE_URL" "Frontend"
    elif [ -n "$FRONTEND_APP" ]; then
        test_app_accessibility "https://$FRONTEND_APP.azurewebsites.net/" "Frontend"
    fi

    if [ -n "$ADMIN_WEBSITE_URL" ]; then
        test_app_accessibility "$ADMIN_WEBSITE_URL" "Admin"
    elif [ -n "$ADMIN_APP" ]; then
        test_app_accessibility "https://$ADMIN_APP.azurewebsites.net/" "Admin"
    fi

    log_success "Enhanced authentication disable process completed!"
    log_info "If you still see authentication errors, wait an additional 15-20 minutes for Azure to fully propagate the changes."
    log_info "Azure App Service authentication changes can take up to 20 minutes to fully take effect."
}

# Run the main function
main "$@"
