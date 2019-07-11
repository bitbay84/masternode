#!/bin/bash

if [[ -f /var/multi-masternode-data/.bashrc ]]
then
  # shellcheck disable=SC1091
  source /var/multi-masternode-data/.bashrc
fi

WEBHOOK_USERNAME_DEFAULT='Masternode Monitor'
WEBHOOK_AVATAR_DEFAULT='https://i.imgur.com/8WHSSa7s.jpg'

arg1="${1}"

# Get sqlite.
if ! [ -x "$(command -v sqlite3 )" ]
then
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq sqlite3
fi
# Get jq.
if ! [ -x "$(command -v jq)" ]
then
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq jq
fi

SQL_QUERY () {
  sqlite3 -batch /var/multi-masternode-data/mnbot/mnmon.sqlite3.db "${1}"
}

# Create tables if they do not exist.
SQL_QUERY "CREATE TABLE IF NOT EXISTS webhook_urls (
 type TEXT PRIMARY KEY,
 url TEXT NOT NULL
);"

SQL_QUERY "CREATE TABLE IF NOT EXISTS telegram_token (
 type TEXT PRIMARY KEY,
 token TEXT NOT NULL,
 chatid TEXT NOT NULL
);"

SQL_QUERY "CREATE TABLE IF NOT EXISTS events_log (
 time INTEGER NOT NULL,
 name_type TEXT NOT NULL,
 message TEXT NOT NULL,
 PRIMARY KEY (time, name_type)
);"

INSTALL_MN_MON_SERVICE () {
cat << SYSTEMD_CONF | sudo tee /etc/systemd/system/mnbot.service >/dev/null

[Unit]
Description=${DAEMON_NAME} ${MASTERNODE_NAME} for user ${USRNAME}
After=syslog.target network.target

[Service]
SyslogIdentifier=cftimer-test-energi-sentinel
Type=oneshot
Restart=no
RestartSec=5
UMask=0027
ExecStart=/bin/bash /var/multi-masternode-data/mnbot/mnmon.sh cron


[Timer]
OnBootSec=60
OnUnitActiveSec=60

SYSTEMD_CONF
}

WEBHOOK_SEND () {
  URL="${1}"
  DESCRIPTION="${2}"
  TITLE="${3}"
  WEBHOOK_USERNAME="${4}"
  if [[ -z "${WEBHOOK_USERNAME}" ]]
  then
    WEBHOOK_USERNAME="${WEBHOOK_USERNAME_DEFAULT}"
  fi
  WEBHOOK_AVATAR="${5}"
  if [[ -z "${WEBHOOK_AVATAR}" ]]
  then
    WEBHOOK_AVATAR="${WEBHOOK_AVATAR_DEFAULT}"
  fi
  WEBHOOK_COLOR="${6}"

  CONTENT=$( date -u )
  CONTENT=$( echo -n "${CONTENT} - " ; hostname -i )
  CONTENT=$( echo -n "${CONTENT} - " ; hostname )
  if [[ ! -z "${7}" ]]
  then
    CONTENT="${7}"
  fi

  # Build HTTP POST.
  _PAYLOAD=$( cat << PAYLOAD
{"username": "${WEBHOOK_USERNAME}",
  "avatar_url": "${WEBHOOK_AVATAR}",
  "content": "${CONTENT}",
  "embeds": [
    {
      "title": "${TITLE}",
      "color": ${WEBHOOK_COLOR},
      "description": "${DESCRIPTION}"
    }
  ]
}
PAYLOAD
)

  # Do the post.
  curl -H "Content-Type: application/json" \
  -X POST \
  -d "${_PAYLOAD}" "${URL}" 2>/dev/null
  sleep 0.3
}

TELEGRAM_SEND () {
  TOKEN="${1}"
  CHAT_ID="${2}"
  MESSAGE="${3}"

  URL="https://api.telegram.org/bot$TOKEN/sendMessage"
  curl -s -X POST "${URL}" -d "chat_id=${CHAT_ID}" -d "text=${MESSAGE}"
  sleep 0.3
}

