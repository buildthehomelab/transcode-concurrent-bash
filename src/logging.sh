#!/bin/bash

# Function to display debug information
debug_log() {
    if [ "$DEBUG" = "1" ]; then
        echo "[DEBUG] $*"
    fi
}

# Function to display information
info_log() {
    # Always show INFO messages, but prefix only in debug mode
    if [ "$DEBUG" = "1" ]; then
        echo "[INFO] $*"
    else
        echo "$*"
    fi
}

# Function to display warning (always shown)
warn_log() {
    echo "[WARN] $*"
}

# Function to display error (always shown)
error_log() {
    echo "[ERROR] $*" >&2
}