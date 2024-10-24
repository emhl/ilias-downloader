#!/bin/bash

# IliasDownload.sh: A download script for ILIAS, an e-learning platform.
# Copyright (C) 2016 - 2018 Ingo Koinzer
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# Für FH Aachen angepasst von Paul Krüger, Oktober 2020.
#

if [ -z "$COOKIE_PATH" ] ; then
	COOKIE_PATH=/tmp/ilias-cookies.txt
fi

# Load env-variables from config
. .config

# .config example:
#   ILIAS_URL="https://www.ili.fh-aachen.de/"
#   ILIAS_PREFIX="elearning"
#   ILIAS_LOGIN_GET="login.php?client_id=elearning&lang=de"
#   ILIAS_HOME="ilias.php?baseClass=ilPersonalDesktopGUI&cmd=jumpToSelectedItems"
#   ILIAS_LOGOUT="logout.php?lang=de"

# Prefix für lokalen Ordernamen von Übungen  
EXC_FOLDER_PREFIX="exc "

# DON'T TOUCH FROM HERE ON

# TODO Die Variablen zählen falsch, da sie nicht zwischen den parallelen Prozessen geteilt werden.. Ein Logfile wäre vermutlich cooler.
ILIAS_DL_COUNT=0
ILIAS_IGN_COUNT=0
ILIAS_FAIL_COUNT=0
ILIAS_DL_NAMES=""
ILIAS_DL_FAILED_NAMES=""

check_config() {
    if [[ -z "${ILIAS_URL}" ]]; then
        echo "[Config] Ilias URL nicht gesetzt."
        exit 10 # terminate with error - ilias url missing
    else
        echo "[Config] ILIAS_URL=$ILIAS_URL"
    fi
    
    if [[ -z "${ILIAS_PREFIX}" ]]; then
        echo "[Config] Ilias Prefix nicht gesetzt."
        exit 11 # terminate with error - ilias prefix missing
    else
        echo "[Config] ILIAS_PREFIX=$ILIAS_PREFIX"
    fi
    
    if [[ -z "${ILIAS_LOGIN_GET}" ]]; then
        echo "[Config] Ilias Login Pfad nicht gesetzt."
        exit 12 # terminate with error - ilias login get missing
    else
        echo "[Config] ILIAS_LOGIN_GET=$ILIAS_LOGIN_GET"
    fi
    
    if [[ -z "${ILIAS_HOME}" ]]; then
        echo "[Config] Ilias Home Pfad nicht gesetzt."
        exit 13 # terminate with error - ilias home missing
    else
        echo "[Config] ILIAS_HOME=$ILIAS_HOME"
    fi
    
    if [[ -z "${ILIAS_LOGOUT}" ]]; then
        echo "[Config] Ilias Logout Pfad nicht gesetzt."
        exit 14 # terminate with error - ilias logout missing
    else
        echo "[Config] ILIAS_LOGOUT=$ILIAS_LOGOUT"
    fi
}

check_credentials() {
    if [[ -z "${ILIAS_USERNAME}" ]]; then
        echo "[Config] Bitte Nutzername eingeben und Script erneut ausführen."
        exit 15 # terminate with error - ilias username missing
    else
        echo "[Config] ILIAS_USERNAME=$ILIAS_USERNAME"
    fi
    
    if [[ -z "${ILIAS_PASSWORD}" ]]; then
        echo "[Config] Bitte Passwort eingeben und Script erneut ausführen."
        exit 16 # terminate with error - ilias prefix missing
    else
        echo "[Config] ILIAS_PASSWORD=$(echo "$ILIAS_PASSWORD" | sed 's/./*/g')"
    fi
}

check_grep_availability() {
	echo "abcde" | grep -oP "abc\Kde"
	GREP_AV=`echo "$?"`
}

