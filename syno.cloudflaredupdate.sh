#!/bin/bash
# shellcheck disable=SC2154,SC2181
# shellcheck source=/dev/null
#
# A script to automagically update cloudlfared on Synology NAS from the builds at
# https://github.com/karasevm/syno-cloudflared-builds. These builds are eventually published in the
# SynoCommunity Package Center but this script allows for more frequent updates.
#
# This must be run as root to natively control running services
#
# Author @paulgit https://github.com/paulgit/syno.cloudflaredupdate
#
# Based on script from: https://github.com/michealespinola/syno.cloudflaredupdate which was based on 
# an original update concept based on: https://github.com/martinorob/plexupdate
#
# Example Synology DSM Scheduled Task type 'user-defined script': 
# bash /volume1/homes/admin/scripts/bash/syno.cloudflaredupdate.sh

# Script version
SCRIPT_VERSION=0.1.0
MIN_DSM_VERSION=7.2

# Obtain script path info
SOURCE_FULL_PATH=$(readlink -f "${BASH_SOURCE[0]}")
SOURCE_FOLDER=$(dirname "$SOURCE_FULL_PATH")
SOURCE_FILE_NAME=${SOURCE_FULL_PATH##*/}

# Obtain Synology hardware model and CPU architecture
SYNOLOGY_HARDWARE_MODEL=$(< /proc/sys/kernel/syno_hw_version)
ARCHITECTURE_FAMILY=$(uname --machine)

# Get DSM version 
DSM_VERSION=$(grep -i "productversion=" "/etc.defaults/VERSION" | cut -d"\"" -f 2)

# Get epoch timestamp for age checks
TODAYS_DATE=$(date +%s)

check_compliance() {
  # Check if root
  if [ "$EUID" -ne "0" ]; then
    printf ' %s\n\n' "* This script must be run as root - exiting.."
    printf "\n"
    exit 1
  fi

  # Check if jq is installed
  if ! command -v jq >/dev/null 2>&1; then
    printf '\n %s\n\n' "* This script requires 'jq' to parse JSON - please install it via SynoCommunity Package Center - exiting.."
    printf "\n"
    exit 1
  fi

  # Check synology architecture family for package selection
  if [ "$ARCHITECTURE_FAMILY" != "x86_64" ] && [ "$ARCHITECTURE_FAMILY" != "i686" ]; then
    printf ' %s\n\n' "* Untested/Unsported architecture: $ARCHITECTURE_FAMILY - exiting.."
    printf "\n"
    exit 1
  fi

  # Check if DSM 7
  if version "$MIN_DSM_VERSION" "$DSM_VERSION"; then
    printf ' %s\n' "* Syno.cloudflared Update requires DSM $MIN_DSM_VERSION minimum to install - exiting.."
    printf "\n"
    exit 1
  fi  
}

# Check if config file exists, create or update with defaults if missing keys
create_or_update_config() {
  local config_file="$1"
  if [ ! -f "$config_file" ]; then
    printf ' %s\n\n' "* Configuration file (config.ini) is missing, creating default setup.."
    touch "$config_file"
    exit_status=1
  fi
  # Function to add key-value pairs along with comments if not present
  add_config_with_comment() {
    local key="$1"
    local value="$2"
    local comment="$3"
    if ! grep -q "^$key=" "$config_file"; then
      printf '%s\n' "$comment" >> "$config_file"
      printf '%s\n' "$key=$value" >> "$config_file"
    fi
  }
  # Default configurations
  add_config_with_comment "minimum_age" "7"   "# A new update must be this many days old"
  add_config_with_comment "old_updates" "60"  "# Previously downloaded packages deleted if older than this many days"
  add_config_with_comment "net_timeout" "900" "# Network timeout in seconds (900s = 15m)"
  add_config_with_comment "self_update" "0"   "# Script will self-update if set to 1"
}

# Function to compare two version strings
# Returns 0 if equal, 1 if v1 > v2, 2 if v1 < v2
version_compare() {
    local v1="${1#v}"  # Remove leading 'v' if present
    local v2="${2#v}"
    
    # Split versions into arrays by '.' and '-'
    IFS='.-' read -ra VER1 <<< "$v1"
    IFS='.-' read -ra VER2 <<< "$v2"
    
    local len1=${#VER1[@]}
    local len2=${#VER2[@]}
    local max_len=$(( len1 > len2 ? len1 : len2 ))
    
    for ((i=0; i<max_len; i++)); do
        local part1=${VER1[i]:-0}
        local part2=${VER2[i]:-0}
        
        # Compare numerically
        if (( part1 > part2 )); then
            return 0
        elif (( part1 < part2 )); then
            return 2
        fi
    done
    
    return 1
}

main() {

  # Redirect stdout to tee in order to duplicate the output to the terminal as well as a .log file
  exec > >(tee "$SOURCE_FULL_PATH.log") 2>"$SOURCE_FULL_PATH.debug"

  # Enable xtrace output for debug file
  set -x

  # Print our glorious header because we are full of ourselves
  printf "\n"
  printf "%s\n" "Syno.cloudflared update script v$SCRIPT_VERSION for DSM 7"
  printf "\n"

  # Check compliance requirements
  check_compliance

  create_or_update_config "$SOURCE_FOLDER/config.ini"

  # Load config file if it exists
  if [ -f "$SOURCE_FOLDER/config.ini" ]; then
    source "$SOURCE_FOLDER/config.ini"
  fi

  # Print script status/debug info
  printf '%16s %s\n'                   "Script:" "$SOURCE_FILE_NAME"
  printf '%16s %s\n'               "Script Dir:" "$(fold -w 72 -s     < <(printf '%s' "$SOURCE_FOLDER") | sed '2,$s/^/                 /')"

  # Check for basic internet connectivity
  if nslookup one.one.one.one >/dev/null 2>&1; then
  #printf '\n %s\n\n' "* OK: DNS resolution works.."
    :
  elif ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
    printf '\n %s\n\n' "* DNS resolution appears to be failing - exiting.."
    exit 1
  else
    printf '\n %s\n\n' "* Internet appears to be down - exiting.."
    exit 1
  fi

  # Override settings with CLI options
  while getopts ":a:mh" opt; do
    case ${opt} in
      a) # Auto-update script or cloudflared 
        # Check if the value is numerical only
        if [[ $OPTARG =~ ^[0-9]+$ ]]; then
          minimum_age=$OPTARG
          printf '%16s %s\n'         "Override:" "-a, Minimum Age set to $minimum_age days"
        else
          printf '\n%16s %s\n\n'   "Bad Option:" "-a, requires a number value for minimum age in days"
          exit 1
        fi
        ;;
      m) # Update to master branch (non-release)
        master_update=true
        printf '%16s %s\n'           "Override:" "-m, Forcing script update from Master branch"
        ;;
      h) # Help option
        printf '\n%s\n\n'  "Usage: $SOURCE_FILE_NAME [-a #] [-c p|b] [-m] [-h]"
        printf ' %s\n'   "-a: Override the minimum age in days"
        printf ' %s\n'   "-c: Override the update channel (p for Public, b for Beta)"
        printf ' %s\n'   "-m: Update from the master branch (non-release version)"
        printf ' %s\n\n' "-h: Display this help message"
        exit 0
        ;;
      \?) # Invalid option
        printf '\n%16s %s\n\n'     "Bad Option:" "-$OPTARG, Invalid (-h for help)"
        exit 1
        ;;
      :) # Missing argument
        printf '\n%16s %s\n\n'     "Bad Option:" "-$OPTARG, Requires an argument (-h for help)"
        exit 1
        ;;
    esac
  done

  # Check if script is archived
  if [ ! -d "$SOURCE_FOLDER/Archive/Scripts" ]; then
    mkdir -p "$SOURCE_FOLDER/Archive/Scripts"
  fi
  if [ ! -f "$SOURCE_FOLDER/Archive/Scripts/syno.cloudflaredupdate.v$SCRIPT_VERSION.sh" ]; then
    cp "$SOURCE_FULL_PATH" "$SOURCE_FOLDER/Archive/Scripts/syno.cloudflaredupdate.v$SCRIPT_VERSION.sh"
  else
    cmp -s "$SOURCE_FULL_PATH" "$SOURCE_FOLDER/Archive/Scripts/syno.cloudflaredupdate.v$SCRIPT_VERSION.sh"
    if [ "$?" -ne "0" ]; then
      cp "$SOURCE_FULL_PATH" "$SOURCE_FOLDER/Archive/Scripts/syno.cloudflaredupdate.v$SCRIPT_VERSION.sh"
    fi
  fi

  # Obtain GitHub website for latest info
  github_repo=paulgit/syno.cloudflaredupdate
  github_html=$(curl -i -m "$net_timeout" -Ls https://api.github.com/repos/$github_repo/releases?per_page=1)
  if [ "$?" -eq "0" ]; then
    # Avoid scraping squared brackets because GitHub is inconsistent
    github_json=$(grep -oPz '\{\s{0,6}\"\X*\s{0,4}\}'          < <(printf '%s' "$github_html") | tr -d '\0')
    # Add squared brackets because it's proper and jq needs it
    github_json=$'[\n'"$github_json"$'\n]'
    github_html=$(grep -oPz '\X*\{\W{0,6}\"'                   < <(printf '%s' "$github_html")  | tr -d '\0' | sed -z 's/\W\[.*//')
    # Obtain current rate limit
    script_api_rate_limit=$(grep -oP '^x-ratelimit-limit: \K[\d]+'       < <(printf '%s' "$github_html"))
    script_api_rate_remaining=$(grep -oP '^x-ratelimit-remaining: \K[\d]+'   < <(printf '%s' "$github_html"))
    # Obtain API messages
    script_api_message=$(jq -r '.[].message'                          < <(printf '%s' "$github_json"))
    script_api_documentation=$(jq -r '.[].documentation_url'                < <(printf '%s' "$github_json"))
    # Obtain expected release-related info
    script_new_version=$(jq -r '.[].tag_name'                         < <(printf '%s' "$github_json"))
    script_new_version=${script_new_version#v}
    script_release_date=$(jq -r '.[].published_at'                     < <(printf '%s' "$github_json"))
    script_release_date=$(date --date "$script_release_date" +'%s')
    script_release_age=$(((TODAYS_DATE-script_release_date)/86400))
    if [ "$master_update" = "true" ]; then
      script_download_url=https://raw.githubusercontent.com/$github_repo/master/syno.cloudflaredupdate.sh
      script_release_description=$'* Check GitHub for master branch commit messages and extended descriptions'
    else
      script_download_url=https://raw.githubusercontent.com/$github_repo/v$script_new_version/syno.cloudlfaredupdate.sh
      script_release_description=$(jq -r '.[].body'                             < <(printf '%s' "$github_json"))
    fi
    script_help_url=https://github.com/$github_repo/issues
  else
    printf ' %s\n\n' "* Unable to check for latest version of script.."
    exit_status=1
  fi

  # Print script status/debug info
  printf '%16s %s\n'      "Running Ver:" "$SCRIPT_VERSION"

  if [ "$script_new_version" = "null" ]; then
    printf "%16s %s\n" "GitHub API Msg:" "$(fold -w 72 -s     < <(printf '%s' "$script_api_message") | sed '2,$s/^/                 /')"
    printf "%16s %s\n" "GitHub API Lmt:" "$script_api_rate_limit connections per hour per IP"
    printf "%16s %s\n" "GitHub API Doc:" "$(fold -w 72 -s     < <(printf '%s' "$script_api_documentation") | sed '2,$s/^/                 /')"
    exit_status=1
  elif [ "$script_new_version" != "" ]; then
    printf '%16s %s\n'     "Online Ver:" "$script_new_version (attempts left $script_api_rate_remaining/$script_api_rate_limit)"
    printf '%16s %s\n'       "Released:" "$(date -date "$script_release_date") ($script_release_age+ days old)"
  fi

  # Compare script versions
  if [[ "$script_new_version" != "null" ]]; then
    if version_compare "$script_new_version" "$SCRIPT_VERSION" || [[ "$master_update" == "true" ]]; then
      if [[ "$master_update" == "true" ]]; then
        printf '%17s%s\n' '' "* Updating from master branch!"
      else
        printf '%17s%s\n' '' "* Newer version found!"
      fi
      # Download and install the script update
      if [ "$self_update" -eq "1" ]; then
        if [ "$script_release_age" -ge "$minimum_age" ] || [ "$master_update" = "true" ]; then
          printf "\n"
          printf "%s\n" "Installing new script:"
          printf "%s\n" "----------------------------------------"
          /bin/wget -nv -O "$SOURCE_FOLDER/Archive/Scripts/$SOURCE_FILE_NAME" "$script_download_url"                               2>&1
          if [ "$?" -eq "0" ]; then
            # Make a copy for upgrade comparison because we are going to move not copy the new file
            cp -f -v "$SOURCE_FOLDER/Archive/Scripts/$SOURCE_FILE_NAME"     "$SOURCE_FOLDER/Archive/Scripts/$SOURCE_FILE_NAME.cmp" 2>&1
            # Move-overwrite instead of copy-overwrite to not corrupt running in-memory version of script
            mv -f -v "$SOURCE_FOLDER/Archive/Scripts/$SOURCE_FILE_NAME"     "$SOURCE_FOLDER/$SOURCE_FILE_NAME"                     2>&1
            printf "%s\n" "----------------------------------------"
            cmp -s   "$SOURCE_FOLDER/Archive/Scripts/$SOURCE_FILE_NAME.cmp" "$SOURCE_FOLDER/$SOURCE_FILE_NAME"
            if [ "$?" -eq "0" ]; then
              printf '%17s%s\n' '' "* Script update succeeded!"
              exit_status=1
              if [ -n "$script_release_description" ]; then
                # Show release notes
                printf "\n"
                printf "%s\n" "Release notes:"
                printf "%s\n" "----------------------------------------"
                printf "%s\n" "$script_release_description"
                printf "%s\n" "----------------------------------------"
                printf "%s\n" "Report issues to: $script_help_url"
              fi
            else
              printf '%17s%s\n' '' "* Script update failed to overwrite."
              exit_status=1
            fi
          else
            printf '%17s%s\n' '' "* Script update failed to download."
            exit_status=1
          fi
        else
          printf ' \n%s\n' "Update newer than $minimum_age days - skipping.."
        fi
        # Delete temp comparison file
        find "$SOURCE_FOLDER/Archive/Scripts" -type f -name "$SOURCE_FILE_NAME.cmp" -delete
      fi
    
    else
      printf '%17s%s\n' '' "* No newer version found."
    fi
  fi
  printf "\n"

  # Obtain currently running cloudflared version
  running_version=$(/usr/syno/bin/synopkg version "cloudflared")
  running_version=$(grep -oP '^.+?(?=\-)'                          < <(printf '%s' "$running_version"))

  # Create archived packages dir w/old file cleanup
  if [ -d "$SOURCE_FOLDER/Archive/Packages" ]; then
    find "$SOURCE_FOLDER/Archive/Packages" -type f -name "cloudflared*.spk" -mtime +"$old_updates" -delete
  else
    mkdir -p "$SOURCE_FOLDER/Archive/Packages"
  fi

  # Obtain GitHub website for latest cloudflared build info
  package_repo=karasevm/syno-cloudflared-builds

  # Fetch the latest releases from the GitHub API
  package_releases=$(curl -s "https://api.github.com/repos/$package_repo/releases")

  # Initialize variables to store the latest version info
  latest_package_version=""
  latest_package_date=""
  package_download_url=""

  # Parse the releases to find the latest version with x64-7.1 this is the tag the build repo adds to the
  # package filename for Synology DSM 7.x on x86_64 architecture
  while read -r release; do
      version=$(echo "$release" | jq -r '.tag_name')
      date=$(echo "$release" | jq -r '.published_at')
      asset_url=$(echo "$release" | jq -r '.assets[] | select(.name | contains("x64-7.1")) | .browser_download_url')
      new_ver_date_secs=$(date --date "$date" +'%s')

      # Check if we found a valid asset
      if [ -n "$asset_url" ]; then
          # Update latest version info if this version is newer
          if [ -z "$latest_package_version" ] || version_compare "$version" "$latest_package_version"; then
              latest_package_version="$version"
              latest_package_date="$date"
              latest_package_age=$(((TODAYS_DATE-new_ver_date_secs)/86400))
              latest_package_url="$asset_url"
              latest_package_name=$(basename "$asset_url")
          fi
      fi
  done < <(echo "$package_releases" | jq -c '.[]')

  # Cloudflared status/debug info
  printf '%16s %s\n'         "Synology:" "$SYNOLOGY_HARDWARE_MODEL ($ARCHITECTURE_FAMILY), DSM $DSM_VERSION"
  printf '%16s %s\n'      "Running Ver:" "$running_version"
  if [ -n "$latest_package_version" ]; then
    printf '%16s %s\n'     "Online Ver:" "$latest_package_version"
    printf '%16s %s\n'       "Released:" "$(date --date "$latest_package_date") ($latest_package_age+ days old)"
  else
    printf '%16s %s\n'     "Online Ver:" "Nonexistent"
    exit_status=1
  fi

  # Compare the latest cloudflared version with the running version
  if version_compare "$latest_package_version" "$running_version"; then
    printf '%17s%s\n' '' "* Newer version found!"
    printf "\n"
    printf '%16s %s\n'    "New Package:" "$latest_package_name"
    printf '%16s %s\n'    "Package Age:" "$latest_package_age+ days old ($minimum_age+ required for install)"
    printf "\n"

    # Download and install the cloudflared update
    if [ "$latest_package_age" -ge "$minimum_age" ]; then
      printf "%s\n" "Installing new package:"
      printf "%s\n" "----------------------------------------"
      printf "%s\n" "Downloading cloudflared package:"
      if [ -f "$SOURCE_FOLDER/Archive/Packages/$latest_package_name" ]; then
        printf "%s\n" "* Package already exists in local Archive"
      fi
      /bin/wget -nv -c -nc -P "$SOURCE_FOLDER/Archive/Packages/" "$latest_package_url"                                      2>&1
      if [ "$?" -eq "0" ]; then
        printf "\n%s\n"   "Stopping cloudflared service (JSON):"
        /usr/syno/bin/synopkg stop    "cloudflared"
        printf "\n%s\n" "Installing cloudflared update (JSON):"
        /usr/syno/bin/synopkg install "$SOURCE_FOLDER/Archive/Packages/$latest_package_name" | \
          jq -c '.results[] |= (
            if (.scripts // empty) | type == "array" then
              .scripts |= map(
                if .message then
                  .message |= (
                    gsub("<[^>]*>"; "")     # Strip HTML
                    | split("\n")[0]        # Keep only the first real line
                  )
                else . end
              )
            else .
            end
          )'
        printf "\n%s\n" "Starting cloudflared service (JSON):"
        /usr/syno/bin/synopkg start   "cloudflared"
      else
        printf '\n %s\n' "* Package download failed, skipping install.."
      fi
      printf "%s\n" "----------------------------------------"
      printf "\n"
      now_version=$(/usr/syno/bin/synopkg version "cloudflared")
      printf '%16s %s\n'  "Update from:" "$running_version"
      printf '%16s %s'             "to:" "$latest_package_version"

      # Report cloudflared update status
      if version_compare "$now_version" "$running_version"; then
        printf ' %s\n' "succeeded!"
        exit_status=1
      else
        printf ' %s\n' "failed!"
        exit_status=1
      fi
    else
      printf ' %s\n' "Update newer than $minimum_age days - skipping.."
    fi
  else
    printf '%17s%s\n' '' "* No newer version found."
  fi

  printf "\n"

  # Close and normalize the logging redirections
  exec >&- 2>&- 1>&2

  # Exit normally but possibly with forced exit status for script notifications
  if [ -n "$exit_status" ]; then
    exit "$exit_status"
  fi
}

main "$@"