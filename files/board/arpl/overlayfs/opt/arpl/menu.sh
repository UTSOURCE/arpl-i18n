#!/usr/bin/env bash

. /opt/arpl/include/functions.sh
. /opt/arpl/include/addons.sh
. /opt/arpl/include/modules.sh

# Check partition 3 space, if < 2GiB is necessary clean cache folder
CLEARCACHE=0
LOADER_DISK="`blkid | grep 'LABEL="ARPL3"' | cut -d3 -f1`"
LOADER_DEVICE_NAME=`echo ${LOADER_DISK} | sed 's|/dev/||'`
if [ `cat /sys/block/${LOADER_DEVICE_NAME}/${LOADER_DEVICE_NAME}3/size` -lt 4194304 ]; then
  CLEARCACHE=1
fi

# Get actual IP
IP=`ip route 2>/dev/null | sed -n 's/.* via .* src \(.*\) metric .*/\1/p' | head -1` # `ip route get 1.1.1.1 2>/dev/null | awk '{print$7}'`

# Dirty flag
DIRTY=0

MODEL="`readConfigKey "model" "${USER_CONFIG_FILE}"`"
BUILD="`readConfigKey "build" "${USER_CONFIG_FILE}"`"
LAYOUT="`readConfigKey "layout" "${USER_CONFIG_FILE}"`"
KEYMAP="`readConfigKey "keymap" "${USER_CONFIG_FILE}"`"
LKM="`readConfigKey "lkm" "${USER_CONFIG_FILE}"`"
DIRECTBOOT="`readConfigKey "directboot" "${USER_CONFIG_FILE}"`"
SN="`readConfigKey "sn" "${USER_CONFIG_FILE}"`"

###############################################################################
# Mounts backtitle dynamically
function backtitle() {
  BACKTITLE="${ARPL_TITLE}"
  if [ -n "${MODEL}" ]; then
    BACKTITLE+=" ${MODEL}"
  else
    BACKTITLE+=" (no model)"
  fi
  if [ -n "${BUILD}" ]; then
    BACKTITLE+=" ${BUILD}"
  else
    BACKTITLE+=" (no build)"
  fi
  if [ -n "${SN}" ]; then
    BACKTITLE+=" ${SN}"
  else
    BACKTITLE+=" (no SN)"
  fi
  if [ -n "${IP}" ]; then
    BACKTITLE+=" ${IP}"
  else
    BACKTITLE+=" (no IP)"
  fi
  if [ -n "${KEYMAP}" ]; then
    BACKTITLE+=" (${LAYOUT}/${KEYMAP})"
  else
    BACKTITLE+=" (qwerty/us)"
  fi
  if [ -d "/sys/firmware/efi" ]; then
    BACKTITLE+=" [UEFI]"
  else
    BACKTITLE+=" [BIOS]"
  fi
  echo ${BACKTITLE}
}

###############################################################################
# Shows available models to user choose one
function modelMenu() {
  if [ -z "${1}" ]; then
    RESTRICT=1
    FLGBETA=0
    dialog --backtitle "`backtitle`" --title "$(TEXT "Model")" --aspect 18 \
      --infobox "$(TEXT "Reading models")" 0 0
    while true; do
      echo "" > "${TMP_PATH}/menu"
      FLGNEX=0
      while read M; do
        M="`basename ${M}`"
        M="${M::-4}"
        PLATFORM=`readModelKey "${M}" "platform"`
        DT="`readModelKey "${M}" "dt"`"
        BETA="`readModelKey "${M}" "beta"`"
        [ "${BETA}" = "true" -a ${FLGBETA} -eq 0 ] && continue
        # Check id model is compatible with CPU
        COMPATIBLE=1
        if [ ${RESTRICT} -eq 1 ]; then
          for F in `readModelArray "${M}" "flags"`; do
            if ! grep -q "^flags.*${F}.*" /proc/cpuinfo; then
              COMPATIBLE=0
              FLGNEX=1
              break
            fi
          done
        fi
        [ "${DT}" = "true" ] && DT="-DT" || DT=""
        [ ${COMPATIBLE} -eq 1 ] && echo "${M} \"\Zb${PLATFORM}${DT}\Zn\" " >> "${TMP_PATH}/menu"
      done < <(find "${MODEL_CONFIG_PATH}" -maxdepth 1 -name \*.yml | sort)
      [ ${FLGNEX} -eq 1 ] && echo "f \"\Z1$(TEXT "Disable flags restriction")\Zn\"" >> "${TMP_PATH}/menu"
      [ ${FLGBETA} -eq 0 ] && echo "b \"\Z1$(TEXT "Show beta models")\Zn\"" >> "${TMP_PATH}/menu"
      dialog --backtitle "`backtitle`" --colors --menu "$(TEXT "Choose the model")" 0 0 0 \
        --file "${TMP_PATH}/menu" 2>${TMP_PATH}/resp
      [ $? -ne 0 ] && return
      resp=$(<${TMP_PATH}/resp)
      [ -z "${resp}" ] && return
      if [ "${resp}" = "f" ]; then
        RESTRICT=0
        continue
      fi
      if [ "${resp}" = "b" ]; then
        FLGBETA=1
        continue
      fi
      break
    done
  else
    resp="${1}"
  fi
  # If user change model, clean buildnumber and S/N
  if [ "${MODEL}" != "${resp}" ]; then
    MODEL=${resp}
    writeConfigKey "model" "${MODEL}" "${USER_CONFIG_FILE}"
    BUILD=""
    writeConfigKey "build" "${BUILD}" "${USER_CONFIG_FILE}"
    SN=""
    writeConfigKey "sn" "${SN}" "${USER_CONFIG_FILE}"
    # Delete old files
    rm -f "${ORI_ZIMAGE_FILE}" "${ORI_RDGZ_FILE}" "${MOD_ZIMAGE_FILE}" "${MOD_RDGZ_FILE}"
    DIRTY=1
  fi
}

###############################################################################
# Shows available buildnumbers from a model to user choose one
function buildMenu() {
  ITEMS="`readConfigEntriesArray "builds" "${MODEL_CONFIG_PATH}/${MODEL}.yml" | sort -r`"
  if [ -z "${1}" ]; then
    dialog --clear --no-items --backtitle "`backtitle`" \
      --menu "$(TEXT "Choose a build number")" 0 0 0 ${ITEMS} 2>${TMP_PATH}/resp
    [ $? -ne 0 ] && return
    resp=$(<${TMP_PATH}/resp)
    [ -z "${resp}" ] && return
  else
    if ! arrayExistItem "${1}" ${ITEMS}; then return; fi
    resp="${1}"
  fi
  if [ "${BUILD}" != "${resp}" ]; then
    local KVER=`readModelKey "${MODEL}" "builds.${resp}.kver"`
    if [ -d "/sys/firmware/efi" -a "${KVER:0:1}" = "3" ]; then
      dialog --backtitle "`backtitle`" --title "$(TEXT "Build Number")" --aspect 18 \
       --msgbox "$(TEXT "This version does not support UEFI startup, Please select another version or switch the startup mode.")" 0 0
      buildMenu
    fi
    dialog --backtitle "`backtitle`" --title "$(TEXT "Build Number")" \
      --infobox "$(TEXT "Reconfiguring Synoinfo, Addons and Modules")" 0 0
    BUILD=${resp}
    writeConfigKey "build" "${BUILD}" "${USER_CONFIG_FILE}"
    # Delete synoinfo and reload model/build synoinfo
    writeConfigKey "synoinfo" "{}" "${USER_CONFIG_FILE}"
    while IFS=': ' read KEY VALUE; do
      writeConfigKey "synoinfo.${KEY}" "${VALUE}" "${USER_CONFIG_FILE}"
    done < <(readModelMap "${MODEL}" "builds.${BUILD}.synoinfo")
    # Check addons
    PLATFORM="`readModelKey "${MODEL}" "platform"`"
    KVER="`readModelKey "${MODEL}" "builds.${BUILD}.kver"`"
    while IFS=': ' read ADDON PARAM; do
      [ -z "${ADDON}" ] && continue
      if ! checkAddonExist "${ADDON}" "${PLATFORM}" "${KVER}"; then
        deleteConfigKey "addons.${ADDON}" "${USER_CONFIG_FILE}"
      fi
    done < <(readConfigMap "addons" "${USER_CONFIG_FILE}")
    # Rebuild modules
    writeConfigKey "modules" "{}" "${USER_CONFIG_FILE}"
    while read ID DESC; do
      writeConfigKey "modules.${ID}" "" "${USER_CONFIG_FILE}"
    done < <(getAllModules "${PLATFORM}" "${KVER}")
    # Remove old files
    rm -f "${ORI_ZIMAGE_FILE}" "${ORI_RDGZ_FILE}" "${MOD_ZIMAGE_FILE}" "${MOD_RDGZ_FILE}"
    DIRTY=1
  fi
}

