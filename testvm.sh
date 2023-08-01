#!/bin/bash
set -euo pipefail

VM_NAME_PREFIX="testvm-"
VM_NAME="$VM_NAME_PREFIX$(date +%Y%m%d%H%M%S)"
VM_IMAGE='debian/bookworm64'
ENV_DIR_PARENT="$HOME/.vagrant.d/testvmenv"


indent() {
	local l=${1:-1} i
	for ((i=0;i!=l;i++)); do
		local spacing+='    '
	done
	sed -e '/^\s*$/d' -e "s/^/$spacing/"
}

if [[ "${1-}" =~ ^(--)?((clean(up)?)|(rem(ove)?)|(del(ete?)?)|(destroy))$ ]]; then destroy=1
else
	destroy=0
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
			echo "Failed to find box image matching \`$image_query'." >&2
			exit 1
		fi
		read -p "Found matching box image \`$VM_IMAGE'; provision? [Y/n] "
		case $REPLY in
			''|Y|y)
				echo 'Proceeding...'
				;;
			*)
				echo 'Aborting.'
				exit 0
				;;
		esac
	elif (($# > 1)); then
		echo 'Wrong usage (expected one or no arguments).' >&2
		exit 2
	fi
fi


# Detect pre-existing testvm's
IFS=$'\n'; if env_dirs=($(ls -1d "$ENV_DIR_PARENT"/"$VM_NAME_PREFIX"* 2>/dev/null)); then
	if ((destroy)); then
		for env_dir in ${env_dirs[@]}; do
			VM_NAME=$(basename "$env_dir")
			echo "Found test VM \`$VM_NAME'; destroying..."
			cd "$env_dir"
			vagrant destroy --no-tty --force 2>&1 | indent || true
			echo 'Cleaning up...'
			rm -vr "$env_dir" 2>&1 | indent
		done
	else
		last_env_dir="${env_dirs[-1]}"
		VM_NAME=$(basename "$last_env_dir")
		echo "Found existing test VM \`$VM_NAME'; connecting..."
		cd "$last_env_dir"
		declare -i ssh_status=0
		vagrant ssh || ssh_status=$?
		if [[ $ssh_status == 1 ]]; then
			echo 'Unsuccesful (1) SSH status; checking test VM status...'
			declare -i vagrant_status=0
			vagrant status --no-tty 2>&1 | indent 1 || vagrant_status=${PIPESTATUS[0]}
			if [[ -n $vagrant_status ]]; then
				read -t 0.1 || true; read -p "Failed status check on test VM \`$VM_NAME'; remove? [Y/n] "
				case $REPLY in
					''|Y|y)
						echo "Removing test VM \`$VM_NAME'..."
						vagrant destroy --no-tty --force 2>&1 | indent || true
						echo 'Cleaning up...'
						rm -vr "$last_env_dir" 2>&1 | indent
						exit 0
						;;
					*) echo Aborting.; exit 0;;
				esac
			else
				echo 'Successful status check; attempting power on...'
				vagrant up 2>&1 | indent
				echo -e 'Connecting to test VM...\n'
				vagrant ssh
			fi
		fi
		exit 0
	fi
fi

if ((destroy)); then
	echo "Removing remaining test VM config/data & Vagrant's box/tmp cache..."
	rm -vfr ~/.vagrant.d/testvmenv/* ~/.vagrant.d/boxes/* ~/.vagrant.d/tmp/* 2>&1 | indent
	rm_status=${PIPESTATUS[0]}
	if ((rm_status)); then
		exit $rm_status
	else
		echo 'Done.' | indent
		exit 0
	fi
fi

echo "Provisioning new test VM \`$VM_NAME' with box image \`$VM_IMAGE'..."

env_dir="$ENV_DIR_PARENT/$VM_NAME"

mkdir -vp "$env_dir" 2>&1 | indent

cd "$env_dir"

vagrantfile=$(
	vagrant init --minimal --no-tty "$VM_IMAGE" --output - |
	 sed 's/^end$/  config.vm.define "testvm" do |testvm|\n    testvm.vm.hostname = "'"$VM_NAME"'"\n  end\nend/'
)

echo '    Writing Vagrantfile:'
echo "$vagrantfile" | indent 2

echo "$vagrantfile" > Vagrantfile

#echo '    Validating Vagrantfile...'
#vagrant status --no-tty 2>&1 | sed -e 's/^/        /' -e '/^\s*$/d'

echo -e "\n    Running \`vagrant up'..."
vagrant up --no-tty 2>&1 | indent 2

echo -e '\nConnecting to test VM...\n'
vagrant ssh

