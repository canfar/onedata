#!/bin/bash

REPO_ROOT="${PWD//getting-started*}getting-started/"
AUTH_CONF="bin/config/auth.conf"
ZONE_COMPOSE_FILE="docker-compose-onezone.yml"
PROVIDER_COMPOSE_FILE="docker-compose-oneprovider.yml"
COMPOSE_FILE="docker-compose.yml"

DEBUG=0;

docker_stack_deploy_sh=("docker" "stack" "deploy")

#Default Onezone
#ZONE_FQDN="beta.onedata.org"

# Error handling.
# $1 - error string
die() {
  echo "${0##*/}: error: $*" >&2
  exit 1
}

# Get variables from env
set_defaults_if_not_defined_in_env() {
  # Default coordinates
  [[ -z ${GEO_LATITUDE+x} ]] && GEO_LATITUDE="50.068968"
  [[ -z ${GEO_LONGITUDE+x} ]] && GEO_LONGITUDE="19.909444"

  # Default paths
  [[ -z ${ONEPROVIDER_DATA_DIR+x} ]] && ONEPROVIDER_DATA_DIR="${PWD}/oneprovider_data/"
  [[ -z ${ONEPROVIDER_CONFIG_DIR+x} ]] && ONEPROVIDER_CONFIG_DIR="${PWD}/config_oneprovider/"
  [[ -z ${ONEZONE_CONFIG_DIR+x} ]] && ONEZONE_CONFIG_DIR="${PWD}/config_onezone/"
  [[ -z ${AUTH_PATH+x} ]] && AUTH_PATH="${REPO_ROOT}${AUTH_CONF}"

  # Default names for provider and zone
  [[ -z ${ZONE_NAME+x} ]] && ZONE_NAME="Example Zone"
  [[ -z ${PROVIDER_NAME+x} ]] && PROVIDER_NAME="Example Provider"
}

print_docker_compose_file() {
  local compose_file_name=$1
  echo "The docker compose file with substituted variables be used:
BEGINING===="

  # http://mywiki.wooledge.org/TemplateFiles
  LC_COLLATE=C
  while read -r; do
    while [[ $REPLY =~ \$(([a-zA-Z_][a-zA-Z_0-9]*)|\{([a-zA-Z_][a-zA-Z_0-9]*)\})(.*) ]]; do
      if [[ -z ${BASH_REMATCH[3]} ]]; then   # found $var
        printf %s "${REPLY%"${BASH_REMATCH[0]}"}${!BASH_REMATCH[2]}"
      else # found ${var}
        printf %s "${REPLY%"${BASH_REMATCH[0]}"}${!BASH_REMATCH[3]}"
      fi
      REPLY=${BASH_REMATCH[4]}
    done
    printf "%s\n" "$REPLY"
  done < "${compose_file_name}"
  echo "====END"
}