TELEGRAM_SETUP () {
  TOKEN=$( SQL_QUERY "SELECT token FROM telegram_token WHERE type = 'All';" )
  if [[ -z "${TOKEN}" ]]
  then
    echo "@botfather https://telegram.me/botfather with the following text: /newbot"
    echo "Then paste in the token below"
    echo
    read -r
    TOKEN="${REPLY}"
  fi

  CHAT_ID=$( SQL_QUERY "SELECT chatid FROM telegram_token WHERE type = 'All';" )
  if [[ -z "${CHAT_ID}" ]]
  then
    while :
    do
      GET_UPDATES=$( curl "https://api.telegram.org/bot${TOKEN}/getUpdates" 2>/dev/null )
      IS_OK=$( echo "${GET_UPDATES}" | jq '.ok' )
      if [[ "${IS_OK}" != 'true' ]]
      then
        echo "Please message the bot."
        read -p "When done press enter or q to quit." -r
        REPLY=${REPLY,,} # tolower
        if [[ "${REPLY}" == q ]]
        then
          return 1 2>/dev/null
        fi
        sleep 1
      else
        break
      fi
    done

    while :
    do
      GET_UPDATES=$( curl "https://api.telegram.org/bot${TOKEN}/getUpdates" 2>/dev/null )
      CHAT_ID=$( echo "${GET_UPDATES}" | jq '.result[0].message.chat.id' 2>/dev/null )
      if [[ -z "${CHAT_ID}" ]]
      then
        echo "Please message the bot."
      else
        SQL_QUERY "REPLACE INTO telegram_token (type,token,chatid) VALUES ('All','${TOKEN}','${CHAT_ID}');"
        break
      fi
    done
  fi

  MESSAGE="Bot Works!"
  TELEGRAM_SEND "${TOKEN}" "${CHAT_ID}" "${MESSAGE}"
}

SEND_ERROR () {
  URL=$( SQL_QUERY "SELECT url FROM webhook_urls WHERE type = 'Error';" )
  TOKEN=$( SQL_QUERY "SELECT token FROM telegram_token WHERE type = 'All';" )
  CHAT_ID=$( SQL_QUERY "SELECT chatid FROM telegram_token WHERE type = 'All';" )

  DESCRIPTION="${1}"
  if [[ -z "${DESCRIPTION}" ]]
  then
    DESCRIPTION="Default Error Message!"
  fi
  TITLE="${2}"
  if [[ -z "${TITLE}" ]]
  then
    TITLE=":exclamation: Error :exclamation:"
  fi
  WEBHOOK_COLOR="${5}"
  if [[ -z "${WEBHOOK_COLOR}" ]]
  then
    WEBHOOK_COLOR=16711680
  fi
  if [[ ! -z "${6}" ]]
  then
    URL="${6}"
  fi

  if [[ ! -z "${URL}" ]]
  then
    WEBHOOK_SEND "${URL}" "${DESCRIPTION}" "${TITLE}" "${3}" "${4}" "${WEBHOOK_COLOR}"
  fi
  if [[ ! -z "${TOKEN}" ]] && [[ ! -z "${CHAT_ID}" ]]
  then
    MESSAGE="${TITLE}
${DESCRIPTION}"
    # https://apps.timwhitlock.info/emoji/tables/unicode
    # :exclamation: \xE2\x9D\x97 %E2%9D%97
    TELEGRAM_SEND "${TOKEN}" "${CHAT_ID}" "${MESSAGE}"
  fi
}

