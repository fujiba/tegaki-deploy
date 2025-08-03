#!/bin/bash
set -eu

# --- Configuration ---
SCRIPT_DIR=$(cd $(dirname $0); pwd)
PROJECT_DIR=$(cd $(dirname ${SCRIPT_DIR}); pwd)
CONFIG_FILE="${PROJECT_DIR}/config.yaml"
TERRAFORM_DIR="${PROJECT_DIR}/terraform"
FUNCTIONS_DIR="${PROJECT_DIR}/functions/gdrive-sync"

PROJECT_ID=""

# --- Helper Functions ---
usage() {
  echo "Usage: $0 [options]"
  echo ""
  echo "This script configures your Firebase project after Terraform has been applied."
  echo ""
  echo "Options:"
  echo "  (no options)       Run the full initial setup (Firebase targets, Drive URL, and Secret)."
  echo "  --update-url       Interactively update only the Google Drive Folder URL parameter."
  echo "  --recreate-secret  Generate and set a new POLLING_SYNC_SECRET."
  echo "  -h, --help         : Show this help message."
  exit 1
}

get_project_id_from_tf() {
  local env_dir=$1
  if [ ! -d "$env_dir" ]; then
    echo "Error: Terraform environment directory '$env_dir' not found." >&2
    exit 1
  fi
  echo "Attempting to get project ID from Terraform output in '$env_dir'..."
  if [ ! -f "${env_dir}/.terraform/terraform.tfstate" ] && [ ! -f "${env_dir}/terraform.tfstate" ]; then
       echo "Error: Terraform state not found in '$env_dir'. Please run 'terraform init' and 'terraform apply' first." >&2
       exit 1
  fi
  if ! PROJECT_ID=$(pushd "$env_dir" > /dev/null && terraform output -raw generated_project_id && popd > /dev/null); then
      echo "Error: Failed to get 'generated_project_id' from Terraform output." >&2
      popd > /dev/null 2>&1 || true
      exit 1
  fi

  if [ -z "$PROJECT_ID" ]; then
      echo "Error: Terraform output 'generated_project_id' was empty." >&2
      exit 1
  fi
  echo "✅ Found Project ID: ${PROJECT_ID}"
}

get_service_account_email_from_tf() {
  local env_dir=$1
  echo "Attempting to get service account email from Terraform output in '$env_dir'..."
  # Redirect stderr to /dev/null to suppress "output not found" errors if it doesn't exist, then handle the empty variable.
  if ! DEPLOY_SA_EMAIL=$(pushd "$env_dir" > /dev/null && terraform output -raw deploy_service_account_email 2>/dev/null && popd > /dev/null); then
      echo "Warning: Could not get 'deploy_service_account_email' from Terraform output. You may need to find it manually in the GCP console." >&2
      DEPLOY_SA_EMAIL="deploy@${PROJECT_ID}.iam.gserviceaccount.com" # Fallback to a likely value
      echo "Assuming service account email is: ${DEPLOY_SA_EMAIL}"
      popd > /dev/null 2>&1 || true
      return
  fi

  if [ -z "$DEPLOY_SA_EMAIL" ]; then
      echo "Warning: Terraform output 'deploy_service_account_email' was empty. You may need to find it manually in the GCP console." >&2
      return
  fi
  echo "✅ Found Service Account Email: ${DEPLOY_SA_EMAIL}"
}

setup_firebase_targets() {
  echo "--- Setting up Firebase targets ---"
  echo "Switching Firebase CLI to use project ${PROJECT_ID}..."
  (cd "${PROJECT_DIR}" && npm --prefix functions/gdrive-sync run target:apply -- hosting prod "${PROJECT_ID}" --project "${PROJECT_ID}")

  echo "Applying hosting target 'prod' to ${PROJECT_ID}..."
  (cd "${PROJECT_DIR}" && npm --prefix functions/gdrive-sync run target:apply -- hosting prod "${PROJECT_ID}" --project "${PROJECT_ID}")

  if [ ! -f "$CONFIG_FILE" ]; then
      echo "Warning: ${CONFIG_FILE} not found. Cannot determine if dev environment setup is needed."
  else
    DEPLOY_ON_COMMIT_DEVELOP=$(yq '.setup.deployOnCommitDevelop' ${CONFIG_FILE})
    if [ "$DEPLOY_ON_COMMIT_DEVELOP" = 'true' ]; then
      echo "Setting up develop environment..."
      DEV_SITE_ID="dev-${PROJECT_ID}"
      echo "Applying hosting target 'dev' to ${DEV_SITE_ID}..."
      (cd "${PROJECT_DIR}" && npm --prefix functions/gdrive-sync run target:apply -- hosting dev "${DEV_SITE_ID}" --project "${PROJECT_ID}")
    else
      echo "Skipping develop environment setup (setup.deployOnCommitDevelop is not true)."
    fi
  fi
}