###############################################################################
# Shows menu to user type one or generate randomly
function serialMenu() {
  while true; do
    dialog --clear --backtitle "`backtitle`" \
      --menu "$(TEXT "Choose a option")" 0 0 0 \
      a "$(TEXT "Generate a random serial number")" \
      m "$(TEXT "Enter a serial number")" \
    2>${TMP_PATH}/resp
    [ $? -ne 0 ] && return
    resp=$(<${TMP_PATH}/resp)
    [ -z "${resp}" ] && return
    if [ "${resp}" = "m" ]; then
      while true; do
        dialog --backtitle "`backtitle`" \
          --inputbox "$(TEXT "Please enter a serial number ")" 0 0 "" \
          2>${TMP_PATH}/resp
        [ $? -ne 0 ] && return
        SERIAL=`cat ${TMP_PATH}/resp`
        if [ -z "${SERIAL}" ]; then
          return
        elif [ `validateSerial ${MODEL} ${SERIAL}` -eq 1 ]; then
          break
        fi
        dialog --backtitle "`backtitle`" --title "$(TEXT "Alert")" \
          --yesno "$(TEXT "Invalid serial, continue?")" 0 0
        [ $? -eq 0 ] && break
      done
      break
    elif [ "${resp}" = "a" ]; then
      SERIAL=`generateSerial "${MODEL}"`
      break
    fi
  done
  SN="${SERIAL}"
  writeConfigKey "sn" "${SN}" "${USER_CONFIG_FILE}"
}

###############################################################################
# Manage addons
function addonMenu() {
  # Read 'platform' and kernel version to check if addon exists
  PLATFORM="`readModelKey "${MODEL}" "platform"`"
  KVER="`readModelKey "${MODEL}" "builds.${BUILD}.kver"`"
  # Read addons from user config
  unset ADDONS
  declare -A ADDONS
  while IFS=': ' read KEY VALUE; do
    [ -n "${KEY}" ] && ADDONS["${KEY}"]="${VALUE}"
  done < <(readConfigMap "addons" "${USER_CONFIG_FILE}")
  NEXT="a"
  # Loop menu
  while true; do
    dialog --backtitle "`backtitle`" --default-item ${NEXT} \
      --menu "$(TEXT "Choose a option")" 0 0 0 \
      a "$(TEXT "Add an addon")" \
      d "$(TEXT "Delete addon(s)")" \
      s "$(TEXT "Show user addons")" \
      m "$(TEXT "Show all available addons")" \
      o "$(TEXT "Download a external addon")" \
      e "$(TEXT "Exit")" \
      2>${TMP_PATH}/resp
    [ $? -ne 0 ] && return
    case "`<${TMP_PATH}/resp`" in
      a) NEXT='a'
        rm "${TMP_PATH}/menu"
        while read ADDON DESC; do
          arrayExistItem "${ADDON}" "${!ADDONS[@]}" && continue          # Check if addon has already been added
          echo "${ADDON} \"${DESC}\"" >> "${TMP_PATH}/menu"
        done < <(availableAddons "${PLATFORM}" "${KVER}")
        if [ ! -f "${TMP_PATH}/menu" ] ; then 
          dialog --backtitle "`backtitle`" --msgbox "$(TEXT "No available addons to add")" 0 0 
          NEXT="e"
          continue
        fi
        dialog --backtitle "`backtitle`" --menu "$(TEXT "Select an addon")" 0 0 0 \
          --file "${TMP_PATH}/menu" 2>"${TMP_PATH}/resp"
        [ $? -ne 0 ] && continue
        ADDON="`<"${TMP_PATH}/resp"`"
        [ -z "${ADDON}" ] && continue
        dialog --backtitle "`backtitle`" --title "$(TEXT "Params")" \
          --inputbox "$(TEXT "Type a opcional params to addon")" 0 0 \
          2>${TMP_PATH}/resp
        [ $? -ne 0 ] && continue
        ADDONS[${ADDON}]="`<"${TMP_PATH}/resp"`"
        writeConfigKey "addons.${ADDON}" "${VALUE}" "${USER_CONFIG_FILE}"
        DIRTY=1
        ;;
      d) NEXT='d'
        if [ ${#ADDONS[@]} -eq 0 ]; then
          dialog --backtitle "`backtitle`" --msgbox "$(TEXT "No user addons to remove")" 0 0 
          continue
        fi
        ITEMS=""
        for I in "${!ADDONS[@]}"; do
          ITEMS+="${I} ${I} off "
        done
        dialog --backtitle "`backtitle`" --no-tags \
          --checklist "$(TEXT "Select addon to remove")" 0 0 0 ${ITEMS} \
          2>"${TMP_PATH}/resp"
        [ $? -ne 0 ] && continue
        ADDON="`<"${TMP_PATH}/resp"`"
        [ -z "${ADDON}" ] && continue
        for I in ${ADDON}; do
          unset ADDONS[${I}]
          deleteConfigKey "addons.${I}" "${USER_CONFIG_FILE}"
        done
        DIRTY=1
        ;;
      s) NEXT='s'
        ITEMS=""
        for KEY in ${!ADDONS[@]}; do
          ITEMS+="${KEY}: ${ADDONS[$KEY]}\n"
        done
        dialog --backtitle "`backtitle`" --title "$(TEXT "User addons")" \
          --msgbox "${ITEMS}" 0 0
        ;;
      m) NEXT='m'
        MSG=""
        while read MODULE DESC; do
          if arrayExistItem "${MODULE}" "${!ADDONS[@]}"; then
            MSG+="\Z4${MODULE}\Zn"
          else
            MSG+="${MODULE}"
          fi
          MSG+=": \Z5${DESC}\Zn\n"
        done < <(availableAddons "${PLATFORM}" "${KVER}")
        dialog --backtitle "`backtitle`" --title "$(TEXT "Available addons")" \
          --colors --msgbox "${MSG}" 0 0
        ;;
      o)
        dialog --backtitle "`backtitle`" --aspect 18 --colors --inputbox "$(TEXT "please enter the complete URL to download.\n")" 0 0 \
          2>${TMP_PATH}/resp
        [ $? -ne 0 ] && continue
        URL="`<"${TMP_PATH}/resp"`"
        [ -z "${URL}" ] && continue
        clear
        echo "`printf "$(TEXT "Downloading %s")" "${URL}"`"
        STATUS=`curl -k -w "%{http_code}" -L "${URL}" -o "${TMP_PATH}/addon.tgz" --progress-bar`
        if [ $? -ne 0 -o ${STATUS} -ne 200 ]; then
          dialog --backtitle "`backtitle`" --title "$(TEXT "Error downloading")" --aspect 18 \
            --msgbox "$(TEXT "Check internet, URL or cache disk space")" 0 0
          return 1
        fi
        ADDON="`untarAddon "${TMP_PATH}/addon.tgz"`"
        if [ -n "${ADDON}" ]; then
          dialog --backtitle "`backtitle`" --title "$(TEXT "Success")" --aspect 18 \
            --msgbox "`printf "$(TEXT "Addon '%s' added to loader")" "${ADDON}"`" 0 0
        else
          dialog --backtitle "`backtitle`" --title "$(TEXT "Invalid addon")" --aspect 18 \
            --msgbox "$(TEXT "File format not recognized!")" 0 0
        fi
        ;;
      e) return ;;
    esac
  done
}

