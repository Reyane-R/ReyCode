#!/bin/sh
set -eu

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
  echo "This release must be built on macOS arm64." >&2
  exit 1
fi

export MIX_ENV=prod
mix deps.get --only prod
mix compile --warnings-as-errors
mix release rey_code --overwrite

echo "Release archive: _build/prod/rey_code-0.1.0.tar.gz"