do_grep() {
	if [ "$GREP_AV" -eq 0 ] ; then
		grep -oP "$1"
	else
		# Workaround if no Perl regex supported
		local prefix=`echo "$1" | awk -F: 'BEGIN {FS="\\\\K"}{print $1}'`
		local match=`echo "$1" | awk -F: 'BEGIN {FS="\\\\K"}{print $2}'`
		grep -o "$prefix$match" | grep -o "$match"
	fi
}

ilias_request() {
	curl -s -k -L -b "$COOKIE_PATH" -c "$COOKIE_PATH" $2 "$ILIAS_URL$1"
}

do_login() {
	if [ -f $COOKIE_PATH ] ; then
		rm $COOKIE_PATH
	fi
	echo "Getting form url..."
	local LOGIN_PAGE=`ilias_request "$ILIAS_LOGIN_GET"`
	ILIAS_LOGIN_POST=`echo "$LOGIN_PAGE" | tr -d "\r\n" | do_grep "name=\"formlogin\".*action=\"\K[^\"]*"`
	if [ "$?" -ne 0 ] ; then
		echo "Failed getting login form url."
		exit 1
	fi
	ILIAS_LOGIN_POST=`echo "$ILIAS_LOGIN_POST" | sed 's/&amp;/\&/g'`
	echo "Sending login information..."
	ilias_request "$ILIAS_LOGIN_POST" "--data-urlencode username=$ILIAS_USERNAME --data-urlencode password=$ILIAS_PASSWORD --data-urlencode cmd[doStandardAuthentication]=Anmelden" > /dev/null
	result="$?"
	if [ "$result" -ne 0 ] ; then
		echo "Failed sending login information: $result."
		exit 2
	fi
	
	echo "Checking if logged in..."
    
	local ITEMS=`ilias_request "$ILIAS_HOME" | do_grep "ilDashboardMainContent"`
	if [ -z "$ITEMS" ] ; then
		echo "Home page check failed. Is your login information correct?"
		exit 3
	fi
}

function do_logout {
	echo "Logging out."
	ilias_request "$ILIAS_LOGOUT" > /dev/null
}

function get_filename {
	ilias_request "$1" "-I" | do_grep "Content-Description: \K(.*)" | tr -cd '[:print:]'
}


function fetch_exc {
	if [ ! -d "$2" ] ; then
		echo "$2 is not a directory!"
		return
	fi
	cd "$2"
	if [ ! -f "$HISTORY_FILE" ] ; then
		touch "$HISTORY_FILE"
	fi
	local HISTORY_CONTENT=`cat "$HISTORY_FILE"`

	echo "Fetching exc $1 to $2"

	local CONTENT_PAGE=`ilias_request "ilias.php?baseClass=ilrepositorygui&ref_id=$1"`

	# Fetch all Download Buttons from this page
	local ITEMS=`echo "$CONTENT_PAGE" | do_grep "<a href=\"\K[^\"]*(?=\">$ILIAS_EXC_BUTTON_DESC)" | sed -e 's/\&amp\;/\&/g'` 
	for file in $ITEMS ; do
		local DO_DOWNLOAD=1
        local FILENAME=`echo $file | do_grep "&file=\K(?=&)"`
        local ECHO_MESSAGE="[$EXC_FOLDER_PREFIX$1] Check file $FILENAME ..."
		echo "$HISTORY_CONTENT" | grep "$file" > /dev/null
		if [ $? -eq 0 ] ; then
			local ITEM=`echo $CONTENT_PAGE | do_grep "<h[34] class=\"il_ContainerItemTitle\"><a href=\"${ILIAS_URL}${file}.*<div style=\"clear:both;\"></div>"`
			echo "$ITEM" | grep "geändert" > /dev/null
			if [ $? -eq 0 ] ; then
				local ECHO_MESSAGE="$ECHO_MESSAGE changed"
				local PART_NAME="${FILENAME%.*}"
				local PART_EXT="${FILENAME##*.}"
				local PART_DATE=`date +%Y%m%d-%H%M%S`
				mv "$FILENAME" "${PART_NAME}.${PART_DATE}.${PART_EXT}"
			else
				local ECHO_MESSAGE="$ECHO_MESSAGE exists"
				((ILIAS_IGN_COUNT++))
				DO_DOWNLOAD=0
			fi
		fi
		if [ $DO_DOWNLOAD -eq 1 ] ; then
			local ECHO_MESSAGE="$ECHO_MESSAGE $FILENAME downloading..."
			
			ilias_request "$file" "-O -J"
			local RESULT=$?
			if [ $RESULT -eq 0 ] ; then
				echo "$file" >> "$HISTORY_FILE"
				((ILIAS_DL_COUNT++))
				local ECHO_MESSAGE="$ECHO_MESSAGE done"
				ILIAS_DL_NAMES="${ILIAS_DL_NAMES} - ${FILENAME}
"
			else
				local ECHO_MESSAGE="$ECHO_MESSAGE failed: $RESULT"
				((ILIAS_FAIL_COUNT++))
				ILIAS_DL_FAILED_NAMES="${ILIAS_DL_NAMES} - ${FILENAME} (failed: $RESULT)
"
			fi
		fi
        echo "$ECHO_MESSAGE"
	done
    
}