SEND_WARNING () {
  URL=$( SQL_QUERY "SELECT url FROM webhook_urls WHERE type = 'Warning';" )
  TOKEN=$( SQL_QUERY "SELECT token FROM telegram_token WHERE type = 'All';" )
  CHAT_ID=$( SQL_QUERY "SELECT chatid FROM telegram_token WHERE type = 'All';" )

  DESCRIPTION="${1}"
  if [[ -z "${DESCRIPTION}" ]]
  then
    DESCRIPTION="Default Warning Message."
  fi
  TITLE="${2}"
  if [[ -z "${TITLE}" ]]
  then
    TITLE=":warning: Warning :warning:"
  fi
  WEBHOOK_COLOR="${5}"
  if [[ -z "${WEBHOOK_COLOR}" ]]
  then
    WEBHOOK_COLOR=16776960
  fi
  if [[ ! -z "${6}" ]]
  then
    URL="${6}"
  fi

  if [[ ! -z "${URL}" ]]
  then
    WEBHOOK_SEND "${URL}" "${DESCRIPTION}" "${TITLE}" "${3}" "${4}" "${WEBHOOK_COLOR}"
  fi
  if [[ ! -z "${TOKEN}" ]] && [[ ! -z "${CHAT_ID}" ]]
  then
    MESSAGE="${TITLE}
${DESCRIPTION}"
    TELEGRAM_SEND "${TOKEN}" "${CHAT_ID}" "${MESSAGE}"
  fi
}

SEND_INFO () {
  URL=$( SQL_QUERY "SELECT url FROM webhook_urls WHERE type = 'Information';" )
  TOKEN=$( SQL_QUERY "SELECT token FROM telegram_token WHERE type = 'All';" )
  CHAT_ID=$( SQL_QUERY "SELECT chatid FROM telegram_token WHERE type = 'All';" )

  DESCRIPTION="${1}"
  if [[ -z "${DESCRIPTION}" ]]
  then
    DESCRIPTION="Default Information Message."
  fi
  TITLE="${2}"
  if [[ -z "${TITLE}" ]]
  then
    TITLE=":blue_book: Information :blue_book:"
  fi
  WEBHOOK_COLOR="${5}"
  if [[ -z "${WEBHOOK_COLOR}" ]]
  then
    WEBHOOK_COLOR=65535
  fi
  if [[ ! -z "${6}" ]]
  then
    URL="${6}"
  fi

  if [[ ! -z "${URL}" ]]
  then
    WEBHOOK_SEND "${URL}" "${DESCRIPTION}" "${TITLE}" "${3}" "${4}" "${WEBHOOK_COLOR}"
  fi
  if [[ ! -z "${TOKEN}" ]] && [[ ! -z "${CHAT_ID}" ]]
  then
    MESSAGE="${TITLE}
${DESCRIPTION}"
    TELEGRAM_SEND "${TOKEN}" "${CHAT_ID}" "${MESSAGE}"
  fi
}

SEND_SUCCESS () {
  URL=$( SQL_QUERY "SELECT url FROM webhook_urls WHERE type = 'Success';" )
  TOKEN=$( SQL_QUERY "SELECT token FROM telegram_token WHERE type = 'All';" )
  CHAT_ID=$( SQL_QUERY "SELECT chatid FROM telegram_token WHERE type = 'All';" )

  DESCRIPTION="${1}"
  if [[ -z "${DESCRIPTION}" ]]
  then
    DESCRIPTION="Default Success Message!"
  fi
  TITLE="${2}"
  if [[ -z "${TITLE}" ]]
  then
    TITLE=":moneybag: Success :money_mouth:"
  fi
  WEBHOOK_COLOR="${5}"
  if [[ -z "${WEBHOOK_COLOR}" ]]
  then
    WEBHOOK_COLOR=65535
  fi
  if [[ ! -z "${6}" ]]
  then
    URL="${6}"
  fi

  if [[ ! -z "${URL}" ]]
  then
    WEBHOOK_SEND "${URL}" "${DESCRIPTION}" "${TITLE}" "${3}" "${4}" "${WEBHOOK_COLOR}"
  fi
  if [[ ! -z "${TOKEN}" ]] && [[ ! -z "${CHAT_ID}" ]]
  then
    MESSAGE="${TITLE}
${DESCRIPTION}"
    TELEGRAM_SEND "${TOKEN}" "${CHAT_ID}" "${MESSAGE}"
  fi
}

