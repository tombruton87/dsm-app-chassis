#!/usr/bin/env bash
# The entrypoint: the chassis core, which sources app.sh beside it.
exec bash "$(dirname "$0")/run-core.sh"
