#!/usr/bin/env bash

set -u
set -e

help(){
	echo \
"
SendAudio - script for sending music albums via sshfs. Reencodes audiofiles too.


Usage:
splitaudio.sh [options] dir1 ...

Where dir - directory with music album's content (audiofiles and scans).
Copies album art and nested directories as well.

Example:
	sendaudio.sh \
	'Jimi Hendrix - Are You Experienced [1967]' \
	'The Jimi Hendrix Experience - Axis Bold As Love [1967]'

Options:

	-i
		include all image files found along audio files (Default)

	-I
		include all image files found in album

	-c
		include only cover image files, such as cover.jpg, front.png, folder.gif (case insensitive)

	-n
		add .nomedia files along any image files.

	-h
		print this help

"
	exit
}


OUTPUT_DIR="$(pwd)"

NOMEDIA=0
IMAGES_INCLUDE_ALONG=0
IMAGES_INCLUDE_ALL=1
IMAGES_INCLUDE_COVER=2

IMAGES_INCLUDE="${IMAGES_INCLUDE_ALONG}"

TMP=$(getopt -o "iIcnh" -- "$@")
eval set -- "${TMP}"
while true
do
	case "$1" in
	-i  ) IMAGES_INCLUDE="${IMAGES_INCLUDE_ALONG}"; shift;;
	-I  ) IMAGES_INCLUDE="${IMAGES_INCLUDE_ALL}"; shift;;
	-c	) IMAGES_INCLUDE="${IMAGES_INCLUDE_COVER}"; shift;;
	-n	) NOMEDIA=1; shift;;
	-h	) help;;
	--	) shift; break;
	esac
done


TMP='/tmp/sendaudio'

ENCODING_PARAMS='-c:a libvorbis -q:a 10'

# Lowest bitrate for reencoding. If lower - just copy.
a_bitrate=320000 #320k
images_cover_names=( 'cover' 'folder' 'front' 'cd' )
IFS=\| eval 'covers_regexp="/(${images_cover_names[*]})\.\w+?$"'


SSH_HOSTNAME='phone_filetransfer'
SSH_OPTIONS='-oauto_cache,reconnect,no_readahead,Ciphers=arcfour,umask=000'
MOUNTDIR='/storage/sdcard0/Music'
DEST='/mnt/phone_music'
CONNECT(){
	mkdir -p "${DEST}" 2>/dev/null||:
	sshfs ${SSH_OPTIONS} "$SSH_HOSTNAME":"${MOUNTDIR}" "${DEST}"
}

close_resources(){
	mountpoint -q "${DEST}" && fusermount -u "${DEST}"||:  #2>/dev/null ||:
	rm -r "${TMP}" &>/dev/null ||: #2>/dev/null ||:
	pkill -P "$$" &>/dev/null ||:
}

PANIC(){
	printf "[PANIC]: %s\n" "$*";
	close_resources
	exit 1;
}

ERROR(){ printf "[ERROR]: %s\n" "$*"; }
COMPLETE(){ printf "[Complete]: %s\n" "$*"; }
STATUS(){ printf "[%s]\n" "$*"; }

find_files_by_mimetype(){
	local delim='///'
	declare -A ignore=( [audio]='audio/x-mpegurl' ) # with declare, local by default

	local dir="$1"
	local mimetype="$2"
	local maxdepth="$3"

	find "${dir}" -maxdepth "${maxdepth:-999}" -type f -print0 \
	| xargs -0 mimetype -F "${delim}" -N  \
	| grep "[\t ]${mimetype}/" \
	| grep -v "[\t ]${ignore[${mimetype}]:-^$$}" \
	| awk -F "${delim}" '{print $1}'
}

get_bitrate(){ mediainfo --Output='Audio;%BitRate%' "$1"; }

handler()
{
	close_resources
	exit 1
} 2>/dev/null

trap handler SIGINT
trap handler EXIT