WEBHOOK_URL_PROMPT () {
  TEXT_A="${1}"
  WEBHOOKURL="${2}"
  while :
  do
    echo
    read -r -e -i "$WEBHOOKURL" -p "${TEXT_A}s WebHook URL: " input
    WEBHOOKURL="${input:-$WEBHOOKURL}"
    if [[ ! -z "${WEBHOOKURL}" ]]
    then
      TOKEN=$( wget -qO- -o- "${WEBHOOKURL}" | jq -r '.token' )
      if [[ -z "$TOKEN" ]]
      then
        echo "Given URL is not a webhook."
        echo
        echo -n 'Get Webhook URL: Your personal server (press plus on left if you do not have one)'
        echo -n ' -> Right click on your server -> Server Settings -> Webhooks'
        echo -n ' -> Create Webhook -> Copy webhook url -> save'
        echo
        WEBHOOKURL=''
      else
        break
      fi
    fi
  done
  SQL_QUERY "REPLACE INTO webhook_urls (type,url) VALUES ('${TEXT_A}','${WEBHOOKURL}');"
}

GET_DISCORD_WEBHOOKS () {
  WEBHOOKURL=$( SQL_QUERY "SELECT url FROM webhook_urls WHERE type = 'Error';" )
  if [[ -z "${WEBHOOKURL}" ]] || [[ "${REPLY}" == y ]]
  then
    # Get webhook url.
    echo
    echo -n 'Get Webhook URL: Your personal server (press plus on left if you do not have one)'
    echo -n ' -> text channels, general, click gear to "edit channel" -> Left side SELECT Webhooks'
    echo -n ' -> Create Webhook -> Copy webhook url -> save'
    echo
    echo "This webhook will be used for ${TEXT_A} Messages."
    echo 'You can reuse the same webhook url if you want all alerts and information'
    echo 'pings in the same channel.'

    WEBHOOK_URL_PROMPT "Error" "${WEBHOOKURL}"
    SEND_ERROR "Test"
  fi
  WEBHOOKURL=$( SQL_QUERY "SELECT url FROM webhook_urls WHERE type = 'Warning';" )
  if [[ -z "${WEBHOOKURL}" ]] || [[ "${REPLY}" == y ]]
  then
    WEBHOOK_URL_PROMPT "Warning" "${WEBHOOKURL}"
    SEND_WARNING "Test"
  fi
  WEBHOOKURL=$( SQL_QUERY "SELECT url FROM webhook_urls WHERE type = 'Information';" )
  if [[ -z "${WEBHOOKURL}" ]] || [[ "${REPLY}" == y ]]
  then
    WEBHOOK_URL_PROMPT "Information" "${WEBHOOKURL}"
    SEND_INFO "Test"
  fi
  WEBHOOKURL=$( SQL_QUERY "SELECT url FROM webhook_urls WHERE type = 'Success';" )
  if [[ -z "${WEBHOOKURL}" ]] || [[ "${REPLY}" == y ]]
  then
    WEBHOOK_URL_PROMPT "Success" "${WEBHOOKURL}"
    SEND_SUCCESS "Test"
  fi
}

