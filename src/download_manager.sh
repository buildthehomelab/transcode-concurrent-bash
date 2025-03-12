#!/bin/bash

# Simplified download manager script for FFmpeg GPU benchmark

# Source the logging functions if this script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PARENT_DIR="$(dirname "$SCRIPT_DIR")"
  
  if [ -f "${SCRIPT_DIR}/logging.sh" ]; then
    source "${SCRIPT_DIR}/logging.sh"
  else
    # Define basic logging functions if not available
    function info_log() { echo "[INFO] $*"; }
    function error_log() { echo "[ERROR] $*" >&2; }
  fi
fi

# Video URLs
VIDEOS=(
  "https://download.blender.org/peach/bigbuckbunny_movies/big_buck_bunny_480p_h264.mov"
  "https://download.blender.org/peach/bigbuckbunny_movies/big_buck_bunny_720p_h264.mov"
  "https://download.blender.org/peach/bigbuckbunny_movies/big_buck_bunny_1080p_h264.mov"
  "https://download.blender.org/demo/movies/BBB/bbb_sunflower_1080p_60fps_normal.mp4.zip"
  "https://download.blender.org/demo/movies/BBB/bbb_sunflower_2160p_60fps_normal.mp4.zip"
)

# Function to create videos directory
create_videos_dir() {
  local dir="videos"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
    echo "Created videos directory: $dir"
  fi
}

# Function to download a file
download_file() {
  local url="$1"
  local output_dir="$2"
  local filename=$(basename "$url")
  local output_file="${output_dir}/${filename}"
  
  # Check if file already exists and has content
  if [ -f "$output_file" ] && [ -s "$output_file" ]; then
    echo "File ${filename} already exists, skipping download."
    return 0
  fi
  
  echo "Downloading ${filename}..."
  
  if command -v curl &> /dev/null; then
    curl -L --progress-bar -o "$output_file" "$url"
    local status=$?
  elif command -v wget &> /dev/null; then
    wget --show-progress -q -O "$output_file" "$url"
    local status=$?
  else
    echo "Error: Neither curl nor wget is available. Please install one of them."
    return 1
  fi
  
  if [ $status -ne 0 ]; then
    echo "Error: Download failed for ${filename}"
    return 1
  fi
  
  if [ ! -s "$output_file" ]; then
    echo "Error: Downloaded file is empty: ${filename}"
    return 1
  fi
  
  echo "Successfully downloaded ${filename} ($(du -h "$output_file" | cut -f1) bytes)"
  return 0
}

# Function to extract ZIP file
extract_zip() {
  local zip_file="$1"
  local extract_dir="$2"
  
  # Check if the zip has already been extracted by looking for expected files
  # For bbb_sunflower files, they extract to mp4 files
  local base_name=$(basename "$zip_file" .zip)
  if [ -f "${extract_dir}/${base_name}" ]; then
    echo "ZIP ${zip_file} appears to be already extracted, skipping extraction."
    return 0
  fi
  
  echo "Extracting ${zip_file}..."
  
  if command -v unzip &> /dev/null; then
    unzip -o "$zip_file" -d "$extract_dir"
    local status=$?
  else
    echo "Error: unzip command not found. Please install unzip."
    return 1
  fi
  
  if [ $status -ne 0 ]; then
    echo "Error: Extraction failed for ${zip_file}"
    return 1
  fi
  
  echo "Successfully extracted ${zip_file}"
  echo "Removing ZIP file..."
  rm -f "$zip_file"
  
  return 0
}

# Function to download all videos
download_videos() {
  local videos_dir="videos"
  create_videos_dir
  
  echo "=== Downloading test videos ==="
  echo "This may take some time depending on your internet connection..."
  echo ""
  
  local total_count=${#VIDEOS[@]}
  local success_count=0
  local skipped_count=0
  
  for ((i=0; i<${#VIDEOS[@]}; i++)); do
    local url="${VIDEOS[$i]}"
    local filename=$(basename "$url")
    
    echo "[${i}/${total_count}] Processing ${filename}..."
    
    # For ZIP files, check if the expected extracted file might exist before download
    if [[ "$filename" == *.zip ]]; then
      local base_name=$(basename "$filename" .zip)
      if [ -f "${videos_dir}/${base_name}" ] || [ -f "${videos_dir}/${base_name}.mp4" ]; then
        echo "Extracted file from ${filename} already exists, skipping download."
        ((skipped_count++))
        ((success_count++))
        continue
      fi
    fi
    
    # Check for non-zip files directly
    if [[ "$filename" != *.zip ]] && [ -f "${videos_dir}/${filename}" ] && [ -s "${videos_dir}/${filename}" ]; then
      echo "File ${filename} already exists, skipping download."
      ((skipped_count++))
      ((success_count++))
      continue
    fi
    
    # Download the file
    download_file "$url" "$videos_dir"
    if [ $? -ne 0 ]; then
      continue
    fi
    
    # If it's a ZIP file, extract it
    if [[ "$filename" == *.zip ]]; then
      extract_zip "${videos_dir}/${filename}" "$videos_dir"
    fi
    
    ((success_count++))
    echo ""
  done
  
  echo "=== Download complete ==="
  echo "Successfully processed ${success_count} out of ${total_count} videos"
  if [ $skipped_count -gt 0 ]; then
    echo "${skipped_count} files were already downloaded and skipped"
  fi
  echo "Videos are available in the '${videos_dir}' directory"
  
  # List available videos
  list_available_videos
}

# Function to list available videos
list_available_videos() {
  local videos_dir="videos"
  
  if [ ! -d "$videos_dir" ]; then
    echo "Videos directory does not exist. Run with --download-videos to create it."
    return 1
  fi
  
  # Use find to reliably locate video files with common extensions
  echo ""
  echo "=== Available Videos ==="
  
  local found_videos=0
  while IFS= read -r video_file; do
    if [ -f "$video_file" ]; then
      local filesize=$(du -h "$video_file" | cut -f1)
      echo "- $(basename "$video_file") (${filesize})"
      ((found_videos++))
    fi
  done < <(find "$videos_dir" -type f \( -name "*.mp4" -o -name "*.mov" -o -name "*.mkv" -o -name "*.avi" \) 2>/dev/null)
  
  if [ $found_videos -eq 0 ]; then
    echo "No video files found in the '${videos_dir}' directory."
    echo "Run with --download-videos to download test videos."
  else
    echo ""
    echo "To use in benchmark: ./main.sh \"${videos_dir}/filename.mp4\""
  fi
  
  echo ""
}

# Direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [ "$1" = "--list" ]; then
    list_available_videos
  else
    download_videos
  fi
fi