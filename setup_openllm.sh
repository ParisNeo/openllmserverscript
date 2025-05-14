#!/bin/bash

# Exit on error, treat unset variables as an error, and prevent errors in pipelines from being hidden.
set -euo pipefail

# --- Configuration ---
SERVICE_USER="openllm"
DATA_GROUP="openllm_data"
DEFAULT_MODEL_DIR="/opt/openllm_models"
PYTHON_CMD="python3"
PIP_CMD="pip3"
START_PORT=3000

# --- Helper Functions ---
log() {
    echo "[INFO] $1"
}

warn() {
    echo "[WARN] $1"
}

error() {
    echo "[ERROR] $1" >&2
    exit 1
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        error "$1 could not be found. Please install it."
    fi
}

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        error "This script must be run as root or with sudo."
    fi
}

# --- Main Script ---
check_root

# 1. Get Model Directory
read -r -p "Enter the directory for OpenLLM models (default: ${DEFAULT_MODEL_DIR}): " MODEL_DIR
MODEL_DIR="${MODEL_DIR:-${DEFAULT_MODEL_DIR}}"
log "Using model directory: ${MODEL_DIR}"

SUDO_INVOKING_USER="${SUDO_USER:-$(whoami)}"

# 2. Create User and Group
log "Setting up user '${SERVICE_USER}' and group '${DATA_GROUP}'..."
if ! getent group "${DATA_GROUP}" > /dev/null; then
    groupadd --system "${DATA_GROUP}"
    log "Group '${DATA_GROUP}' created."
else
    log "Group '${DATA_GROUP}' already exists."
fi

if ! id -u "${SERVICE_USER}" > /dev/null 2>&1; then
    useradd --system --gid "${DATA_GROUP}" --home-dir "${MODEL_DIR}" --create-home \
            --shell /bin/bash "${SERVICE_USER}"
    log "User '${SERVICE_USER}' created with home directory ${MODEL_DIR}."
else
    log "User '${SERVICE_USER}' already exists."
    usermod -d "${MODEL_DIR}" "${SERVICE_USER}"
    usermod -a -G "${DATA_GROUP}" "${SERVICE_USER}"
    log "Ensured '${SERVICE_USER}' home is ${MODEL_DIR} and is in group '${DATA_GROUP}'."
fi

# 3. Setup Model Directory and Permissions
log "Setting up model directory: ${MODEL_DIR}"
mkdir -p "${MODEL_DIR}"
chown "${SERVICE_USER}:${DATA_GROUP}" "${MODEL_DIR}"
chmod 770 "${MODEL_DIR}"

log "Adding user '${SUDO_INVOKING_USER}' to group '${DATA_GROUP}' for access to ${MODEL_DIR}."
usermod -aG "${DATA_GROUP}" "${SUDO_INVOKING_USER}"
log "You may need to log out and log back in for group changes for '${SUDO_INVOKING_USER}' to take effect."

# 4. Install Dependencies
log "Checking and installing dependencies (python3-venv, python3-pip)..."
if ! dpkg -s python3-venv > /dev/null 2>&1 || ! dpkg -s python3-pip > /dev/null 2>&1; then
    apt-get update
    apt-get install -y python3-venv python3-pip
else
    log "Python venv and pip seem to be installed."
fi
check_command "${PYTHON_CMD}"
check_command "${PIP_CMD}"

# 5. Create Virtual Environment
VENV_PATH="${MODEL_DIR}/.venv"
log "Creating Python virtual environment at ${VENV_PATH}..."
if [ ! -d "${VENV_PATH}" ]; then
    "${PYTHON_CMD}" -m venv "${VENV_PATH}"
    chown -R "${SERVICE_USER}:${DATA_GROUP}" "${VENV_PATH}"
    log "Virtual environment created."
else
    log "Virtual environment already exists at ${VENV_PATH}."
    chown -R "${SERVICE_USER}:${DATA_GROUP}" "${VENV_PATH}"
fi

# 6. Install OpenLLM in Virtual Environment as SERVICE_USER
log "Installing OpenLLM into the virtual environment as user '${SERVICE_USER}'..."
sudo -u "${SERVICE_USER}" -H bash -c "
    set -e
    export PATH=\"${VENV_PATH}/bin:\$PATH\"
    export OPENLLM_HOME=\"${MODEL_DIR}\"
    echo 'Upgrading pip...'
    \"${VENV_PATH}/bin/pip\" install --upgrade pip
    echo 'Installing openllm...'
    \"${VENV_PATH}/bin/pip\" install openllm
    echo 'OpenLLM installation complete.'