###############################################################################
function cmdlineMenu() {
  unset CMDLINE
  declare -A CMDLINE
  while IFS=': ' read KEY VALUE; do
    [ -n "${KEY}" ] && CMDLINE["${KEY}"]="${VALUE}"
  done < <(readConfigMap "cmdline" "${USER_CONFIG_FILE}")
  echo "a \"$(TEXT "Add/edit a cmdline item")\""                           > "${TMP_PATH}/menu"
  echo "d \"$(TEXT "Delete cmdline item(s)")\""                           >> "${TMP_PATH}/menu"
  echo "c \"$(TEXT "Define a custom MAC")\""                              >> "${TMP_PATH}/menu"
  echo "s \"$(TEXT "Show user cmdline")\""                                >> "${TMP_PATH}/menu"
  echo "m \"$(TEXT "Show model/build cmdline")\""                         >> "${TMP_PATH}/menu"
  echo "e \"$(TEXT "Exit")\""                                             >> "${TMP_PATH}/menu"
  # Loop menu
  while true; do
    dialog --backtitle "`backtitle`" --menu "$(TEXT "Choose a option")" 0 0 0 \
      --file "${TMP_PATH}/menu" 2>${TMP_PATH}/resp
    [ $? -ne 0 ] && return
    case "`<${TMP_PATH}/resp`" in
      a)
        dialog --backtitle "`backtitle`" --title "$(TEXT "User cmdline")" \
          --inputbox "$(TEXT "Type a name of cmdline")" 0 0 \
          2>${TMP_PATH}/resp
        [ $? -ne 0 ] && continue
        NAME="`sed 's/://g' <"${TMP_PATH}/resp"`"
        [ -z "${NAME}" ] && continue
        dialog --backtitle "`backtitle`" --title "$(TEXT "User cmdline")" \
          --inputbox "`printf "$(TEXT "Type a value of '%s' cmdline")" "${NAME}"`" 0 0 "${CMDLINE[${NAME}]}" \
          2>${TMP_PATH}/resp
        [ $? -ne 0 ] && continue
        VALUE="`<"${TMP_PATH}/resp"`"
        CMDLINE[${NAME}]="${VALUE}"
        writeConfigKey "cmdline.${NAME}" "${VALUE}" "${USER_CONFIG_FILE}"
        ;;
      d)
        if [ ${#CMDLINE[@]} -eq 0 ]; then
          dialog --backtitle "`backtitle`" --msgbox "$(TEXT "No user cmdline to remove")" 0 0 
          continue
        fi
        ITEMS=""
        for I in "${!CMDLINE[@]}"; do
          [ -z "${CMDLINE[${I}]}" ] && ITEMS+="${I} \"\" off " || ITEMS+="${I} ${CMDLINE[${I}]} off "
        done
        dialog --backtitle "`backtitle`" \
          --checklist "$(TEXT "Select cmdline to remove")" 0 0 0 ${ITEMS} \
          2>"${TMP_PATH}/resp"
        [ $? -ne 0 ] && continue
        RESP=`<"${TMP_PATH}/resp"`
        [ -z "${RESP}" ] && continue
        for I in ${RESP}; do
          unset CMDLINE[${I}]
          deleteConfigKey "cmdline.${I}" "${USER_CONFIG_FILE}"
        done
        ;;
      c)
        NUM=`ip link show | grep ether | wc -l`
        for i in $(seq 1 ${NUM}); do
          RET=1
          while true; do
            dialog --backtitle "`backtitle`" --title "$(TEXT "User cmdline")" \
              --inputbox "`printf "$(TEXT "Type a custom MAC address of %s")" "eth$(expr ${i} - 1)"`" 0 0 "${CMDLINE["mac${i}"]}"\
              2>${TMP_PATH}/resp
            RET=$?
            [ ${RET} -ne 0 ] && break
            MAC="`<"${TMP_PATH}/resp"`"
            [ -z "${MAC}" ] && MAC="`readConfigKey "original-mac${i}" "${USER_CONFIG_FILE}"`"
            MACF="`echo "${MAC}" | sed 's/://g'`"
            [ ${#MACF} -eq 12 ] && break
            dialog --backtitle "`backtitle`" --title "$(TEXT "User cmdline")" --msgbox "$(TEXT "Invalid MAC")" 0 0
          done
          if [ ${RET} -eq 0 ]; then
            CMDLINE["mac${i}"]="${MACF}"
            CMDLINE["netif_num"]=${NUM}
            writeConfigKey "cmdline.mac${i}"      "${MACF}" "${USER_CONFIG_FILE}"
            writeConfigKey "cmdline.netif_num"    "${NUM}"  "${USER_CONFIG_FILE}"
            MAC="${MACF:0:2}:${MACF:2:2}:${MACF:4:2}:${MACF:6:2}:${MACF:8:2}:${MACF:10:2}"
            ip link set dev eth$(expr ${i} - 1) address ${MAC} 2>&1 | dialog --backtitle "`backtitle`" \
              --title "$(TEXT "User cmdline")" --progressbox "$(TEXT "Changing MAC")" 20 70
            /etc/init.d/S41dhcpcd restart 2>&1 | dialog --backtitle "`backtitle`" \
              --title "$(TEXT "User cmdline")" --progressbox "$(TEXT "Renewing IP")" 20 70
            IP=`ip route 2>/dev/null | sed -n 's/.* via .* src \(.*\) metric .*/\1/p' | head -1` # IP=`ip route get 1.1.1.1 2>/dev/null | awk '{print$7}'`
          fi
        done
        ;;
      s)
        ITEMS=""
        for KEY in ${!CMDLINE[@]}; do
          ITEMS+="${KEY}: ${CMDLINE[$KEY]}\n"
        done
        dialog --backtitle "`backtitle`" --title "$(TEXT "User cmdline")" \
          --aspect 18 --msgbox "${ITEMS}" 0 0
        ;;
      m)
        ITEMS=""
        while IFS=': ' read KEY VALUE; do
          ITEMS+="${KEY}: ${VALUE}\n"
        done < <(readModelMap "${MODEL}" "builds.${BUILD}.cmdline")
        dialog --backtitle "`backtitle`" --title "$(TEXT "Model/build cmdline")" \
          --aspect 18 --msgbox "${ITEMS}" 0 0
        ;;
      e) return ;;
    esac
  done
}

###############################################################################
function synoinfoMenu() {
  # Read synoinfo from user config
  unset SYNOINFO
  declare -A SYNOINFO
  while IFS=': ' read KEY VALUE; do
    [ -n "${KEY}" ] && SYNOINFO["${KEY}"]="${VALUE}"
  done < <(readConfigMap "synoinfo" "${USER_CONFIG_FILE}")

  echo "a \"$(TEXT "Add/edit a synoinfo item")\""   > "${TMP_PATH}/menu"
  echo "d \"$(TEXT "Delete synoinfo item(s)")\""    >> "${TMP_PATH}/menu"
  echo "s \"$(TEXT "Show synoinfo entries")\""      >> "${TMP_PATH}/menu"
  echo "e \"$(TEXT "Exit")\""                       >> "${TMP_PATH}/menu"

  # menu loop
  while true; do
    dialog --backtitle "`backtitle`" --menu "$(TEXT "Choose a option")" 0 0 0 \
      --file "${TMP_PATH}/menu" 2>${TMP_PATH}/resp
    [ $? -ne 0 ] && return
    case "`<${TMP_PATH}/resp`" in
      a)
        dialog --backtitle "`backtitle`" --title "$(TEXT "Synoinfo entries")" \
          --inputbox "$(TEXT "Type a name of synoinfo entry")" 0 0 \
          2>${TMP_PATH}/resp
        [ $? -ne 0 ] && continue
        NAME="`<"${TMP_PATH}/resp"`"
        [ -z "${NAME}" ] && continue
        dialog --backtitle "`backtitle`" --title "$(TEXT "Synoinfo entries")" \
          --inputbox "`printf "$(TEXT "Type a value of '%s' synoinfo entry")" "${NAME}"`" 0 0 "${SYNOINFO[${NAME}]}" \
          2>${TMP_PATH}/resp
        [ $? -ne 0 ] && continue
        VALUE="`<"${TMP_PATH}/resp"`"
        SYNOINFO[${NAME}]="${VALUE}"
        writeConfigKey "synoinfo.${NAME}" "${VALUE}" "${USER_CONFIG_FILE}"
        DIRTY=1
        ;;
      d)
        if [ ${#SYNOINFO[@]} -eq 0 ]; then
          dialog --backtitle "`backtitle`" --msgbox "$(TEXT "No synoinfo entries to remove")" 0 0 
          continue
        fi
        ITEMS=""
        for I in "${!SYNOINFO[@]}"; do
          [ -z "${SYNOINFO[${I}]}" ] && ITEMS+="${I} \"\" off " || ITEMS+="${I} ${SYNOINFO[${I}]} off "
        done
        dialog --backtitle "`backtitle`" \
          --checklist "$(TEXT "Select synoinfo entry to remove")" 0 0 0 ${ITEMS} \
          2>"${TMP_PATH}/resp"
        [ $? -ne 0 ] && continue
        RESP=`<"${TMP_PATH}/resp"`
        [ -z "${RESP}" ] && continue
        for I in ${RESP}; do
          unset SYNOINFO[${I}]
          deleteConfigKey "synoinfo.${I}" "${USER_CONFIG_FILE}"
        done
        DIRTY=1
        ;;
      s)
        ITEMS=""
        for KEY in ${!SYNOINFO[@]}; do
          ITEMS+="${KEY}: ${SYNOINFO[$KEY]}\n"
        done
        dialog --backtitle "`backtitle`" --title "$(TEXT "Synoinfo entries")" \
          --aspect 18 --msgbox "${ITEMS}" 0 0
        ;;
      e) return ;;
    esac
  done
}

