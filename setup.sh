#!/usr/bin/env bash
# Configure and start a CircleCI machine runner 3 container on this host.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${ROOT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: ./setup.sh [options]

Without options the script asks for the runner name and the resource class
token, then offers the advanced settings.

Required values (asked for when not given):
  --name NAME             Label of this runner instance in CircleCI
                          (letters, digits and . ( ) - _). Not the namespace.
  --token-file PATH       Read the resource class token from a file
  --token-stdin           Read the resource class token from standard input
                          The CIRCLECI_RUNNER_API_AUTH_TOKEN environment
                          variable is honoured too. There is no --token flag
                          on purpose: arguments show up in `ps` and in shell
                          history.

Advanced:
  --mode MODE             continuous (default) | single-task
  --replicas N            Runner containers to run; one job each (default 1)
  --cpus N                CPU limit per container, e.g. 2 or 1.5 (0 = none)
  --memory SIZE           Memory limit per container, e.g. 4G (0 = none)
  --max-run-time DUR      Longest job duration, e.g. 5h, 1h30m (default 5h)
  --extra-packages "..."  Extra apt packages to bake into the image
  --dood                  Mount the host Docker socket into the runner.
                          Gives jobs root-equivalent access to this host.
  --no-dood               Turn that off again
  --api-url URL           CircleCI Server only: URL of your installation

Behaviour:
  --non-interactive       Never prompt; fail when a required value is missing
  --no-start              Write the configuration but do not build or start
  -h, --help              Show this help

Examples:
  ./setup.sh
  ./setup.sh --name vps-01 --token-file /root/cci-token --non-interactive
  printf '%s' "$TOKEN" | ./setup.sh --name vps-01 --token-stdin \
      --replicas 2 --cpus 2 --memory 4G --non-interactive
EOF
}

