#!/bin/bash

set -eu

SCRIPT_DIR=$(cd $(dirname $0); pwd)
PROJECT_DIR=$(cd $(dirname ${SCRIPT_DIR}); pwd)
DIST_DIR=${PROJECT_DIR}/dist

PROJECT_ID=$(yq .firebase.projectId ${PROJECT_DIR}/config.yaml)
PROJECT_NAME=$(yq .firebase.projectName ${PROJECT_DIR}/config.yaml)

cat - << EOS > ${PROJECT_DIR}/terraform/environments/usedev/.envrc
export TF_VAR_project_id=${PROJECT_ID}
export TF_VAR_project_name="${PROJECT_NAME}"
export TF_VAR_billing_account=
EOS

cp ${PROJECT_DIR}/terraform/environments/usedev/.envrc ${PROJECT_DIR}/terraform/environments/prodonly/