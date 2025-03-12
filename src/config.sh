#!/bin/bash

# Default configuration values (can be overridden by command-line arguments)
PORT_START=8090                       # Starting port for HTTP server
MAX_STREAMS=100                       # Maximum number of streams to test
TEST_DURATION=60                      # Duration of each test in seconds
OUTPUT_DIR="./logs"                   # Directory for temporary files
STREAM_LOG="${OUTPUT_DIR}/stream.log" # Log file for stream statistics
STREAM_ALL_LOG="${OUTPUT_DIR}/stream_all.log" # Persistent log file that accumulates across runs

# These variables will be populated during execution
VIDEO_RESOLUTION=""                   # Will be populated with video resolution
FRIENDLY_RESOLUTION=""                # Will be populated with friendly resolution name
VIDEO_CODEC=""                        # Will be populated with video codec

# Hardware acceleration variables
HW_ACCEL="auto"                       # Hardware acceleration method (default: auto-detect)
HW_ENCODER=""                         # Will be populated with the encoder to use
HW_DECODER=""                         # Will be populated with the decoder to use

# Variables to track disk stats - changed to IOPS
PREV_READ_IOPS=0
PREV_WRITE_IOPS=0