# ---------------------------------------------------------------- validation
valid_name()     { [[ "$1" =~ ^[A-Za-z0-9._\(\)-]+$ ]]; }
valid_token()    { [[ -n "$1" && ! "$1" =~ [[:space:]\'\"] ]]; }
valid_mode()     { [[ "$1" == "continuous" || "$1" == "single-task" ]]; }
valid_replicas() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
valid_memory()   { [[ "$1" == "0" || "$1" =~ ^[1-9][0-9]*[KkMmGg][Bb]?$ ]]; }
valid_duration() { [[ -n "$1" && "$1" =~ ^([0-9]+h)?([0-9]+m)?([0-9]+s)?$ ]]; }
valid_packages() { [[ "$1" =~ ^[a-z0-9.+:=\ -]*$ ]]; }
valid_url()      { [[ "$1" =~ ^https?://[^[:space:]]+$ ]]; }

host_cpus() { nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0; }

valid_cpus() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  local max
  max="$(host_cpus)"
  # Docker refuses a limit above the host's CPU count.
  if [[ "${max}" != "0" ]]; then
    awk -v want="$1" -v max="${max}" 'BEGIN { exit !(want <= max) }' || return 1
  fi
}

# ------------------------------------------------------------------- prompts
# ask VAR "Question" validator "error message"   (default = current $VAR)
ask() {
  local var="$1" question="$2" validator="$3" message="$4" reply current
  while true; do
    current="${!var}"
    if [[ -n "${current}" ]]; then
      read -r -p "${question} [${current}]: " reply
    else
      read -r -p "${question}: " reply
    fi
    reply="${reply:-${current}}"
    if "${validator}" "${reply}"; then
      printf -v "${var}" '%s' "${reply}"
      return 0
    fi
    warn "${message}"
  done
}

# ask_yes_no "Question" default(y|n)  -> exit status 0 for yes
ask_yes_no() {
  local question="$1" default="$2" reply hint='[y/N]'
  [[ "${default}" == "y" ]] && hint='[Y/n]'
  while true; do
    read -r -p "${question} ${hint}: " reply
    reply="${reply:-${default}}"
    case "${reply}" in
      y | Y | yes | YES) return 0 ;;
      n | N | no | NO) return 1 ;;
      *) warn "Answer y or n." ;;
    esac
  done
}

ask_token() {
  local reply
  while true; do
    if [[ -n "${TOKEN}" ]]; then
      read -r -s -p "Resource class token (hidden, Enter keeps the current one): " reply
    else
      read -r -s -p "Resource class token (hidden): " reply
    fi
    printf '\n' >&2
    reply="${reply:-${TOKEN}}"
    if valid_token "${reply}"; then
      TOKEN="${reply}"
      return 0
    fi
    warn "The token must not be empty or contain spaces or quotes."
  done
}

# ------------------------------------------------------------------ defaults
default_name() {
  local host
  host="$(hostname 2>/dev/null || echo runner)"
  host="${host//[^A-Za-z0-9._-]/-}"
  printf '%s' "${host:-runner}"
}

# Existing configuration is offered as the default on a re-run.
NAME="$(get_kv "${RUNNER_ENV_FILE}" CIRCLECI_RUNNER_NAME)"
TOKEN="${CIRCLECI_RUNNER_API_AUTH_TOKEN:-}"
[[ -n "${TOKEN}" ]] || TOKEN="$(get_kv "${RUNNER_ENV_FILE}" CIRCLECI_RUNNER_API_AUTH_TOKEN)"
MODE="$(get_kv "${RUNNER_ENV_FILE}" CIRCLECI_RUNNER_MODE)"
MAX_RUN_TIME="$(get_kv "${RUNNER_ENV_FILE}" CIRCLECI_RUNNER_MAX_RUN_TIME)"
API_URL="$(get_kv "${RUNNER_ENV_FILE}" CIRCLECI_RUNNER_API_URL)"
REPLICAS="$(get_kv "${ENV_FILE}" RUNNER_REPLICAS)"
CPUS="$(get_kv "${ENV_FILE}" RUNNER_CPUS)"
MEMORY="$(get_kv "${ENV_FILE}" RUNNER_MEMORY)"
EXTRA_PACKAGES="$(get_kv "${ENV_FILE}" EXTRA_APT_PACKAGES)"
IMAGE_TAG="$(get_kv "${ENV_FILE}" RUNNER_IMAGE_TAG)"
PIDS_LIMIT="$(get_kv "${ENV_FILE}" RUNNER_PIDS_LIMIT)"
STOP_GRACE="$(get_kv "${ENV_FILE}" RUNNER_STOP_GRACE_PERIOD)"
DOOD="false"
[[ "$(get_kv "${ENV_FILE}" RUNNER_BUILD_TARGET)" == "runner-dood" ]] && DOOD="true"

[[ "${TOKEN}" == "paste-your-resource-class-token-here" ]] && TOKEN=""
NAME="${NAME:-$(default_name)}"
MODE="${MODE:-continuous}"
MAX_RUN_TIME="${MAX_RUN_TIME:-5h}"
REPLICAS="${REPLICAS:-1}"
CPUS="${CPUS:-0}"
MEMORY="${MEMORY:-0}"
IMAGE_TAG="${IMAGE_TAG:-machine-3}"
PIDS_LIMIT="${PIDS_LIMIT:-4096}"
STOP_GRACE="${STOP_GRACE:-10m}"

INTERACTIVE="true"
START="true"
NAME_GIVEN="false"
TOKEN_GIVEN="false"

# ----------------------------------------------------------------- arguments
need_value() { [[ $# -ge 2 ]] || die "Option $1 needs a value."; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)           need_value "$@"; NAME="$2"; NAME_GIVEN="true"; shift 2 ;;
    --token-file)
      need_value "$@"
      [[ -r "$2" ]] || die "Cannot read token file: $2"
      TOKEN="$(tr -d '[:space:]' <"$2")"; TOKEN_GIVEN="true"; shift 2 ;;
    --token-stdin)    TOKEN="$(tr -d '[:space:]')"; TOKEN_GIVEN="true"; shift ;;
    --token | --token=*)
      die "--token is not supported: it would expose the token in 'ps' and shell history. Use --token-file, --token-stdin or the CIRCLECI_RUNNER_API_AUTH_TOKEN variable." ;;
    --mode)           need_value "$@"; MODE="$2"; shift 2 ;;
    --replicas)       need_value "$@"; REPLICAS="$2"; shift 2 ;;
    --cpus)           need_value "$@"; CPUS="$2"; shift 2 ;;
    --memory)         need_value "$@"; MEMORY="$2"; shift 2 ;;
    --max-run-time)   need_value "$@"; MAX_RUN_TIME="$2"; shift 2 ;;
    --extra-packages) need_value "$@"; EXTRA_PACKAGES="$2"; shift 2 ;;
    --api-url)        need_value "$@"; API_URL="$2"; shift 2 ;;
    --dood)           DOOD="true"; shift ;;
    --no-dood)        DOOD="false"; shift ;;
    --non-interactive) INTERACTIVE="false"; shift ;;
    --no-start)       START="false"; shift ;;
    -h | --help)      usage; exit 0 ;;
    *)                usage >&2; die "Unknown option: $1" ;;
  esac
