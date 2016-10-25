#!/bin/bash

set -euo pipefail

if [[ $BUNDLE_BIN && ! $PATH =~ $BUNDLE_BIN  ]]; then
		export PATH="$BUNDLE_BIN:$PATH"
fi

bundle check || bundle install

command -v guard || bundle binstub --force guard
command -v rake || bundle binstub --force rake

exec $@