###############################################################################
# Extract linux and ramdisk files from the DSM .pat
function extractDsmFiles() {
  PAT_URL="`readModelKey "${MODEL}" "builds.${BUILD}.pat.url"`"
  PAT_HASH="`readModelKey "${MODEL}" "builds.${BUILD}.pat.hash"`"
  RAMDISK_HASH="`readModelKey "${MODEL}" "builds.${BUILD}.pat.ramdisk-hash"`"
  ZIMAGE_HASH="`readModelKey "${MODEL}" "builds.${BUILD}.pat.zimage-hash"`"

  SPACELEFT=`df --block-size=1 | awk '/'${LOADER_DEVICE_NAME}'3/{print $4}'`  # Check disk space left

  PAT_FILE="${MODEL}-${BUILD}.pat"
  PAT_PATH="${CACHE_PATH}/dl/${PAT_FILE}"
  EXTRACTOR_PATH="${CACHE_PATH}/extractor"
  EXTRACTOR_BIN="syno_extract_system_patch"
  OLDPAT_URL="https://global.synologydownload.com/download/DSM/release/7.0.1/42218/DSM_DS3622xs%2B_42218.pat"

  if [ -f "${PAT_PATH}" ]; then
    echo "`printf "$(TEXT "%s cached.")" "${PAT_FILE}"`"
  else
    # If we have little disk space, clean cache folder
    if [ ${CLEARCACHE} -eq 1 ]; then
      echo "$(TEXT "Cleaning cache")"
      rm -rf "${CACHE_PATH}/dl"
    fi
    mkdir -p "${CACHE_PATH}/dl"

    speed_a="`curl -Lo /dev/null -m 1 -skw "%{speed_download}" "https://global.synologydownload.com/download/DSM/release/7.0.1/42218/DSM_DS3622xs%2B_42218.pat"`"
    speed_b="`curl -Lo /dev/null -m 1 -skw "%{speed_download}" "https://global.download.synology.com/download/DSM/release/7.0.1/42218/DSM_DS3622xs%2B_42218.pat"`"
    speed_c="`curl -Lo /dev/null -m 1 -skw "%{speed_download}" "https://cndl.synology.cn/download/DSM/release/7.0.1/42218/DSM_DS3622xs%2B_42218.pat"`"
    fastest="`echo -e "global.synologydownload.com ${speed_a}\nglobal.download.synology.com ${speed_b}\ncndl.synology.cn ${speed_c}" | sort -k2rn | head -1 | awk '{print $1}'`"

    mirror="`echo ${PAT_URL} | sed 's|^http[s]*://\([^/]*\).*|\1|'`"
    if [ "${mirror}" != "${fastest}" ]; then
      echo "`printf "$(TEXT "Based on the current network situation, switch to %s mirror to downloading.")" "${fastest}"`"
      PAT_URL="`echo ${PAT_URL} | sed "s/${mirror}/${fastest}/"`"
      OLDPAT_URL="https://${fastest}/download/DSM/release/7.0.1/42218/DSM_DS3622xs%2B_42218.pat"
    fi
    echo "`printf "$(TEXT "Downloading %s")" "${PAT_FILE}"`"
    # Discover remote file size
    FILESIZE=`curl -k -sLI "${PAT_URL}" | grep -i Content-Length | awk '{print$2}'`
    if [ 0${FILESIZE} -ge ${SPACELEFT} ]; then
      # No disk space to download, change it to RAMDISK
      PAT_PATH="${TMP_PATH}/${PAT_FILE}"
    fi
    STATUS=`curl -k -w "%{http_code}" -L "${PAT_URL}" -o "${PAT_PATH}" --progress-bar`
    if [ $? -ne 0 -o ${STATUS} -ne 200 ]; then
      rm "${PAT_PATH}"
      dialog --backtitle "`backtitle`" --title "$(TEXT "Error downloading")" --aspect 18 \
        --msgbox "$(TEXT "Check internet or cache disk space")" 0 0
      return 1
    fi
  fi

  echo -n "`printf "$(TEXT "Checking hash of %s: ")" "${PAT_FILE}"`"
  if [ "`sha256sum ${PAT_PATH} | awk '{print$1}'`" != "${PAT_HASH}" ]; then
    dialog --backtitle "`backtitle`" --title "$(TEXT "Error")" --aspect 18 \
      --msgbox "$(TEXT "Hash of pat not match, try again!")" 0 0
    rm -f ${PAT_PATH}
    return 1
  fi
  echo "$(TEXT "OK")"

  rm -rf "${UNTAR_PAT_PATH}"
  mkdir "${UNTAR_PAT_PATH}"
  echo -n "`printf "$(TEXT "Disassembling %s: ")" "${PAT_FILE}"`"

  header="$(od -bcN2 ${PAT_PATH} | head -1 | awk '{print $3}')"
  case ${header} in
    105)
      echo "$(TEXT "Uncompressed tar")"
      isencrypted="no"
      ;;
    213)
      echo "$(TEXT "Compressed tar")"
      isencrypted="no"
      ;;
    255)
      echo "$(TEXT "Encrypted")"
      isencrypted="yes"
      ;;
    *)
      dialog --backtitle "`backtitle`" --title "$(TEXT "Error")" --aspect 18 \
        --msgbox "$(TEXT "Could not determine if pat file is encrypted or not, maybe corrupted, try again!")" \
        0 0
      return 1
      ;;
  esac

  SPACELEFT=`df --block-size=1 | awk '/'${LOADER_DEVICE_NAME}'3/{print$4}'`  # Check disk space left

  if [ "${isencrypted}" = "yes" ]; then
    # Check existance of extractor
    if [ -f "${EXTRACTOR_PATH}/${EXTRACTOR_BIN}" ]; then
      echo "$(TEXT "Extractor cached.")"
    else
      # Extractor not exists, get it.
      mkdir -p "${EXTRACTOR_PATH}"
      # Check if old pat already downloaded
      OLDPAT_PATH="${CACHE_PATH}/dl/DS3622xs+-42218.pat"
      if [ ! -f "${OLDPAT_PATH}" ]; then
        echo "$(TEXT "Downloading old pat to extract synology .pat extractor...")"
        # Discover remote file size
        FILESIZE=`curl -k -sLI "${OLDPAT_URL}" | grep -i Content-Length | awk '{print$2}'`
        if [ 0${FILESIZE} -ge ${SPACELEFT} ]; then
          # No disk space to download, change it to RAMDISK
          OLDPAT_PATH="${TMP_PATH}/DS3622xs+-42218.pat"
        fi
        STATUS=`curl -k -w "%{http_code}" -L "${OLDPAT_URL}" -o "${OLDPAT_PATH}"  --progress-bar`
        if [ $? -ne 0 -o ${STATUS} -ne 200 ]; then
          rm "${OLDPAT_PATH}"
          dialog --backtitle "`backtitle`" --title "$(TEXT "Error downloading")" --aspect 18 \
            --msgbox "$(TEXT "Check internet or cache disk space")" 0 0
          return 1
        fi
      fi
      # Extract DSM ramdisk file from PAT
      rm -rf "${RAMDISK_PATH}"
      mkdir -p "${RAMDISK_PATH}"
      tar -xf "${OLDPAT_PATH}" -C "${RAMDISK_PATH}" rd.gz >"${LOG_FILE}" 2>&1
      if [ $? -ne 0 ]; then
        rm -f "${OLDPAT_PATH}"
        rm -rf "${RAMDISK_PATH}"
        dialog --backtitle "`backtitle`" --title "$(TEXT "Error extracting")" --textbox "${LOG_FILE}" 0 0
        return 1
      fi
      [ ${CLEARCACHE} -eq 1 ] && rm -f "${OLDPAT_PATH}"
      # Extract all files from rd.gz
      (cd "${RAMDISK_PATH}"; xz -dc < rd.gz | cpio -idm) >/dev/null 2>&1 || true
      # Copy only necessary files
      for f in libcurl.so.4 libmbedcrypto.so.5 libmbedtls.so.13 libmbedx509.so.1 libmsgpackc.so.2 libsodium.so libsynocodesign-ng-virtual-junior-wins.so.7; do
        cp "${RAMDISK_PATH}/usr/lib/${f}" "${EXTRACTOR_PATH}"
      done
      cp "${RAMDISK_PATH}/usr/syno/bin/scemd" "${EXTRACTOR_PATH}/${EXTRACTOR_BIN}"
      rm -rf "${RAMDISK_PATH}"
    fi
    # Uses the extractor to untar pat file
    echo "$(TEXT "Extracting...")"
    LD_LIBRARY_PATH=${EXTRACTOR_PATH} "${EXTRACTOR_PATH}/${EXTRACTOR_BIN}" "${PAT_PATH}" "${UNTAR_PAT_PATH}" || true
  else
    echo "$(TEXT "Extracting...")"
    tar -xf "${PAT_PATH}" -C "${UNTAR_PAT_PATH}" >"${LOG_FILE}" 2>&1
    if [ $? -ne 0 ]; then
      dialog --backtitle "`backtitle`" --title "$(TEXT "Error extracting")" --textbox "${LOG_FILE}" 0 0
    fi
  fi

  echo -n "$(TEXT "Checking hash of zImage: ")"
  HASH="`sha256sum ${UNTAR_PAT_PATH}/zImage | awk '{print$1}'`"
  if [ "${HASH}" != "${ZIMAGE_HASH}" ]; then
    sleep 1
    dialog --backtitle "`backtitle`" --title "$(TEXT "Error")" --aspect 18 \
      --msgbox "$(TEXT "Hash of zImage not match, try again!")" 0 0
    return 1
  fi
  echo "$(TEXT "OK")"
  writeConfigKey "zimage-hash" "${ZIMAGE_HASH}" "${USER_CONFIG_FILE}"

  echo -n "$(TEXT "Checking hash of ramdisk: ")"
  HASH="`sha256sum ${UNTAR_PAT_PATH}/rd.gz | awk '{print$1}'`"
  if [ "${HASH}" != "${RAMDISK_HASH}" ]; then
    sleep 1
    dialog --backtitle "`backtitle`" --title "$(TEXT "Error")" --aspect 18 \
      --msgbox "$(TEXT "Hash of ramdisk not match, try again!")" 0 0
    return 1
  fi
  echo "$(TEXT "OK")"
  writeConfigKey "ramdisk-hash" "${RAMDISK_HASH}" "${USER_CONFIG_FILE}"

  echo -n "$(TEXT "Copying files: ")"
  cp "${UNTAR_PAT_PATH}/grub_cksum.syno" "${BOOTLOADER_PATH}"
  cp "${UNTAR_PAT_PATH}/GRUB_VER"        "${BOOTLOADER_PATH}"
  cp "${UNTAR_PAT_PATH}/grub_cksum.syno" "${SLPART_PATH}"
  cp "${UNTAR_PAT_PATH}/GRUB_VER"        "${SLPART_PATH}"
  cp "${UNTAR_PAT_PATH}/zImage"          "${ORI_ZIMAGE_FILE}"
  cp "${UNTAR_PAT_PATH}/rd.gz"           "${ORI_RDGZ_FILE}"
  rm -rf "${UNTAR_PAT_PATH}"
  echo "$(TEXT "OK")"
}