done

if [[ "${INTERACTIVE}" == "true" && ! -t 0 ]]; then
  die "Standard input is not a terminal. Add --non-interactive and pass the values as options."
fi

# ----------------------------------------------------------------- preflight
info "Checking prerequisites"
if [[ "${START}" == "true" ]]; then
  require_docker
  ok "Docker $(docker version --format '{{.Server.Version}}'), Compose $(docker compose version --short)"
fi

probe_url="${API_URL:-${DEFAULT_API_URL}}"
for url in "${probe_url}" "${BINARY_HOST_URL}"; do
  rc=0
  endpoint_reachable "${url}" || rc=$?
  case "${rc}" in
    0) ok "Reachable: ${url}" ;;
    2) warn "curl is not installed; skipped the connectivity check for ${url}" ;;
    *) warn "Cannot reach ${url} from this host. The runner needs outbound HTTPS to it." ;;
  esac
done

# ------------------------------------------------------------------- collect
if [[ "${INTERACTIVE}" == "true" ]]; then
  printf '\n%sCircleCI self-hosted runner setup%s\n' "${C_BOLD}" "${C_RESET}" >&2
  cat >&2 <<'EOF'
The runner name is a label for this machine in the CircleCI Runners page.
It is NOT your namespace or resource class - the token already carries those.

EOF
  [[ "${NAME_GIVEN}" == "true" ]] ||
    ask NAME "Runner name" valid_name "Use only letters, digits and . ( ) - _"
  [[ "${TOKEN_GIVEN}" == "true" ]] || ask_token

  if ask_yes_no "Configure advanced options?" n; then
    ask MODE "Mode (continuous | single-task)" valid_mode "Type continuous or single-task."
    ask REPLICAS "Runner containers (one job each)" valid_replicas "Enter a whole number, 1 or more."
    ask CPUS "CPU limit per container, 0 = none (host has $(host_cpus))" valid_cpus \
      "Enter a number no larger than the host's CPU count."
    ask MEMORY "Memory limit per container, e.g. 4G, 0 = none" valid_memory "Use a size such as 512M or 4G, or 0."
    ask MAX_RUN_TIME "Longest job duration" valid_duration "Use h/m/s units, e.g. 5h or 1h30m."
    ask EXTRA_PACKAGES "Extra apt packages (space separated, may be empty)" valid_packages \
      "Package names may contain lowercase letters, digits and . + : = -"
    if ask_yes_no "Let jobs use the host's Docker daemon? (root-equivalent access to this host)" \
      "$([[ "${DOOD}" == "true" ]] && echo y || echo n)"; then
      DOOD="true"
    else
      DOOD="false"
    fi
    if ask_yes_no "Is this for a CircleCI Server installation (not circleci.com)?" \
      "$([[ -n "${API_URL}" ]] && echo y || echo n)"; then
      ask API_URL "CircleCI Server URL" valid_url "Enter a URL starting with https:// or http://"
    else
      API_URL=""
    fi
  fi
