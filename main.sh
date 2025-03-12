#!/bin/bash

# Main entry point script that sources all components and orchestrates the benchmark

# Source all component scripts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/src/config.sh"
source "${SCRIPT_DIR}/src/logging.sh"
source "${SCRIPT_DIR}/src/hw_accel.sh"
source "${SCRIPT_DIR}/src/video_info.sh"
source "${SCRIPT_DIR}/src/system_stats.sh"
source "${SCRIPT_DIR}/src/stream_manager.sh"
source "${SCRIPT_DIR}/src/uuid.sh"

# Video download and management functions
download_videos() {
    echo "Downloading test videos..."
    source "${SCRIPT_DIR}/src/download_manager.sh"
    download_videos
}

list_videos() {
    echo "Listing available videos..."
    source "${SCRIPT_DIR}/src/download_manager.sh"
    list_available_videos
}

check_video_path() {
    # If input file doesn't exist but videos directory does, try to resolve
    if [ ! -f "$INPUT_FILE" ]; then
        # Check if this is a filename without path
        if [ -d "videos" ] && [ -f "videos/$INPUT_FILE" ]; then
            echo "Found input file in videos directory"
            INPUT_FILE="videos/$INPUT_FILE"
            return 0
        fi
    fi
}

# Function to check input file exists and is a valid video
check_input_file() {
    if [ ! -f "$INPUT_FILE" ]; then
        error_log "Input file '$INPUT_FILE' does not exist."
        echo "Please provide a valid video file path."
        exit 1
    fi
    
    # Check if file is a valid video using ffprobe
    if command -v ffprobe &> /dev/null; then
        if ! ffprobe -v error -select_streams v:0 -show_entries stream=codec_type -of default=nw=1:nk=1 "$INPUT_FILE" 2>/dev/null | grep -q "video"; then
            error_log "File '$INPUT_FILE' does not appear to be a valid video file."
            exit 1
        fi
    else
        # If ffprobe is not available, just check file extension
        local ext="${INPUT_FILE##*.}"
        if [[ ! $ext =~ ^(mp4|mov|mkv|avi|webm|flv|wmv|ts)$ ]]; then
            warn_log "File extension .$ext not recognized as a common video format. Continuing anyway..."
        fi
    fi
    
    info_log "Input file check passed: $INPUT_FILE"
}

# Parse command line arguments
# Parse command line arguments
parse_arguments() {
    # Check for special commands first
    if [ "$1" = "--download-videos" ]; then
        download_videos
        exit 0
    elif [ "$1" = "--list-videos" ]; then
        list_videos
        exit 0
    fi

    # Check if input file is provided
    if [ -z "$1" ]; then
        error_log "Please provide an input file path."
        echo "Usage: $0 /path/to/videofile.mp4 [hw_accel_method] [debug] [test_duration]"
        echo "   or: $0 --download-videos     # Download test videos"
        echo "   or: $0 --list-videos        # List available test videos"
        echo ""
        echo "Available hw_accel methods: auto, videotoolbox, qsv, cuda, vaapi, none"
        echo "Debug mode: 0 (off) or 1 (on)"
        echo "Test duration: seconds per test (default: 60)"
        exit 1
    fi

    INPUT_FILE="$1"
    HW_ACCEL="${2:-auto}"
    DEBUG="${3:-0}"
    
    # Allow test duration to be specified as 4th parameter
    if [ -n "$4" ] && [ "$4" -gt 0 ]; then
        TEST_DURATION="$4"
        echo "Using custom test duration: $TEST_DURATION seconds"
    else
        # Increased default test duration for more reliable results
        TEST_DURATION=60
        echo "Using default test duration: $TEST_DURATION seconds"
    fi

    # Try to find the file in the videos directory if it doesn't exist
    check_video_path

    # Check if input file exists
    if [ ! -f "$INPUT_FILE" ]; then
        error_log "Input file '$INPUT_FILE' does not exist."
        echo "You can download test videos with: $0 --download-videos"
        echo "Or list available videos with: $0 --list-videos"
        exit 1
    fi

    # Do not redirect stderr completely, only reduce FFmpeg verbosity
    if [ "$DEBUG" != "1" ]; then
        export FFMPEG_LOGLEVEL="warning"
    else
        export FFMPEG_LOGLEVEL="info"
    fi
}

