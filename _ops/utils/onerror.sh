#!/bin/bash

function __errhelper__() {
    echo "#####################################################"
    echo 'SSH into tmate session using the key or instructions given below in the end'
    echo 'To terminate session: touch /tmp/tm-stop, To hold session beyond 15min timeout: touch /tmp/tm-hold'
    echo "--> Errorcode $last_status_code @line ${error_line_number[0]} for command: $bash_command"
    echo "--> Stacktrace <--"
    echo -e "$stacktrace"
    echo "--> Code <--"
    perl -slne 'if($.+5 >= $ln && $.-4 <= $ln){ $_="$. $_"; s/$ln/">" x length($ln)/eg; s/^\D+.*?$/\e[1;31m$&\e[0m/g;  print}' -- -ln=$error_line_number $0
    echo "--> Reproduce error: NSDEBUG=true bash $0 ${__script_arguments__:-}"
    echo "#####################################################"
}

function __stacktrace__() {
    set +e
    local frame=1 LINE SUB FILE

    temp_file=$(mktemp)  # Create a temporary file
    caller "$frame" > "$temp_file"  # Redirect output to the temporary file

    while read -r LINE SUB FILE; do
        echo "${SUB} @ ${FILE}:${LINE}"
        ((frame++))
    done < "$temp_file"  # Read from the temporary file

    rm "$temp_file"  # Clean up the temporary file
}

function __install_tmate_linux__()
{
    # Install tmate
    TMATE_VERSION=2.4.0
    TMATE_HASH=6e503a1a3b0f9117bce6ff7cc30cf61bdc79e9b32d074cf96deb0264e067a60d
    pushd /usr/local/bin
    wget -t 3 -qO tmate.tar.xz https://github.com/tmate-io/tmate/releases/download/${TMATE_VERSION}/tmate-${TMATE_VERSION}-static-linux-amd64.tar.xz
    echo "${TMATE_HASH}  ./tmate.tar.xz" | sha256sum -c -
    tar -xvf tmate.tar.xz
    rm -rf tmate.tar.xz
    mv tmate-${TMATE_VERSION}-static-linux-amd64/tmate ./
    chmod +x ./tmate
    rm -rf tmate-${TMATE_VERSION}-static-linux-amd64
    ln -fs /usr/local/bin/tmate /usr/bin/tmate
    popd
}

function __ensure_tmate__() {

    if [ $(type /usr/bin/tmate >/dev/null 2>&1; echo $?) = 0 ]; then
        return 0
    fi
    if [ $(type /usr/local/bin/tmate >/dev/null 2>&1; echo $?) = 0 ] && [ "$_OS_" != "Darwin" ]; then
        ln -fs /usr/local/bin/tmate /usr/bin/tmate
        return 0
    fi

    echo -e "#### Missing tmate. Consider adding to Dockerfile ####"

    if [ "$_OS_" = "Darwin" ]; then # Add macOS-specific commands or logic here
        bash -c "su $CURRENT_USER -c 'brew install tmate'" &>/dev/null
    elif [ "$_OS_" = "Linux" ]; then
        if [ -f "/etc/centos-release" ]; then
            yum -y install wget curl perl &>/dev/null
            __install_tmate_linux__ &>/dev/null
        elif [ -f "/etc/debian_version" ]; then
            apt update &>/dev/null && apt install -y wget curl perl &>/dev/null
            __install_tmate_linux__ &>/dev/null
        elif [ -f "/etc/alpine-release" ]; then
            apk add --no-cache wget curl perl &>/dev/null
            __install_tmate_linux__ &>/dev/null
        else
            echo "Unknown Linux distribution" && exit 1
        fi
    else
        echo "Unknown or unsupported operating system" && exit 1
    fi
}

