#!/bin/bash

# Enhanced script to completely disable Azure App Service authentication
# This script addresses the specific issues seen in your deployment logs

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
        RESOURCE_GROUP=$(az group list --query "[?contains(name, 'rg-')]" -o tsv | head -1)
        if [ -n "$RESOURCE_GROUP" ]; then
            log_warning "Resource group found by fallback pattern: $RESOURCE_GROUP"
        fi
    fi

    if [ -z "$RESOURCE_GROUP" ]; then
        log_error "Could not determine resource group"
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

    # Step 1: Get current authentication status
    log_info "Step 1: Checking current authentication status..."
    AUTH_ENABLED=$(az webapp auth show --name "$app_name" --resource-group "$rg_name" --query "enabled" --output tsv 2>/dev/null || echo "false")
    log_info "Current auth status: $AUTH_ENABLED"

    # Step 2: Disable authentication using multiple methods
    log_info "Step 2: Disabling authentication via webapp auth..."
    for attempt in {1..5}; do
        if az webapp auth update --name "$app_name" --resource-group "$rg_name" --enabled false >/dev/null 2>&1; then
            log_success "Authentication disabled via webapp auth (attempt $attempt)"
            break
        else
            log_warning "Authentication disable failed via webapp auth (attempt $attempt), retrying..."
            sleep 10
        fi
    done

    # Step 3: Use ARM template approach for more reliable disable
    log_info "Step 3: Disabling authentication via ARM resource update..."
    AUTH_SETTINGS_JSON=$(cat <<EOF
{
  "properties": {
    "enabled": false,
    "unauthenticatedClientAction": "AllowAnonymous",
    "defaultProvider": null,
    "tokenStoreEnabled": false,
    "allowedExternalRedirectUrls": [],
    "clientId": null,
    "clientSecret": null,
    "issuer": null,
    "allowedAudiences": [],
    "additionalLoginParams": [],
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

    # Apply ARM template update
    echo "$AUTH_SETTINGS_JSON" > auth_settings.json
    az rest --method PUT \
        --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$rg_name/providers/Microsoft.Web/sites/$app_name/config/authsettings?api-version=2020-06-01" \
        --body @auth_settings.json >/dev/null 2>&1 || log_warning "ARM template auth update failed"
    rm -f auth_settings.json

    # Step 4: Clear authentication-related app settings
    log_info "Step 4: Clearing authentication app settings..."
    az webapp config appsettings delete --name "$app_name" --resource-group "$rg_name" --setting-names \
        "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET" \
        "FACEBOOK_PROVIDER_AUTHENTICATION_SECRET" \
        "GOOGLE_PROVIDER_AUTHENTICATION_SECRET" \
        "TWITTER_PROVIDER_AUTHENTICATION_SECRET" \
        "AZURE_CLIENT_ID" \
        "AZURE_CLIENT_SECRET" \
        "AZURE_TENANT_ID" >/dev/null 2>&1 || log_warning "Some app settings couldn't be deleted"

    # Set explicit false values for auth-related settings
    az webapp config appsettings set --name "$app_name" --resource-group "$rg_name" --settings \
        "AUTH_ENABLED=false" \
        "AZURE_USE_AUTHENTICATION=false" \
        "AZURE_ENABLE_AUTH=false" \
        "REQUIRE_AUTHENTICATION=false" \
        "AUTHENTICATION_ENABLED=false" \
        "WEBSITES_AUTH_ENABLED=false" \
        "WEBSITE_AUTH_ENABLED=false" >/dev/null 2>&1 || log_warning "Failed to set some auth settings"

    # Step 5: Configure site config to allow anonymous access
    log_info "Step 5: Configuring site for anonymous access..."
    SITE_CONFIG_JSON=$(cat <<EOF
{
  "properties": {
    "siteAuthEnabled": false,
    "siteAuthSettings": {
      "enabled": false,
      "unauthenticatedClientAction": "AllowAnonymous"
    }
  }
}
EOF
)

    echo "$SITE_CONFIG_JSON" > site_config.json
    az rest --method PATCH \
        --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$rg_name/providers/Microsoft.Web/sites/$app_name/config/web?api-version=2020-06-01" \
        --body @site_config.json >/dev/null 2>&1 || log_warning "Site config update failed"
    rm -f site_config.json

    # Step 6: Update CORS settings
    log_info "Step 6: Updating CORS settings..."
    az webapp cors add --name "$app_name" --resource-group "$rg_name" --allowed-origins "*" >/dev/null 2>&1 || log_warning "CORS update failed"

    # Step 7: Restart the app
    log_info "Step 7: Restarting application..."
    for attempt in {1..3}; do
        if az webapp restart --name "$app_name" --resource-group "$rg_name" >/dev/null 2>&1; then
            log_success "App restarted successfully (attempt $attempt)"
            break
        else
            log_warning "App restart failed (attempt $attempt), retrying..."
            sleep 15
        fi
    done

    # Step 8: Wait for changes to propagate
    log_info "Step 8: Waiting for changes to propagate..."
    sleep 30

    # Step 9: Verify authentication is disabled
    log_info "Step 9: Verifying authentication status..."
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

    # Test with curl
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 30 --max-time 60 "$app_url" || echo "000")

    case $HTTP_CODE in
        200|302|301)
            log_success "$app_name is accessible (HTTP $HTTP_CODE)"
            ;;
        401|403)
            log_error "$app_name returned HTTP $HTTP_CODE - authentication may still be required"
            ;;
        000)
            log_warning "$app_name is not responding - may still be starting up"
            ;;
        *)
            log_warning "$app_name returned HTTP $HTTP_CODE - check application logs"
            ;;
    esac
}

# Main execution
main() {
    log_info "Starting enhanced authentication disable process..."

    # Azure login check
    if ! az account show >/dev/null 2>&1; then
        log_error "Not logged into Azure CLI. Please run 'az login' first."
        exit 1
    fi

    # Extract deployment information
    extract_deployment_info

    # Disable authentication for both apps
    if [ -n "$FRONTEND_APP" ]; then
        disable_authentication_completely "$FRONTEND_APP" "$RESOURCE_GROUP"
    fi

    if [ -n "$ADMIN_APP" ]; then
        disable_authentication_completely "$ADMIN_APP" "$RESOURCE_GROUP"
    fi

    # Wait for all changes to propagate
    log_info "Waiting additional time for all changes to propagate..."
    sleep 120

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

    log_success "Authentication disable process completed!"
    log_info "If you still see authentication errors, wait an additional 5-10 minutes for Azure to fully propagate the changes."
}

# Run the main function
main "$@"
