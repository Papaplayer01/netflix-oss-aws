#!/usr/bin/env bash
# Delete everything so you stop paying.
set -euo pipefail
cd terraform
terraform destroy -auto-approve
