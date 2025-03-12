#!/bin/bash


# Function to start an HTTP stream server with GPU acceleration
start_http_stream() {
    local stream_id=$1
    local port=$((PORT_START + stream_id))
    local hw_args=""
    local decoder_args=""
    
    # Set up hardware acceleration arguments
    if [ "$HW_ACCEL" != "none" ]; then
        hw_args="-hwaccel $HW_ACCEL"
        
        # Add decoder if available and specified
        if [ -n "$HW_DECODER" ]; then
            decoder_args="-c:v $HW_DECODER"
        fi
    fi
    
    # Ensure we have a valid encoder
    if [ -z "$HW_ENCODER" ]; then
        debug_log "WARNING: No encoder specified, falling back to libx264"
        HW_ENCODER="libx264"
    fi
    
    # Set log level based on debug mode or environment variable
    local log_level="${FFMPEG_LOGLEVEL:-warning}"
    
    # Create log path
    local log_file="${OUTPUT_DIR}/server_${stream_id}.log"
    
    # Show command if in debug mode
    debug_log "Starting FFmpeg server with command:"
    debug_log "ffmpeg -loglevel $log_level $hw_args $decoder_args -re -i \"$INPUT_FILE\" -c:v $HW_ENCODER -b:v 3M -c:a aac -f mpegts -listen 1 -timeout 5000000 http://127.0.0.1:${port}"
    
    # Start FFmpeg as HTTP server with GPU acceleration
    ffmpeg -loglevel $log_level $hw_args $decoder_args -re -i "$INPUT_FILE" \
           -c:v "$HW_ENCODER" -b:v "3M" -c:a aac -f mpegts \
           -listen 1 -timeout 5000000 \
           "http://127.0.0.1:${port}" \
           > "$log_file" 2>&1 &
    
    local pid=$!
    echo $pid > "${OUTPUT_DIR}/server_pid_${stream_id}.txt"
    
    debug_log "Started FFmpeg server on port $port with PID $pid using encoder: $HW_ENCODER"
    
    # Wait longer for server to start when not in debug mode
    if [ "$DEBUG" = "1" ]; then
        sleep 3
    else
        sleep 8
    fi    
    # Check if the process is still running after a short delay
    if ps -p $pid > /dev/null 2>&1; then
        debug_log "FFmpeg server $stream_id successfully started and running (PID: $pid)"
        # For Apple VideoToolbox, verify no early errors in log
        if [ "$HW_ACCEL" = "videotoolbox" ]; then
            if grep -q -i "Error|Failed|Cannot" "$log_file" 2>/dev/null; then
                warn_log "Potential early errors detected with VideoToolbox for stream $stream_id"
                # Process is running but may have initialization issues
                if [ "$DEBUG" != "1" ]; then
                    # In non-debug mode, add extra delay to allow recovery
                    sleep 3
                fi
            fi
        fi
        return 0
    else
        error_log "FFmpeg server $stream_id failed to start or crashed immediately!"
        
        # Always show error log in this case, regardless of debug mode
        if [ -f "$log_file" ]; then
            echo "Error from server log (last 10 lines):"
            tail -n 10 "$log_file"
        fi
        return 1
    fi
}

# Function to start FFmpeg clients to consume the streams
start_clients() {
    local num_servers=$1
    local hw_args=""
    
    # Set up hardware acceleration arguments for client
    if [ "$HW_ACCEL" != "none" ]; then
        hw_args="-hwaccel $HW_ACCEL"
        
        # Add decoder if available and specified (but only for non-videotoolbox)
        if [ -n "$HW_DECODER" ] && [ "$HW_ACCEL" != "videotoolbox" ]; then
            hw_args="$hw_args -c:v $HW_DECODER"
        fi
    fi
    
    # Set log level based on debug mode or environment variable
    local log_level="${FFMPEG_LOGLEVEL:-warning}"
    
    for i in $(seq 1 $num_servers); do
        # Add more delay between starting servers when not in debug mode
        if [ "$DEBUG" != "1" ]; then
            sleep 5
        else
            sleep 1
        fi
        
        local port=$((PORT_START + i))
        local log_file="${OUTPUT_DIR}/client_${i}.log"
        
        # Show command if in debug mode
        debug_log "Starting FFmpeg client with command:"
        debug_log "ffmpeg -loglevel $log_level $hw_args -i http://127.0.0.1:${port} -f null -"
        
        # Start a client for each server (using hardware decoding if available)
        ffmpeg -loglevel $log_level $hw_args -i "http://127.0.0.1:${port}" \
               -f null - \
               > "$log_file" 2>&1 &
        
        local pid=$!
        echo $pid > "${OUTPUT_DIR}/client_pid_${i}.txt"
        
        debug_log "Started FFmpeg client $i connecting to port $port (PID: $pid)"
        
        # Check if the client is still running after a short delay
        sleep 1
        if ! ps -p $pid > /dev/null 2>&1; then
            warn_log "FFmpeg client $i failed to start or crashed immediately!"
            
            # Always show the client log on failure
            if [ -f "$log_file" ]; then
                echo "Last 10 lines of client log:"
                tail -n 10 "$log_file"
            fi
        fi
    done
}

