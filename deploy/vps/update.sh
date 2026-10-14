#!/bin/sh
# Updates (or rolls back) the console on a server in one command (0.1.3).
# Plain sh, git and docker compose: nothing else on the host.
#
#   ./update.sh 0.2.1                     # from deploy/vps of the checkout
#   ./update.sh --dry-run 0.2.1           # print the steps, change nothing
#   ./update.sh 0.1.3 --restore <backup>  # back to 0.1.3 with that backup's data
#
# In order:
#   1. checks: the .env, the checkout has no local changes, the tag
#      v<version> (fetched when missing), docker compose answers
#   2. a backup of the console's databases (bin/asterism backup in a one-off
#      container, into the "backups" volume), taken with the newer of the
#      two images, before anything starts on the other version
#   3. git checkout v<version>, CONSOLE_VERSION=<version> in .env,
#      docker compose pull
#   4. (--restore) stops the console, the bridge and the backup service and
#      restores the backup named
#   5. bin/asterism setup --from-update (the migrations; idempotent). When
#      the registry's configuration of the cloud router differs from the
#      router's file, it writes the file and restarts the router on it (as
#      Apply does): after the update the router runs the registry
#   6. the restart: systemctl restart <unit> when the stack runs as a systemd
#      unit (and nothing else: the unit starts the stack), otherwise
#      docker compose up -d --remove-orphans
#   7. checks that every service runs, the console's ones on the new image,
#      and that no other container of the project is left
#   8. says whether the router's configuration changed, and prints how to go
#      back (this script with the old version and --restore <the backup it
#      took>)
# When something fails before the restart, the checkout and .env are put
# back as they were.
#
# Options:
#   -C DIR          the deploy/vps directory (default: this script's directory)
#   -f FILE         a compose file (repeatable; default: COMPOSE_FILE, else
#                   DIR/docker-compose.yml). An include wrapper is fine.
#   -p NAME         the compose project name (default: the compose file's)
#   --env-file F    the .env holding CONSOLE_VERSION (default: DIR/.env)
#   --sudo          run docker, systemctl (and git / sed when needed) with sudo
#   --unit UNIT     restart with systemctl restart UNIT (or ASTERISM_SYSTEMD_UNIT);
#                   default: docker-compose-service@<project> when that unit is active
#   --no-unit       never use systemctl
#   --restore NAME  restore this backup (bin/asterism backups lists them)
#   --dry-run       print what it would do
#
# Paths must not contain spaces. Docs: docs/install.md, "Updating".

usage() {
  sed -n '2,/^# Paths must/p' "$SELF" | sed 's/^# \{0,1\}//'
  exit "${1:-2}"
}

say() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die() { printf '\nupdate.sh: %s\n' "$*" >&2; exit 1; }

# A command that changes something: printed, and run unless --dry-run;
# its failure stops the script.
act() {
  case "$1" in
    compose)
      shift
      say "+ ${SUDO:+$SUDO }docker compose ${CFLAGS:+$CFLAGS }$*"
      [ "$DRY" = 1 ] || compose "$@" || die "failed: docker compose $*"
      ;;
    compose_with)
      v=$2
      shift 2
      say "+ ${SUDO:+$SUDO }env CONSOLE_VERSION=$v docker compose ${CFLAGS:+$CFLAGS }$*"
      [ "$DRY" = 1 ] || compose_with "$v" "$@" || die "failed: docker compose $* (image $v)"
      ;;
    *)
      say "+ $*"
      [ "$DRY" = 1 ] || "$@" || die "failed: $*"
      ;;
  esac
}

# version_le A B: A <= B in version order.
version_le() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$1" ]
}

compose() {
  # shellcheck disable=SC2086
  $SUDO docker compose $CFLAGS "$@"
}

compose_with() {
  # compose_with VERSION args...: the console's services on another image
  v=$1
  shift
  # shellcheck disable=SC2086
  $SUDO env CONSOLE_VERSION="$v" docker compose $CFLAGS "$@"
}

env_value() {
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1 | sed "s/^[\"']//; s/[\"']\$//"
}