"
if [ $? -ne 0 ]; then # This checks the exit status of the sudo command
    error "Failed to install OpenLLM as user '${SERVICE_USER}'."
fi
log "OpenLLM installed successfully in ${VENV_PATH}."

OPENLLM_EXEC="${VENV_PATH}/bin/openllm"
SELECTED_TARGETS_ARRAY=() # Stores targets to start (local paths or Hub IDs)

# 7. Handle Local Models (Optional)
log "--- Local Model Setup ---"
read -r -p "Do you want to set up and serve local model files? (y/N): " SETUP_LOCAL_CHOICE
SETUP_LOCAL_CHOICE=$(echo "${SETUP_LOCAL_CHOICE}" | tr '[:upper:]' '[:lower:]')

if [[ "${SETUP_LOCAL_CHOICE}" == "y" || "${SETUP_LOCAL_CHOICE}" == "yes" ]]; then
    while true; do # This is the start of the while loop
        echo ""
        log "Setting up a local model..."
        read -r -p "Enter a unique Service ID for this local model (e.g., my-local-llama-7b): " LOCAL_SERVICE_ID
        if [ -z "$LOCAL_SERVICE_ID" ]; then
            warn "Service ID cannot be empty."
            continue
        fi

        ALREADY_EXISTS=0
        for existing_target_info_str in "${SELECTED_TARGETS_ARRAY[@]}"; do
            # Extract service ID from stored string (assuming format type:service_id:path:backend)
            existing_service_id=$(echo "$existing_target_info_str" | cut -d':' -f2)
            if [[ "$existing_service_id" == "$LOCAL_SERVICE_ID" ]]; then
                warn "Service ID '$LOCAL_SERVICE_ID' is already in use. Please choose a different one."
                ALREADY_EXISTS=1
                break
            fi
        done # Done for the inner for loop
        if [[ "$ALREADY_EXISTS" -eq 1 ]]; then
            continue
        fi

        read -r -p "Enter the full path to your local model file (e.g., /path/to/model.gguf) or directory: " LOCAL_MODEL_PATH
        if [ ! -e "$LOCAL_MODEL_PATH" ]; then
            warn "Path '$LOCAL_MODEL_PATH' does not exist."
            continue
        fi

        if ! sudo -u "${SERVICE_USER}" test -r "${LOCAL_MODEL_PATH}"; then
            warn "User '${SERVICE_USER}' may not have read access to '${LOCAL_MODEL_PATH}'."
            warn "Please ensure permissions are set correctly for '${LOCAL_MODEL_PATH}' before the service starts."
            # continue # Decide if this should be a hard stop
        fi

        MODEL_TYPE_FOR_START_LOGIC="local_hfdir"
        OPENLLM_START_MODEL_ARG="--model-id \"${LOCAL_MODEL_PATH}\"" # Default for HF directory

        read -r -p "Is this a single GGUF model file? (y/N): " IS_GGUF
        IS_GGUF_LOWER=$(echo "${IS_GGUF}" | tr '[:upper:]' '[:lower:]') # Use a different var for lower
        if [[ "${IS_GGUF_LOWER}" == "y" || "${IS_GGUF_LOWER}" == "yes" ]]; then
            if [[ ! -f "$LOCAL_MODEL_PATH" ]]; then
                warn "'$LOCAL_MODEL_PATH' is not a file. Expected a GGUF file."
                continue
            fi
            MODEL_TYPE_FOR_START_LOGIC="local_gguf"
            # For GGUF, OpenLLM expects: openllm start <runner_usually_ctransformers> --model-id /path/to/file.gguf
            OPENLLM_START_MODEL_ARG="ctransformers --model-id \"${LOCAL_MODEL_PATH}\""
            log "GGUF model selected. Will use 'ctransformers' runner with the specified model path."
        else
            if [[ ! -d "$LOCAL_MODEL_PATH" ]]; then
                warn "'$LOCAL_MODEL_PATH' is not a directory. Expected a HuggingFace model directory."
                continue
            fi
            log "HuggingFace model directory selected. OpenLLM will attempt auto-detection using the model path."
        fi

        # Store: type_for_logic : service_id_for_naming : openllm_start_model_argument_string
        SELECTED_TARGETS_ARRAY+=("${MODEL_TYPE_FOR_START_LOGIC}:${LOCAL_SERVICE_ID}:${OPENLLM_START_MODEL_ARG}")
        log "Local model '${LOCAL_SERVICE_ID}' from path '${LOCAL_MODEL_PATH}' added for service creation."

        read -r -p "Add another local model? (y/N): " ADD_ANOTHER_LOCAL
        ADD_ANOTHER_LOCAL_LOWER=$(echo "${ADD_ANOTHER_LOCAL}" | tr '[:upper:]' '[:lower:]') # Use a different var
        if [[ "${ADD_ANOTHER_LOCAL_LOWER}" != "y" && "${ADD_ANOTHER_LOCAL_LOWER}" != "yes" ]]; then
            break # Exit the while true loop
        fi
    done # This is the 'done' for the 'while true' loop
