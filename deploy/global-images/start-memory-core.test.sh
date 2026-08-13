#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/start-memory-core-test.XXXXXX")"
SERVER_START_ATTEMPTS=50
SERVER_START_DELAY_SECONDS=0.02
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

cp "$SCRIPT_DIR/start-memory-core.sh" "$SCRIPT_DIR/_lib.sh" "$TEST_DIR/"
mkdir -p "$TEST_DIR/bin"

cat > "$TEST_DIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash

case "$1 $2" in
  "network inspect"|"ps -a")
    exit 0
    ;;
  "run -d")
    echo fake-container-id
    exit 0
    ;;
  "inspect -f")
    case "$3" in
      *State.Status*) echo running ;;
      *State.Health*) echo healthy ;;
      *) exit 1 ;;
    esac
    exit 0
    ;;
esac

echo "unexpected docker command: $*" >&2
exit 1
DOCKER
chmod +x "$TEST_DIR/bin/docker"

cat > "$TEST_DIR/http-server.py" <<'PYTHON'
import http.server
import pathlib
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(content_length)
        response = b'{"status":"ok"}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, format, *args):
        pass


port_file = pathlib.Path(sys.argv[1])
server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
port_file.write_text(str(server.server_port))
server.serve_forever()
PYTHON

python3 "$TEST_DIR/http-server.py" "$TEST_DIR/http-port" &
SERVER_PID=$!
for ((attempt = 1; attempt <= SERVER_START_ATTEMPTS; attempt++)); do
  [[ -s "$TEST_DIR/http-port" ]] && break
  sleep "$SERVER_START_DELAY_SECONDS"
done
if [[ ! -s "$TEST_DIR/http-port" ]]; then
  echo "FAIL: test HTTP server did not start" >&2
  exit 1
fi
TEST_HTTP_PORT=$(cat "$TEST_DIR/http-port")

cat > "$TEST_DIR/.env" <<ENV
MEMORY_CORE_IMAGE=memory-core:test
MEMORY_CORE_PORT=$TEST_HTTP_PORT
MEMORY_CORE_VOLUME=memory-core-test-data
MEMORY_LLM_BASE_URL=http://127.0.0.1:$TEST_HTTP_PORT/v1
MEMORY_LLM_API_KEY=test-key
MEMORY_LLM_MODEL=test-model
ENV

set +e
test_output=$(
  PATH="$TEST_DIR/bin:$PATH" \
  MEMORY_CORE_CONFIG_DIR="$TEST_DIR/config" \
  MEMORY_CORE_ADMIN_KEY_FILE="$TEST_DIR/admin-key" \
  /bin/bash "$TEST_DIR/start-memory-core.sh" 2>&1
)
test_exit=$?
set -e

if [[ "$test_exit" -ne 0 ]]; then
  printf '%s\n' "$test_output" >&2
  echo "FAIL: start-memory-core.sh exited with $test_exit" >&2
  exit 1
fi

if [[ "$test_output" != *"初始化 admin user"* ]]; then
  printf '%s\n' "$test_output" >&2
  echo "FAIL: admin initialization was not reached" >&2
  exit 1
fi

echo "PASS: start-memory-core.sh reaches admin initialization under Bash 3.2"
