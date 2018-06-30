#!/usr/bin/env bash

set -euo pipefail

COUNT=10000
PATCH=add-pprof.patch
TERRAFORM_BIN="./terraform"
TERRAFORM_TF="terraform.tf"
TERRAFORM_CONFIG=".terraform"
TERRAFORM_STATE="terraform.tfstate"

if [ ! -f "${TERRAFORM_BIN}" ]; then
  FAKE_GO_PATH=$(mktemp -d)
  mkdir -p "${FAKE_GO_PATH}/src/github.com/hashicorp/"
  git clone git@github.com:hashicorp/terraform.git "${FAKE_GO_PATH}/src/github.com/hashicorp/terraform"
  cp "${PATCH}" "${FAKE_GO_PATH}/src/github.com/hashicorp/terraform"

  pushd "${FAKE_GO_PATH}/src/github.com/hashicorp/terraform"
  patch -i "${PATCH}"

  ulimit -n 1024

  export GOPATH="${FAKE_GO_PATH}"
  go get github.com/hashicorp/hcl2/hcldec
  go get github.com/hashicorp/hcl2/hcl
  go get github.com/hashicorp/errwrap
  make fmt tools dev

  popd
  cp "${FAKE_GO_PATH}/bin/terraform" "${TERRAFORM_BIN}"

  rm -rf "${FAKE_GO_PATH}"
fi

if [ ! -f "${TERRAFORM_TF}" ]; then
  seq "${COUNT}" | xargs -n 1 -I% echo 'resource "null_resource" "null_resource_%" {}' >> "${TERRAFORM_TF}"
fi

if [ ! -f "${TERRAFORM_CONFIG}" ]; then
  "${TERRAFORM_BIN}" init -input=false
fi

if [ ! -f "${TERRAFORM_STATE}" ]; then
  "${TERRAFORM_BIN}" apply -input=false -auto-approve
fi

# Ok, time to run the actual benchmark. We'll plan
# against an existing state file.
TF_FORK=0 "${TERRAFORM_BIN}" plan
go tool pprof -png cpuprofile.prof > cpuprofile.png
go tool pprof -png memprofile.prof > memprofile.png
