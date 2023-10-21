#!/usr/bin/env bash
set -euo pipefail

VM_NAME_PREFIX="testvm-"
VM_NAME="$VM_NAME_PREFIX$(date +%Y%m%d%H%M%S)"
VM_IMAGE='debian/bookworm64'
ENV_DIR_PARENT="$HOME/.vagrant.d/testvmenv"
SSH_TIMEOUT=30
	# ^ also used as threshold for when SSH returning 255 is not handled anymore


if (($# > 1)); then
	echo 'Wrong usage (expected one or no arguments).' >&2
	exit 2
elif [[ "${1-}" =~ ^(--)?((clean(up)?)|(rem(ove)?)|(del(ete?)?)|(dlete?)|(destroy))$ ]]; then destroy=1
else destroy=0
fi

indent() {
	local l=${1:-1} i
	for ((i=0;i!=l;i++)); do
		local spacing+='    '
	done
	sed -e '/^\s*$/d' -e "s/^/$spacing/"
}

necho() {
	echo; echo "$@"
}

vssh() {
	echo
	ssh_status=0
	ssh_start_time=$(date +%s)
	vagrant ssh testvm -- -o ConnectTimeout=$SSH_TIMEOUT || ssh_status=$?
	ssh_time=$(($(date +%s) - ssh_start_time))
}

destroy() {
	local env_dir="$1"
	cd "$env_dir"
	vagrant destroy --no-tty --force testvm 2>&1 | indent || true
	necho 'Cleaning up...'
	rm -vr "$env_dir" 2>&1 | indent
}

offer() {
	local REPLY
	local prompt="$1"
	read -t 0.1 || true
	necho -n "$prompt [Y/n] "
	read
	case $REPLY in
		''|Y|y) return 0;;
		*)
			echo 'Aborting.'
			exit 0
			;;
	esac
}