fi # This is the 'fi' for the 'if [[ "${SETUP_LOCAL_CHOICE}" ... ]]'

# 8. List and Select Models from Hugging Face Hub (Optional)
log "--- Hugging Face Hub Model Selection ---"
read -r -p "Do you want to list and select models from Hugging Face Hub to install? (y/N): " FETCH_HUB_MODELS_CHOICE
FETCH_HUB_MODELS_CHOICE_LOWER=$(echo "${FETCH_HUB_MODELS_CHOICE}" | tr '[:upper:]' '[:lower:]')

if [[ "${FETCH_HUB_MODELS_CHOICE_LOWER}" == "y" || "${FETCH_HUB_MODELS_CHOICE_LOWER}" == "yes" ]]; then
    log "Fetching list of available OpenLLM models from Hub..."
    AVAILABLE_MODELS_OUTPUT=$(sudo -u "${SERVICE_USER}" -H bash -c "
        export PATH=\"${VENV_PATH}/bin:\$PATH\"
        export OPENLLM_HOME=\"${MODEL_DIR}\"
        \"${OPENLLM_EXEC}\" models --show-available --quiet --output json
    ")

    HUB_MODELS_LIST=()
    if [ -z "$AVAILABLE_MODELS_OUTPUT" ]; then
        warn "Could not fetch available models from Hub. Maybe there's no network or OpenLLM has an issue."
    else
        if command -v jq &> /dev/null; then
            mapfile -t HUB_MODELS_LIST < <(echo "$AVAILABLE_MODELS_OUTPUT" | jq -r '.[]')
        else
            warn "jq not found. Parsing model list with basic tools. May not be perfect for complex names."
            mapfile -t HUB_MODELS_LIST < <(echo "$AVAILABLE_MODELS_OUTPUT" | tr -s '[:space:],[]"' '\n' | grep -vE '^\s*$' | awk 'NF')
        fi
    fi

    if [ ${#HUB_MODELS_LIST[@]} -eq 0 ]; then
        warn "No models found on Hub or failed to parse."
    else
        log "Available models from Hub:"
        for model_id in "${HUB_MODELS_LIST[@]}"; do
            echo "  - ${model_id}"
        done
        echo ""
        read -r -p "Enter Hub model IDs to install and run, separated by spaces (e.g., opt llama): " SELECTED_HUB_MODELS_INPUT
        IFS=' ' read -r -a SELECTED_HUB_MODELS_ARRAY_TEMP <<< "${SELECTED_HUB_MODELS_INPUT}"
        for hub_model_id_raw in "${SELECTED_HUB_MODELS_ARRAY_TEMP[@]}"; do
            if [[ -n "$hub_model_id_raw" ]]; then
                # Ensure service ID uniqueness for Hub models too
                HUB_SERVICE_ID_BASE=$(echo "${hub_model_id_raw}" | tr '/' '-') # Basic sanitization for temp ID
                temp_hub_service_id="${HUB_SERVICE_ID_BASE}"
                counter=1
                ALREADY_EXISTS=0
                while true; do
                    ALREADY_EXISTS=0
                    for existing_target_info_str in "${SELECTED_TARGETS_ARRAY[@]}"; do
                        existing_service_id=$(echo "$existing_target_info_str" | cut -d':' -f2)
                        if [[ "$existing_service_id" == "$temp_hub_service_id" ]]; then
                            ALREADY_EXISTS=1
                            break
                        fi
                    done
                    if [[ "$ALREADY_EXISTS" -eq 0 ]]; then
                        break # Unique ID found
                    fi
                    temp_hub_service_id="${HUB_SERVICE_ID_BASE}-${counter}"
                    counter=$((counter + 1))
                done
                
                # Store: type_for_logic : service_id_for_naming : openllm_start_model_argument_string
                SELECTED_TARGETS_ARRAY+=("hub:${temp_hub_service_id}:\"${hub_model_id_raw}\"")
                log "Hub model '${hub_model_id_raw}' (Service ID: ${temp_hub_service_id}) added for service creation."
            fi
        done
    fi
fi

# 9. Create and Start Services for ALL selected targets
if [ ${#SELECTED_TARGETS_ARRAY[@]} -eq 0 ]; then
    log "No models (neither local nor Hub) selected to run as services. Script will exit."
    exit 0
fi

log "--- Creating and Starting Services ---"
CURRENT_PORT=$START_PORT

for target_info_str in "${SELECTED_TARGETS_ARRAY[@]}"; do
    # Stored format: type_for_logic:service_id_for_naming:openllm_start_model_argument_string
    # Example local GGUF: local_gguf:my-local-model:ctransformers --model-id "/path/to/model.gguf"
    # Example local HFDir: local_hfdir:my-other-model:--model-id "/path/to/dir"
    # Example Hub: hub:Mistral-7B-Instruct:"MistralAi/Mistral-7B-Instruct-v0.1"

    target_type=$(echo "$target_info_str" | cut -d':' -f1)
    service_id_for_naming=$(echo "$target_info_str" | cut -d':' -f2)
    # The rest of the string is the model argument for openllm start
    openllm_model_arg_string=$(echo "$target_info_str" | cut -d':' -f3-)
    
    log "Processing target: Type='${target_type}', ServiceID='${service_id_for_naming}', OpenLLM Arg='${openllm_model_arg_string}'"

    # Sanitize the service_id_for_naming to create the actual service file name
    sanitized_service_name_base=$(echo "${service_id_for_naming}" | tr '/' '-' | tr -cd '[:alnum:]._-')
    service_name="openllm-${sanitized_service_name_base}.service"
    service_file="/etc/systemd/system/${service_name}"

    log "Creating systemd service file: ${service_file} for '${service_id_for_naming}' on port ${CURRENT_PORT}"

    EXEC_START_CMD="${OPENLLM_EXEC} start ${openllm_model_arg_string} --port ${CURRENT_PORT}"
    # One could add --working-dir "${MODEL_DIR}" if openllm start needs it, but OPENLLM_HOME should suffice.
    # Add other common flags if needed: e.g. --workers 1

    cat << EOF > "${service_file}"
[Unit]
Description=OpenLLM Server for ${service_id_for_naming}
After=network.target

[Service]
User=${SERVICE_USER}
Group=${DATA_GROUP}
WorkingDirectory=${MODEL_DIR}
Environment="OPENLLM_HOME=${MODEL_DIR}"
Environment="PATH=${VENV_PATH}/bin:/usr/bin:/bin"
Environment="TRANSFORMERS_OFFLINE=1"
Environment="HF_HUB_OFFLINE=1"
# If you use models requiring specific CUDA visibility
# Environment="CUDA_VISIBLE_DEVICES=0"

ExecStart=${EXEC_START_CMD}

Restart=always
RestartSec=10
Type=simple

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "${service_file}"
    systemctl daemon-reload
    systemctl enable "${service_name}"

    log "Attempting to start service ${service_name}..."
    if systemctl start "${service_name}"; then
        log "Service ${service_name} started successfully for '${service_id_for_naming}' on port ${CURRENT_PORT}."
        if [[ "${target_type}" == "hub" ]]; then
            log "If this is a Hub model being downloaded for the first time, it might take a while to become ready."
        fi
        log "Check status with: systemctl status ${service_name}"
        log "Check logs with: journalctl -u ${service_name} -f"
    else
        warn "Service ${service_name} FAILED to start. Please check the logs:"
        warn "journalctl -u ${service_name} --no-pager -n 50"
        warn "systemctl status ${service_name}"
    fi
    
    CURRENT_PORT=$((CURRENT_PORT + 1))
    echo "" # Newline for better readability
done

log "--- OpenLLM Server Setup Complete ---"
log "Model directory: ${MODEL_DIR}"
log "Virtual environment: ${VENV_PATH}"
log "Make sure user '${SUDO_INVOKING_USER}' logs out and back in if they need to manage files in ${MODEL_DIR} directly."
log "Installed services can be managed with systemctl (status, stop, start, restart)."
log "For example, to check all openllm services: systemctl list-units 'openllm-*.service'"
log "If you used local models, ensure the '${SERVICE_USER}' user has persistent read access to their original paths."

exit 0
