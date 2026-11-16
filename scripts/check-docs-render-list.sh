#!/usr/bin/env bash
# Fail if a tracked README.md isn't in the docs site's render list
# (_quarto.yml). Quarto drops README.md from glob matches, so each one has
# to be listed by name; this catches a new stack that forgot to.
# The top-level README is on the site via index.qmd, so it's exempt.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

missing=0
while IFS= read -r readme; do
  if ! grep -qxF "    - ${readme}" _quarto.yml; then
    echo "not in _quarto.yml project.render: ${readme}"
    missing=1
  fi
done < <(git ls-files '*README.md' ':!:README.md')

exit "$missing"