set_env_version() {
  if grep -q '^CONSOLE_VERSION=' "$ENV_FILE"; then
    act $ESUDO sed -i "s/^CONSOLE_VERSION=.*/CONSOLE_VERSION=$1/" "$ENV_FILE"
  else
    say "+ echo CONSOLE_VERSION=$1 >> $ENV_FILE"
    [ "$DRY" = 1 ] || printf 'CONSOLE_VERSION=%s\n' "$1" | $ESUDO tee -a "$ENV_FILE" >/dev/null || die "could not write $ENV_FILE"
  fi
}

undo() {
  [ "$ARMED" = 1 ] || return 0
  ARMED=0
  printf '\nupdate.sh: failed; putting the checkout and .env back (%s, CONSOLE_VERSION=%s)\n' "$OLD_REF" "$FROM" >&2
  $GIT -C "$TOP" checkout -q "$OLD_REF" || say "  could not check out $OLD_REF again: do it by hand" >&2
  $ESUDO sed -i "s/^CONSOLE_VERSION=.*/CONSOLE_VERSION=$FROM/" "$ENV_FILE" || true
  [ -z "$BACKUP" ] || say "  the backup taken: $BACKUP" >&2
  say "  the running containers were not restarted; check with: ${SUDO:+$SUDO }docker compose ${CFLAGS:+$CFLAGS }ps" >&2
}

take_backup() {
  # take_backup VERSION_OF_IMAGE LABEL
  args="bin/asterism backup --label $2 --data-version $FROM"
  [ -z "$RESTORE" ] || args="$args --no-rotate"
  say "+ ${SUDO:+$SUDO }env CONSOLE_VERSION=$1 docker compose ${CFLAGS:+$CFLAGS }run --rm --no-deps -T console $args"
  if [ "$DRY" = 1 ]; then
    BACKUP="asterism-<time>-$FROM-$2.tar.gz"
    return 0
  fi
  # shellcheck disable=SC2086
  out=$(compose_with "$1" run --rm --no-deps -T console $args) || {
    say "$out"
    die "the backup failed: nothing was changed on the running console"
  }
  say "$out" | grep -v '^BACKUP_NAME=' || true
  BACKUP=$(say "$out" | sed -n 's/^BACKUP_NAME=//p' | tail -n 1)
  [ -n "$BACKUP" ] || die "the backup printed no name"
}

restore_backup() {
  # restore_backup VERSION_OF_IMAGE (one that has bin/asterism restore)
  step "Restore $RESTORE"
  act compose stop console bridge backup
  act compose_with "$1" run --rm --no-deps -T console bin/asterism restore "$RESTORE"
}

check_backup_exists() {
  # check_backup_exists VERSION_OF_IMAGE
  [ -n "$RESTORE" ] || return 0
  case "$RESTORE" in
    asterism-*.tar.gz) ;;
    *) die "--restore takes a backup's file name (asterism-<time>-<version>....tar.gz)" ;;
  esac
  [ "$DRY" = 1 ] && return 0
  list=$(compose_with "$1" run --rm --no-deps -T console bin/asterism backups) || die "could not list the backups"
  say "$list" | grep -q " $RESTORE " || {
    say "$list"
    die "no backup $RESTORE"
  }
}

verify() {
  step "Check"
  if [ "$DRY" = 1 ]; then
    say "(would wait until every service runs, the console's on $IMAGE:$VERSION, and nothing else of project $PROJECT is left)"
    return 0
  fi
  want="$IMAGE:$VERSION"
  services=$(compose config --services) || die "docker compose config failed"
  tries=0
  while :; do
    problems=""
    for s in $services; do
      cid=$(compose ps -q "$s" 2>/dev/null | head -n 1)
      if [ -z "$cid" ]; then
        problems="$problems\n  $s: no container"
        continue
      fi
      # shellcheck disable=SC2086
      set -- $($SUDO docker inspect -f '{{.State.Status}} {{.Config.Image}}' "$cid")
      [ "$1" = running ] || problems="$problems\n  $s: $1"
      case "$2" in
        "$IMAGE":*) [ "$2" = "$want" ] || problems="$problems\n  $s: runs $2, not $want" ;;
      esac
    done
    left=$($SUDO docker ps -a --filter "label=com.docker.compose.project=$PROJECT" \
      --format '{{.Names}} {{.Image}} {{.State}} {{.Label "com.docker.compose.service"}} {{.Label "com.docker.compose.oneoff"}}' |
      while read -r name image state svc oneoff; do
        known=0
        for s in $services; do [ "$s" = "$svc" ] && known=1; done
        if [ "$oneoff" = True ] || [ "$known" = 0 ] || [ "$state" != running ]; then
          printf '\\n  left over: %s (%s, %s)' "$name" "$image" "$state"
        else
          case "$image" in
            "$IMAGE":*) [ "$image" = "$want" ] || printf '\\n  left over: %s (%s)' "$name" "$image" ;;
          esac
        fi
      done)
    problems="$problems$left"
    [ -z "$problems" ] && break
    tries=$((tries + 1))
    if [ "$tries" -ge 30 ]; then
      printf 'update.sh: not as expected after 60 s:%b\n' "$problems" >&2
      compose ps -a >&2 || true
      say "  a container left over from a one-off run or an older compose file: ${SUDO:+$SUDO }docker rm -f <its name>" >&2
      way_back >&2
      die "not as expected (docker compose logs <service>); the commands above go back"
    fi
    sleep 2
  done
  got=$(compose exec -T console bin/asterism version 2>/dev/null) || got="(no answer)"
  case "$got" in
    *" $VERSION") say "  every service runs; the console says: $got" ;;
    *) die "the console says \"$got\", not $VERSION" ;;
  esac
  say "  nothing else of project $PROJECT is left (docker ps -a)"
}