set_drive_url() {
  echo ""
  echo "--- Configuring Google Drive Folder URL ---"
  local GDRIVE_FOLDER_URL=""
  while [ -z "$GDRIVE_FOLDER_URL" ]; do
    read -p "Enter the Google Drive Folder URL to sync from: " GDRIVE_FOLDER_URL
    if [ -z "$GDRIVE_FOLDER_URL" ]; then
      echo "This URL is required. Please enter a valid Google Drive folder URL."
    fi
  done

  echo "Setting function parameter (GDRIVE_FOLDER_URL) on Firebase server..."
  (cd "${PROJECT_DIR}" && npm --prefix functions/gdrive-sync run params:set -- GDRIVE_FOLDER_URL="${GDRIVE_FOLDER_URL}" --project="${PROJECT_ID}" --non-interactive)
  echo "✅ GDRIVE_FOLDER_URL parameter set for deployed function."

  # Write to local .env file for emulator
  local LOCAL_ENV_FILE="${FUNCTIONS_DIR}/.env.${PROJECT_ID}"
  echo "Writing URL to ${LOCAL_ENV_FILE} for local development..."
  echo "GDRIVE_FOLDER_URL=\"${GDRIVE_FOLDER_URL}\"" > "${LOCAL_ENV_FILE}"
  echo "✅ Local .env file updated."
}

set_polling_secret() {
  echo ""
  echo "--- Configuring Polling Sync Secret ---"
  echo "Generating and setting POLLING_SYNC_SECRET..."
  local SECRET_VALUE
  SECRET_VALUE=$(openssl rand -base64 32)

  if echo "$SECRET_VALUE" | (cd "${PROJECT_DIR}" && npm --prefix functions/gdrive-sync run secrets:set -- POLLING_SYNC_SECRET --project="${PROJECT_ID}" --non-interactive); then
    echo "✅ POLLING_SYNC_SECRET set successfully in Secret Manager."
    echo ""
    echo "********************************************************************************"
    echo "IMPORTANT: Copy the following secret value. You will need it for GitHub Actions."
    echo ""
    echo "  ${SECRET_VALUE}"
    echo ""
    echo "********************************************************************************"
    # Write to local .secret.local file for emulator
    local LOCAL_SECRET_FILE="${FUNCTIONS_DIR}/.secret.local"
    echo "Writing secret to ${LOCAL_SECRET_FILE} for local development..."
    echo "POLLING_SYNC_SECRET=${SECRET_VALUE}" > "${LOCAL_SECRET_FILE}"
    echo "✅ Local .secret.local file created/updated."
  else
    echo "Error: Failed to set POLLING_SYNC_SECRET. Please check your Firebase permissions (e.g., Secret Manager Admin role)." >&2
    exit 1
  fi
}

# --- Argument Parsing ---
UPDATE_URL_ONLY=false
RECREATE_SECRET_ONLY=false
RUN_FULL_SETUP=true

if [[ $# -gt 0 ]]; then
  RUN_FULL_SETUP=false
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --update-url)
      UPDATE_URL_ONLY=true
      shift
      ;;
    --recreate-secret)
      RECREATE_SECRET_ONLY=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Invalid option: $1" >&2
      usage
      ;;
  esac
done

# --- Main Execution ---

# Ensure dependencies are installed in the function directory
echo "Ensuring function dependencies are installed..."
(cd "${PROJECT_DIR}/functions/gdrive-sync" && npm install --quiet)
echo "✅ Dependencies are up to date."

get_project_id_from_tf "$TERRAFORM_DIR"
get_service_account_email_from_tf "$TERRAFORM_DIR"

# Update config.yaml with the generated Project ID
echo "Updating ${CONFIG_FILE} with Project ID: ${PROJECT_ID}..."
yq -i '.firebase.generatedProjectId = "'"${PROJECT_ID}"'"' "$CONFIG_FILE"
echo "✅ ${CONFIG_FILE} updated."

if [ "$RUN_FULL_SETUP" = true ]; then
  echo ""
  echo "🚀 Running full Firebase setup..."

  echo ""
  echo "********************************************************************************"
  echo "ACTION REQUIRED: Please share your Google Drive folder with the following"
  echo "                 service account email address (as an Editor):"
  echo ""
  echo "  ${DEPLOY_SA_EMAIL}"
  echo ""
  echo "********************************************************************************"
  setup_firebase_targets
  set_drive_url
  set_polling_secret
elif [ "$UPDATE_URL_ONLY" = true ]; then
  set_drive_url
elif [ "$RECREATE_SECRET_ONLY" = true ]; then
  set_polling_secret
fi

echo ""
echo "ℹ️  To apply any new settings, you must deploy the function."
echo "    Run the following command from the project root:"
echo "    npm run deploy:gdrive-sync"
echo ""
echo "✅ Firebase setup complete for project ${PROJECT_ID}."