prepare_videos() {
  # We need to ensure we have the download_manager.sh available
  # No need to re-source, just check if the file exists first
  if [ ! -f "$INPUT_FILE" ]; then
    info_log "Input file not found, checking videos directory..."
    
    # Create videos directory if needed
    if [ -f "${SCRIPT_DIR}/src/download_manager.sh" ]; then
      source "${SCRIPT_DIR}/src/download_manager.sh"
      create_videos_dir
      
      # If videos directory is empty, download default videos
      if [ "$(find videos -type f \( -name "*.mp4" -o -name "*.mov" \) | wc -l)" -eq 0 ]; then
        info_log "No videos found. Downloading sample videos..."
        download_videos
      fi
      
      # List available videos and exit
      list_available_videos
    else
      error_log "Could not find download_manager.sh at ${SCRIPT_DIR}/src/download_manager.sh"
      error_log "Please ensure the script directory structure is correct."
    fi
    exit 1
  fi
}

# Function to handle interrupts - only for actual interruptions
handle_interrupt() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Benchmark interrupted! Cleaning up..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cleanup
    exit 1
}

# Function to check GPU resources 
check_gpu_resources() {
    local gpu_usage="Unknown"
    local gpu_memory="Unknown"
    local gpu_temp="Unknown"
    
    # NVIDIA GPU check
    if command -v nvidia-smi &> /dev/null; then
        gpu_usage=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits | head -1)
        gpu_memory=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader | head -1)
        gpu_temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits | head -1)
        debug_log "  GPU Usage: ${gpu_usage}%, Memory: ${gpu_memory}, Temperature: ${gpu_temp}°C"
    # For Apple GPUs (limited info available)
    elif [[ "$OSTYPE" == "darwin"* ]] && command -v system_profiler &> /dev/null; then
        local gpu_info=$(system_profiler SPDisplaysDataType 2>/dev/null)
        debug_log "  Apple GPU: Limited monitoring available"
        # You can extract some basic info if available
    # For Intel GPUs on Linux
    elif command -v intel_gpu_top &> /dev/null; then
        local gpu_info=$(intel_gpu_top -J -d 1 | head -20)
        debug_log "  Intel GPU monitoring data available"
    else
        debug_log "  GPU monitoring not available for this platform"
    fi
}

# Success cleanup without interrupt message
finish_benchmark() {
    cleanup
    
    # If not in debug mode, also clean up temporary files from the logs directory
    if [ "$DEBUG" != "1" ]; then
        debug_log "Removing temporary files from output directory"
        
        # Keep only the final benchmark log files and summary
        find "$OUTPUT_DIR" -type f -not -name "stream.log" \
                          -not -name "benchmark_summary.txt" \
                          -not -name "*.json" \
                          -delete 2>/dev/null
    fi
    
    exit 0
}

update_log_header() {
    # Initialize stream log with header
    echo "TestIteration,StreamCount,ActiveStreams,FailedStreams,CPUUsage,CPUName,GPUName,Resolution,InputCodec,Encoder,AvgReadIOPS,AvgWriteIOPS,UUID,VideoFile" > "$STREAM_LOG"
    
    # Create the all_streams log if it doesn't exist yet
    if [ ! -f "$STREAM_ALL_LOG" ]; then
        echo "TestIteration,StreamCount,ActiveStreams,FailedStreams,CPUUsage,CPUName,GPUName,Resolution,InputCodec,Encoder,AvgReadIOPS,AvgWriteIOPS,UUID,VideoFile,Timestamp" > "$STREAM_ALL_LOG"
    fi
}