###############################################################################
# Where the magic happens!
function make() {
  clear
  PLATFORM="`readModelKey "${MODEL}" "platform"`"
  KVER="`readModelKey "${MODEL}" "builds.${BUILD}.kver"`"

  # Check if all addon exists
  while IFS=': ' read ADDON PARAM; do
    [ -z "${ADDON}" ] && continue
    if ! checkAddonExist "${ADDON}" "${PLATFORM}" "${KVER}"; then
      dialog --backtitle "`backtitle`" --title "$(TEXT "Error")" --aspect 18 \
        --msgbox "`printf "$(TEXT "Addon %s not found!")" "${ADDON}"`" 0 0
      return 1
    fi
  done < <(readConfigMap "addons" "${USER_CONFIG_FILE}")

  [ ! -f "${ORI_ZIMAGE_FILE}" -o ! -f "${ORI_RDGZ_FILE}" ] && extractDsmFiles

  /opt/arpl/zimage-patch.sh
  if [ $? -ne 0 ]; then
    dialog --backtitle "`backtitle`" --title "$(TEXT "Error")" --aspect 18 \
      --msgbox "$(TEXT "zImage not patched:\n")`<"${LOG_FILE}"`" 0 0
    return 1
  fi

  /opt/arpl/ramdisk-patch.sh
  if [ $? -ne 0 ]; then
    dialog --backtitle "`backtitle`" --title "$(TEXT "Error")" --aspect 18 \
      --msgbox "$(TEXT "Ramdisk not patched:\n")`<"${LOG_FILE}"`" 0 0
    return 1
  fi

  echo "$(TEXT "Cleaning")"
  rm -rf "${UNTAR_PAT_PATH}"

  echo "$(TEXT "Ready!")"
  sleep 3
  DIRTY=0
  return 0
}

###############################################################################
# Advanced menu
function advancedMenu() {
  NEXT="l"
  while true; do
    rm "${TMP_PATH}/menu"
    if [ -n "${BUILD}" ]; then
      echo "l \"$(TEXT "Switch LKM version:") \Z4${LKM}\Zn\""        >> "${TMP_PATH}/menu"
      echo "o \"$(TEXT "Modules")\""                                 >> "${TMP_PATH}/menu"
    fi
    if loaderIsConfigured; then
      echo "r \"$(TEXT "Switch direct boot:") \Z4${DIRECTBOOT}\Zn\"" >> "${TMP_PATH}/menu"
    fi
    echo "u \"$(TEXT "Edit user config file manually")\""            >> "${TMP_PATH}/menu"
    echo "t \"$(TEXT "Try to recovery a DSM installed system")\""    >> "${TMP_PATH}/menu"
    echo "s \"$(TEXT "Show SATA(s) # ports and drives")\""           >> "${TMP_PATH}/menu"
    echo "d \"$(TEXT "Custom dts location:/mnt/p1/model.dts # Need rebuild")\""           >> "${TMP_PATH}/menu"
    echo "e \"$(TEXT "Exit")\""                                      >> "${TMP_PATH}/menu"

    dialog --default-item ${NEXT} --backtitle "`backtitle`" --title "$(TEXT "Advanced")" \
      --colors --menu "$(TEXT "Choose the option")" 0 0 0 --file "${TMP_PATH}/menu" \
      2>${TMP_PATH}/resp
    [ $? -ne 0 ] && break
    case `<"${TMP_PATH}/resp"` in
      l) LKM=$([ "${LKM}" = "dev" ] && echo 'prod' || ([ "${LKM}" = "test" ] && echo 'dev' || echo 'test'))
        writeConfigKey "lkm" "${LKM}" "${USER_CONFIG_FILE}"
        DIRTY=1
        NEXT="o"
        ;;
      o) selectModules; NEXT="r" ;;
      r) [ "${DIRECTBOOT}" = "false" ] && DIRECTBOOT='true' || DIRECTBOOT='false'
        writeConfigKey "directboot" "${DIRECTBOOT}" "${USER_CONFIG_FILE}"
        NEXT="u"
        ;;
      u) editUserConfig; NEXT="e" ;;
      t) tryRecoveryDSM ;;
      s) MSG=""
        NUMPORTS=0
        ATTACHTPORTS=0
        DiskIdxMap=""
        for PCI in `lspci -d ::106 | awk '{print$1}'`; do
          NAME=`lspci -s "${PCI}" | sed "s/\ .*://"`
          MSG+="\Zb${NAME}\Zn\nPorts: "
          unset HOSTPORTS
          declare -A HOSTPORTS
          while read LINE; do
            ATAPORT="`echo ${LINE} | grep -o 'ata[0-9]*'`"
            PORT=`echo ${ATAPORT} | sed 's/ata//'`
            HOSTPORTS[${PORT}]=`echo ${LINE} | grep -o 'host[0-9]*$'`
          done < <(ls -l /sys/class/scsi_host | fgrep "${PCI}")
          while read PORT; do
            ls -l /sys/block | fgrep -q "${PCI}/ata${PORT}" && ATTACH=1 || ATTACH=0
            PCMD=`cat /sys/class/scsi_host/${HOSTPORTS[${PORT}]}/ahci_port_cmd`
            [ "${PCMD}" = "0" ] && DUMMY=1 || DUMMY=0
            [ ${ATTACH} -eq 1 ] && MSG+="\Z2\Zb" && ATTACHTPORTS=$((${ATTACHTPORTS}+1))
            [ ${DUMMY} -eq 1 ] && MSG+="\Z1"
            MSG+="${PORT}\Zn "
            NUMPORTS=$((${NUMPORTS}+1))
          done < <(echo ${!HOSTPORTS[@]} | tr ' ' '\n' | sort -n)
          MSG+="\n"
          DiskIdxMap+=`printf '%02x' ${ATTACHTPORTS}`
        done
        MSG+="`printf "$(TEXT "\nTotal of ports: %s\n")" "${NUMPORTS}"`"
        MSG+="$(TEXT "\nPorts with color \Z1red\Zn as DUMMY, color \Z2\Zbgreen\Zn has drive connected.")"
        MSG+="$(TEXT "\nRecommended value:")"
        MSG+="$(TEXT "\nDiskIdxMap:") ${DiskIdxMap}"
        dialog --backtitle "`backtitle`" --colors --aspect 18 \
          --msgbox "${MSG}" 0 0
        ;;
        e) break ;;
    esac
  done
}

