#!/bin/bash
set -eu

# --- Configuration ---
SCRIPT_DIR=$(cd $(dirname $0); pwd)
PROJECT_DIR=$(cd $(dirname ${SCRIPT_DIR}); pwd)
CONFIG_FILE="${PROJECT_DIR}/config.yaml"
TERRAFORM_DIR="${PROJECT_DIR}/terraform" # Define the single Terraform directory
PROJECT_ID=""

# --- Helper Functions ---
usage() {
  # Updated usage message as -e option is removed
  echo "Usage: $0"
  exit 1
}

get_project_id_from_tf() {
  local env_dir=$1
  if [ ! -d "$env_dir" ]; then
    echo "Error: Terraform environment directory '$env_dir' not found."
    echo "       Please ensure the 'terraform' directory exists at the project root."
    exit 1
  fi
  echo "Attempting to get project ID from Terraform output in '$env_dir'..."
  # Check if terraform state exists before trying to read output
  if [ ! -f "${env_dir}/.terraform/terraform.tfstate" ] && [ ! -f "${env_dir}/terraform.tfstate" ]; then
       echo "Error: Terraform state not found in '$env_dir'. Please run 'terraform init' and 'terraform apply' in the '$env_dir' directory first."
       exit 1
  fi
  # Use pushd/popd to change directory temporarily and safely
  if ! PROJECT_ID=$(pushd "$env_dir" > /dev/null && terraform output -raw generated_project_id && popd > /dev/null); then
      echo "Please ensure 'terraform apply' completed successfully and the output exists."
      # Clean up pushd stack in case of error
      popd > /dev/null 2>&1 || true
      exit 1
  fi

  if [ -z "$PROJECT_ID" ]; then
      echo "Error: Terraform output 'generated_project_id' was empty in '$env_dir'."
      exit 1
  fi
  echo "✅ Found Project ID: ${PROJECT_ID}"
}

# --- Argument Parsing ---
while getopts "h" opt; do
  case $opt in
    h) usage ;;
    \?) echo "Invalid option: -$OPTARG" >&2; usage ;;
  esac
done
shift $((OPTIND-1))

# --- Get Project ID ---
get_project_id_from_tf "$TERRAFORM_DIR" # Use the single Terraform directory

# --- Update config.yaml with the generated Project ID ---
# Add/Update firebase.generatedProjectId in config.yaml
echo "Adding/Updating firebase.generatedProjectId in ${CONFIG_FILE} with value: ${PROJECT_ID}..."
# Use yq to add/update the value in place. Create backup (.bak)
yq -i '.firebase.generatedProjectId = "'"${PROJECT_ID}"'"' "$CONFIG_FILE"
echo "✅ ${CONFIG_FILE} updated."

# --- Firebase Setup ---
echo "Switching Firebase CLI to use project ${PROJECT_ID}..."
firebase use ${PROJECT_ID}

echo "Applying hosting target 'prod' to ${PROJECT_ID}..."
firebase target:apply hosting prod ${PROJECT_ID}

# Conditional setup based on config.yaml
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Warning: ${CONFIG_FILE} not found. Cannot determine if dev environment setup is needed."
else
  DEPLOY_ON_COMMIT_DEVELOP=$(yq '.setup.deployOnCommitDevelop' ${CONFIG_FILE})
  if [ "$DEPLOY_ON_COMMIT_DEVELOP" = 'true' ]; then
    echo "Setting up develop environment..."
    DEV_SITE_ID="dev-${PROJECT_ID}"
    echo "Applying hosting target 'dev' to ${DEV_SITE_ID}..."
    firebase target:apply hosting dev ${DEV_SITE_ID}
  else
    echo "Skipping develop environment setup (setup.deployOnCommitDevelop is not true)."
  fi
fi

echo "✅ Firebase setup complete for project ${PROJECT_ID}."