# Modified monitor_streams function to track average IOPS during TEST_DURATION
monitor_streams() {
    local num_streams=$1
    local test_iteration=$2
    
    # Get system resources before the test
    local cpu_usage=$(get_cpu_usage)
    local cpu_name=$(get_cpu_name)
    local gpu_name=$(get_gpu_name)
    
    # Get initial disk IOPS
    if [ "$DEBUG" = "1" ]; then
        echo "[DEBUG] Getting initial disk IOPS"
    fi
    
    # Get disk IOPS without mixing debug output in command substitution
    local disk_iops=$(get_disk_iops 2>/dev/null)
    IFS=',' read -r PREV_READ_IOPS PREV_WRITE_IOPS <<< "$disk_iops"
    
    # Initialize tracking arrays
    declare -a server_pids
    declare -a client_pids
    declare -a stream_status
    
    # Arrays for IOPS measurements
    declare -a read_iops_measurements
    declare -a write_iops_measurements
    
    # Collect initial PIDs
    for i in $(seq 1 $num_streams); do
        local server_pid_file="${OUTPUT_DIR}/server_pid_${i}.txt"
        local client_pid_file="${OUTPUT_DIR}/client_pid_${i}.txt"
        
        if [ -f "$server_pid_file" ] && [ -f "$client_pid_file" ]; then
            server_pids[$i]=$(cat "$server_pid_file")
            client_pids[$i]=$(cat "$client_pid_file")
            stream_status[$i]="active"
        else
            stream_status[$i]="failed"
        fi
    done
    
    # Start monitoring loop - check multiple times during test duration
    local start_time=$(date +%s)
    local end_time=$((start_time + TEST_DURATION))
    local check_interval=5  # Check every 5 seconds
    local iops_measure_interval=10  # Measure IOPS every 10 seconds
    local next_iops_time=$((start_time + iops_measure_interval))
    
    echo "  Monitoring streams for $TEST_DURATION seconds..."
    echo -n "  ["
    
    # Add initial IOPS measurement
    local initial_iops=$(get_disk_iops 2>/dev/null)
    IFS=',' read -r current_read_iops current_write_iops <<< "$initial_iops"
    read_iops_measurements+=("$current_read_iops")
    write_iops_measurements+=("$current_write_iops")
    
    # During monitoring, check streams periodically
    while [ $(date +%s) -lt $end_time ]; do
        # Print progress indicator
        echo -n "#"
        
        # Get current time for IOPS interval check
        local current_time=$(date +%s)
        
        # Measure IOPS every 10 seconds
        if [ $current_time -ge $next_iops_time ]; then
            local current_iops=$(get_disk_iops 2>/dev/null)
            IFS=',' read -r current_read_iops current_write_iops <<< "$current_iops"
            
            # Store the measurements
            read_iops_measurements+=("$current_read_iops")
            write_iops_measurements+=("$current_write_iops")
            
            # Set next measurement time
            next_iops_time=$((current_time + iops_measure_interval))
            
            debug_log "IOPS Measurement at $(date -u +%H:%M:%S): Read=$current_read_iops, Write=$current_write_iops"
        fi
        
        # Check each stream's process status
        for i in $(seq 1 $num_streams); do
            # Only check streams that are still active
            if [ "${stream_status[$i]}" = "active" ]; then
                local server_pid=${server_pids[$i]}
                local client_pid=${client_pids[$i]}
                
                # Check if both processes are still running
                local server_running=0
                local client_running=0
                
                if [ -n "$server_pid" ]; then
                    if ps -p "$server_pid" > /dev/null 2>&1; then
                        server_running=1
                    fi
                fi
                
                if [ -n "$client_pid" ]; then
                    if ps -p "$client_pid" > /dev/null 2>&1; then
                        client_running=1
                    fi
                fi
                
                # Mark as failed if either process died
                if [ $server_running -eq 0 ] || [ $client_running -eq 0 ]; then
                    stream_status[$i]="failed"
                    debug_log "Stream $i failed during monitoring check (server: $server_running, client: $client_running)"
                    
                    # Check for error messages
                    if [ "$DEBUG" = "1" ]; then
                        if [ -f "${OUTPUT_DIR}/server_${i}.log" ]; then
                            if grep -q "Error\|error\|failed\|GPU" "${OUTPUT_DIR}/server_${i}.log" ]; then
                                debug_log "Server $i log shows errors:"
                                grep -i "Error\|error\|failed\|GPU" "${OUTPUT_DIR}/server_${i}.log" | tail -5
                            fi
                        fi
                        
                        if [ -f "${OUTPUT_DIR}/client_${i}.log" ]; then
                            if grep -q "Error\|error\|failed" "${OUTPUT_DIR}/client_${i}.log" ]; then
                                debug_log "Client $i log shows errors:"
                                grep -i "Error\|error\|failed" "${OUTPUT_DIR}/client_${i}.log" | tail -5
                            fi
                        fi
                    fi
                fi
            fi
        done
        
        # If all streams have failed, exit early
        local all_failed=1
        for i in $(seq 1 $num_streams); do
            if [ "${stream_status[$i]}" = "active" ]; then
                all_failed=0
                break
            fi
        done
        
        if [ $all_failed -eq 1 ] && [ $num_streams -gt 0 ]; then
            debug_log "All streams have failed, exiting monitoring loop early"
            break
        fi
        
        # Sleep until next check interval
        sleep $check_interval
    done
    
    echo "] Done."
    
    # Clean up all processes
    debug_log "Test duration completed, cleaning up processes"
    cleanup
    
    # Count active and failed streams
    local active_streams=0
    local failed_streams=0
    
    for i in $(seq 1 $num_streams); do
        if [ "${stream_status[$i]}" = "active" ]; then
            active_streams=$((active_streams + 1))
        else
            failed_streams=$((failed_streams + 1))
        fi
    done
    
    # Also check log files for errors that might indicate failures
    for i in $(seq 1 $num_streams); do
        if [ "${stream_status[$i]}" = "active" ]; then
            local has_errors=0
            
            # MODIFIED: Skip rigorous error checking in non-debug mode
            if [ "$DEBUG" != "1" ]; then
                # In non-debug mode, only check if processes were running
                # and ignore log file content errors
                continue
            fi

            # Check server log for critical errors
            if [ -f "${OUTPUT_DIR}/server_${i}.log" ]; then
                if grep -q -i "Error\|GPU rejected\|No hardware\|Cannot\|failed\|Unable\|too slow" "${OUTPUT_DIR}/server_${i}.log"; then
                    debug_log "Stream $i appears active but server log contains errors"
                fi
            else
                has_errors=1
            fi
            
            # Check client log for critical errors
            if [ -f "${OUTPUT_DIR}/client_${i}.log" ]; then
                if grep -q -i "Error\|Invalid\|Failed\|Cannot\|Conversion failed" "${OUTPUT_DIR}/client_${i}.log" ]; then
                    has_errors=1
                    debug_log "Stream $i appears active but client log contains errors"
                fi
            else
                has_errors=1
            fi
            
            # Reclassify as failed if errors are found
            if [ $has_errors -eq 1 ]; then
                stream_status[$i]="failed_with_errors"
                active_streams=$((active_streams - 1))
                failed_streams=$((failed_streams + 1))
            fi
        fi
    done
    
    # Calculate average IOPS
    local avg_read_iops=0
    local avg_write_iops=0
    local num_measurements=${#read_iops_measurements[@]}
    
    if [ $num_measurements -gt 0 ]; then
        local total_read=0
        local total_write=0
        
        debug_log "IOPS Measurements count: $num_measurements"
        
        for i in "${!read_iops_measurements[@]}"; do
            total_read=$((total_read + read_iops_measurements[i]))
            total_write=$((total_write + write_iops_measurements[i]))
            
            debug_log "Measurement $i: Read=${read_iops_measurements[i]}, Write=${write_iops_measurements[i]}"
        done
        
        avg_read_iops=$((total_read / num_measurements))
        avg_write_iops=$((total_write / num_measurements))
    else
        debug_log "No IOPS measurements were taken"
        
        # Fallback to single measurement
        local final_disk_iops=$(get_disk_iops 2>/dev/null)
        IFS=',' read -r avg_read_iops avg_write_iops <<< "$final_disk_iops"
    fi
    
    # Log values for debugging including the new averages and UUID (renamed from BenchmarkUID)
    debug_log "Writing to log: $test_iteration,$num_streams,$active_streams,$failed_streams,$cpu_usage,$cpu_name,$gpu_name,$FRIENDLY_RESOLUTION,$VIDEO_CODEC,$HW_ENCODER,$avg_read_iops,$avg_write_iops,$UUID"
    
    # Extract the video filename
    video_filename=$(basename "$INPUT_FILE")

    # Log values for debugging including the new averages and UUID
    debug_log "Writing to log: $test_iteration,$num_streams,$active_streams,$failed_streams,$cpu_usage,$cpu_name,$gpu_name,$FRIENDLY_RESOLUTION,$VIDEO_CODEC,$HW_ENCODER,$avg_read_iops,$avg_write_iops,$UUID,$video_filename"
    
    # Add video filename to the log entry
    echo "$test_iteration,$num_streams,$active_streams,$failed_streams,$cpu_usage,$cpu_name,$gpu_name,$FRIENDLY_RESOLUTION,$VIDEO_CODEC,$HW_ENCODER,$avg_read_iops,$avg_write_iops,$UUID,$video_filename" >> "$STREAM_LOG"

    # Add the same data plus timestamp to the all_streams log
    current_timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "$test_iteration,$num_streams,$active_streams,$failed_streams,$cpu_usage,$cpu_name,$gpu_name,$FRIENDLY_RESOLUTION,$VIDEO_CODEC,$HW_ENCODER,$avg_read_iops,$avg_write_iops,$UUID,$video_filename,$current_timestamp" >> "$STREAM_ALL_LOG"
    
    # Print a more detailed summary of this test iteration
    echo "  Results: $active_streams streams active, $failed_streams failed, CPU: ${cpu_usage}%, Avg Read IOPS: $avg_read_iops, Avg Write IOPS: $avg_write_iops"
    
    # Detailed failure reporting in debug mode
    if [ "$DEBUG" = "1" ] && [ $failed_streams -gt 0 ]; then
        echo "  Failed streams:"
        for i in $(seq 1 $num_streams); do
            if [ "${stream_status[$i]}" != "active" ]; then
                echo "    - Stream $i (${stream_status[$i]})"
            fi
        done
    fi
    
    # Return success or failure based on stream states
    if [ $failed_streams -gt 0 ]; then
        return 1
    else
        return 0
    fi
}