if [[ "${arg1}" != 'cron' ]]
then
  echo
  PREFIX='Setup'
  WEBHOOKURL=$( SQL_QUERY "SELECT url FROM webhook_urls WHERE type = 'Error';" )
  if [[ ! -z "${WEBHOOKURL}" ]]
  then
    PREFIX='Redo'
  fi
  read -p "${PREFIX} Discord Bot webhook URLs (y/n)? " -r
  echo
  REPLY=${REPLY,,} # tolower
  if [[ "${REPLY}" == y ]]
  then
    GET_DISCORD_WEBHOOKS
  fi

  echo
  PREFIX='Setup'
  CHAT_ID=$( SQL_QUERY "SELECT chatid FROM telegram_token WHERE type = 'All';" )
  if [[ ! -z "${CHAT_ID}" ]]
  then
    PREFIX='Redo'
  fi
  read -p "${PREFIX} Telegram Bot token (y/n)? " -r
  echo
  REPLY=${REPLY,,} # tolower
  if [[ "${REPLY}" == y ]]
  then
    TELEGRAM_SETUP
  fi

fi

GET_LATEST_LOGINS () {
  while read -r DATE_1 DATE_2 DATE_3 LINE
  do
    UNIX_TIME=$( date -u --date="${DATE_1} ${DATE_2} ${DATE_3}" +%s )
    MESSAGE=$( SQL_QUERY "SELECT message FROM events_log WHERE time == ${UNIX_TIME} AND name_type == 'ssh_login';" )
    if [[ ! -z "${MESSAGE}" ]] && [[ "${arg1}" != 'test' ]]
    then
      continue
    fi

    INFO=$( grep -B 20 -F "${DATE_1} ${DATE_2} ${DATE_3} ${LINE}" /var/log/auth.log | grep -v 'CRON\|preauth\|Invalid user\|user unknown\|Failed[[:space:]]password\|authentication[[:space:]]failure\|refused[[:space:]]connect\|ignoring[[:space:]]max\|not[[:space:]]receive[[:space:]]identification\|[[:space:]]sudo\|[[:space:]]su\|Bad[[:space:]]protocol' | grep 'port' | grep -oE '\]\: .*' | cut -c 4- )

    if [[ -z "${INFO}" ]]
    then
      continue
    fi

    ERRORS=$( SEND_INFO "${INFO}" ":unlock: User logged in" )
    if [[ -z "${ERRORS}" ]]
    then
      echo "${ERRORS}"
      SQL_QUERY "REPLACE INTO events_log (time,name_type,message) VALUES ('${UNIX_TIME}','ssh_login','${INFO}');"
    fi
  done <<< "$( grep ' systemd-logind'  /var/log/auth.log | grep 'New' )"
}
GET_LATEST_LOGINS

CHECK_DISK () {
  UNIX_TIME=$( date -u +%s )
  UNIX_TIME=$( echo "${UNIX_TIME}" - 7200 | bc )
  MESSAGE=$( SQL_QUERY "SELECT message FROM events_log WHERE time > ${UNIX_TIME} AND name_type == 'disk_space';" )
  if [[ ! -z "${MESSAGE}" ]] && [[ "${arg1}" != 'test' ]]
  then
    return
  fi

  FREEPSPACE_ALL=$( df -P . | tail -1 | awk '{print $4}' )
  FREEPSPACE_BOOT=$( df -P /boot | tail -1 | awk '{print $4}' )
  MESSAGE=''
  if [[ "${FREEPSPACE_ALL}" -lt 1572864 ]] || [[ "${arg1}" == 'test' ]]
  then
    FREEPSPACE_ALL=$( echo "${FREEPSPACE_ALL} / 1024" | bc )
    MESSAGE="${MESSAGE} Less than 1.5 GB of free space is left on the drive. ${FREEPSPACE_ALL} MB left."
  fi
  if [[ "${FREEPSPACE_BOOT}" -lt 131072 ]] || [[ "${arg1}" == 'test' ]]
  then
    FREEPSPACE_BOOT=$( echo "${FREEPSPACE_BOOT} / 1024" | bc )
    MESSAGE="${MESSAGE} Less than 128 MB of free space is left in the boot folder. ${FREEPSPACE_BOOT} MB left."
  fi

  if [[ ! -z "${MESSAGE}" ]]
  then
    UNIX_TIME=$( date -u +%s )
    ERRORS=$( SEND_WARNING ":floppy_disk: ${MESSAGE} :floppy_disk:" )
    if [[ -z "${ERRORS}" ]]
    then
      echo "${ERRORS}"
      SQL_QUERY "REPLACE INTO events_log (time,name_type,message) VALUES ('${UNIX_TIME}','disk_space','${MESSAGE}');"
    fi
  fi
}
CHECK_DISK