# As the name suggests
usage() {
  echo "Usage: ${0##*/}  [-h] [ --zone  | --provider ] [ --(with-|without-)clean ] [ --debug ]

Onezone usage: ${0##*/} --zone
Oneprovider usage: ${0##*/} --provider [ --provider-fqdn <fqdn> ] [ --zone-fqdn <fqdn> ] [ --provider-data-dir ] [ --set-lat-long ]

Example usage:
${0##*/} --provider --provider-fqdn 'myonedataprovider.tk' --zone-fqdn 'myonezone.tk' --provider-data-dir '/mnt/super_fast_big_storage/' --provider-conf-dir '/etc/oneprovider/'

Options:
  -h, --help           display this help and exit
  --name               a name of a provider or a zone
  --zone               starts onezone service
  --provider           starts oneprovider service
  --provider-fqdn      FQDN for oneprovider (not providing this option causes a script to try to guess public ip using http://ipinfo.io/ip service)
  --zone-fqdn          FQDN for onezone (defaults to beta.onedata.org)
  --provider-data-dir  a directory where provider will store users raw data
  --provider-conf-dir  directory where provider will store configuration its files
  --zone-conf-dir      directory where zone will store configuration its files
  --set-lat-long       sets latitude and longitude from reegeoip.net service based on your public ip's
  --clean              clean all onezone, oneprivder and oneclient configuration and data files - provided all docker containers using them have been shutdown
  --with-clean         run --clean prior to setting up service
  --without-clean      prevents running --clean prior to setting up service
  --debug              write to STDOUT the docker-compose config and commands that would be executed
  --detach             run container in background and print container name"
  exit 0
}

get_log_lat(){
  ip="$(curl http://ipinfo.io/ip)"
  read -r GEO_LATITUDE GEO_LONGITUDE <<< $(curl freegeoip.net/xml/"$ip" | grep -E "Latitude|Longitude" | cut -d '>' -f 2 | cut -d '<' -f 1)
}

debug() {
  set -o posix ; set
}

is_clean_needed () {

  [[ -d "$ONEZONE_CONFIG_DIR" ]] && return 0
  [[ -d "$ONEPROVIDER_CONFIG_DIR" ]] && return 0
  [[ -d "$ONEPROVIDER_DATA_DIR" ]] && return 0

  [[ $(docker ps -aqf 'name=onezone') != "" ]] && return 0
  [[ $(docker ps -aqf 'name=oneprovider') != "" ]] && return 0

  return 1
}

clean() {
  echo "The cleaning procedure will need to run commands using sudo, in order to remove volumes created by docker. Please provide a password if needed."

  [[ $(git status --porcelain "$ZONE_COMPOSE_FILE") != ""  ]] && echo "Warrning the file $ZONE_COMPOSE_FILE has changed, the cleaning procedure may not work!"
  [[ $(git status --porcelain "$PROVIDER_COMPOSE_FILE") != ""  ]] && echo "Warrning the file $PROVIDER_COMPOSE_FILE has changed, the cleaning procedure may not work!"

  echo "Removing provider and/or zone config dirs..."
  sudo rm -rf "${ONEZONE_CONFIG_DIR}"
  sudo rm -rf "${ONEPROVIDER_CONFIG_DIR}"

  echo "Removing provider data dir..."
  sudo rm -rf "${ONEPROVIDER_DATA_DIR}"

  clean_scenario
}

batch_mode_check() {
  local service=$1
  local compose_file_name=$2

  grep 'ONEPANEL_BATCH_MODE: "true"' "$compose_file_name" > /dev/null
  if [[ $? -eq 0 ]] ; then

    RED="$(tput setaf 1)"
    GREEN="$(tput setaf 2)"
    RESET="$(tput sgr0)"

    echo -e "${RED}IMPORTANT: After each start wait for a message: ${GREEN}Congratulations! ${service} has been successfully started.${RESET}"
    echo -e "${RED}To ensure that the ${service} is completely setup.${RESET}"
  fi
}

handle_stack() {
  local n=$1
  local compose_file_name=$2
  local stack_name=$3

  mkdir -p "$ONEZONE_CONFIG_DIR"

  _docker_stack_deploy_sh() {
    CMD="ZONE_NAME=\"${ZONE_NAME}\" ZONE_DOMAIN_NAME=\"${ZONE_DOMAIN_NAME}\" PROVIDER_FQDN=\"${PROVIDER_FQDN}\" ZONE_FQDN=\"${ZONE_FQDN}\" AUTH_PATH=\"${AUTH_PATH}\" ONEZONE_CONFIG_DIR=\"${ONEZONE_CONFIG_DIR}\" ${docker_stack_deploy_sh[*]} ${@}"
    echo "Executing ${CMD}";
    eval ${CMD}
  }

  _docker_stack_deploy_sh --compose-file $compose_file_name $stack_name
  docker service ls
}

main() {

  if (( ! $# )); then
    usage
  fi

  set_defaults_if_not_defined_in_env

  local n=1
  local get_log_lat_flag=0

  while (( $# )); do
      case $1 in
          -h|-\?|--help)   # Call a "usage" function to display a synopsis, then exit.
              usage
              exit 0
              ;;
          --name)
              STACK_NAME=$2
              shift
              ;;
          --zone-name)
              ZONE_NAME="$2"
              shift
              ;;
          --provider-name)
              PROVIDER_NAME="$2"
              shift
              ;;
          --zone-conf-dir)
              ONEZONE_CONFIG_DIR=$2
              shift
              ;;
          --provider-data-dir)
              ONEPROVIDER_DATA_DIR=$2
              shift
              ;;
          --provider-conf-dir)
              ONEPROVIDER_CONFIG_DIR=$2
              shift
              ;;
          --without-clean)
              keep_old_config='y'
              ;;
          --with-clean)
              keep_old_config='n'
              ;;
          --debug)
              DEBUG=1
              ;;
          --zone-fqdn)
              ZONE_FQDN=$2
              shift
              ;;
          --provider-fqdn)
              PROVIDER_FQDN=$2
              shift
              ;;
          --swarm-manager-ip)
              SWARM_MANAGER_IP=$2
              shift
              ;;
          --set-lat-long)
              get_log_lat_flag=1
              ;;
          -?*)
              printf 'WARN: Unknown option (ignored): %s\n' "$1" >&2
              exit 1
              ;;
          *)
              die "no option $1"
              ;;
      esac
      shift
  done

  if is_clean_needed ; then
    if [[ -z $keep_old_config ]]; then
      echo "We detected configuration files, data and docker containers from a previous Onedata deployment.
  Would you like to keep them (y) or start a new deployment (n)?"
      read -r keep_old_config
    fi
    if [[ $keep_old_config == 'n' ]]; then
        clean
    fi
  fi

  if [[ $get_log_lat_flag -eq 1 ]]; then
    get_log_lat
  fi

  [[ -z ${SWARM_MANAGER_IP} ]] && SWARM_MANAGER_IP="$(docker-machine ip swarm-manager)"

  echo "Found Swarm Manager ${SWARM_MANAGER_IP}"

  handle_stack ${n} ${COMPOSE_FILE} ${STACK_NAME}

  echo "Swarm deployed."
}

clean_scenario() {
  : # pass
}

main "$@"
