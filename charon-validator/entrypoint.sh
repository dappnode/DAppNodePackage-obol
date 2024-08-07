#!/bin/bash

#############
# VARIABLES #
#############
ERROR="[ ERROR-charon-manager ]"
INFO="[ INFO-charon-manager ]"

CHARON_ROOT_DIR=/opt/charon/.charon
CREATE_ENR_FILE=${CHARON_ROOT_DIR}/create_enr.txt
ENR_PRIVATE_KEY_FILE=${CHARON_ROOT_DIR}/charon-enr-private-key
ENR_FILE=${CHARON_ROOT_DIR}/enr
DEFINITION_FILE_URL_FILE=${CHARON_ROOT_DIR}/definition_file_url.txt

CHARON_LOCK_FILE=${CHARON_ROOT_DIR}/cluster-lock.json
VALIDATOR_KEYS_DIR=${CHARON_ROOT_DIR}/validator_keys

if [ -n "$DEFINITION_FILE_URL" ]; then
    echo "$DEFINITION_FILE_URL" >$DEFINITION_FILE_URL_FILE
fi

if [ "$ENABLE_MEV_BOOST" = true ]; then
    CHARON_EXTRA_OPTS="--builder-api $CHARON_EXTRA_OPTS"

    VALIDATOR_EXTRA_OPTS="--builder=true --builder.selection=builderonly $VALIDATOR_EXTRA_OPTS"
fi

export CHARON_P2P_EXTERNAL_HOSTNAME=${_DAPPNODE_GLOBAL_DOMAIN}

CHARON_PID=0
VALIDATOR_CLIENT_PID=0

#############
# FUNCTIONS #
#############

# Finds the first .tar.gz or .zip file in the IMPORT_DIR
function find_import_file() {
    find "${IMPORT_DIR}" -type f \( -name "*.tar.gz" -o -name "*.zip" -o -name "*.tar.xz" \) | head -1
}