# Generate a summary report
create_summary_report() {
    local max_streams=$1
    local report_file="${OUTPUT_DIR}/benchmark_summary.txt"
    
    echo "═════════════════════════════════════════════════════" > "$report_file"
    echo "  FFmpeg GPU-Focused Streaming Benchmark Summary      " >> "$report_file"
    echo "═════════════════════════════════════════════════════" >> "$report_file"
    echo "" >> "$report_file"
    echo " Test performed on: $(date)" >> "$report_file"
    echo " UUID: $UUID" >> "$report_file"
    echo " Video file: $INPUT_FILE" >> "$report_file"
    echo " - Video filename: $(basename "$INPUT_FILE")" >> "$report_file"
    echo " Resolution: $FRIENDLY_RESOLUTION ($VIDEO_RESOLUTION)" >> "$report_file"
    echo " Input codec: $VIDEO_CODEC" >> "$report_file"
    echo "" >> "$report_file"
    echo " Hardware details:" >> "$report_file"
    echo " - CPU: $(get_cpu_name)" >> "$report_file"
    echo " - GPU: $(get_gpu_name)" >> "$report_file"
    echo " - Hardware acceleration: $HW_ACCEL" >> "$report_file"
    echo " - Encoder used: $HW_ENCODER" >> "$report_file"
    echo "" >> "$report_file"
    echo " Results:" >> "$report_file"
    echo " - Maximum successful streams: $max_streams" >> "$report_file"
    echo " - Test duration per stream count: $TEST_DURATION seconds" >> "$report_file"
    
    # Extract performance metrics for max_streams from log file
    if [ -f "$STREAM_LOG" ]; then
        # Get the line with max_streams value in column 2
        local max_stream_line=$(grep "^[^,]*,$max_streams," "$STREAM_LOG")
        
        if [ -n "$max_stream_line" ]; then
            # Extract average IOPS values (now columns 11 and 12 after removing ReadIOPS and WriteIOPS)
            local avg_read_iops=$(echo "$max_stream_line" | cut -d',' -f11)
            local avg_write_iops=$(echo "$max_stream_line" | cut -d',' -f12)
            
            echo "" >> "$report_file"
            echo " IOPS Metrics at max streams:" >> "$report_file"
            echo " - Average Read IOPS: $avg_read_iops" >> "$report_file"
            echo " - Average Write IOPS: $avg_write_iops" >> "$report_file"
        fi
    fi
    
    echo "" >> "$report_file"
    echo " For detailed metrics, see: $STREAM_LOG" >> "$report_file"
    
    # Add note about debug logs if in debug mode
    if [ "$DEBUG" = "1" ]; then
        echo "" >> "$report_file"
        echo " Debug mode was enabled - detailed logs were preserved in: $OUTPUT_DIR/" >> "$report_file"
    else
        echo "" >> "$report_file"
        echo " Debug mode was disabled - only summary data was preserved" >> "$report_file"
    fi
    
    echo "Summary report generated: $report_file"
}

# Main benchmark function with progress display
run_benchmark() {
    # Initialize stream log with updated header
    update_log_header
    
    # Try increasing number of streams
    local max_successful=0
    
    # Display benchmark UUID (renamed from UID)
    echo "UUID: $UUID"
    
    # Run tests with increasing stream counts
    for test_iteration in $(seq 1 $MAX_STREAMS); do
        local num_streams=$test_iteration
        
        echo ""
        echo "Test #$test_iteration: Testing $num_streams concurrent stream(s) with $HW_ACCEL GPU acceleration..."
        
        # Clean up from previous test
        cleanup
        
        # Start the server streams
        for i in $(seq 1 $num_streams); do
            start_http_stream $i
            debug_log "Started GPU-accelerated HTTP server $i on port $((PORT_START + i))"
            # Add small delay between starting servers to avoid overwhelming the system
            sleep 1
        done
        
        # Start clients to consume the streams
        start_clients $num_streams
        
        # Run the monitor_streams function for full status
        monitor_streams $num_streams $test_iteration
        local result=$?
        
        # System resources check after test
        debug_log "  System state after test:"
        check_gpu_resources
        
        # Double-check that all processes are stopped (this is critical)
        debug_log "Ensuring all test processes are stopped"
        cleanup
        
        # If monitoring returned error, we've reached the limit
        if [ $result -ne 0 ]; then
            echo ""
            echo "┌────────────────────────────────────────────────────────┐"
            echo "│ GPU reached its limit at $num_streams streams          │"
            echo "│ Some streams failed, indicating system cannot handle   │"
            echo "│ this load. Maximum reliable streams: $max_successful   │"
            echo "└────────────────────────────────────────────────────────┘"
            break
        else
            max_successful=$num_streams
        fi
        
        # All streams succeeded
        if [ $num_streams -eq $MAX_STREAMS ]; then
            echo ""
            echo "┌────────────────────────────────────────────────────────┐"
            echo "│ All $MAX_STREAMS streams completed successfully        │"
            echo "│ Your GPU might be able to handle more streams.         │"
            echo "│ Increase MAX_STREAMS in config.sh and run again.       │"
            echo "└────────────────────────────────────────────────────────┘"
        fi
    done
    
    echo ""
    echo "Benchmark complete! Maximum successful GPU-accelerated streams: $max_successful with $HW_ACCEL acceleration"
    echo "Check $STREAM_LOG for detailed performance data."
    
    # Create a summary report
    create_summary_report $max_successful
}

# Set up trap for clean exit
trap handle_interrupt INT TERM
# Removed EXIT from trap to allow clean exits

# Main execution
parse_arguments "$@"
check_input_file


# Make Videos available
prepare_videos

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

# Get video information
VIDEO_RESOLUTION=$(get_video_resolution "$INPUT_FILE")
FRIENDLY_RESOLUTION=$(friendly_resolution_name "$VIDEO_RESOLUTION")
VIDEO_CODEC=$(get_video_codec "$INPUT_FILE")

# Set up hardware acceleration
setup_hw_accel

# Run the benchmark
run_benchmark

# Final cleanup without interrupt message
finish_benchmark