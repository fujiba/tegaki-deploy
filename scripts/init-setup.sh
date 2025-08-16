#!/bin/bash
set -eu

echo "🚀 Starting initial project setup..."
# --- Helper Functions ---
usage() {
  echo "Usage: $0 [-f]"
  echo "  -f, --force: Force overwrite existing config.yaml and run interactive setup."
  exit 1
}

# --- Argument Parsing ---
FORCE_SETUP=false
while getopts "fh-:" opt; do
  # Support long options
  case "${opt}" in
      -)
          case "${OPTARG}" in
              force) FORCE_SETUP=true ;;
              *) echo "Invalid long option --${OPTARG}" >&2; usage ;;
          esac ;;
      f) FORCE_SETUP=true ;;
      h) usage ;;
      \?) echo "Invalid option: -$OPTARG" >&2; usage ;;
  esac
done
shift $((OPTIND-1))

# 1. Check if initial setup is needed or forced
INITIAL_SETUP_NEEDED=false
if [ "$FORCE_SETUP" = true ]; then
  INITIAL_SETUP_NEEDED=true
  echo "ℹ️ Force flag detected. Running interactive setup and overwriting existing config..."
elif [ ! -f "config.yaml" ]; then
  INITIAL_SETUP_NEEDED=true # If config.yaml doesn't exist, setup is needed
elif [[ "$(yq -r '.firebase.projectIdPrefix' config.yaml)" == '__YOUR_FIREBASE_PROJECT_ID_PREFIX_HERE__' ]]; then
  INITIAL_SETUP_NEEDED=true
fi