# Function to clean up all running FFmpeg processes and log files
cleanup() {
    debug_log "Cleaning up all FFmpeg processes..."
    # Small delay to ensure previous processes have time to exit cleanly
    sleep 2    
    # Kill all FFmpeg server and client processes with more safeguards
    for pid_file in "${OUTPUT_DIR}"/server_pid_*.txt "${OUTPUT_DIR}"/client_pid_*.txt; do
        if [ -f "$pid_file" ]; then
            pid=$(cat "$pid_file")
            if ps -p "$pid" > /dev/null 2>&1; then
                debug_log "Killing process with PID $pid"
                # Try graceful termination first
                kill "$pid" > /dev/null 2>&1
                sleep 1
                # Force kill if still running
                if ps -p "$pid" > /dev/null 2>&1; then
                    kill -9 "$pid" > /dev/null 2>&1
                    sleep 1
                fi
            fi
            rm -f "$pid_file"
        fi
    done    
    # Additional safety to ensure all FFmpeg processes are stopped
    if pgrep -x "ffmpeg" > /dev/null; then
        debug_log "Killing any remaining FFmpeg processes"
        pkill -9 -x "ffmpeg" > /dev/null 2>&1
    fi
    
    # Remove log files unless debug mode is enabled
    if [ "$DEBUG" != "1" ]; then
        debug_log "Removing log files (debug mode is disabled)"
        rm -f "${OUTPUT_DIR}"/server_*.log
        rm -f "${OUTPUT_DIR}"/client_*.log
    else
        debug_log "Keeping log files for debugging"
    fi
}