fi

# ------------------------------------------------------------------ validate
valid_name "${NAME}"          || die "Invalid runner name '${NAME}'. Allowed: letters, digits and . ( ) - _"
valid_token "${TOKEN}"        || die "No usable token. Pass --token-file, --token-stdin or set CIRCLECI_RUNNER_API_AUTH_TOKEN."
valid_mode "${MODE}"          || die "Invalid --mode '${MODE}'. Use continuous or single-task."
valid_replicas "${REPLICAS}"  || die "Invalid --replicas '${REPLICAS}'. Use a whole number, 1 or more."
valid_cpus "${CPUS}"          || die "Invalid --cpus '${CPUS}'. Use a number up to the host's $(host_cpus) CPUs, or 0."
valid_memory "${MEMORY}"      || die "Invalid --memory '${MEMORY}'. Use a size such as 512M or 4G, or 0."
valid_duration "${MAX_RUN_TIME}" || die "Invalid --max-run-time '${MAX_RUN_TIME}'. Use h/m/s units, e.g. 5h."
valid_packages "${EXTRA_PACKAGES}" || die "Invalid --extra-packages value."
[[ -z "${API_URL}" ]] || valid_url "${API_URL}" || die "Invalid --api-url '${API_URL}'."

DOCKER_GID=""
if [[ "${DOOD}" == "true" ]]; then
  [[ -S /var/run/docker.sock ]] ||
    die "--dood needs /var/run/docker.sock on this host (rootless or remote Docker is not supported by the overlay)."
  DOCKER_GID="$(stat -c '%g' /var/run/docker.sock)"
  sock_mode="$(stat -c '%a' /var/run/docker.sock)"
  # The runner user reaches the socket through its group, so the group needs
  # read and write (the usual root:docker 0660).
  (( ${sock_mode: -2:1} >= 6 )) ||
    die "--dood: /var/run/docker.sock has mode ${sock_mode}, so its group cannot use it. The overlay needs the usual root:docker 660 socket."
fi

APPEND_HOSTNAME="false"
(( REPLICAS > 1 )) && APPEND_HOSTNAME="true"

