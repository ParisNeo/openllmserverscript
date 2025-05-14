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

# Ensure the script runner (sudo user) is captured for group addition
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
if [ $? -ne 0 ]; then
    error "Failed to install OpenLLM as user '${SERVICE_USER}'."
fi
log "OpenLLM installed successfully in ${VENV_PATH}."

OPENLLM_EXEC="${VENV_PATH}/bin/openllm"
SELECTED_MODELS_ARRAY=() # Initialize array to hold all selected models

# 7. Import Local Models (Optional)
log "--- Local Model Import ---"
read -r -p "Do you want to import and serve local model files? (y/N): " IMPORT_LOCAL_CHOICE
IMPORT_LOCAL_CHOICE=$(echo "${IMPORT_LOCAL_CHOICE}" | tr '[:upper:]' '[:lower:]')

if [[ "${IMPORT_LOCAL_CHOICE}" == "y" || "${IMPORT_LOCAL_CHOICE}" == "yes" ]]; then
    while true; do
        log "Importing a local model..."
        read -r -p "Enter a custom Model ID for OpenLLM (e.g., my-local-llama-7b): " LOCAL_MODEL_ID
        if [ -z "$LOCAL_MODEL_ID" ]; then
            warn "Model ID cannot be empty."
            continue
        fi

        read -r -p "Enter the full path to your model file (e.g., /path/to/model.gguf) or directory: " LOCAL_MODEL_PATH
        if [ ! -e "$LOCAL_MODEL_PATH" ]; then
            warn "Path '$LOCAL_MODEL_PATH' does not exist."
            continue
        fi

        MODEL_TYPE_ARG=""
        read -r -p "Is this a GGUF model file? (y/N): " IS_GGUF
        IS_GGUF=$(echo "${IS_GGUF}" | tr '[:upper:]' '[:lower:]')
        if [[ "${IS_GGUF}" == "y" || "${IS_GGUF}" == "yes" ]]; then
            MODEL_TYPE_ARG="--model-type ctransformers"
            log "GGUF model selected. Will use --model-type ctransformers."
        else
            read -r -p "Optional: Specify HuggingFace model type (e.g., llama, mistral, or leave blank for auto-detection from config.json): " SPECIFIC_MODEL_TYPE
            if [ -n "$SPECIFIC_MODEL_TYPE" ]; then
                MODEL_TYPE_ARG="--model-type ${SPECIFIC_MODEL_TYPE}"
            fi
        fi

        log "Attempting to import '${LOCAL_MODEL_ID}' from '${LOCAL_MODEL_PATH}'..."
        IMPORT_CMD="export PATH=\"${VENV_PATH}/bin:\$PATH\"; \
                    export OPENLLM_HOME=\"${MODEL_DIR}\"; \
                    export TRANSFORMERS_OFFLINE=1; \
                    export HF_HUB_OFFLINE=1; \
                    \"${OPENLLM_EXEC}\" import \"${LOCAL_MODEL_ID}\" \"${LOCAL_MODEL_PATH}\" ${MODEL_TYPE_ARG}"

        if sudo -u "${SERVICE_USER}" -H bash -c "${IMPORT_CMD}"; then
            log "Model '${LOCAL_MODEL_ID}' imported successfully."
            SELECTED_MODELS_ARRAY+=("${LOCAL_MODEL_ID}")
        else
            warn "Failed to import model '${LOCAL_MODEL_ID}'. Check the path, model type, and permissions."
            warn "Make sure the '${SERVICE_USER}' user has read access to '${LOCAL_MODEL_PATH}'."
        fi

        read -r -p "Import another local model? (y/N): " IMPORT_ANOTHER
        IMPORT_ANOTHER=$(echo "${IMPORT_ANOTHER}" | tr '[:upper:]' '[:lower:]')
        if [[ "${IMPORT_ANOTHER}" != "y" && "${IMPORT_ANOTHER}" != "yes" ]]; then
            break
        fi
        echo "" # Newline for readability
    done
fi

# 8. List and Select Models from Hugging Face Hub (Optional)
log "--- Hugging Face Hub Model Selection ---"
read -r -p "Do you want to list and select models from Hugging Face Hub to install? (y/N): " FETCH_HUB_MODELS_CHOICE
FETCH_HUB_MODELS_CHOICE=$(echo "${FETCH_HUB_MODELS_CHOICE}" | tr '[:upper:]' '[:lower:]')