function fetch_folder {
	if [ ! -d "$2" ] ; then
		echo "$2 is not a directory!"
		return
	fi
	cd "$2"
	if [ ! -f "$HISTORY_FILE" ] ; then
		touch "$HISTORY_FILE"
	fi
	local HISTORY_CONTENT=`cat "$HISTORY_FILE"`
	
	echo "Fetching folder $1 to $2"

	echo "$1" | do_grep "^[0-9]*$" > /dev/null
	local CONTENT_PAGE=`ilias_request "ilias.php?baseClass=ilrepositorygui&ref_id=$1"`
    
	# Fetch Subfolders recursive (async) 
	local ITEMS=`echo "$CONTENT_PAGE" | do_grep "<h[34] class=\"il_ContainerItemTitle\"><a href=\"\Kilias\.php\?baseClass.*ref_id=[0-9]*"`
	for folder in $ITEMS ; do
		local FOLD_NUM=`echo "$folder" | do_grep "ref_id=\K[0-9]*"`
		local FOLDER_NAME=`echo "$CONTENT_PAGE" | do_grep "ref_id=${FOLD_NUM}\"[^>]*>\K[^<]*"`
		
		# Replace / character
		local FOLDER_NAME=`echo "${FOLDER_NAME//\//-}" | head -1`
		echo "Entering folder $FOLDER_NAME"
		if [ ! -e "$2/$FOLDER_NAME" ] ; then
			mkdir "$2/$FOLDER_NAME"
		fi
		fetch_folder "$FOLD_NUM" "$2/$FOLDER_NAME" &
	done
    
    
	# Filesi
	local ITEMS=`echo $CONTENT_PAGE | do_grep "<h[34] class=\"il_ContainerItemTitle\"><a href=\"${ILIAS_URL}\Kgoto\.php\?target=file_[0-9]*_download"`
	for file in $ITEMS ; do
		local DO_DOWNLOAD=1
		local NUMBER=`echo "$file" | do_grep "[0-9]*"`
		local ECHO_MESSAGE="[$1-$NUMBER]"
        
        # find the box around the file we are processing.
		local ITEM=`echo $CONTENT_PAGE | do_grep "<h[34] class=\"il_ContainerItemTitle\"><a href=\"${ILIAS_URL}${file}.*<div style=\"clear:both;\"></div>"`
	# extract version information from file. (Might be empty)
		local VERSION=`echo "$ITEM" | grep -o -P '(?<=<span class=\"il_ItemProperty\"> Version: ).*?(?=&nbsp;&nbsp;</span>.*)'`
        # build fileId
		local FILEID=`echo "$file $VERSION" | xargs`
        
		echo "$HISTORY_CONTENT" | grep "$FILEID" > /dev/null
		if [ $? -eq 0 ] ; then
            
            # If ITEM contains text geändert we must download
			echo "$ITEM" | grep "geändert" > /dev/null
			if [ $? -eq 0 ] ; then
				local FILENAME=`get_filename "$file"`
				local ECHO_MESSAGE="$ECHO_MESSAGE $FILENAME changed"
				local PART_NAME="${FILENAME%.*}"
				local PART_EXT="${FILENAME##*.}"
				local PART_DATE=`date +%Y%m%d-%H%M%S`
				mv "$FILENAME" "${PART_NAME}.${PART_DATE}.${PART_EXT}"
			else
				local ECHO_MESSAGE="$ECHO_MESSAGE exists"
				((ILIAS_IGN_COUNT++))
				DO_DOWNLOAD=0
			fi
		fi
		if [ $DO_DOWNLOAD -eq 1 ] ; then
			local FILENAME=`get_filename "$file"`
            
            # Prüfen, ob lokale Datei mit dem Namen existiert. Falls ja, muss diese umbenannt werden. (Kann passieren, wenn Dateien im Ilias nicht aktualisiert, sondern gelöscht und neu hochgeladen werden.)
            if [[ -f "$FILENAME" ]]; then
				local ECHO_MESSAGE="$ECHO_MESSAGE $FILENAME new"
				local PART_NAME="${FILENAME%.*}"
				local PART_EXT="${FILENAME##*.}"
				local PART_DATE=`date +%Y%m%d-%H%M%S`
				mv "$FILENAME" "${PART_NAME}.${PART_DATE}.${PART_EXT}"
            fi
            
			local ECHO_MESSAGE="$ECHO_MESSAGE $FILENAME downloading..."
			
			ilias_request "$file" "-O -J"
			local RESULT=$?
			if [ $RESULT -eq 0 ] ; then
				echo "$FILEID" >> "$HISTORY_FILE"
				((ILIAS_DL_COUNT++))
				local ECHO_MESSAGE="$ECHO_MESSAGE done"
				ILIAS_DL_NAMES="${ILIAS_DL_NAMES} - ${FILENAME}
"
			else
				local ECHO_MESSAGE="$ECHO_MESSAGE failed: $RESULT"
				((ILIAS_FAIL_COUNT++))
				ILIAS_DL_FAILED_NAMES="${ILIAS_DL_NAMES} - ${FILENAME} (failed: $RESULT)
"
			fi
		fi
        
        echo "$ECHO_MESSAGE"
	done
    
    
    # Übungen
    
	local ITEMS=`echo $CONTENT_PAGE | do_grep "<h[34] class=\"il_ContainerItemTitle\"><a href=\"${ILIAS_URL}\Kgoto_${ILIAS_PREFIX}_exc_[0-9]*.html"`
	
	for exc in $ITEMS ; do
		local EXC_NAME=`echo "$CONTENT_PAGE" | do_grep "<h[34] class=\"il_ContainerItemTitle\"><a href=\"${ILIAS_URL}${exc}\"[^>]*>\K[^<]*"`
		
		# Replace / character
		local EXC_NAME=${EXC_NAME//\//-}
		echo "Entering exc $EXC_NAME"
		local EXC_NUM=`echo "$exc" | do_grep "exc_\K[0-9]*"`
		if [ ! -e "$2/$EXC_FOLDER_PREFIX$EXC_NAME" ] ; then
			mkdir "$2/$EXC_FOLDER_PREFIX$EXC_NAME"
		fi
		fetch_exc "$EXC_NUM" "$2/$EXC_FOLDER_PREFIX$EXC_NAME" 
	done
    
	wait
	
}

function print_stat() {
	echo
	echo "Downloaded $ILIAS_DL_COUNT new files, ignored $ILIAS_IGN_COUNT files, $ILIAS_FAIL_COUNT failed."
	echo "$ILIAS_DL_NAMES"

	if [ ! -z "$ILIAS_DL_FAILED_NAMES" ] ; then
		echo "Following downloads failed:"
		echo "$ILIAS_DL_FAILED_NAMES"
	fi
}

check_grep_availability
check_config
check_credentials
