#!/usr/bin/env bash
# Usage : smoke-test.sh compose | dev | prod | ci
. "$(dirname "$0")/lib.sh"
case "${1:?compose|dev|prod|ci}" in
  compose) python3 "$ROOT/scripts/api_client.py" smoke --url http://127.0.0.1:8081 ;;
  ci)      python3 "$ROOT/scripts/api_client.py" smoke --url "${CI_URL:-http://127.0.0.1:8081}" ;;
  dev|prod) python3 "$ROOT/scripts/api_client.py" smoke --url "https://127.0.0.1:$HTTPS_PORT" --host "$(host_for "$1")" ;;
esac
