#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Function to log with timestamp
log_info() {
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  echo -e "${BLUE}[$timestamp] [INFO] $1${NC}"
}

log_success() {
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  echo -e "${GREEN}[$timestamp] [SUCCESS] $1${NC}"
}

log_warning() {
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  echo -e "${YELLOW}[$timestamp] [WARNING] $1${NC}"
}

log_error() {
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  echo -e "${RED}[$timestamp] [ERROR] $1${NC}"
}

log_debug() {
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  echo -e "${PURPLE}[$timestamp] [DEBUG] $1${NC}"
}

log_trace() {
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  echo -e "${CYAN}[$timestamp] [TRACE] $1${NC}"
}

# Function to log to file as well
log_to_file() {
  local level="$1"
  local message="$2"
  local logfile="$3"
  
  if [[ -n "$logfile" ]]; then
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" >> "$logfile"
  fi
}

# Combined logging function (console + file)
log_both() {
  local level="$1"
  local message="$2"
  local logfile="$3"
  
  case "$level" in
    "INFO")    log_info "$message" ;;
    "SUCCESS") log_success "$message" ;;
    "WARNING") log_warning "$message" ;;
    "ERROR")   log_error "$message" ;;
    "DEBUG")   log_debug "$message" ;;
    "TRACE")   log_trace "$message" ;;
  esac
  
  log_to_file "$level" "$message" "$logfile"
}