# Moves existing files in the .charon directory to a timestamped old-charon directory
function move_old_charon() {
    if [ -d "${CHARON_ROOT_DIR}" ] && [ "$(ls -A ${CHARON_ROOT_DIR})" ]; then
        TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
        OLD_CHARON_DIR="/opt/charon/old-charons/${TIMESTAMP}"
        echo "${INFO} Moving existing files in ${CHARON_ROOT_DIR} to ${OLD_CHARON_DIR}..."
        mkdir -p "${OLD_CHARON_DIR}"
        mv ${CHARON_ROOT_DIR}/* "${OLD_CHARON_DIR}"
    else
        echo "${INFO} No existing files found in ${CHARON_ROOT_DIR} to move."
    fi
}

# Extracts the import file into the .charon directory
function extract_file_into_charon_dir() {
    echo "${INFO} Starting extraction of ${1} into ${CHARON_ROOT_DIR}"

    # Create a temporary directory for initial extraction
    tmp_dir=$(mktemp -d)

    # Extract the archive to the temporary directory
    if [[ "${1}" == *.tar.gz || "${1}" == *.tar.xz ]]; then
        tar --exclude='._*' -xvf "${1}" -C "${tmp_dir}" && echo "${INFO} Extraction (.tar.gz or .tar.xz format) to temporary directory complete."
    elif [[ "${1}" == *.zip ]]; then
        unzip -o "${1}" -d "${tmp_dir}" && echo "${INFO} Extraction (.zip format) to temporary directory complete."
    fi

    # Read contents of the temp directory into an array using mapfile
    mapfile -t contents < <(ls -A "${tmp_dir}")

    echo "${INFO} Moving files from temporary directory to ${CHARON_ROOT_DIR}..."

    if [[ ${#contents[@]} == 1 && -d "${tmp_dir}/${contents[0]}" ]]; then
        echo "${INFO} Found exactly one directory in the archive: ${contents[0]}"

        # If there is exactly one directory, move its contents to CHARON_ROOT_DIR
        mv "${tmp_dir}/${contents[0]}"/* "${CHARON_ROOT_DIR}"
        rmdir "${tmp_dir}/${contents[0]}" # Remove the now empty directory
    else
        echo "${INFO} Moving all files and directories from the temporary directory to ${CHARON_ROOT_DIR}"

        # Move all files and directories from the temp directory directly to CHARON_ROOT_DIR
        mv "${tmp_dir}"/* "${CHARON_ROOT_DIR}"
    fi

    echo "${INFO} Files moved to ${CHARON_ROOT_DIR}"

    # Cleanup the temporary directory
    rmdir "${tmp_dir}"
    echo "${INFO} Temporary directory cleaned up."
}

# Remove all keys from the validator service
function empty_lodestar_keys() {
    echo "${INFO} Emptying validator service keys..."
    rm -rf "${VALIDATOR_DATA_DIR}"/cache/* "${VALIDATOR_DATA_DIR}"/keystores/* "${VALIDATOR_DATA_DIR}"/secrets/*
}

# Main function to handle Charon file import
function handle_charon_file_import() {
    echo "${INFO} Starting Charon file import process in ${IMPORT_DIR}"
    if [ -n "${IMPORT_DIR}" ] && [ -d "${IMPORT_DIR}" ]; then

        echo "${INFO} Searching for .tar.gz, .tar.xz or .zip files in ${IMPORT_DIR}"
        IMPORT_FILE=$(find_import_file)

        if [ -n "${IMPORT_FILE}" ]; then
            echo "${INFO} Found file to import: ${IMPORT_FILE}"
            move_old_charon
            extract_file_into_charon_dir "${IMPORT_FILE}"
            rm -f "${IMPORT_FILE}"
            empty_lodestar_keys
            echo "${INFO} Import file processing complete."
        else
            echo "${INFO} No files to import."
        fi
    else
        echo "${INFO} IMPORT_DIR is not set or does not exist. No import process to be performed."
    fi
}

function enable_restart_on_artifact_upload() {
    echo "${INFO} Enabling restart on artifact upload in ${IMPORT_DIR}"

    # Monitor the IMPORT_DIR for new files and restart the charon process if a new file is detected
    (inotifywait -m -q -e close_write --format '%f' "${IMPORT_DIR}" | while read -r filename; do
        echo "${INFO} Detected new file: ${filename}"

        # Check if the new file matches the expected patterns
        if [[ "${filename}" =~ \.zip$|\.tar\.gz$|\.tar\.xz$ ]]; then
            echo "${INFO} Artifact ${filename} uploaded, triggering container restart..."
            # Forcefully terminate the charon process to trigger a container restart
            local main_pid

            main_pid=$(pidof charon)

            # If main_pid is empty, container is kept running by sleep command
            if [ -z "$main_pid" ]; then
                main_pid=$(pidof sleep)
            fi

            echo "${INFO} Sending charon process with PID ${CHARON_PID} signal SIGKILL..."
            kill -s SIGKILL "${main_pid}"
        fi
    done) &
}

function get_beacon_node_endpoint() {

    if [ -n "$CUSTOM_BEACON_NODE_URLS" ]; then
        export CHARON_BEACON_NODE_ENDPOINTS=$CUSTOM_BEACON_NODE_URLS
        echo "Using external beacon node endpoint: $CUSTOM_BEACON_NODE_URLS"
        return
    fi

    case "$_DAPPNODE_GLOBAL_CONSENSUS_CLIENT_MAINNET" in
    "prysm.dnp.dappnode.eth")
        export CHARON_BEACON_NODE_ENDPOINTS="http://beacon-chain.prysm.dappnode:3500"
        ;;
    "teku.dnp.dappnode.eth")
        export CHARON_BEACON_NODE_ENDPOINTS="http://beacon-chain.teku.dappnode:3500"
        ;;
    "lighthouse.dnp.dappnode.eth")
        export CHARON_BEACON_NODE_ENDPOINTS="http://beacon-chain.lighthouse.dappnode:3500"
        ;;
    "nimbus.dnp.dappnode.eth")
        export CHARON_BEACON_NODE_ENDPOINTS="http://beacon-validator.nimbus.dappnode:4500"
        ;;
    "lodestar.dnp.dappnode.eth")
        export CHARON_BEACON_NODE_ENDPOINTS="http://beacon-chain.lodestar.dappnode:3500"
        ;;
    *)
        echo "${ERROR} Unknown value for _DAPPNODE_GLOBAL_CONSENSUS_CLIENT_HOLESKY: $_DAPPNODE_GLOBAL_CONSENSUS_CLIENT_HOLESKY"
        echo "${ERROR} Please set a full node for network ${NETWORK} in the Stakers tab or input a custom beacon node URL in this package config."
        ;;
    esac
}

# Get the ENR of the node or create it if it does not exist
function get_ENR() {
    # Check if ENR file exists and create it if it does not
    if [[ ! -f "$ENR_PRIVATE_KEY_FILE" ]]; then
        echo "${INFO} ENR does not exist, creating it..."
        if ! charon create enr --data-dir=${CHARON_ROOT_DIR} | tee ${CREATE_ENR_FILE}; then
            echo "${ERROR} Failed to create ENR."
            exit 1
        fi
    fi

    echo "${INFO} Storing ENR to file..."
    ENR=$(charon enr --data-dir=${CHARON_ROOT_DIR})
    echo "[INFO] ENR: ${ENR}"
    echo "${ENR}" >$ENR_FILE

    echo "${INFO} Publishing ENR to dappmanager..."
    post_ENR_to_dappmanager
}

# function to be post the ENR to dappmanager
function post_ENR_to_dappmanager() {
    # Post ENR to dappmanager
    curl --connect-timeout 5 \
        --max-time 10 \
        --silent \
        --retry 5 \
        --retry-delay 0 \
        --retry-max-time 40 \
        -X POST "http://my.dappnode/data-send?key=ENR%20Cluster%20${CLUSTER_ID}&data=${ENR}" ||
        {
            echo "[ERROR] failed to post ENR to dappmanager"
        }
}

function check_DKG() {
    # If the definition file URL is set and the lock file does not exist, start DKG ceremony
    if [ -n "${DEFINITION_FILE_URL}" ] && [ ! -f "${CHARON_LOCK_FILE}" ]; then
        echo "${INFO} Waiting for DKG ceremony..."
        charon dkg --definition-file="${DEFINITION_FILE_URL}" --data-dir="${CHARON_ROOT_DIR}" || {
            echo "${ERROR} DKG ceremony failed"
            exit 1
        }

    # If the definition file URL is not set and the lock file does not exist, wait for the definition file URL to be set
    elif [ -z "${DEFINITION_FILE_URL}" ] && [ ! -f "${CHARON_LOCK_FILE}" ]; then
        echo "${INFO} Set the definition file URL in the Charon config to start DKG ceremony..."
        sleep 1h # To let the user restore a backup
        exit 0

    else
        echo "${INFO} DKG ceremony already done. Process can continue..."
    fi
}

function run_charon() {
    # Start charon in a subshell in the background
    (
        exec charon run --private-key-file=$ENR_PRIVATE_KEY_FILE --lock-file=$CHARON_LOCK_FILE ${CHARON_EXTRA_OPTS}
    ) &
    CHARON_PID=$!
}

function import_keystores_to_lodestar() {

    VALIDATOR_CLIENT_KEYS_DIR=${VALIDATOR_DATA_DIR}/keystores

    for f in "${VALIDATOR_KEYS_DIR}"/keystore-*.json; do

        # Read the JSON and get the pubkey field
        pubkey=$(jq -r '.pubkey' "${f}")

        # Check if the keystore is already imported
        if [[ -d "${VALIDATOR_CLIENT_KEYS_DIR}/0x${pubkey}" ]]; then
            echo "Keystore for pubkey ${pubkey} already imported"

        else
            echo "Importing key ${f}"

            # Import keystore with password.
            ${VALIDATOR_SERVICE_BIN} \
                --dataDir="${VALIDATOR_DATA_DIR}" \
                validator import \
                --network="${NETWORK}" \
                --importKeystores="${f}" \
                --importKeystoresPassword="${f//json/txt}"
        fi
    done
}

function sign_exit() {

    if [ "$SIGN_EXIT" != true ]; then
        echo "${INFO} Signing exit is disabled. Skipping..."
        return
    fi

    # Validate exit epoch
    if [ -n "$EXIT_EPOCH" ]; then

        if [[ "$EXIT_EPOCH" =~ ^[0-9]+$ ]] && [ "$EXIT_EPOCH" -ge 1 ]; then
            echo "${INFO} Signing exit with EXIT_EPOCH=${EXIT_EPOCH}"
        else
            echo "${ERROR} EXIT_EPOCH is not valid. It must be a positive integer."
            return
        fi

    else
        echo "${INFO} Signing exit without EXIT_EPOCH"
    fi

    sign_exit_lodestar
}

function sign_exit_lodestar() {

    local flags="validator \
        voluntary-exit \
        --beaconNodes=http://localhost:3600 \
        --dataDir=${VALIDATOR_DATA_DIR} \
        --network=${NETWORK} \
        --yes"

    if [ -n "$EXIT_EPOCH" ]; then
        flags="${flags} --exitEpoch=${EXIT_EPOCH}"
    fi

    # shellcheck disable=SC2086
    ${VALIDATOR_SERVICE_BIN} ${flags}
}

function run_lodestar() {

    local flags="validator \
        --network=${NETWORK} \
        --dataDir=${VALIDATOR_DATA_DIR} \
        --beaconNodes=http://localhost:3600 \
        --metrics=true \
        --metrics.address=0.0.0.0 \
        --metrics.port=${VALIDATOR_METRICS_PORT} \
        --graffiti=${GRAFFITI} \
        --suggestedFeeRecipient=${DEFAULT_FEE_RECIPIENT} \
        --distributed"

    if [ -n "$VALIDATOR_EXTRA_OPTS" ]; then
        flags="${flags} ${VALIDATOR_EXTRA_OPTS}"
    fi

    (
        # shellcheck disable=SC2086
        exec ${VALIDATOR_SERVICE_BIN} ${flags}
    ) &
    VALIDATOR_CLIENT_PID=$!
}

########
# MAIN #
########

echo "${INFO} Checking if there are charon settings to import..."
handle_charon_file_import

echo "${INFO} Enabling restart on artifact upload..."
enable_restart_on_artifact_upload

echo "${INFO} Getting the current beacon chain in use..."
get_beacon_node_endpoint

echo "${INFO} Getting the ENR..."
get_ENR

echo "${INFO} Checking for DKG ceremony..."
check_DKG

echo "${INFO} Starting charon..."
run_charon

echo "${INFO} Importing keystores to lodestar validator service..."
import_keystores_to_lodestar

echo "${INFO} Signing exit..."
sign_exit

echo "${INFO} Starting lodestar validator service..."
run_lodestar

# This wait will exit as soon as any of the background processes exits
wait -n

# Check which process has exited and exit the other one
if ! kill -0 $CHARON_PID 2>/dev/null; then
    echo "${INFO} Charon process has exited. Exiting validator client..."
    kill -SIGTERM $VALIDATOR_CLIENT_PID 2>/dev/null
elif ! kill -0 $VALIDATOR_CLIENT_PID 2>/dev/null; then
    echo "${INFO} Validator client process has exited. Exiting charon..."
    kill -SIGTERM $CHARON_PID 2>/dev/null
fi

echo "${INFO} All processes stopped. Exiting..."
