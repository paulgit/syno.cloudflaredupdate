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
            return 1
        elif (( part1 < part2 )); then
            return 2
        fi
    done
    
    return 0
}

main() {
  # SCRAPE SCRIPT PATH INFO
  SrceFllPth=$(readlink -f "${BASH_SOURCE[0]}")
  SrceFolder=$(dirname "$SrceFllPth")
  SrceFileNm=${SrceFllPth##*/}

  # REDIRECT STDOUT TO TEE IN ORDER TO DUPLICATE THE OUTPUT TO THE TERMINAL AS WELL AS A .LOG FILE
  exec > >(tee "$SrceFllPth.log") 2>"$SrceFllPth.debug"

  # ENABLE XTRACE OUTPUT FOR DEBUG FILE
  set -x

  # SCRIPT VERSION
  SpuscrpVer=0.1.0
  MinDSMVers=7.2
  # PRINT OUR GLORIOUS HEADER BECAUSE WE ARE FULL OF OURSELVES
  printf "\n"
  printf "%s\n" "SYNO.CLOUDFLARED UPDATE SCRIPT v$SpuscrpVer for DSM 7"
  printf "\n"

  # CHECK IF ROOT
  if [ "$EUID" -ne "0" ]; then
    printf ' %s\n\n' "* This script MUST be run as root - exiting.."
    /usr/syno/bin/synonotify PKGHasUpgrade '{"%PKG_HAS_UPDATE%": "cloudflared\n\nSyno.cloudflared Update task failed. Script was not run as root."}'
    printf "\n"
    exit 1
  fi

  # CHECK IF DEFAULT CONFIG FILE EXISTS, IF NOT CREATE IT
  create_or_update_config() {
    local ConfigFile="$1"
    if [ ! -f "$ConfigFile" ]; then
      printf ' %s\n\n' "* CONFIGURATION FILE (config.ini) IS MISSING, CREATING DEFAULT SETUP.."
      touch "$ConfigFile"
      ExitStatus=1
    fi
    # Function to add key-value pairs along with comments if not present
    add_config_with_comment() {
      local key="$1"
      local value="$2"
      local comment="$3"
      if ! grep -q "^$key=" "$ConfigFile"; then
        printf '%s\n' "$comment" >> "$ConfigFile"
        printf '%s\n' "$key=$value" >> "$ConfigFile"
      fi
    }
    # Default configurations
    add_config_with_comment "MinimumAge" "7"   "# A NEW UPDATE MUST BE THIS MANY DAYS OLD"
    add_config_with_comment "OldUpdates" "60"  "# PREVIOUSLY DOWNLOADED PACKAGES DELETED IF OLDER THAN THIS MANY DAYS"
    add_config_with_comment "NetTimeout" "900" "# NETWORK TIMEOUT IN SECONDS (900s = 15m)"
    add_config_with_comment "SelfUpdate" "0"   "# SCRIPT WILL SELF-UPDATE IF SET TO 1"
  }
  create_or_update_config "$SrceFolder/config.ini"

  # LOAD CONFIG FILE IF IT EXISTS
  if [ -f "$SrceFolder/config.ini" ]; then
    source "$SrceFolder/config.ini"
  fi

  # PRINT SCRIPT STATUS/DEBUG INFO
  printf '%16s %s\n'                   "Script:" "$SrceFileNm"
  printf '%16s %s\n'               "Script Dir:" "$(fold -w 72 -s     < <(printf '%s' "$SrceFolder") | sed '2,$s/^/                 /')"

  # CHECK FOR BASIC INTERNET CONNECTIVITY
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

  # OVERRIDE SETTINGS WITH CLI OPTIONS
  while getopts ":a:c:mh" opt; do
    case ${opt} in
      a) # AUTO-UPDATE SCRIPT AND CLOUDFLARED
        # Check if the value is numerical only
        if [[ $OPTARG =~ ^[0-9]+$ ]]; then
          MinimumAge=$OPTARG
          printf '%16s %s\n'         "Override:" "-a, Minimum Age set to $MinimumAge days"
        else
          printf '\n%16s %s\n\n'   "Bad Option:" "-a, requires a number value for minimum age in days"
          exit 1
        fi
        ;;
      c) # CHOOSE UPDATE CHANNEL
        case $OPTARG in
          p) UpdtChannl="0" # Public channel
            printf '%16s %s\n'       "Override:" "-c, Update Channel set to Public"
            ;;
          b) UpdtChannl="8" # Beta channel
            printf '%16s %s\n'       "Override:" "-c, Update Channel set to Beta"
            ;;
          *)
            printf '\n%16s %s\n\n' "Bad Option:" "-c, Requires either 'p' for Public or 'b' for Beta channels"
            exit 1
            ;;
        esac
        ;;
      m) # UPDATE TO MASTER BRANCH (NON-RELEASE)
        MasterUpdt=true
        printf '%16s %s\n'           "Override:" "-m, Forcing script update from Master branch"
        ;;
      h) # HELP OPTION
        printf '\n%s\n\n'  "Usage: $SrceFileNm [-a #] [-c p|b] [-m] [-h]"
        printf ' %s\n'   "-a: Override the minimum age in days"
        printf ' %s\n'   "-c: Override the update channel (p for Public, b for Beta)"
        printf ' %s\n'   "-m: Update from the master branch (non-release version)"
        printf ' %s\n\n' "-h: Display this help message"
        exit 0
        ;;
      \?) # INVALID OPTION
        printf '\n%16s %s\n\n'     "Bad Option:" "-$OPTARG, Invalid (-h for help)"
        exit 1
        ;;
      :) # MISSING ARGUMENT
        printf '\n%16s %s\n\n'     "Bad Option:" "-$OPTARG, Requires an argument (-h for help)"
        exit 1
        ;;
    esac
  done

  # CHECK IF SCRIPT IS ARCHIVED
  if [ ! -d "$SrceFolder/Archive/Scripts" ]; then
    mkdir -p "$SrceFolder/Archive/Scripts"
  fi
  if [ ! -f "$SrceFolder/Archive/Scripts/syno.cloudflaredupdate.v$SpuscrpVer.sh" ]; then
    cp "$SrceFllPth" "$SrceFolder/Archive/Scripts/syno.cloudflaredupdate.v$SpuscrpVer.sh"
  else
    cmp -s "$SrceFllPth" "$SrceFolder/Archive/Scripts/syno.cloudflaredupdate.v$SpuscrpVer.sh"
    if [ "$?" -ne "0" ]; then
      cp "$SrceFllPth" "$SrceFolder/Archive/Scripts/syno.cloudflaredupdate.v$SpuscrpVer.sh"
    fi
  fi

  # GET EPOCH TIMESTAMP FOR AGE CHECKS
  TodaysDate=$(date +%s)

  # SCRAPE GITHUB WEBSITE FOR LATEST INFO
  GitHubRepo=paulgit/syno.cloudflaredupdate
  GitHubHtml=$(curl -i -m "$NetTimeout" -Ls https://api.github.com/repos/$GitHubRepo/releases?per_page=1)
  if [ "$?" -eq "0" ]; then
    # AVOID SCRAPING SQUARED BRACKETS BECAUSE GITHUB IS INCONSISTENT
    GitHubJson=$(grep -oPz '\{\s{0,6}\"\X*\s{0,4}\}'          < <(printf '%s' "$GitHubHtml") | tr -d '\0')
    # ADD SQUARED BRACKETS BECAUSE ITS PROPER AND JQ NEEDS IT
    GitHubJson=$'[\n'"$GitHubJson"$'\n]'
    GitHubHtml=$(grep -oPz '\X*\{\W{0,6}\"'                   < <(printf '%s' "$GitHubHtml")  | tr -d '\0' | sed -z 's/\W\[.*//')
    # SCRAPE CURRENT RATE LIMIT
    SpusApiRlm=$(grep -oP '^x-ratelimit-limit: \K[\d]+'       < <(printf '%s' "$GitHubHtml"))
    SpusApiRlr=$(grep -oP '^x-ratelimit-remaining: \K[\d]+'   < <(printf '%s' "$GitHubHtml"))
    #if [[ -n "$SpusApiRlm" && -n "$SpusApiRlr" ]]; then
    #  SpusApiRla=$((SpusApiRlm - SpusApiRlr))
    #fi
    # SCRAPE API MESSAGES
    SpusApiMsg=$(jq -r '.[].message'                          < <(printf '%s' "$GitHubJson"))
    SpusApiDoc=$(jq -r '.[].documentation_url'                < <(printf '%s' "$GitHubJson"))
    # SCRAPE EXPECTED RELEASE-RELATED INFO
    SpusNewVer=$(jq -r '.[].tag_name'                         < <(printf '%s' "$GitHubJson"))
    SpusNewVer=${SpusNewVer#v}
    SpusRlDate=$(jq -r '.[].published_at'                     < <(printf '%s' "$GitHubJson"))
    SpusRlDate=$(date --date "$SpusRlDate" +'%s')
    SpusRelAge=$(((TodaysDate-SpusRlDate)/86400))
    if [ "$MasterUpdt" = "true" ]; then
      SpusDwnUrl=https://raw.githubusercontent.com/$GitHubRepo/master/syno.cloudflaredupdate.sh
      SpusRelDes=$'* Check GitHub for master branch commit messages and extended descriptions'
    else
      SpusDwnUrl=https://raw.githubusercontent.com/$GitHubRepo/v$SpusNewVer/syno.cloudlfaredupdate.sh
      SpusRelDes=$(jq -r '.[].body'                             < <(printf '%s' "$GitHubJson"))
    fi
    SpusHlpUrl=https://github.com/$GitHubRepo/issues
  else
    printf ' %s\n\n' "* UNABLE TO CHECK FOR LATEST VERSION OF SCRIPT.."
    ExitStatus=1
  fi

  # PRINT SCRIPT STATUS/DEBUG INFO
  printf '%16s %s\n'      "Running Ver:" "$SpuscrpVer"

  if [ "$SpusNewVer" = "null" ]; then
    printf "%16s %s\n" "GitHub API Msg:" "$(fold -w 72 -s     < <(printf '%s' "$SpusApiMsg") | sed '2,$s/^/                 /')"
    printf "%16s %s\n" "GitHub API Lmt:" "$SpusApiRlm connections per hour per IP"
    printf "%16s %s\n" "GitHub API Doc:" "$(fold -w 72 -s     < <(printf '%s' "$SpusApiDoc") | sed '2,$s/^/                 /')"
    ExitStatus=1
  elif [ "$SpusNewVer" != "" ]; then
    printf '%16s %s\n'     "Online Ver:" "$SpusNewVer (attempts left $SpusApiRlr/$SpusApiRlm)"
    printf '%16s %s\n'       "Released:" "$(date --rfc-3339 seconds --date @"$SpusRlDate") ($SpusRelAge+ days old)"
  fi

  # COMPARE SCRIPT VERSIONS
  if [[ "$SpusNewVer" != "null" ]]; then
    if /usr/bin/dpkg --compare-versions "$SpusNewVer" gt "$SpuscrpVer" || [[ "$MasterUpdt" == "true" ]]; then
      if [[ "$MasterUpdt" == "true" ]]; then
        printf '%17s%s\n' '' "* Updating from master branch!"
      else
        printf '%17s%s\n' '' "* Newer version found!"
      fi
      # DOWNLOAD AND INSTALL THE SCRIPT UPDATE
      if [ "$SelfUpdate" -eq "1" ]; then
        if [ "$SpusRelAge" -ge "$MinimumAge" ] || [ "$MasterUpdt" = "true" ]; then
          printf "\n"
          printf "%s\n" "INSTALLING NEW SCRIPT:"
          printf "%s\n" "----------------------------------------"
          /bin/wget -nv -O "$SrceFolder/Archive/Scripts/$SrceFileNm" "$SpusDwnUrl"                               2>&1
          if [ "$?" -eq "0" ]; then
            # MAKE A COPY FOR UPGRADE COMPARISON BECAUSE WE ARE GOING TO MOVE NOT COPY THE NEW FILE
            cp -f -v "$SrceFolder/Archive/Scripts/$SrceFileNm"     "$SrceFolder/Archive/Scripts/$SrceFileNm.cmp" 2>&1
            # MOVE-OVERWRITE INSTEAD OF COPY-OVERWRITE TO NOT CORRUPT RUNNING IN-MEMORY VERSION OF SCRIPT
            mv -f -v "$SrceFolder/Archive/Scripts/$SrceFileNm"     "$SrceFolder/$SrceFileNm"                     2>&1
            printf "%s\n" "----------------------------------------"
            cmp -s   "$SrceFolder/Archive/Scripts/$SrceFileNm.cmp" "$SrceFolder/$SrceFileNm"
            if [ "$?" -eq "0" ]; then
              printf '%17s%s\n' '' "* Script update succeeded!"
              /usr/syno/bin/synonotify PKGHasUpgrade '{"%PKG_HAS_UPDATE%": "Syno.cloudflared Update\n\nSelf-Update completed successfully"}'
              ExitStatus=1
              if [ -n "$SpusRelDes" ]; then
                # SHOW RELEASE NOTES
                printf "\n"
                printf "%s\n" "RELEASE NOTES:"
                printf "%s\n" "----------------------------------------"
                printf "%s\n" "$SpusRelDes"
                printf "%s\n" "----------------------------------------"
                printf "%s\n" "Report issues to: $SpusHlpUrl"
              fi
            else
              printf '%17s%s\n' '' "* Script update failed to overwrite."
              /usr/syno/bin/synonotify PKGHasUpgrade '{"%PKG_HAS_UPDATE%": "Syno.cloudflared Update\n\nSelf-Update failed."}'
              ExitStatus=1
            fi
          else
            printf '%17s%s\n' '' "* Script update failed to download."
            /usr/syno/bin/synonotify PKGHasUpgrade '{"%PKG_HAS_UPDATE%": "Syno.cloudflared Update\n\nSelf-Update failed to download."}'
            ExitStatus=1
          fi
        else
          printf ' \n%s\n' "Update newer than $MinimumAge days - skipping.."
        fi
        # DELETE TEMP COMPARISON FILE
        find "$SrceFolder/Archive/Scripts" -type f -name "$SrceFileNm.cmp" -delete
      fi
    
    else
      printf '%17s%s\n' '' "* No new version found."
    fi
  fi
  printf "\n"

  # SCRAPE SYNOLOGY HARDWARE MODEL
  SynoHModel=$(< /proc/sys/kernel/syno_hw_version)
  # SCRAPE SYNOLOGY CPU ARCHITECTURE FAMILY
  ArchFamily=$(uname --machine)

  # Check synology architecture family for package selection
  if [ "$ArchFamily" != "x86_64" ] && [ "$ArchFamily" != "i686" ]; then
    printf ' %s\n\n' "* Untested/Unsported architecture: $ArchFamily - exiting.."
    ExitStatus=1
  fi  

  # SCRAPE DSM VERSION AND CHECK COMPATIBILITY
  DSMVersion=$(grep -i "productversion=" "/etc.defaults/VERSION" | cut -d"\"" -f 2)

  # CHECK IF DSM 7
  if /usr/bin/dpkg --compare-versions "$MinDSMVers" gt "$DSMVersion"; then
    printf ' %s\n' "* Syno.cloudflared Update requires DSM $MinDSMVers minimum to install - exiting.."
    /usr/syno/bin/synonotify PKGHasUpgrade '{"%PKG_HAS_UPDATE%": "cloudflared\n\nSyno.cloudflared Update task failed. DSM not sufficient version."}'
    printf "\n"
    exit 1
  fi

  # SCRAPE CURRENTLY RUNNING CLOUDFLARED VERSION
  RunVersion=$(/usr/syno/bin/synopkg version "cloudflared")
  RunVersion=$(grep -oP '^.+?(?=\-)'                          < <(printf '%s' "$RunVersion"))

  # CREATE ARCHIVED PACKAGES DIR W/OLD FILE CLEANUP
  if [ -d "$SrceFolder/Archive/Packages" ]; then
    find "$SrceFolder/Archive/Packages" -type f -name "cloudflared*.spk" -mtime +"$OldUpdates" -delete
  else
    mkdir -p "$SrceFolder/Archive/Packages"
  fi

  # SCRAPE GITHUB WEBSITE FOR LATEST CLOUDFLARED BUILD INFO
  PKG_REPO=karasevm/syno-cloudflared-builds

  # Fetch the latest releases from the GitHub API
  PKG_RELEASES=$(curl -s "https://api.github.com/repos/$PKG_REPO/releases")

  # Initialize variables to store the latest version info
  LATEST_PKG_VERSION=""
  LATEST_PKG_DATE=""
  PKG_DOWNLOAD_URL=""

  # Parse the releases to find the latest version with x64-7.1
  while read -r release; do
      VERSION=$(echo "$release" | jq -r '.tag_name')
      DATE=$(echo "$release" | jq -r '.published_at')
      ASSET_URL=$(echo "$release" | jq -r '.assets[] | select(.name | contains("x64-7.1")) | .browser_download_url')

      # Check if we found a valid asset
      if [ -n "$ASSET_URL" ]; then
          # Update latest version info if this version is newer
          if [ -z "$LATEST_PKG_VERSION" ] || version_compare "$VERSION" "$LATEST_PKG_VERSION"; then
              LATEST_PKG_VERSION="$VERSION"
              LATEST_PKG_DATE="$DATE"
              LATEST_PKG_AGE=$(((TodaysDate-NewVerDate)/86400))
              LATEST_PKG_URL="$ASSET_URL"
              LATEST_PKG_NAME=$(basename "$ASSET_URL")
          fi
      fi
  done < <(echo "$RELEASES" | jq -c '.[]')


  # cloudflared status/debug info
  printf '%16s %s\n'         "Synology:" "$SynoHModel ($ArchFamily), DSM $DSMVersion"
  printf '%16s %s\n'      "Running Ver:" "$RunVersion"
  if [ -n "$LATEST_PKG_VERSION" ]; then
    printf '%16s %s\n'     "Online Ver:" "$LATEST_PKG_VERSION"
    printf '%16s %s\n'       "Released:" "$(date --rfc-3339 seconds --date @"$LATEST_PKG_DATE") ($LATEST_PKG_AGE+ days old)"
  else
    printf '%16s %s\n'     "Online Ver:" "Nonexistent"
    ExitStatus=1
  fi

  # Compare the latest cloudflared version with the running version
  if version_compare "$LATEST_PKG_VERSION" "$RunVersion"; then
    printf '%17s%s\n' '' "* Newer version found!"
    printf "\n"
    printf '%16s %s\n'    "New Package:" "$LATEST_PKG_NAME"
    printf '%16s %s\n'    "Package Age:" "$LATEST_PKG_AGE+ days old ($MinimumAge+ required for install)"
    printf "\n"

    # DOWNLOAD AND INSTALL THE CLOUDFLARED UPDATE
    if [ "$LATEST_PKG_AGE" -ge "$MinimumAge" ]; then
      printf "%s\n" "INSTALLING NEW PACKAGE:"
      printf "%s\n" "----------------------------------------"
      printf "%s\n" "Downloading cloudflared package:"
      if [ -f "$SrceFolder/Archive/Packages/$LATEST_PKG_NAME" ]; then
        printf "%s\n" "* Package already exists in local Archive"
      fi
      /bin/wget -nv -c -nc -P "$SrceFolder/Archive/Packages/" "$LATEST_PKG_URL"                                      2>&1
      if [ "$?" -eq "0" ]; then
        printf "\n%s\n"   "Stopping cloudflared service (JSON):"
        /usr/syno/bin/synopkg stop    "cloudflared"
        printf "\n%s\n" "Installing cloudflared update (JSON):"
        /usr/syno/bin/synopkg install "$SrceFolder/Archive/Packages/$LATEST_PKG_NAME" | \
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
      NowVersion=$(/usr/syno/bin/synopkg version "cloudflared")
      printf '%16s %s\n'  "Update from:" "$RunVersion"
      printf '%16s %s'             "to:" "$LATEST_PKG_VERSION"

      # REPORT CLOUDFLARED UPDATE STATUS
      if version_compare "$NowVersion" "$RunVersion"; then
        printf ' %s\n' "succeeded!"
        printf "\n"
        /usr/syno/bin/synonotify PKGHasUpgrade '{"%PKG_HAS_UPDATE%": "cloudflared\n\nSyno.cloudflared Update task completed successfully"}'
        ExitStatus=1
      else
        printf ' %s\n' "failed!"
        /usr/syno/bin/synonotify PKGHasUpgrade '{"%PKG_HAS_UPDATE%": "cloudflared\n\nSyno.cloudflared Update task failed. Installation not newer version."}'
        ExitStatus=1
      fi
    else
      printf ' %s\n' "Update newer than $MinimumAge days - skipping.."
    fi
  else
    printf '%17s%s\n' '' "* No new version found."
  fi

  printf "\n"

  # CLOSE AND NORMALIZE THE LOGGING REDIRECTIONS
  exec >&- 2>&- 1>&2

  # EXIT NORMALLY BUT POSSIBLY WITH FORCED EXIT STATUS FOR SCRIPT NOTIFICATIONS
  if [ -n "$ExitStatus" ]; then
    exit "$ExitStatus"
  fi
}

main "$@"