mountpoint -q "$DEST" &&
{
	ERROR "Something is already mounted to ${DEST}. Trying to unmount"
	fusermount -u "${DEST}" || PANIC "Unsuccessful"
}

CONNECT || PANIC "Couldn't connect to phone"

mkdir -p "${TMP}"
for dir in "$@";
do
	dname=$(basename "$dir")
	STATUS 'Sending "'"${dname}"'"'
	[[ ! -d "${dir}" ]] && ERROR "$dir is not a directory. Omitting."
	outdir="${TMP}/${dname}"

	mkdir -p "${outdir}"

	cd "${dir}"
	set +u

	readarray -t audiofiles < <( find_files_by_mimetype . audio )
	readarray -t audiodirs < <( { echo "."; printf '%s\0' "${audiofiles[@]}"; } | xargs -0 dirname | sort -u;)

	case "${IMAGES_INCLUDE}" in
		"${IMAGES_INCLUDE_ALONG}"	)
			readarray -t images < <( for i in "${audiodirs[@]}"; do find_files_by_mimetype "$i" image 1; done  );
			# break
			;;
		"${IMAGES_INCLUDE_ALL}"		)
			readarray -t images < <( find_files_by_mimetype . image);
			# break
			;;
		"${IMAGES_INCLUDE_COVER}"	)
			readarray -t images < <( find_files_by_mimetype . image | grep -iE "${covers_regexp}");
			# break
			;;
	esac
	readarray -t imagedirs < <({ printf '%s\0' "${images[@]}"; } | xargs -0 dirname | sort -u;)


	# echo "=========AUDIOFILES=========="; printf -- '%s\n' "${audiofiles[@]}"; echo
	# echo "=========MEDIADIRS=========="; printf -- '%s\n' "${audiodirs[@]}"; echo
	# echo "=========IMAGES=========="; printf -- '%s\n' "${images[@]}"; echo

	STATUS 'Creating hierarchy'
	for i in "${audiodirs[@]}" "${imagedirs[@]}";
	do
		mkdir -p "${outdir}"/"$i" &>/dev/null
	done

	STATUS 'Reencoding audio files'
	pids=()
	c=0
	for i in "${audiofiles[@]}";
	do
		bitrate=$(mediainfo --Output='Audio;%BitRate%' "$i")
		if [[ $bitrate -gt $a_bitrate ]];
		then
			# STATUS "Reencoding $i"
			newfile="${outdir}/${i%.*}.ogg"
			ffmpeg -loglevel panic -hide_banner -y -i "$i" -map 0:a ${ENCODING_PARAMS} "${newfile}" \
			&&	COMPLETE $(basename "${newfile}") \
			||	ERROR "Reencoding of ${i}" \
			&
		else
			# STATUS "Copying $i"
			newfile="${outdir}/${i}"
			cp "$i" "${newfile}" \
			&& COMPLETE $(basename "${newfile}") \
			|| ERROR "Copying of $i" \
			&
		fi

		pids[$c]=$!
		(( c++ )) ||:

	done

	STATUS 'Copying images'
	for i in "${images[@]}";
	do
		STATUS "Copying $i"
		cp "$i" "${outdir}/$i"
	done
	set -u
	cd - &>/dev/null

	if [[ $NOMEDIA -eq 1 ]]
	then
		for i in "${imagedirs[@]}"
		do
			>"$(dirname $i)/.nomedia"
		done
	fi


	STATUS 'Waiting for encoding'
	wait "${pids[@]}"

	STATUS "Transfering ${dname} to phone"

	{
		s=$(du -hs "${outdir}" | cut -f1)
		t=$({ time cp -r --no-preserve=timestamps "${outdir}" "${DEST}"; } 2>&1 | grep real | cut -f2) \
		&& rm -r "${outdir}" \
		&& COMPLETE Transfered $(basename "${outdir}") "(of $s in $t)" \
		|| ERROR Transfering of $(basename "${outdir}")
	} &

done

wait
close_resources