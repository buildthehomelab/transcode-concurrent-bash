#!/bin/bash

# Video information functions for FFmpeg GPU-Focused Streaming Benchmark

# Function to get video resolution
get_video_resolution() {
    local input_file="$1"
    
    # Get video resolution using ffprobe
    if command -v ffprobe &> /dev/null; then
        local resolution=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$input_file" 2>/dev/null)
        
        # Check if resolution was successfully obtained
        if [ -n "$resolution" ]; then
            echo "$resolution"
            return 0
        fi
    fi
    
    # If ffprobe failed or isn't available, return "Unknown"
    echo "Unknown"
    return 1
}

# Function to get video codec
get_video_codec() {
    local input_file="$1"
    
    # Get video codec using ffprobe
    if command -v ffprobe &> /dev/null; then
        # First try to get the codec name
        local codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>/dev/null)
        
        # If that worked, return it
        if [ -n "$codec" ]; then
            echo "$codec"
            return 0
        fi
    fi
    
    # If ffprobe failed or isn't available, return "Unknown"
    echo "Unknown"
    return 1
}

# Function to convert resolution to standard name
friendly_resolution_name() {
    local resolution="$1"
    
    # Only process if we have a valid resolution
    if [ "$resolution" = "Unknown" ] || [ -z "$resolution" ]; then
        echo "$resolution"
        return
    fi
    
    # Extract width and height
    local width=$(echo "$resolution" | cut -d'x' -f1)
    local height=$(echo "$resolution" | cut -d'x' -f2)
    
    # Check for standard resolutions
    if [ "$width" = "3840" ] && [ "$height" = "2160" ]; then
        echo "4K"
    elif [ "$width" = "2560" ] && [ "$height" = "1440" ]; then
        echo "1440p"
    elif [ "$width" = "1920" ] && [ "$height" = "1080" ]; then
        echo "1080p"
    elif [ "$width" = "1280" ] && [ "$height" = "720" ]; then
        echo "720p"
    elif [ "$width" = "7680" ] && [ "$height" = "4320" ]; then
        echo "8K"
    elif [ "$width" = "4096" ] && [ "$height" = "2160" ]; then
        echo "DCI 4K"
    elif [ "$width" = "2048" ] && [ "$height" = "1080" ]; then
        echo "2K"
    else
        echo "$resolution" # Return original if no match
    fi
}