# --------------------------------------------------------------------- write
# Both files are created 0600 from the first byte (umask), then moved into
# place so a failed run never leaves a half-written file behind.
write_config() {
  local tmp_env tmp_runner
  umask 077
  tmp_env="$(mktemp "${ROOT_DIR}/.env.XXXXXX")"
  tmp_runner="$(mktemp "${ROOT_DIR}/runner.env.XXXXXX")"
  trap 'rm -f "${tmp_env:-}" "${tmp_runner:-}"' EXIT

  {
    echo "# Written by setup.sh. Compose-level settings (not secret)."
    echo "RUNNER_IMAGE_TAG=${IMAGE_TAG}"
    echo "EXTRA_APT_PACKAGES=\"${EXTRA_PACKAGES}\""
    echo "RUNNER_REPLICAS=${REPLICAS}"
    echo "RUNNER_CPUS=${CPUS}"
    echo "RUNNER_MEMORY=${MEMORY}"
    echo "RUNNER_PIDS_LIMIT=${PIDS_LIMIT}"
    echo "RUNNER_STOP_GRACE_PERIOD=${STOP_GRACE}"
    if [[ "${DOOD}" == "true" ]]; then
      echo "RUNNER_BUILD_TARGET=runner-dood"
      echo "COMPOSE_PATH_SEPARATOR=:"
      echo "COMPOSE_FILE=compose.yaml:compose.dood.yaml"
      echo "DOCKER_GID=${DOCKER_GID}"
    else
      echo "RUNNER_BUILD_TARGET=runner"
    fi
  } >"${tmp_env}"

  {
    echo "# Written by setup.sh. Holds the resource class token - keep it 0600."
    echo "CIRCLECI_RUNNER_NAME='${NAME}'"
    echo "CIRCLECI_RUNNER_API_AUTH_TOKEN='${TOKEN}'"
    echo "CIRCLECI_RUNNER_MODE=${MODE}"
    echo "CIRCLECI_RUNNER_MAX_RUN_TIME=${MAX_RUN_TIME}"
    echo "CIRCLECI_RUNNER_CLEANUP_WORK_DIR=true"
    echo "CIRCLECI_RUNNER_LOGGING_LEVEL=info"
    echo "CIRCLECI_RUNNER_LOGGING_FORMAT=text"
    echo "RUNNER_NAME_APPEND_HOSTNAME=${APPEND_HOSTNAME}"
    [[ -z "${API_URL}" ]] || echo "CIRCLECI_RUNNER_API_URL=${API_URL}"
  } >"${tmp_runner}"

  chmod 600 "${tmp_env}" "${tmp_runner}"
  mv -f "${tmp_env}" "${ENV_FILE}"
  mv -f "${tmp_runner}" "${RUNNER_ENV_FILE}"
  trap - EXIT
}

printf '\n' >&2
info "Configuration"
cat >&2 <<EOF
     runner name   ${NAME}$([[ "${APPEND_HOSTNAME}" == "true" ]] && echo '-<container-id> (unique per replica)')
     token         set (${#TOKEN} characters, not shown)
     mode          ${MODE}
     replicas      ${REPLICAS}
     cpu / memory  ${CPUS} / ${MEMORY}   (0 = no limit)
     max run time  ${MAX_RUN_TIME}
     extra apt     ${EXTRA_PACKAGES:-none}
     host docker   ${DOOD}
     api url       ${API_URL:-${DEFAULT_API_URL} (default)}
EOF

if [[ "${INTERACTIVE}" == "true" ]]; then
  ask_yes_no "Write this configuration$([[ "${START}" == "true" ]] && echo ' and start the runner')?" y ||
    die "Aborted. Nothing was written."
fi

write_config
ok "Wrote .env and runner.env (mode $(file_mode "${RUNNER_ENV_FILE}"))"

if [[ "${START}" != "true" ]]; then
  info "Skipped build and start (--no-start). Start later with: ./runner.sh up"
  exit 0
fi

# --------------------------------------------------------------------- start
info "Building the runner image"
compose build --pull

info "Starting ${REPLICAS} runner container(s)"
compose up --detach --remove-orphans

info "Waiting for the runner to contact CircleCI (first start downloads the task agent)"
rc=0
wait_for_first_claim 150 || rc=$?
case "${rc}" in
  0)
    ok "The runner is polling CircleCI and the token was accepted."
    ;;
  1)
    compose stop >/dev/null 2>&1 || true
    err "CircleCI rejected the token (401 Unauthorized). The runner was stopped."
    die "Create a new token for your resource class and run ./setup.sh again."
    ;;
  2)
    err "The runner container is not running. Last log lines:"
    compose logs --no-color --tail 20 "${SERVICE}" >&2 || true
    exit 1
    ;;
  *)
    warn "No answer from CircleCI seen in the logs yet. Check with: ./runner.sh logs"
    ;;
esac

cat >&2 <<EOF

${C_BOLD}Next steps${C_RESET}
  1. In CircleCI open Runners and check that '${NAME}' is listed.
  2. In your repository's .circleci/config.yml use (see examples/):
         machine: true
         resource_class: <your-namespace>/<your-resource-class>
  3. Day-to-day: ./runner.sh status | logs | doctor | update | down
EOF