function __exit_handler__() {
    local error_line_number=$1
    local last_status_code=$2
    local bash_command=${BASH_COMMAND}
    local stacktrace="$(__stacktrace__)"

    if [ "$(echo "${DEBUG:-}" | tr '[:upper:]' '[:lower:]')" = "true" ]; then
        [ -w /proc/$$/fd/1 ] && echo "${last_status_code}::${NSDEBUG:-null}::${DEBUG:-null}::${WAIT_ON_ERROR:-null}"
    fi
    #111 status for ctrl-c
    if [[ ! -f /tmp/tm-stop && "$last_status_code" != "0" && "$last_status_code" != "111" && "${NSDEBUG:-}" != "true" && "${DEBUG:-}" == "true" && ${WAIT_ON_ERROR:-} == "true" ]]; then
        export NSDEBUG=true && touch /tmp/tm-hol
        export CURRENT_USER=`whoami`
        # Get the operating system name
        export _OS_=$(uname -s)
        #echo $os && ls /etc/*-release &&  cat /etc/*-release

        # Add macOS-specific commands or logic here
        if [ "$_OS_" = "Darwin" ]; then
            BASE64="base64"
        else
            BASE64="base64 -w0"
        fi

        sudo -E bash -c "$(declare -f __install_tmate_linux__; declare -f __ensure_tmate__); __ensure_tmate__" || __ensure_tmate__

        # Configure tmate
        if [[ "${TMATE_HOST:-}" != "" ]]; then
            cat > ~/.tmate.conf <<-EOF
set -g tmate-server-host ${TMATE_HOST}
set -g tmate-server-port ${TMATE_PORT}
set -g tmate-server-rsa-fingerprint     "${TMATE_RSA}"
set -g tmate-server-ed25519-fingerprint "${TMATE_ED25519}"
EOF
        fi

        # Output to stdout && capture/send msg to Slack
        exec 3>&1
        HELP_TEXT=/tmp/onerror_help_text.$RANDOM
        touch $HELP_TEXT

        echo "Halting for remote debugging ..." | tee -a "$HELP_TEXT" >&3
        __errhelper__ | tee -a "$HELP_TEXT" >&3
        { command -v /usr/bin/tmate >/dev/null 2>&1 && TMATE_BIN=/usr/bin/tmate; } || { command -v /usr/local/bin/tmate >/dev/null 2>&1 && TMATE_BIN=/usr/local/bin/tmate; }
        $TMATE_BIN -F 2>&1 | tee -a "$HELP_TEXT" >&3 &

        sleep 2
        escaped_help_text=$(cat "$HELP_TEXT" | sed 's/\\/\\\\/g; s/'\''/\\'\''/g; s/"/\\\"/g; s/$'\''\n'/$'\\n/g; s/$'\''\r'/$'\\r/g; s/$'\''\t'/$'\\t/g')
        curl --fail -X POST -H 'Content-type: application/json' --data '{"text":"'''"$escaped_help_text"'''"}' `echo $SLACK_WEBHOOK_B64 | base64 -d` 2>/dev/null || curl --fail -X POST -H 'Content-type: application/json' --data '{"text":"onerror: ERROR found in DEBUG mode: '''"$(echo $escaped_help_text | $BASE64)"'''"}' `echo $SLACK_WEBHOOK_B64 | base64 -d` 2>/dev/null || :
        rm -f "$HELP_TEXT"

        SOFT_LIMIT=$((SECONDS+900));
        HARD_LIMIT=$((SECONDS+7200));
        until [ -f /tmp/tm-stop ]; do
            if [ $SECONDS -ge $SOFT_LIMIT ] && [ ! -f /tmp/tm-hold ] || [ $SECONDS -ge $HARD_LIMIT ]; then break; fi;
            sleep 5;
        done
        __ctrl_c__
    fi
    exit $last_status_code
}
# trap ctrl-c and call __ctrl_c__()
function __ctrl_c__() {
    ps ax | grep "tmate -F" | grep -v grep | head -n1 | awk '{print $1;}' | sudo xargs kill || :
    exec 3>&1- || :
    if [ -f /tmp/tm-step ]; then exit 112; else exit 111; fi
}

# Wireup error commands
set +x
[ -n "${BASH_VERSION:-}" ] && : || exec bash "$0" "$@"
__script_arguments__="${@:-}"
trap 'err_code=$?; set +x; __exit_handler__ ${BASH_LINENO:-LINENO} $err_code' EXIT
trap __ctrl_c__ INT

# Optionally enable verbose mode
for arg in ${*:-}; do
    if [[ $arg == '__verbose__' ]]; then
        set -v;
    fi
done
if [ "$(echo "${DEBUG:-}" | tr '[:upper:]' '[:lower:]')" = "true" ]; then set -x; fi
