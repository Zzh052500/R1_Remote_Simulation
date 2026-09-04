#!/usr/bin/env bash
# R1Mk3 museum-world remote-control simulation helper.
# Usage:
#   ./r1_remote_sim.sh start   # clean old sim containers, start Gazebo + baseControl2 + yarpMobilebaseGUI
#   ./r1_remote_sim.sh status  # show container, processes, YARP ports, and VNC windows
#   ./r1_remote_sim.sh logs    # follow sim container logs
#   ./r1_remote_sim.sh drive-logs
#   ./r1_remote_sim.sh shell
#   ./r1_remote_sim.sh stop

set -euo pipefail

SIM_DIR="${SIM_DIR:-/home/maxw/4sim/gh-ref/tour-guide-robot/tour-guide-robot/docker_stuff/docker_sim_compose}"
CONTAINER="${CONTAINER:-r1-toursim-compose}"
DISPLAY_NUM="${DISPLAY_NUM:-:21}"
WORLD="${WORLD:-/usr/local/src/robot/tour-guide-robot/app/maps/SIM_MADAMA/madama_clock.world}"
IMAGE_TAG="${IMAGE_TAG:-ghcr.io/hsp-iit/r1images:tourSim2_ubuntu24.04_jazzy_devel}"

cd "$SIM_DIR"

say() {
  printf '[r1-sim] %s\n' "$*"
}

die() {
  printf '[r1-sim] ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

check_prereqs() {
  need_cmd docker
  docker compose version >/dev/null 2>&1 || die "docker compose is not available"
  [[ -S "/tmp/.X11-unix/X${DISPLAY_NUM#:}" ]] || die "X socket /tmp/.X11-unix/X${DISPLAY_NUM#:} not found"
  [[ -f "${HOME}/.Xauthority" ]] || die "${HOME}/.Xauthority not found"
}

compose_args() {
  if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia; then
    printf '%s\n' compose.yaml
  else
    printf '%s\n' compose.yaml compose.no-nvidia.yaml
  fi
}

docker_compose() {
  local files=()
  while IFS= read -r file; do
    files+=("-f" "$file")
  done < <(compose_args)
  docker compose "${files[@]}" "$@"
}

stop_old_compose_run_containers() {
  local ids
  ids="$(docker ps -q --filter 'name=docker_sim_compose-sim-run-' || true)"
  if [[ -n "$ids" ]]; then
    say "stopping old docker_sim_compose-sim-run-* containers"
    docker stop $ids >/dev/null
  fi
}

stop_named_container() {
  if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    say "stopping existing $CONTAINER"
    docker stop "$CONTAINER" >/dev/null 2>&1 || true
    docker rm "$CONTAINER" >/dev/null 2>&1 || true
  fi
}

start_sim() {
  check_prereqs
  say "using compose directory: $SIM_DIR"
  say "using VNC/X display: $DISPLAY_NUM"
  say "target image: $IMAGE_TAG"

  stop_old_compose_run_containers
  stop_named_container

  say "starting Gazebo + YARP + yarpmanager"
  DISPLAY="$DISPLAY_NUM" WORLD="$WORLD" docker_compose run -d --name "$CONTAINER" sim ./sim_up.sh >/dev/null

  say "waiting for R1 mobile base YARP ports"
  docker exec "$CONTAINER" bash -lc \
    'timeout 90 bash -c '\''until yarp name list 2>/dev/null | grep -q "/r1mk3Sim/mobile_base/command:i" && timeout 2 yarp ping /r1mk3Sim/mobile_base/rpc:i >/dev/null 2>&1; do sleep 1; done'\'''

  say "starting baseControl2 + yarpMobilebaseGUI"
  docker exec -d "$CONTAINER" bash -lc '/home/user1/drive_up.sh > /tmp/r1_drive_up.log 2>&1'

  say "waiting for baseControl2"
  docker exec "$CONTAINER" bash -lc \
    'timeout 45 bash -c '\''until yarp name list 2>/dev/null | grep -q "/baseControl/rpc "; do sleep 1; done'\'''

  say "waiting for yarpMobilebaseGUI"
  docker exec "$CONTAINER" bash -lc \
    'timeout 45 bash -c '\''until yarp name list 2>/dev/null | grep -q "/yarpmobilebasegui:o"; do sleep 1; done'\'''

  say "connecting yarpmobilebasegui to baseControl"
  echo 'yarp connect /yarpmobilebasegui:o /baseControl/input/joystick/data:i' | docker exec -i "$CONTAINER" bash -l

  say "ready. Connect to TurboVNC ${DISPLAY_NUM} and use yarpMobilebaseGUI."
  status
}

status() {
  check_prereqs
  say "container"
  docker ps --filter "name=$CONTAINER" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'

  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    say "$CONTAINER is not running"
    return 0
  fi

  say "key processes"
  docker exec "$CONTAINER" bash -lc \
    'ps -eo pid,comm,args | egrep "yarpserver|gz sim|yarpmanager|yarprun|yarplogger|baseControl2|yarpmobilebasegui" | grep -v egrep || true'

  say "key YARP ports"
  docker exec "$CONTAINER" bash -lc \
    'yarp name list | egrep "/root|/clock|/console|/yarplogger|/r1mk3Sim/mobile_base|/baseControl|/yarpmobilebasegui" || true'

  if command -v xdotool >/dev/null 2>&1; then
    say "VNC ${DISPLAY_NUM} windows"
    DISPLAY="$DISPLAY_NUM" xdotool search --name 'mobile|base|yarp|YARP|Gazebo|manager' getwindowname %@ 2>/dev/null || true
  fi
}

stop_sim() {
  stop_named_container
  stop_old_compose_run_containers
  say "stopped"
}

logs() {
  docker logs -f "$CONTAINER"
}

drive_logs() {
  docker exec "$CONTAINER" bash -lc 'tail -f /tmp/r1_drive_up.log'
}

shell_in() {
  docker exec -it "$CONTAINER" bash
}

usage() {
  sed -n '2,10p' "$0"
}

case "${1:-start}" in
  start)
    start_sim
    ;;
  status)
    status
    ;;
  stop)
    stop_sim
    ;;
  logs)
    logs
    ;;
  drive-logs)
    drive_logs
    ;;
  shell)
    shell_in
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage
    die "unknown command: ${1:-}"
    ;;
esac