# The setup, its output shown; ROUTER_CONFIG= its last line says what it
# did with the cloud router's configuration (bin/asterism, 0.2.1 and later;
# an older one says nothing: "unknown").
run_setup() {
  ROUTER_CONFIG=unknown
  say "+ ${SUDO:+$SUDO }docker compose ${CFLAGS:+$CFLAGS }run --rm -T console bin/asterism setup --from-update"
  [ "$DRY" = 1 ] && return 0
  out=$(compose run --rm -T console bin/asterism setup --from-update 2>&1) || {
    say "$out"
    die "failed: bin/asterism setup"
  }
  say "$out" | grep -v '^ROUTER_CONFIG=' || true
  got=$(say "$out" | sed -n 's/^ROUTER_CONFIG=//p' | tail -n 1)
  [ -z "$got" ] || ROUTER_CONFIG=$got
}

router_note() {
  case "$ROUTER_CONFIG" in
    written)
      say "  the registry is applied: the setup wrote the cloud router's configuration from it and restarted"
      say "  the router on it. Apply (Admin > Relay) is needed only after you change the registry later." ;;
    unchanged|new)
      say "  the registry is applied: the cloud router's configuration already was the registry's."
      say "  Apply (Admin > Relay) is needed only after you change the registry later." ;;
    written-not-restarted)
      say "  the setup wrote the cloud router's configuration from the registry but could not restart the router:"
      say "  Apply once (Admin > Relay)." ;;
    *)
      if [ "$DRY" = 1 ]; then
        say "  (the setup says whether it changed the cloud router's configuration; then nothing more is needed)"
      else
        say "  the setup of $VERSION does not say whether the cloud router's configuration changed:"
        say "  if Admin > Relay shows \"Changes not yet applied\", Apply once."
      fi ;;
  esac
}

way_back() {
  if [ "$FROM" != "$VERSION" ]; then
    say ""
    say "To go back to $FROM with the data as it was before this update:"
    if version_le 0.1.3 "$VERSION"; then
      say "  sh $DIR/update.sh -C $DIR$KEEP_OPTS $FROM --restore $BACKUP"
    else
      # this version's checkout has no update.sh: take the newer tag's
      say "  git -C $TOP show v$FROM:deploy/vps/update.sh > /tmp/asterism-update.sh"
      say "  sh /tmp/asterism-update.sh -C $DIR$KEEP_OPTS $FROM --restore $BACKUP"
    fi
    if ! version_le 0.1.3 "$FROM"; then
      say "($FROM has no update.sh: to update again after going back, use the newer tag's script:"
      say "  git -C $TOP show v$VERSION:deploy/vps/update.sh > /tmp/asterism-update.sh"
      say "  sh /tmp/asterism-update.sh -C $DIR$KEEP_OPTS $VERSION )"
    fi
  elif [ -n "$BACKUP" ]; then
    say ""
    say "To put the data back as it was before this run:"
    say "  sh $DIR/update.sh -C $DIR$KEEP_OPTS $VERSION --restore $BACKUP"
  fi
}