CHECK_CPU_LOAD () {
  UNIX_TIME=$( date -u +%s )
  UNIX_TIME=$( echo "${UNIX_TIME}" - 7200 | bc )
  MESSAGE=$( SQL_QUERY "SELECT message FROM events_log WHERE time > ${UNIX_TIME} AND name_type == 'cpu_usage';" )
  if [[ ! -z "${MESSAGE}" ]] && [[ "${arg1}" != 'test' ]]
  then
    return
  fi

  LOAD=$( uptime | grep -oE 'load average: [0-9]+([.][0-9]+)?' | grep -oE '[0-9]+([.][0-9]+)?' )
  CPU_COUNT=$( grep -c 'processor' /proc/cpuinfo )
  LOAD_PER_CPU="$( printf "%.3f\n" "$( bc -l <<< "${LOAD} / ${CPU_COUNT}" )" )"

  if [[ $( echo "${LOAD_PER_CPU} > 4" | bc ) -gt 0 ]] || [[ "${arg1}" == 'test' ]]
  then
    ERRORS=$( SEND_ERROR ":desktop: :fire:  CPU LOAD is over 4: ${LOAD_PER_CPU} :fire: :desktop: " )
    if [[ -z "${ERRORS}" ]] && [[ "${arg1}" != 'test' ]]
    then
      echo "${ERRORS}"
      SQL_QUERY "REPLACE INTO events_log (time,name_type,message) VALUES ('${UNIX_TIME}','cpu_usage','CPU LOAD is over 2');"
    fi
  fi
  if ([[ $( echo "${LOAD_PER_CPU} > 2" | bc ) -gt 0 ]] && [[ $( echo "${LOAD_PER_CPU} <= 4" | bc ) -gt 0 ]]) || [[ "${arg1}" == 'test' ]]
  then
    ERRORS=$( SEND_WARNING ":desktop: CPU LOAD is over 2: ${LOAD_PER_CPU} :desktop: " )
    if [[ -z "${ERRORS}" ]] && [[ "${arg1}" != 'test' ]]
    then
      echo "${ERRORS}"
      SQL_QUERY "REPLACE INTO events_log (time,name_type,message) VALUES ('${UNIX_TIME}','cpu_usage','CPU LOAD is over 2');"
    fi
  fi

}
CHECK_CPU_LOAD

CHECK_SWAP () {
  UNIX_TIME=$( date -u +%s )
  UNIX_TIME=$( echo "${UNIX_TIME}" - 7200 | bc )
  MESSAGE=$( SQL_QUERY "SELECT message FROM events_log WHERE time > ${UNIX_TIME} AND name_type == 'swap_free';" )
  if [[ ! -z "${MESSAGE}" ]] && [[ "${arg1}" != 'test' ]]
  then
    return
  fi

  SWAP_FREE_MB=$( free -wm | grep -i 'Swap:' | awk '{print $4}' )
  if [[ $( echo "${SWAP_FREE_MB} < 512" | bc ) -gt 0 ]] || [[ "${arg1}" == 'test' ]]
  then
    ERRORS=$( SEND_ERROR ":desktop: :fire: Swap is under 512 MB: ${SWAP_FREE_MB} :fire: :desktop: " )
    if [[ -z "${ERRORS}" ]] && [[ "${arg1}" != 'test' ]]
    then
      echo "${ERRORS}"
      SQL_QUERY "REPLACE INTO events_log (time,name_type,message) VALUES ('${UNIX_TIME}','cpu_usage','Swap is under 512 MB');"
    fi
  fi
  if ([[ $( echo "${SWAP_FREE_MB} >= 512" | bc ) -gt 0 ]] && [[ $( echo "${SWAP_FREE_MB} < 1024" | bc ) -gt 0 ]]) || [[ "${arg1}" == 'test' ]]
  then
    ERRORS=$( SEND_WARNING ":desktop: Swap is under 1024 MB: ${SWAP_FREE_MB} :desktop: " )
    if [[ -z "${ERRORS}" ]] && [[ "${arg1}" != 'test' ]]
    then
      echo "${ERRORS}"
      SQL_QUERY "REPLACE INTO events_log (time,name_type,message) VALUES ('${UNIX_TIME}','cpu_usage','Swap is under 1024 MB');"
    fi
  fi

}
CHECK_SWAP