###############################################################################
# Try to recovery a DSM already installed
function tryRecoveryDSM() {
  dialog --backtitle "`backtitle`" --title "$(TEXT "Try recovery DSM")" --aspect 18 \
    --infobox "$(TEXT "Trying to recovery a DSM installed system")" 0 0
  if findAndMountDSMRoot; then
    MODEL=""
    BUILD=""
    if [ -f "${DSMROOT_PATH}/.syno/patch/VERSION" ]; then
      eval `cat ${DSMROOT_PATH}/.syno/patch/VERSION | grep unique`
      eval `cat ${DSMROOT_PATH}/.syno/patch/VERSION | grep base`
      if [ -n "${unique}" ] ; then
        while read F; do
          M="`basename ${F}`"
          M="${M::-4}"
          UNIQUE=`readModelKey "${M}" "unique"`
          [ "${unique}" = "${UNIQUE}" ] || continue
          # Found
          modelMenu "${M}"
        done < <(find "${MODEL_CONFIG_PATH}" -maxdepth 1 -name \*.yml | sort)
        if [ -n "${MODEL}" ]; then
          buildMenu ${base}
          if [ -n "${BUILD}" ]; then
            cp "${DSMROOT_PATH}/.syno/patch/zImage" "${SLPART_PATH}"
            cp "${DSMROOT_PATH}/.syno/patch/rd.gz" "${SLPART_PATH}"
            MSG="`printf "$(TEXT "Found a installation:\nModel: %s\nBuildnumber: %s")" "${MODEL}" "${BUILD}"`"
            SN=`_get_conf_kv SN "${DSMROOT_PATH}/etc/synoinfo.conf"`
            if [ -n "${SN}" ]; then
              writeConfigKey "sn" "${SN}" "${USER_CONFIG_FILE}"
              MSG+="`printf "$(TEXT "\nSerial: %s")" "${SN}"`"
            fi
            dialog --backtitle "`backtitle`" --title "$(TEXT "Try recovery DSM")" \
              --aspect 18 --msgbox "${MSG}" 0 0
          fi
        fi
      fi
    fi
  else
    dialog --backtitle "`backtitle`" --title "$(TEXT "Try recovery DSM")" --aspect 18 \
      --msgbox "$(TEXT "Unfortunately I couldn't mount the DSM partition!")" 0 0
  fi
}

###############################################################################
# Permit user select the modules to include
function selectModules() {
  PLATFORM="`readModelKey "${MODEL}" "platform"`"
  KVER="`readModelKey "${MODEL}" "builds.${BUILD}.kver"`"
  dialog --backtitle "`backtitle`" --title "$(TEXT "Modules")" --aspect 18 \
    --infobox "$(TEXT "Reading modules")" 0 0
  ALLMODULES=`getAllModules "${PLATFORM}" "${KVER}"`
  unset USERMODULES
  declare -A USERMODULES
  while IFS=': ' read KEY VALUE; do
    [ -n "${KEY}" ] && USERMODULES["${KEY}"]="${VALUE}"
  done < <(readConfigMap "modules" "${USER_CONFIG_FILE}")
  # menu loop
  while true; do
    dialog --backtitle "`backtitle`" --menu "$(TEXT "Choose a option")" 0 0 0 \
      s "$(TEXT "Show selected modules")" \
      a "$(TEXT "Select all modules")" \
      d "$(TEXT "Deselect all modules")" \
      c "$(TEXT "Choose modules to include")" \
      e "$(TEXT "Exit")" \
      2>${TMP_PATH}/resp
    [ $? -ne 0 ] && break
    case "`<${TMP_PATH}/resp`" in
      s) ITEMS=""
        for KEY in ${!USERMODULES[@]}; do
          ITEMS+="${KEY}: ${USERMODULES[$KEY]}\n"
        done
        dialog --backtitle "`backtitle`" --title "$(TEXT "User modules")" \
          --msgbox "${ITEMS}" 0 0
        ;;
      a) dialog --backtitle "`backtitle`" --title "$(TEXT "Modules")" \
           --infobox "$(TEXT "Selecting all modules")" 0 0
        unset USERMODULES
        declare -A USERMODULES
        writeConfigKey "modules" "{}" "${USER_CONFIG_FILE}"
        while read ID DESC; do
          USERMODULES["${ID}"]=""
          writeConfigKey "modules.${ID}" "" "${USER_CONFIG_FILE}"
        done <<<${ALLMODULES}
        ;;

      d) dialog --backtitle "`backtitle`" --title "$(TEXT "Modules")" \
           --infobox "$(TEXT "Deselecting all modules")" 0 0
        writeConfigKey "modules" "{}" "${USER_CONFIG_FILE}"
        unset USERMODULES
        declare -A USERMODULES
        ;;

      c)
        rm -f "${TMP_PATH}/opts"
        while read ID DESC; do
          arrayExistItem "${ID}" "${!USERMODULES[@]}" && ACT="on" || ACT="off"
          echo "${ID} ${DESC} ${ACT}" >> "${TMP_PATH}/opts"
        done <<<${ALLMODULES}
        dialog --backtitle "`backtitle`" --title "$(TEXT "Modules")" --aspect 18 \
          --checklist "$(TEXT "Select modules to include")" 0 0 0 \
          --file "${TMP_PATH}/opts" 2>${TMP_PATH}/resp
        [ $? -ne 0 ] && continue
        resp=$(<${TMP_PATH}/resp)
        [ -z "${resp}" ] && continue
        dialog --backtitle "`backtitle`" --title "$(TEXT "Modules")" \
           --infobox "$(TEXT "Writing to user config")" 0 0
        unset USERMODULES
        declare -A USERMODULES
        writeConfigKey "modules" "{}" "${USER_CONFIG_FILE}"
        for ID in ${resp}; do
          USERMODULES["${ID}"]=""
          writeConfigKey "modules.${ID}" "" "${USER_CONFIG_FILE}"
        done
        ;;

      e)
        break
        ;;
    esac
  done
}

###############################################################################
# Permits user edit the user config
function editUserConfig() {
  while true; do
    dialog --backtitle "`backtitle`" --title "$(TEXT "Edit with caution")" \
      --editbox "${USER_CONFIG_FILE}" 0 0 2>"${TMP_PATH}/userconfig"
    [ $? -ne 0 ] && return
    mv "${TMP_PATH}/userconfig" "${USER_CONFIG_FILE}"
    ERRORS=`yq eval "${USER_CONFIG_FILE}" 2>&1`
    [ $? -eq 0 ] && break
    dialog --backtitle "`backtitle`" --title "$(TEXT "Invalid YAML format")" --msgbox "${ERRORS}" 0 0
  done
  OLDMODEL=${MODEL}
  OLDBUILD=${BUILD}
  MODEL="`readConfigKey "model" "${USER_CONFIG_FILE}"`"
  BUILD="`readConfigKey "build" "${USER_CONFIG_FILE}"`"
  SN="`readConfigKey "sn" "${USER_CONFIG_FILE}"`"

  if [ "${MODEL}" != "${OLDMODEL}" -o "${BUILD}" != "${OLDBUILD}" ]; then
    # Remove old files
    rm -f "${MOD_ZIMAGE_FILE}"
    rm -f "${MOD_RDGZ_FILE}"
  fi
  DIRTY=1
}

###############################################################################
# Calls boot.sh to boot into DSM kernel/ramdisk
function boot() {
  [ ${DIRTY} -eq 1 ] && dialog --backtitle "`backtitle`" --title "$(TEXT "Alert")" \
    --yesno "$(TEXT "Config changed, would you like to rebuild the loader?")" 0 0
  if [ $? -eq 0 ]; then
    make || return
  fi
  boot.sh
}

###############################################################################
# Shows language to user choose one
function languageMenu() {
  ITEMS="`ls /usr/share/locale`"
  dialog --backtitle "`backtitle`" --default-item "${LAYOUT}" --no-items \
    --menu "$(TEXT "Choose a language")" 0 0 0 ${ITEMS} 2>${TMP_PATH}/resp
  [ $? -ne 0 ] && return
  resp=`cat /tmp/resp 2>/dev/null`
  [ -z "${resp}" ] && return
  LANGUAGE=${resp}
  echo "${LANGUAGE}.UTF-8" > ${BOOTLOADER_PATH}/.locale
  export LANG="${LANGUAGE}.UTF-8"
}

