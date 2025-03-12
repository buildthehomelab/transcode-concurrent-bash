#!/bin/bash

# This script generates a SHA-256 unique identifier for the benchmark instance
# and stores it for future runs

# Get script directory for proper file paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
UID_FILE="${SCRIPT_DIR}/.uuid"
OUTPUT_DIR="./logs"

# Function to generate a new unique ID using timestamp and uuidgen
generate_unique_id() {
    # Simple method that combines current timestamp with UUID
    local raw_id=""
    
    # Get nanosecond timestamp if available, otherwise use seconds
    if date +%N &> /dev/null; then
        raw_id+="$(date +%s%N)"
    else
        raw_id+="$(date +%s)"
    fi
    
    # Add UUID if available
    if command -v uuidgen &> /dev/null; then
        raw_id+="$(uuidgen)"
    else
        # Fallback if uuidgen is not available
        raw_id+="$(date +%s)$(hostname)$$"
    fi
    
    # Generate SHA-256 hash
    local unique_id=""
    if command -v sha256sum &> /dev/null; then
        unique_id=$(echo -n "$raw_id" | sha256sum | cut -d' ' -f1)
    elif command -v shasum &> /dev/null; then
        unique_id=$(echo -n "$raw_id" | shasum -a 256 | cut -d' ' -f1)
    else
        # Fallback to OpenSSL if available
        if command -v openssl &> /dev/null; then
            unique_id=$(echo -n "$raw_id" | openssl dgst -sha256 | cut -d' ' -f2)
        else
            echo "ERROR: Unable to generate SHA-256 hash. Install sha256sum, shasum, or openssl." >&2
            unique_id="UNKNOWN-$(date +%s)"
        fi
    fi
    
    echo "$unique_id"
}

# Function to get existing or create new unique ID
get_or_create_unique_id() {
    # Create output directory if it doesn't exist
    mkdir -p "$OUTPUT_DIR"
    
    # Check if UID file already exists
    if [ -f "$UID_FILE" ]; then
        # Read existing UID
        local existing_uid=$(cat "$UID_FILE")
        echo "$existing_uid"
        return 0
    fi
    
    # Generate a new UID
    local new_uid=$(generate_unique_id)
    
    # Store the UID for future runs
    echo "$new_uid" > "$UID_FILE"
    
    echo "$new_uid"
}

# Main function - always runs when this script is sourced
UUID=$(get_or_create_unique_id)
export UUID

# Output UID if in debug mode
if [ "$DEBUG" = "1" ]; then
    echo "[DEBUG] Benchmark UUID: $UUID"
    echo "[DEBUG] UUID file location: $UID_FILE"
fi