main() {
  ARMED=0
  DIR=""
  FILES=""
  PROJECT=""
  ENV_FILE=""
  SUDO=""
  UNIT="${ASTERISM_SYSTEMD_UNIT:-}"
  NO_UNIT=0
  RESTORE=""
  DRY=0
  VERSION=""
  KEEP_OPTS=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -C) DIR=$2; shift 2 ;;
      -f) FILES="$FILES -f $2"; KEEP_OPTS="$KEEP_OPTS -f $2"; shift 2 ;;
      -p) PROJECT=$2; KEEP_OPTS="$KEEP_OPTS -p $2"; shift 2 ;;
      --env-file) ENV_FILE=$2; KEEP_OPTS="$KEEP_OPTS --env-file $2"; shift 2 ;;
      --sudo) SUDO=sudo; KEEP_OPTS="$KEEP_OPTS --sudo"; shift ;;
      --unit) UNIT=$2; KEEP_OPTS="$KEEP_OPTS --unit $2"; shift 2 ;;
      --no-unit) NO_UNIT=1; KEEP_OPTS="$KEEP_OPTS --no-unit"; shift ;;
      --restore) RESTORE=$2; shift 2 ;;
      --dry-run|-n) DRY=1; shift ;;
      -h|--help) usage 0 ;;
      -*) say "update.sh: unknown option $1" >&2; usage 2 ;;
      *) [ -z "$VERSION" ] || die "one version only ($VERSION, $1)"; VERSION=$1; shift ;;
    esac
  done
  [ -n "$VERSION" ] || usage 2
  VERSION=${VERSION#v}
  printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' || die "not a version: $VERSION"

  SELF_DIR=$(cd "$(dirname "$SELF")" && pwd)
  if [ -z "$DIR" ]; then
    if [ -f "$SELF_DIR/docker-compose.yml" ] && [ -f "$SELF_DIR/env.example" ]; then DIR=$SELF_DIR; else DIR=$(pwd); fi
  fi
  DIR=$(cd "$DIR" && pwd) || die "no directory $DIR"
  [ -f "$DIR/docker-compose.yml" ] || die "$DIR is not deploy/vps (no docker-compose.yml); give it with -C"
  cd "$DIR"
  [ -n "$ENV_FILE" ] || ENV_FILE="$DIR/.env"
  [ -f "$ENV_FILE" ] || die "no $ENV_FILE (env.example; docs/install.md, \"Settings\")"
  if [ -z "$FILES" ] && [ -n "${COMPOSE_FILE:-}" ]; then
    for f in $(printf '%s' "$COMPOSE_FILE" | tr ':' ' '); do FILES="$FILES -f $f"; KEEP_OPTS="$KEEP_OPTS -f $f"; done
  fi
  [ -z "$PROJECT" ] || FILES="-p $PROJECT$FILES"
  CFLAGS=$(printf '%s' "$FILES" | sed 's/^ *//')
  ESUDO=""
  [ -w "$ENV_FILE" ] || ESUDO=$SUDO

  FROM=$(env_value CONSOLE_VERSION)
  [ -n "$FROM" ] || die "$ENV_FILE has no CONSOLE_VERSION= line (env.example)"
  IMAGE=$(env_value CONSOLE_IMAGE)
  [ -n "$IMAGE" ] || IMAGE=ghcr.io/ruby-asterism/asterism-console

  if version_le "$FROM" "$VERSION"; then UP=1; NEWER=$VERSION; else UP=0; NEWER=$FROM; fi
  version_le 0.1.3 "$NEWER" ||
    die "one of the two versions must be 0.1.3 or later (the backup command came with 0.1.3); see docs/install.md"
  [ -z "$RESTORE" ] || version_le 0.1.3 "$NEWER" || die "--restore needs 0.1.3 or later on one side"

  step "Checks"
  TOP=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null) || die "$DIR is not in a git checkout of asterism-console"
  GIT=git
  [ -w "$TOP/.git" ] || GIT="$SUDO git"
  $GIT -C "$TOP" diff --quiet HEAD -- || die "the checkout $TOP has local changes (git status); commit or drop them first"
  OLD_REF=$($GIT -C "$TOP" symbolic-ref -q --short HEAD || $GIT -C "$TOP" rev-parse HEAD)
  TAG="v$VERSION"
  if ! $GIT -C "$TOP" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    depth=""
    [ "$($GIT -C "$TOP" rev-parse --is-shallow-repository)" = true ] && depth="--depth 1"
    # shellcheck disable=SC2086
    act $GIT -C "$TOP" fetch -q $depth origin "refs/tags/$TAG:refs/tags/$TAG" ||
      die "no tag $TAG (git fetch failed; is $VERSION released?)"
  fi
  # shellcheck disable=SC2086
  $SUDO docker compose $CFLAGS version >/dev/null 2>&1 || die "docker compose does not answer (try --sudo)"
  if [ -z "$PROJECT" ]; then
    PROJECT=$(compose config 2>/dev/null | sed -n 's/^name: //p' | head -n 1)
    [ -n "$PROJECT" ] || die "could not read the compose project's name (docker compose $CFLAGS config)"
  fi
  if [ "$NO_UNIT" = 1 ]; then
    UNIT=""
  elif [ -z "$UNIT" ] && command -v systemctl >/dev/null 2>&1 &&
    systemctl is-active --quiet "docker-compose-service@$PROJECT" 2>/dev/null; then
    UNIT="docker-compose-service@$PROJECT"
  fi
  say "  $DIR (checkout $TOP at $OLD_REF), project $PROJECT"
  if [ -n "$UNIT" ]; then how="systemctl restart $UNIT (the unit starts the stack)"; else how="docker compose up -d"; fi
  say "  console $FROM -> $VERSION ($IMAGE), restart: $how"
  [ -z "$RESTORE" ] || say "  then the data of $RESTORE"
  [ "$DRY" = 0 ] || say "  dry run: nothing below is run"

  BACKUP=""
  ARMED=1
  trap undo EXIT
  if [ "$UP" = 1 ]; then
    # The newer side is the target: its files and image take the backup.
    step "The files and the image of $VERSION"
    act $GIT -C "$TOP" -c advice.detachedHead=false checkout -q "$TAG"
    set_env_version "$VERSION"
    act compose pull
    step "Backup (with $VERSION's image, of $FROM's data)"
    check_backup_exists "$VERSION"
    take_backup "$VERSION" "before-$VERSION"
    [ -z "$RESTORE" ] || restore_backup "$VERSION"
  else
    # Going back: the running (newer) side takes the backup and restores,
    # before its files are replaced by the older ones.
    step "The image of $VERSION"
    act compose_with "$VERSION" pull console
    step "Backup (with $FROM's image)"
    check_backup_exists "$FROM"
    take_backup "$FROM" "before-$VERSION"
    [ -z "$RESTORE" ] || restore_backup "$FROM"
    step "The files of $VERSION"
    act $GIT -C "$TOP" -c advice.detachedHead=false checkout -q "$TAG"
    set_env_version "$VERSION"
    act compose pull
  fi
  missing=""
  for k in $(sed -n 's/^#\{0,1\} \{0,1\}\([A-Z][A-Z0-9_]*\)=.*/\1/p' "$DIR/env.example" | sort -u); do
    grep -q "^$k=" "$ENV_FILE" || grep -q "^# *$k=" "$ENV_FILE" || missing="$missing $k"
  done
  [ -z "$missing" ] || say "  note: env.example has settings your .env does not mention:$missing (CHANGELOG.md says which matter)"

  step "Setup (migrations, the cloud router's configuration)"
  run_setup

  ARMED=0
  step "Restart"
  # A systemd unit runs `docker compose up` itself: starting the stack a
  # second time here would race it for the containers' names. With a unit,
  # the restart is the unit's alone; verify then waits for it.
  if [ -n "$UNIT" ]; then
    act $SUDO systemctl restart "$UNIT"
  else
    act compose up -d --remove-orphans
  fi
  verify
  trap - EXIT

  step "Done: console $VERSION"
  [ -z "$BACKUP" ] || say "  backup taken first: $BACKUP (in the \"backups\" volume)"
  [ -z "$RESTORE" ] || say "  restored: $RESTORE"
  router_note
  say "  old images stay for going back; list them: ${SUDO:+$SUDO }docker image ls $IMAGE"
  way_back
}

SELF=$0
# The whole script is read before it runs (main), so the checkout of
# another version may replace this file while it runs.
main "$@"; exit $?
