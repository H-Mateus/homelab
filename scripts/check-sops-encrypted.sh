#!/usr/bin/env bash
# check-sops-encrypted.sh
#
# Pre-commit hook: verifies that every staged *.sops.yaml file has already
# been encrypted by SOPS.  An encrypted file always ends with a 'sops:' block
# at the YAML top level; a plaintext file will not contain it.
#
# Usage (called automatically by pre-commit):
#   check-sops-encrypted.sh <file1> [file2 ...]
#
# To encrypt a file:
#   sops --encrypt --in-place <file>

set -euo pipefail

failed=0

for file in "$@"; do
  if ! grep -q "^sops:" "$file"; then
    echo "ERROR: '$file' does not appear to be SOPS-encrypted." >&2
    echo "       Run: sops --encrypt --in-place $file" >&2
    failed=1
  fi
done

if [[ $failed -ne 0 ]]; then
  echo "" >&2
  echo "Commit blocked: one or more *.sops.yaml files are not encrypted." >&2
  echo "Encrypting before commit keeps secrets out of git history." >&2
  exit 1
fi
