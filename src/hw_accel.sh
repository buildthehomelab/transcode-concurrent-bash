#!/bin/bash

# Hardware acceleration functions for FFmpeg GPU-Focused Streaming Benchmark

# Function to detect available GPU hardware acceleration methods
detect_hw_accel() {
    info_log "Detecting available GPU hardware acceleration methods..."
    
    # Get available hardware accelerators
    hw_accels=$(ffmpeg -hwaccels 2>/dev/null | grep -v "Hardware acceleration methods:" | tr '\n' ' ')
    debug_log "Available hardware accelerators: $hw_accels"
    
    # Check for specific hardware, prioritizing GPU acceleration
    if [[ "$hw_accels" == *"cuda"* ]]; then
        # CUDA is available on systems with NVIDIA GPUs
        info_log "Detected NVIDIA CUDA hardware acceleration"
        HW_ACCEL="cuda"
        HW_ENCODER="h264_nvenc"
        HW_DECODER="h264_cuvid"
        return 0
    elif [[ "$hw_accels" == *"videotoolbox"* ]]; then
        # videotoolbox is available on all Mac systems (both Intel and Apple Silicon)
        info_log "Detected Apple VideoToolbox hardware acceleration"
        HW_ACCEL="videotoolbox"
        HW_ENCODER="h264_videotoolbox"
        # VideoToolbox doesn't use a specific decoder name in some FFmpeg builds
        HW_DECODER=""
        return 0
    elif [[ "$hw_accels" == *"vaapi"* ]]; then
        # VAAPI for Intel/AMD GPUs on Linux
        info_log "Detected VAAPI hardware acceleration"
        HW_ACCEL="vaapi"
        HW_ENCODER="h264_vaapi"
        HW_DECODER="h264_vaapi"
        return 0
    elif [[ "$hw_accels" == *"qsv"* ]]; then
        # QSV is available on Intel systems
        info_log "Detected Intel QuickSync Video hardware acceleration"
        HW_ACCEL="qsv"
        HW_ENCODER="h264_qsv"
        HW_DECODER="h264_qsv"
        return 0
    elif [[ "$hw_accels" == *"opencl"* ]]; then
        # OpenCL is widely available
        info_log "Detected OpenCL hardware acceleration"
        HW_ACCEL="opencl"
        # Fallback to best available encoder
        if ffmpeg -encoders 2>/dev/null | grep -q "h264_videotoolbox"; then
            HW_ENCODER="h264_videotoolbox"
        else
            HW_ENCODER="libx264" # Fallback to software
            warn_log "No GPU encoder found for OpenCL, falling back to software encoding"
        fi
        return 0
    else
        warn_log "No supported GPU hardware acceleration detected"
        info_log "Using software encoding (this will not utilize GPU)"
        HW_ACCEL="none"
        HW_ENCODER="libx264"
        return 1
    fi
}

# Set up hardware acceleration based on method
setup_hw_accel() {
    if [ "$HW_ACCEL" = "auto" ]; then
        detect_hw_accel
    elif [ "$HW_ACCEL" = "cuda" ]; then
        info_log "Using NVIDIA CUDA acceleration"
        HW_ENCODER="h264_nvenc"
        HW_DECODER="h264_cuvid"
    elif [ "$HW_ACCEL" = "videotoolbox" ]; then
        info_log "Using Apple VideoToolbox acceleration"
        # Add VideoToolbox specific parameters to help with stability
        export VIDEOTOOLS_ALLOW_FALLBACK=1
        HW_ENCODER="h264_videotoolbox"
        # VideoToolbox doesn't use a specific decoder name in some FFmpeg builds
        HW_DECODER=""
    elif [ "$HW_ACCEL" = "vaapi" ]; then
        info_log "Using VAAPI acceleration"
        HW_ENCODER="h264_vaapi"
        HW_DECODER="h264_vaapi"
    elif [ "$HW_ACCEL" = "qsv" ]; then
        info_log "Using Intel QuickSync Video acceleration"
        HW_ENCODER="h264_qsv"
        HW_DECODER="h264_qsv"
    elif [ "$HW_ACCEL" = "none" ]; then
        info_log "GPU acceleration disabled, using software encoding"
        HW_ENCODER="libx264"
        HW_DECODER=""
    else
        warn_log "Unknown hardware acceleration method: $HW_ACCEL"
        info_log "Falling back to auto-detection"
        detect_hw_accel
    fi
    
    # Verify the encoder exists
    if ! ffmpeg -encoders 2>/dev/null | grep -q "$HW_ENCODER"; then
        warn_log "GPU encoder $HW_ENCODER not found in your FFmpeg installation"
        info_log "Falling back to libx264 software encoding (this will not utilize GPU)"
        HW_ACCEL="none"
        HW_ENCODER="libx264"
        HW_DECODER=""
    fi
    
    debug_log "Selected GPU acceleration: $HW_ACCEL"
    debug_log "Selected GPU encoder: $HW_ENCODER"
    if [ -n "$HW_DECODER" ]; then
        debug_log "Selected GPU decoder: $HW_DECODER"
    fi
}