if [ ${INITIAL_SETUP_NEEDED} = true ]; then
  echo "📄 config.yaml not found. Let's configure your project interactively."

  # Define variables to store config values
  declare HUGO_VERSION NODE_VERSION DEPLOY_ON_COMMIT_DEVELOP PROJECT_ID_PREFIX PROJECT_NAME BILLING_ACCOUNT 


  # Ask for Hugo Version (default: latest)
  read -p "Enter Hugo version to use (default: latest): " HUGO_VERSION
  HUGO_VERSION=${HUGO_VERSION:-latest}

  # Ask for Node Version (default: 20)
  read -p "Enter Node.js version to use (LTS recommended, default: 20): " NODE_VERSION
  NODE_VERSION=${NODE_VERSION:-20}

  # Ask for Deploy on Commit Develop (default: false)
  read -p "Deploy automatically on commit to 'develop' branch? (true/false, default: false): " DEPLOY_DEV_INPUT
  DEPLOY_ON_COMMIT_DEVELOP=${DEPLOY_DEV_INPUT:-false}
  # Basic validation for boolean
  if [[ "$DEPLOY_ON_COMMIT_DEVELOP" != "true" && "$DEPLOY_ON_COMMIT_DEVELOP" != "false" ]]; then
      echo "Invalid input for deploy setting. Defaulting to 'false'."
      DEPLOY_ON_COMMIT_DEVELOP="false"
  fi

  # Ask for Project ID Prefix
  # Add validation for prefix length/characters based on GCP rules
  while true; do
    # GCP Project ID rules: 6-30 chars, lowercase letters, digits, hyphen. Must start with letter. Cannot end with hyphen.
    read -p "Enter Firebase Project ID Prefix (6-29 chars, lowercase letters, digits, hyphen, start with letter): " PROJECT_ID_PREFIX
    if [[ "$PROJECT_ID_PREFIX" =~ ^[a-z][a-z0-9-]{4,27}[a-z0-9]$ ]] && [ ${#PROJECT_ID_PREFIX} -ge 6 ] && [ ${#PROJECT_ID_PREFIX} -le 29 ]; then
      break
    else
      echo "Invalid prefix. Must be 6-29 chars, start with a letter, contain only lowercase letters, digits, or hyphens, and not end with a hyphen."
    fi
  done

  # Ask for Project Name
  # Add validation for name length/characters
   while true; do
    # GCP Project Name rules: 4-30 chars, letters, numbers, hyphen, single-quote, double-quote, space, exclamation point.
    read -p "Enter Firebase Project Display Name (4-30 chars): " PROJECT_NAME
    if [ ${#PROJECT_NAME} -ge 4 ] && [ ${#PROJECT_NAME} -le 30 ]; then
        # Check for invalid characters (anything NOT in the allowed set)
        if [[ "$PROJECT_NAME" =~ [^a-zA-Z0-9\'\"\ \!-] ]]; then
             echo "Invalid characters found. Please use only letters, numbers, spaces, hyphens, single-quotes, double-quotes, or exclamation points."
        else
            break
        fi
    else
      echo "Invalid name length. Must be 4-30 characters."
    fi
  done

  # Generate config.yaml
  echo "Generating config.yaml..."
  cat << EOF > config.yaml
setup:
  hugoVersion: ${HUGO_VERSION}
  nodeVersion: ${NODE_VERSION}
  deployOnCommitDevelop: ${DEPLOY_ON_COMMIT_DEVELOP}
firebase:
  projectIdPrefix: ${PROJECT_ID_PREFIX}
  projectName: ${PROJECT_NAME}
EOF
  echo "✅ config.yaml generated successfully."
  # Set flag to indicate config was just created
  CONFIG_JUST_CREATED=true

  # Use the values just entered
  CONFIG_PROJECT_ID_PREFIX=$PROJECT_ID_PREFIX
  CONFIG_PROJECT_NAME=$PROJECT_NAME
  CONFIG_DEPLOY_ON_COMMIT_DEVELOP=$DEPLOY_ON_COMMIT_DEVELOP

else
  echo "ℹ️ config.yaml already exists. Skipping interactive setup."
  CONFIG_JUST_CREATED=false

  # Read values from existing config.yaml for .envrc generation
  CONFIG_PROJECT_ID_PREFIX=$(yq '.firebase.projectIdPrefix' config.yaml)
  CONFIG_PROJECT_NAME=$(yq '.firebase.projectName' config.yaml)
  CONFIG_DEPLOY_ON_COMMIT_DEVELOP=$(yq '.setup.deployOnCommitDevelop' config.yaml)
fi

# Ask for Billing Account ID only if dev environment is enabled
CONFIG_BILLING_ACCOUNT="" # Initialize as empty
if [ "$CONFIG_DEPLOY_ON_COMMIT_DEVELOP" = "true" ]; then
    echo "ℹ️ Development environment features require a Billing Account (Blaze plan)."
    read -p "Enter Billing Account ID (optional, leave blank if unsure or not needed yet): " BILLING_ACCOUNT_INPUT
    CONFIG_BILLING_ACCOUNT=${BILLING_ACCOUNT_INPUT:-} # Use input or default to empty
fi

# 2. Prepare Terraform environment variables
echo "⚙️ Preparing Terraform environment files (.envrc)..."

# Function to generate .envrc content
generate_envrc() {
  local target_file="terraform/.envrc" # Target file in the terraform directory
  echo "Generating ${target_file}..."
  mkdir -p "$(dirname "$target_file")" # Ensure terraform directory exists
  cat << EOF > "${target_file}"
export TF_VAR_project_id_prefix=${CONFIG_PROJECT_ID_PREFIX}
export TF_VAR_project_name="${CONFIG_PROJECT_NAME}"
export TF_VAR_billing_account=${CONFIG_BILLING_ACCOUNT:-} # Use entered/read value or default to empty
export TF_VAR_enable_dev_environment=${CONFIG_DEPLOY_ON_COMMIT_DEVELOP} # Set based on config.yaml
EOF
}

# Generate the single .envrc file
generate_envrc

echo "🎉 Initial setup complete!"
# Remind user to review files if config.yaml was just created
if [ "$CONFIG_JUST_CREATED" = true ]; then
    echo "   Please review the generated config.yaml and .envrc files."
fi

echo "➡️ Next steps typically involve running 'npm install' (if needed) and then proceeding with Terraform setup in the 'terraform/' directory."
echo "   Remember to set TF_VAR_billing_account in terraform/.envrc if required."