###############################################################################
# Shows available keymaps to user choose one
function keymapMenu() {
  dialog --backtitle "`backtitle`" --default-item "${LAYOUT}" --no-items \
    --menu "$(TEXT "Choose a layout")" 0 0 0 "azerty" "bepo" "carpalx" "colemak" \
    "dvorak" "fgGIod" "neo" "olpc" "qwerty" "qwertz" \
    2>${TMP_PATH}/resp
  [ $? -ne 0 ] && return
  LAYOUT="`<${TMP_PATH}/resp`"
  OPTIONS=""
  while read KM; do
    OPTIONS+="${KM::-7} "
  done < <(cd /usr/share/keymaps/i386/${LAYOUT}; ls *.map.gz)
  dialog --backtitle "`backtitle`" --no-items --default-item "${KEYMAP}" \
    --menu "$(TEXT "Choice a keymap")" 0 0 0 ${OPTIONS} \
    2>/tmp/resp
  [ $? -ne 0 ] && return
  resp=`cat /tmp/resp 2>/dev/null`
  [ -z "${resp}" ] && return
  KEYMAP=${resp}
  writeConfigKey "layout" "${LAYOUT}" "${USER_CONFIG_FILE}"
  writeConfigKey "keymap" "${KEYMAP}" "${USER_CONFIG_FILE}"
  loadkeys /usr/share/keymaps/i386/${LAYOUT}/${KEYMAP}.map.gz
}

###############################################################################
function updateMenu() {
  PLATFORM="`readModelKey "${MODEL}" "platform"`"
  KVER="`readModelKey "${MODEL}" "builds.${BUILD}.kver"`"
  PROXY="`readConfigKey "proxy" "${USER_CONFIG_FILE}"`"; [ -n "${PROXY}" ] && [[ "${PROXY: -1}" != "/" ]] && PROXY="${PROXY}/"
  while true; do
    dialog --backtitle "`backtitle`" --menu "$(TEXT "Choose a option")" 0 0 0 \
      a "$(TEXT "Update arpl")" \
      d "$(TEXT "Update addons")" \
      l "$(TEXT "Update LKMs")" \
      m "$(TEXT "Update modules")" \
      p "$(TEXT "Set proxy server")" \
      e "$(TEXT "Exit")" \
      2>${TMP_PATH}/resp
    [ $? -ne 0 ] && return
    case "`<${TMP_PATH}/resp`" in
      a)
        dialog --backtitle "`backtitle`" --title "$(TEXT "Update arpl")" --aspect 18 \
          --infobox "$(TEXT "Checking last version")" 0 0
        ACTUALVERSION="${ARPL_VERSION}"
        TAG="`curl -k -s "${PROXY}https://api.github.com/repos/wjz304/arpl-i18n/releases/latest" | grep "tag_name" | awk '{print substr($2, 2, length($2)-3)}'`"
        if [ $? -ne 0 -o -z "${TAG}" ]; then
          dialog --backtitle "`backtitle`" --title "$(TEXT "Update arpl")" --aspect 18 \
            --msgbox "$(TEXT "Error checking new version")" 0 0
          continue
        fi
        [[ "${TAG:0:1}" == "v" ]] && TAG="${TAG:1}"
        if [ "${ACTUALVERSION}" = "${TAG}" ]; then
          dialog --backtitle "`backtitle`" --title "$(TEXT "Update arpl")" --aspect 18 \
            --yesno "`printf "$(TEXT "No new version. Actual version is %s\nForce update?")" "${ACTUALVERSION}"`" 0 0
          [ $? -ne 0 ] && continue
        fi
        dialog --backtitle "`backtitle`" --title "$(TEXT "Update arpl")" --aspect 18 \
          --infobox "`printf "$(TEXT "Downloading last version %s")" "${TAG}"`" 0 0
        # Download update file
        STATUS=`curl -k -w "%{http_code}" -L "${PROXY}https://github.com/wjz304/arpl-i18n/releases/download/${TAG}/update.zip" -o "/tmp/update.zip"`
        if [ $? -ne 0 -o ${STATUS} -ne 200 ]; then
          dialog --backtitle "`backtitle`" --title "$(TEXT "Update arpl")" --aspect 18 \
            --msgbox "$(TEXT "Error downloading update file")" 0 0
          continue
        fi
        unzip -oq /tmp/update.zip -d /tmp
        if [ $? -ne 0 ]; then
          dialog --backtitle "`backtitle`" --title "$(TEXT "Update arpl")" --aspect 18 \
            --msgbox "$(TEXT "Error extracting update file")" 0 0
          continue
        fi
        # Check checksums
        (cd /tmp && sha256sum --status -c sha256sum)
        if [ $? -ne 0 ]; then
          dialog --backtitle "`backtitle`" --title "$(TEXT "Update arpl")" --aspect 18 \
            --msgbox "$(TEXT "Checksum do not match!")" 0 0
          continue
        fi
        dialog --backtitle "`backtitle`" --title "$(TEXT "Update arpl")" --aspect 18 \
          --infobox "$(TEXT "Installing new files")" 0 0
        # Process update-list.yml
        while read F; do
          [ -f "${F}" ] && rm -f "${F}"
          [ -d "${F}" ] && rm -Rf "${F}"
        done < <(readConfigArray "remove" "/tmp/update-list.yml")
        while IFS=': ' read KEY VALUE; do
          if [ "${KEY: -1}" = "/" ]; then
            rm -Rf "${VALUE}"
            mkdir -p "${VALUE}"
            gzip -dc "/tmp/`basename "${KEY}"`.tgz" | tar xf - -C "${VALUE}"
          else
            mkdir -p "`dirname "${VALUE}"`"
            mv "/tmp/`basename "${KEY}"`" "${VALUE}"
          fi
        done < <(readConfigMap "replace" "/tmp/update-list.yml")
        dialog --backtitle "`backtitle`" --title "$(TEXT "Update arpl")" --aspect 18 \
          --yesno "`printf "$(TEXT "Arpl updated with success to %s!\nReboot?")" "${TAG}"`" 0 0
        [ $? -ne 0 ] && continue
        arpl-reboot.sh config
        exit
        ;;

      d)
        dialog --backtitle "`backtitle`" --title "$(TEXT "Update addons")" --aspect 18 \
          --infobox "$(TEXT "Checking last version")" 0 0
        TAG=`curl -k -s "${PROXY}https://api.github.com/repos/wjz304/arpl-addons/releases/latest" | grep "tag_name" | awk '{print substr($2, 2, length($2)-3)}'`
        if [ $? -ne 0 -o -z "${TAG}" ]; then
          dialog --backtitle "`backtitle`" --title "$(TEXT "Update addons")" --aspect 18 \
            --msgbox "$(TEXT "Error checking new version")" 0 0
          continue
        fi
        dialog --backtitle "`backtitle`" --title "$(TEXT "Update addons")" --aspect 18 \
          --infobox "$(TEXT "Downloading last version")" 0 0
        STATUS=`curl -k -s -w "%{http_code}" -L "${PROXY}https://github.com/wjz304/arpl-addons/releases/download/${TAG}/addons.zip" -o "/tmp/addons.zip"`
        if [ $? -ne 0 -o ${STATUS} -ne 200 ]; then
          dialog --backtitle "`backtitle`" --title "$(TEXT "Update addons")" --aspect 18 \
            --msgbox "$(TEXT "Error downloading new version")" 0 0
          continue
        fi
        dialog --backtitle "`backtitle`" --title "$(TEXT "Update addons")" --aspect 18 \
          --infobox "$(TEXT "Extracting last version")" 0 0
        rm -rf /tmp/addons
        mkdir -p /tmp/addons
        unzip /tmp/addons.zip -d /tmp/addons >/dev/null 2>&1
        dialog --backtitle "`backtitle`" --title "$(TEXT "Update addons")" --aspect 18 \
          --infobox "$(TEXT "Installing new addons")" 0 0
        rm -Rf "${ADDONS_PATH}/"*
        for PKG in `ls /tmp/addons/*.addon`; do
          ADDON=`basename ${PKG} | sed 's|.addon||'`
          rm -rf "${ADDONS_PATH}/${ADDON}"
          mkdir -p "${ADDONS_PATH}/${ADDON}"
          tar xaf "${PKG}" -C "${ADDONS_PATH}/${ADDON}" >/dev/null 2>&1
        done
        DIRTY=1
        dialog --backtitle "`backtitle`" --title "$(TEXT "Update addons")" --aspect 18 \
          --msgbox "$(TEXT "Addons updated with success!")" 0 0
        ;;

      l)
        dialog --backtitle "`backtitle`" --title "$(TEXT "Update LKMs")" --aspect 18 \
          --infobox "$(TEXT "Checking last version")" 0 0
        TAG=`curl -k -s "${PROXY}https://api.github.com/repos/wjz304/redpill-lkm/releases/latest" | grep "tag_name" | awk '{print substr($2, 2, length($2)-3)}'`
        if [ $? -ne 0 -o -z "${TAG}" ]; then
          dialog --backtitle "`backtitle`" --title "$(TEXT "Update LKMs")" --aspect 18 \
            --msgbox "$(TEXT "Error checking new version")" 0 0
          continue
        fi
        dialog --backtitle "`backtitle`" --title "$(TEXT "Update LKMs")" --aspect 18 \
          --infobox "$(TEXT "Downloading last version")" 0 0
        STATUS=`curl -k -s -w "%{http_code}" -L "${PROXY}https://github.com/wjz304/redpill-lkm/releases/download/${TAG}/rp-lkms.zip" -o "/tmp/rp-lkms.zip"`
        if [ $? -ne 0 -o ${STATUS} -ne 200 ]; then
          dialog --backtitle "`backtitle`" --title "$(TEXT "Update LKMs")" --aspect 18 \
            --msgbox "$(TEXT "Error downloading last version")" 0 0
          continue
        fi
        dialog --backtitle "`backtitle`" --title "$(TEXT "Update LKMs")" --aspect 18 \
          --infobox "$(TEXT "Extracting last version")" 0 0
        rm -rf "${LKM_PATH}/"*
        unzip /tmp/rp-lkms.zip -d "${LKM_PATH}" >/dev/null 2>&1
        DIRTY=1
        dialog --backtitle "`backtitle`" --title "$(TEXT "Update LKMs")" --aspect 18 \
          --msgbox "$(TEXT "LKMs updated with success!")" 0 0
        ;;
      m)
        dialog --backtitle "`backtitle`" --title "$(TEXT "Update Modules")" --aspect 18 \
          --infobox "$(TEXT "Checking last version")" 0 0
        TAG=`curl -k -s "${PROXY}https://api.github.com/repos/wjz304/arpl-modules/releases/latest" | grep "tag_name" | awk '{print substr($2, 2, length($2)-3)}'`
        if [ $? -ne 0 -o -z "${TAG}" ]; then
          dialog --backtitle "`backtitle`" --title "$(TEXT "Update Modules")" --aspect 18 \
            --msgbox "$(TEXT "Error checking new version")" 0 0
          continue
        fi

        dialog --backtitle "`backtitle`" --title "$(TEXT "Update Modules")" --aspect 18 \
          --infobox "$(TEXT "Downloading last version")" 0 0
        STATUS=`curl -k -s -w "%{http_code}" -L "${PROXY}https://github.com/wjz304/arpl-modules/releases/download/${TAG}/modules.zip" -o "/tmp/modules.zip"`
        if [ $? -ne 0 -o ${STATUS} -ne 200 ]; then
          dialog --backtitle "`backtitle`" --title "$(TEXT "Update Modules")" --aspect 18 \
            --msgbox "$(TEXT "Error downloading last version")" 0 0
          continue
        fi
        rm "${MODULES_PATH}/"*
        unzip /tmp/modules.zip -d "${MODULES_PATH}" >/dev/null 2>&1

        # Rebuild modules if model/buildnumber is selected
        if [ -n "${PLATFORM}" -a -n "${KVER}" ]; then
          writeConfigKey "modules" "{}" "${USER_CONFIG_FILE}"
          while read ID DESC; do
            writeConfigKey "modules.${ID}" "" "${USER_CONFIG_FILE}"
          done < <(getAllModules "${PLATFORM}" "${KVER}")
        fi
        DIRTY=1
        dialog --backtitle "`backtitle`" --title "$(TEXT "Update Modules")" --aspect 18 \
          --msgbox "$(TEXT "Modules updated with success!")" 0 0
        ;;
      p)
        RET=1
        while true; do
          dialog --backtitle "`backtitle`" --title "$(TEXT "Set Proxy Server")" \
            --inputbox "$(TEXT "Please enter a proxy server url")" 0 0 "${PROXY}" \
            2>${TMP_PATH}/resp
          RET=$?
          [ ${RET} -ne 0 ] && break
          PROXY=`cat ${TMP_PATH}/resp`
          if [ -z "${PROXYSERVER}" ]; then
            break
          elif [[ "${PROXYSERVER}" =~ "^(https?|ftp)://[^\s/$.?#].[^\s]*$" ]]; then
            break
          else
            dialog --backtitle "`backtitle`" --title "$(TEXT "Alert")" \
              --yesno "$(TEXT "Invalid proxy server url, continue?")" 0 0
            RET=$?
            [ ${RET} -eq 0 ] && break
          fi
        done
        [ ${RET} -eq 0 ] && writeConfigKey "proxy" "${PROXY}" "${USER_CONFIG_FILE}"
        ;;
      e) return ;;
    esac
  done
}