CHECK_RAM () {
  UNIX_TIME=$( date -u +%s )
  UNIX_TIME=$( echo "${UNIX_TIME}" - 7200 | bc )
  MESSAGE=$( SQL_QUERY "SELECT message FROM events_log WHERE time > ${UNIX_TIME} AND name_type == 'ram_free';" )
  if [[ ! -z "${MESSAGE}" ]] && [[ "${arg1}" != 'test' ]]
  then
    return
  fi

  MEM_AVAILABLE=$( sudo cat /proc/meminfo | grep -i 'MemAvailable:\|MemFree:' | awk '{print $2}' | tail -n 1 )
  MEM_AVAILABLE_MB=$( echo "${MEM_AVAILABLE} / 1024" | bc )

  if [[ $( echo "${MEM_AVAILABLE_MB} < 256" | bc ) -gt 0 ]] || [[ "${arg1}" == 'test' ]]
  then
    ERRORS=$( SEND_ERROR ":desktop: :fire: Free RAM is under 256 MB: ${MEM_AVAILABLE_MB} :fire: :desktop: " )
    if [[ -z "${ERRORS}" ]] && [[ "${arg1}" != 'test' ]]
    then
      echo "${ERRORS}"
      SQL_QUERY "REPLACE INTO events_log (time,name_type,message) VALUES ('${UNIX_TIME}','cpu_usage','Free RAM is under 256 MB');"
    fi
  fi
  if ([[ $( echo "${MEM_AVAILABLE_MB} >= 256" | bc ) -gt 0 ]] && [[ $( echo "${MEM_AVAILABLE_MB} < 512" | bc ) -gt 0 ]]) || [[ "${arg1}" == 'test' ]]
  then
    ERRORS=$( SEND_WARNING ":desktop: Free RAM is under 512 MB: ${MEM_AVAILABLE_MB} :desktop: " )
    if [[ -z "${ERRORS}" ]] && [[ "${arg1}" != 'test' ]]
    then
      echo "${ERRORS}"
      SQL_QUERY "REPLACE INTO events_log (time,name_type,message) VALUES ('${UNIX_TIME}','cpu_usage','Free RAM is under 512 MB');"
    fi
  fi
}
CHECK_RAM

