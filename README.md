# OpenLLM Server Setup Script

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash Version](https://img.shields.io/badge/bash-%3E%3D4.x-blue.svg)](https://www.gnu.org/software/bash/)
[![Contributions Welcome](https://img.shields.io/badge/contributions-welcome-brightgreen.svg?style=flat)](https://github.com/ParisNeo/openllmserverscript/issues)
<!-- Optional: Add a badge for your latest release if you create tags/releases -->
<!-- [![Latest Release](https://img.shields.io/github/v/release/ParisNeo/openllmserverscript)](https://github.com/ParisNeo/openllmserverscript/releases) -->

This repository contains `setup_openllm.sh`, a Bash script designed to automate the installation and configuration of [OpenLLM](https://github.com/bentoml/OpenLLM) as a server on Debian/Ubuntu-based systems. It simplifies setting up multiple LLMs to run simultaneously, each as a dedicated systemd service.

The script supports:
*   Serving models downloaded from Hugging Face Hub.
*   Importing and serving your own local model files (GGUF or Hugging Face directory format).

## Features

*   **Dedicated User & Group:** Creates a system user `openllm` and group `openllm_data` for running services and managing models securely.
*   **Custom Model Directory:** Allows you to specify a directory for storing models and the Python virtual environment.
*   **Python Virtual Environment:** Isolates OpenLLM and its dependencies.
*   **Local Model Import:** Prompts to import local GGUF files or Hugging Face model directories.
*   **Hugging Face Hub Integration:** Lists available models from the Hub and allows selection for installation.
*   **Multiple Model Services:** Configures each selected model to run as a separate systemd service on a unique port (starting from 3000).
*   **Offline-First for Local Models:** Sets `TRANSFORMERS_OFFLINE=1` and `HF_HUB_OFFLINE=1` for services running local models to prevent unnecessary network calls.
*   **Permission Management:** Sets appropriate permissions for the model directory, granting access to the `openllm` user and the user who ran the script (via the `openllm_data` group).
*   **Dependency Installation:** Automatically installs `python3-venv` and `python3-pip` if not present (for Debian/Ubuntu).

## Prerequisites

*   A Debian/Ubuntu-based Linux system.
*   `sudo` or root privileges to run the script.
*   `curl` or `wget` to download the script (or clone the repository).
*   **Recommended:** `jq` for robust parsing of model lists from Hugging Face Hub (`sudo apt-get install jq`). The script has a basic fallback if `jq` is not found.
*   Sufficient disk space for models and Python environment.
*   Sufficient RAM/VRAM depending on the models you intend to run.

## Installation & Usage

1.  **Download the script:**
    ```bash
    curl -LO https://raw.githubusercontent.com/ParisNeo/openllmserverscript/main/setup_openllm.sh
    # OR using wget:
    # wget https://raw.githubusercontent.com/ParisNeo/openllmserverscript/main/setup_openllm.sh
    ```

2.  **Make it executable:**
    ```bash
    chmod +x setup_openllm.sh
    ```

3.  **Run the script with sudo:**
    ```bash
    sudo ./setup_openllm.sh
    ```

4.  **Follow the prompts:**
    *   **Model Directory:** You'll be asked to specify the directory where models and the OpenLLM virtual environment will be stored (default: `/opt/openllm_models`).
    *   **Import Local Models:** The script will ask if you want to import local models.
        *   If "yes", provide a custom ID for OpenLLM to refer to the model, the full path to the model file (e.g., `/path/to/model.gguf`) or directory, and specify if it's a GGUF model.
    *   **Hugging Face Hub Models:** The script will then ask if you want to list and select models from Hugging Face Hub.
        *   If "yes", a list of available models will be shown (if `jq` is installed, this list is more reliable). Enter the space-separated IDs of the models you wish to install (e.g., `mistralai/Mistral-7B-Instruct-v0.1 meta-llama/Llama-2-7b-chat-hf`).
        *   **Note:** For gated models on Hugging Face Hub, ensure you have logged in via `huggingface-cli login` or set the `HF_TOKEN` environment variable *before* running the script if you intend to download them. The script itself does not handle `HF_TOKEN` input.

5.  **Service Creation:**
    The script will create systemd service files (e.g., `openllm-your-model-id.service`) for each selected model in `/etc/systemd/system/`. It will then enable and attempt to start these services.

## Post-Installation

*   **Check Service Status:**
    ```bash
    systemctl status openllm-<your-sanitized-model-id>.service
    # To list all openllm services:
    systemctl list-units 'openllm-*.service'
    ```

*   **View Logs:**
    Model downloads (for Hub models) and initialization can take time. Monitor the logs:
    ```bash
    journalctl -u openllm-<your-sanitized-model-id>.service -f
    ```
    Replace `<your-sanitized-model-id>` with the model ID used in the service name (e.g., `openllm-mistralai-Mistral-7B-Instruct-v0.1.service`).

*   **Accessing Models:**
    Each model service will be running on a different port, starting from `3000` and incrementing (3001, 3002, etc.). You can typically access the OpenAI-compatible API at `http://localhost:<port>/v1/`.

*   **File Access Permissions:**
    The user who ran the `setup_openllm.sh` script (the `sudo` user) is added to the `openllm_data` group. This grants them read/write access to the model directory (e.g., `/opt/openllm_models`). You may need to **log out and log back in** for these group changes to take effect for your user.

*   **Local Model File Permissions:**
    If you imported local models, ensure the `openllm` user has persistent read access to their original paths, as OpenLLM might symlink or reference them. The imported model data itself (or symlinks) will be managed within the `OPENLLM_HOME` directory (your chosen model directory).

## Managing Services

You can use standard `systemctl` commands to manage the services:
*   `sudo systemctl stop openllm-<model-id>.service`
*   `sudo systemctl start openllm-<model-id>.service`
*   `sudo systemctl restart openllm-<model-id>.service`
*   `sudo systemctl enable openllm-<model-id>.service` (to start on boot)
*   `sudo systemctl disable openllm-<model-id>.service` (to prevent starting on boot)

## Configuration Details

*   **User:** `openllm`
*   **Group:** `openllm_data`
*   **Default Model Directory:** `/opt/openllm_models`
*   **Virtual Environment:** Located at `<MODEL_DIR>/.venv`
*   **OpenLLM Executable in venv:** `<MODEL_DIR>/.venv/bin/openllm`
*   **Environment Variables for Services:**
    *   `OPENLLM_HOME`: Set to your chosen model directory.
    *   `TRANSFORMERS_OFFLINE=1`: Ensures OpenLLM doesn't try to fetch from Hugging Face Hub unnecessarily.
    *   `HF_HUB_OFFLINE=1`: Similar to above, for Hugging Face Hub specific operations.

## Troubleshooting

*   **Service Fails to Start:** Check the logs (`journalctl -u <service-name>`) for errors. Common issues include:
    *   Port conflicts (another service using the assigned port).
    *   Insufficient RAM/VRAM.
    *   Incorrect model ID or model files.
    *   Permissions issues for local model paths.
    *   Missing `CUDA_VISIBLE_DEVICES` environment variable in the service file if you have multiple GPUs and the model requires a specific one (e.g., for `bitsandbytes`).
*   **`jq: command not found`:** The script will try to parse model lists without `jq`, but it's less reliable. Install `jq` for best results: `sudo apt-get install jq`.
*   **Access Denied to Model Directory:** If your user cannot access the model directory after running the script, ensure you have logged out and logged back in for group membership changes to apply.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request or open an Issue for any bugs, feature requests, or improvements.

1.  Fork the repository.
2.  Create your feature branch (`git checkout -b feature/AmazingFeature`).
3.  Commit your changes (`git commit -m 'Add some AmazingFeature'`).
4.  Push to the branch (`git push origin feature/AmazingFeature`).
5.  Open a Pull Request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details (you'll need to create this file if you haven't).