if [[ "${FETCH_HUB_MODELS_CHOICE}" == "y" || "${FETCH_HUB_MODELS_CHOICE}" == "yes" ]]; then
    log "Fetching list of available OpenLLM models from Hub..."
    # Note: Set HF_TOKEN in environment if you need to access gated models from Hub
    # export HF_TOKEN="your_token" # This should be done by the user in their shell, not hardcoded
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
            mapfile -t HUB_MODELS_LIST < <(echo "$AVAILABLE_MODELS_OUTPUT" | tr -s ' ' '\n' | grep -vE '^\s*\[|\]\s*$|^\s*,$' | sed 's/["',]//g' | awk 'NF')
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
        IFS=' ' read -r -a SELECTED_HUB_MODELS_ARRAY <<< "${SELECTED_HUB_MODELS_INPUT}"
        for hub_model in "${SELECTED_HUB_MODELS_ARRAY[@]}"; do
            if [[ -n "$hub_model" ]]; then # Ensure not empty
                SELECTED_MODELS_ARRAY+=("${hub_model}")
            fi
        done
    fi
fi

# 9. Create and Start Services for ALL selected models
if [ ${#SELECTED_MODELS_ARRAY[@]} -eq 0 ]; then
    log "No models (neither local nor Hub) selected to run as services. Script will exit."
    log "You can manually import models using: sudo -u ${SERVICE_USER} -H OPENLLM_HOME=${MODEL_DIR} ${OPENLLM_EXEC} import <id> <path>"
    log "And start them using: sudo -u ${SERVICE_USER} -H OPENLLM_HOME=${MODEL_DIR} ${OPENLLM_EXEC} start <model_id>"
    exit 0
fi

log "--- Creating and Starting Services ---"
CURRENT_PORT=$START_PORT
# Deduplicate SELECTED_MODELS_ARRAY in case a local ID matched a hub ID
UNIQUE_SELECTED_MODELS_ARRAY=($(echo "${SELECTED_MODELS_ARRAY[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

for model_id_for_service in "${UNIQUE_SELECTED_MODELS_ARRAY[@]}"; do
    log "Processing model: ${model_id_for_service}"

    # Sanitize model_id for service name (replace / with -, remove other unsafe chars)
    sanitized_model_name=$(echo "${model_id_for_service}" | tr '/' '-' | tr -cd '[:alnum:]._-')
    service_name="openllm-${sanitized_model_name}.service"
    service_file="/etc/systemd/system/${service_name}"

    log "Creating systemd service file: ${service_file} for model ${model_id_for_service} on port ${CURRENT_PORT}"

    cat << EOF > "${service_file}"
[Unit]
Description=OpenLLM Server for ${model_id_for_service}
After=network.target

[Service]
User=${SERVICE_USER}
Group=${DATA_GROUP}
WorkingDirectory=${MODEL_DIR}
Environment="OPENLLM_HOME=${MODEL_DIR}"
Environment="PATH=${VENV_PATH}/bin:/usr/bin:/bin"
Environment="TRANSFORMERS_OFFLINE=1"
Environment="HF_HUB_OFFLINE=1"
# If you use models requiring specific CUDA visibility (e.g., with bitsandbytes or multi-GPU)
# Environment="CUDA_VISIBLE_DEVICES=0" # Example: use first GPU

# The 'openllm start' command will download the model if it's a Hub ID and not already present.
# For imported local models, it will use the existing files.
ExecStart=${OPENLLM_EXEC} start ${model_id_for_service} --port ${CURRENT_PORT}
# Add other 'openllm start' flags if needed, e.g.:
# ExecStart=${OPENLLM_EXEC} start ${model_id_for_service} --port ${CURRENT_PORT} --workers 1 --model-version <sha_if_needed>

Restart=always
RestartSec=10 # Increased restart delay
Type=simple   # Default, but explicit

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "${service_file}"
    systemctl daemon-reload
    systemctl enable "${service_name}"

    log "Attempting to start service ${service_name}..."
    if systemctl start "${service_name}"; then
        log "Service ${service_name} started successfully for model ${model_id_for_service} on port ${CURRENT_PORT}."
        log "If this is a Hub model being downloaded for the first time, it might take a while to become ready."
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
log "If you imported local models, ensure the '${SERVICE_USER}' user has persistent read access to their original paths if OpenLLM symlinks or only references them."

exit 0