GET_ALL_NODES () {
  CONF_N_USRNAMES=''
  LSLOCKS=$( lslocks -n -o COMMAND,PID,PATH )
  PS_LIST=$( ps --no-headers -axo user:32,pid,command )

  # shellcheck disable=SC2034
  while read -r USRNAME DEL_1 DEL_2 DEL_3 DEL_4 DEL_5 DEL_6 DEL_7 DEL_8 USR_HOME_DIR USR_HOME_DIR_ALT DEL_9
  do
    if [[ "${USR_HOME_DIR}" == 'X' ]]
    then
      USR_HOME_DIR=${USR_HOME_DIR_ALT}
    fi

    if [[ "${#USR_HOME_DIR}" -lt 3 ]] || [[ ${USR_HOME_DIR} == /var/run/* ]] || [[ ${USR_HOME_DIR} == '/proc' ]]
    then
      continue
    fi

    MN_USRNAME=$( basename "${USR_HOME_DIR}" )
    DAEMON_BIN=''
    CONTROLLER_BIN=''

    CONF_LOCATIONS=$( find "${USR_HOME_DIR}" -name "peers.dat" 2>/dev/null )
    if [[ -z "${CONF_LOCATIONS}" ]]
    then
      continue
    fi
    CONF_FOLDER=$( dirname "${CONF_LOCATIONS}" )
    CONF_LOCATIONS=$( grep --include=\*.conf -rl "rpc" "${CONF_FOLDER}" )

    if [[ -z "${CONF_LOCATIONS}" ]] && [[ "$( type "${MN_USRNAME}" 2>/dev/null | grep -c '_masternode_dameon_2' )" -gt 0 ]]
    then
      CONF_LOCATIONS=$( "${MN_USRNAME}" conf loc )
    fi

    while read -r CONF_LOCATION
    do
      if [[ $( echo "${CONF_LOCATION}" | grep -c '/contrib/' ) -eq 1 ]]
      then
        continue
      fi

      CONF_FOLDER=$( dirname "${CONF_LOCATION}" )
      DAEMON_BIN=$( echo "${LSLOCKS}" | grep -m 1 "${CONF_FOLDER}" | awk '{print $1}' )
      CONTROLLER_BIN=${DAEMON_BIN}
      TEMP_VAR_PID=$( echo "${LSLOCKS}" | grep -m 1 "${CONF_FOLDER}" | awk '{print $2}' )
      if [[ ! -z "${TEMP_VAR_PID}" ]]
      then
        COMMAND=$( echo "${PS_LIST}" | cut -c 32- | grep " ${TEMP_VAR_PID} " | awk '{print $2}' )
        COMMAND_FOLDER=$( dirname "${COMMAND}" )
        CONTROLLER_BIN_FOLDER=$( find "${COMMAND_FOLDER}" -executable -type f | grep -v "${DAEMON_BIN}" | grep -i "${DAEMON_BIN::-1}" )
        if [[ ! -z "${CONTROLLER_BIN_FOLDER}" ]]
        then
          CONTROLLER_BIN=$( basename "${CONTROLLER_BIN_FOLDER}" )
        fi
      fi

      if [[ "$( type "${MN_USRNAME}" 2>/dev/null | grep -c '_masternode_dameon_2' )" -gt 0 ]]
      then
        if [[ -z "${DAEMON_BIN}" ]]
        then
          DAEMON_BIN=$( "${MN_USRNAME}" daemon )
        fi
        if [[ -z "${CONTROLLER_BIN}" ]]
        then
          CONTROLLER_BIN=$( "${MN_USRNAME}" cli )
        fi
      fi

      CONF_N_USRNAMES="${CONF_N_USRNAMES}
${USRNAME} ${CONTROLLER_BIN} ${DAEMON_BIN} ${CONF_LOCATION} ${TEMP_VAR_PID}"
    done <<< "${CONF_LOCATIONS}"
  done <<< "$( cut -d: -f1 /etc/passwd | getent passwd | sed 's/:/ X /g' | sort -h )"

  # Clean up var.
  CONF_N_USRNAMES=$( echo "${CONF_N_USRNAMES}" | sed '/^[[:space:]]*$/d' )
  ROOT_ENTRY=$( echo "${CONF_N_USRNAMES}" | grep -E '^root .*' )
  CONF_N_USRNAMES=$( echo "${CONF_N_USRNAMES}" | sed '/^root .*/d' )
  CONF_N_USRNAMES="${CONF_N_USRNAMES}
${ROOT_ENTRY}"
  CONF_N_USRNAMES=$( echo "${CONF_N_USRNAMES}" | sed '/^[[:space:]]*$/d' )

  echo "${CONF_N_USRNAMES}" | column -t
}
ALL_RUNNING_NODES=$( GET_ALL_NODES )