###############################################################################
###############################################################################

if [ "x$1" = "xb" -a -n "${MODEL}" -a -n "${BUILD}" -a loaderIsConfigured ]; then
  install-addons.sh
  make
  boot && exit 0 || sleep 5
fi
# Main loop
NEXT="m"
while true; do
  echo "m \"$(TEXT "Choose a model")\""                          > "${TMP_PATH}/menu"
  if [ -n "${MODEL}" ]; then
    echo "n \"$(TEXT "Choose a Build Number")\""                >> "${TMP_PATH}/menu"
    echo "s \"$(TEXT "Choose a serial number")\""               >> "${TMP_PATH}/menu"
    if [ -n "${BUILD}" ]; then
      echo "a \"$(TEXT "Addons")\""                             >> "${TMP_PATH}/menu"
      echo "x \"$(TEXT "Cmdline menu")\""                       >> "${TMP_PATH}/menu"
      echo "i \"$(TEXT "Synoinfo menu")\""                      >> "${TMP_PATH}/menu"
    fi
  fi
  echo "v \"$(TEXT "Advanced menu")\""                          >> "${TMP_PATH}/menu"
  if [ -n "${MODEL}" ]; then
    if [ -n "${BUILD}" ]; then
      echo "d \"$(TEXT "Build the loader")\""                   >> "${TMP_PATH}/menu"
    fi
  fi
  if loaderIsConfigured; then
    echo "b \"$(TEXT "Boot the loader")\""                      >> "${TMP_PATH}/menu"
  fi
  echo "l \"$(TEXT "Choose a language")\""                      >> "${TMP_PATH}/menu"
  echo "k \"$(TEXT "Choose a keymap")\""                        >> "${TMP_PATH}/menu"
  if [ ${CLEARCACHE} -eq 1 -a -d "${CACHE_PATH}/dl" ]; then
    echo "c \"$(TEXT "Clean disk cache")\""                     >> "${TMP_PATH}/menu"
  fi
  echo "p \"$(TEXT "Update menu")\""                            >> "${TMP_PATH}/menu"
  echo "e \"$(TEXT "Exit")\""                                   >> "${TMP_PATH}/menu"

  dialog --default-item ${NEXT} --backtitle "`backtitle`" --colors \
    --menu "$(TEXT "Choose the option")" 0 0 0 --file "${TMP_PATH}/menu" \
    2>${TMP_PATH}/resp
  [ $? -ne 0 ] && break
  case `<"${TMP_PATH}/resp"` in
    m) modelMenu; NEXT="n" ;;
    n) buildMenu; NEXT="s" ;;
    s) serialMenu; NEXT="a" ;;
    a) addonMenu; NEXT="x" ;;
    x) cmdlineMenu; NEXT="i" ;;
    i) synoinfoMenu; NEXT="v" ;;
    v) advancedMenu; NEXT="d" ;;
    d) make; NEXT="b" ;;
    b) boot && exit 0 || sleep 5 ;;
    l) languageMenu ;;
    k) keymapMenu ;;
    c) dialog --backtitle "`backtitle`" --title "$(TEXT "Cleaning")" --aspect 18 \
      --prgbox "rm -rfv \"${CACHE_PATH}/dl\"" 0 0 ;;
    p) updateMenu ;;
    e) break ;;
  esac
done
clear
echo -e "$(TEXT "Call \033[1;32mmenu.sh\033[0m to return to menu")"