offer_destroy() {
	local env_dir="$1"
	local prompt='remove?'
	if [[ $# > 1 ]]; then
		prompt="$2; $prompt"
	fi
	if offer "$prompt"; then
		necho "Removing test VM \`$VM_NAME'..."
		destroy "$env_dir"
	fi
}

ssh_status_check() {
	if (( ssh_status == 1 || (ssh_status == 255 && ssh_time <= SSH_TIMEOUT + 2) )); then
		return 1
	else return 0
	fi
}

progress_bar() {
	local progress_perc=$1
	local msg=${2:-}
	local width_offset=${3:-0}
	local width_room=$(( ${#msg} + ( (${#msg} > 0) * 1) + 2 + width_offset )) ||:
	local width=$(( $(tput cols) - width_room )) ||:
	local done=$((width * progress_perc / 100)) ||:
	local todo=$((width - done)) ||:
	printf '\r%*s' $width_offset
	printf '[%*s' $done | tr ' ' '#'
	printf '%*s]' $todo | tr ' ' -
	printf ' %s' "$msg"
}

# Detect preexisting testvm's
IFS=$'\n'; if env_dirs=($(ls -1d "$ENV_DIR_PARENT"/"$VM_NAME_PREFIX"* 2>/dev/null)); then
	if ((destroy)); then
		for env_dir in "${env_dirs[@]}"; do
			VM_NAME=$(basename "$env_dir")
			necho "Found test VM \`$VM_NAME'; destroying..."
			destroy "$env_dir"
		done
	else
		last_env_dir="${env_dirs[-1]}"
		VM_NAME=$(basename "$last_env_dir")
		necho "Found existing test VM \`$VM_NAME'; connecting..."
		cd "$last_env_dir"
		vssh
		if ! ssh_status_check; then
			necho "Unsuccesful ($ssh_status) SSH status; checking test VM status..."
			vagrant_status=0
			vagrant_status_output=$(vagrant status --no-tty testvm 2>&1) || vagrant_status=$?
			echo "$vagrant_status_output" | indent
			if ! grep -qE '^testvm\s{2,}((running)|(poweroff)) \([^)]+)$' <<< "$vagrant_status_output"
			then vagrant_status=1
			fi
			if ((vagrant_status)); then
				offer_destroy "$last_env_dir" "Unexpected status for test VM \`$VM_NAME'"
			else
				necho -n 'Successful status check; retrying in 10s...'
				sleep 10; echo
				vssh
				if ! ssh_status_check; then
					offer "SSH status still unsuccessful ($ssh_status); attempt reboot / power on?"
					necho 'Attempting reboot / power on...'
					vagrant reload 2>&1 | indent
					necho 'Connecting to test VM...'
					vssh
				fi
			fi
		fi
		exit 0
	fi
fi

if ((destroy)); then
	necho "Removing remaining test VM config/data & Vagrant's box/tmp cache..."
	rm -vfr ~/.vagrant.d/testvmenv/* ~/.vagrant.d/boxes/* ~/.vagrant.d/tmp/* 2>&1 | indent
	rm_status=${PIPESTATUS[0]}
	if ((rm_status)); then
		exit $rm_status
	else
		echo 'Done.' | indent
		exit 0
	fi
fi

# If query in $1, set $VM_IMAGE to first match in Vagrant Cloud box search results
if (($# == 1)); then
	image_query=$1
	VM_IMAGE=$(
		curl https://app.vagrantup.com/boxes/search \
		  -sLG -d sort=downloads \
		  --data-urlencode "q=$image_query" |
		 grep -Em1 '^\s+<img .*alt=".*'"$image_query"'.*" */>$' |
		 grep -Eo ' alt="[^"]+' |
		 cut -d'"' -f2
	) ||:
	if [[ -z "$VM_IMAGE" ]]; then
		necho "Failed to find box image matching \`$image_query'." >&2
		exit 1
	fi
	offer "Found matching box image \`$VM_IMAGE'; provision?"
fi

necho "Provisioning new test VM \`$VM_NAME' with box image \`$VM_IMAGE'..."

env_dir="$ENV_DIR_PARENT/$VM_NAME"

mkdir -vp "$env_dir" 2>&1 | indent

cd "$env_dir"

vagrantfile_extraconf='  config.vm.define "testvm" do |testvm|\n'
vagrantfile_extraconf+="    testvm.vm.hostname = \"$VM_NAME\"\n"
vagrantfile_extraconf+='  end\n'
vagrantfile_extraconf+='  config.vm.synced_folder ".", "/vagrant", disabled: true'

vagrantfile=$(
	vagrant init --minimal --no-tty "$VM_IMAGE" --output - |
	 sed 's%^end$%'"$vagrantfile_extraconf"'\nend%'
)

echo 'Writing Vagrantfile:' | indent
echo "$vagrantfile" | indent 2
echo "$vagrantfile" > Vagrantfile

necho "Running \`vagrant up'..." | indent
vagrant up --machine-readable 2>&1 | while read -r vu_line; do
	vu_target=$(cut -d, -f2 <<< $vu_line)
	vu_type=$(cut -d, -f3 <<< $vu_line)
	if [[ $vu_type == ui ]]; then
		vu_msg_raw=$(cut -d, -f5- <<< $vu_line)
		vu_msg=$(sed -e 's/%!(VAGRANT_COMMA)/,/g' -e 's/\\[rn]/\n/g' <<< $vu_msg_raw)
		if [[ -z $vu_target && $vu_msg =~ ^Progress:\  ]]; then
			vu_progress_perc=$(cut -d' ' -f2 <<< $vu_msg | tr -d %)
			vu_progress_msg=$(
				grep -Po '(?<= \().+(?=\)$)' <<< $vu_msg |
				 sed -re 's/^Rate: //' -e 's/Estimated time remaining:/ETA:/'
			)
			progress_bar $vu_progress_perc "$vu_progress_msg" 12
		else
			if [[ -n ${vu_progress_perc:-} ]]; then
				vu_progress_msg='Done!'$( printf '%*s' $(( ${#vu_progress_msg} - 5 )) )
				progress_bar 100 "$vu_progress_msg" 12
				unset vu_progress_perc vu_progress_msg
			fi
			echo "$vu_msg" | indent 2
		fi
	fi
done

necho 'Connecting to test VM...'
vssh

exit 0
