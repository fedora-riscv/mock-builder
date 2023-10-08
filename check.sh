#!/bin/bash

check_requirements() {
  local cmds=(curl mock koji)
  local missing_commands=()
  for cmd in "${cmds[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      missing_commands+=("$cmd")
    fi
  done
  if [ ${#missing_commands[@]} -eq 0 ]; then
    return 0
  else
    echo "[x] Missing commands:"
    for missing_cmd in "${missing_commands[@]}"; do
      echo "  $missing_cmd"
    done
    return 1
  fi
}

show_help() {
  echo "Tools to build packages in mock.
Usage:
  $0 -m <mock_template> [-p|-P] <package|packages_file> [options]

Options:

  --help (-h)
      Show this help message.

  --mock-template (-m) <mock_template>
      Use specified mock template file.

  --workdir (-w) <workdir>
      Use specified workdir.

  --package (-p) <package>
      Build specified package.

  --packages-file (-P) <packages_file>
      Build packages listed in specified file.

  --script (-s) <script> <script_param>
      Run specified script after build success.
      For example: --script ./test.sh \"@@PACKAGE@@\"

  --thread (-t) <num_threads>
      Set the number of concurrent threads for processing.

  --timeout (-T) <timeout>
      Set the timeout for each build.

  --clean-after (-c) <times>
      Clean mock environment after success for <times> times.
      For example: --clean-after 50
    
  --profile (-p) <profile>
      Use specified koji profile.
      For example: --profile fedora

  --tag (-t) <tag>
      Use specified koji tag.
      For example: --tag f38-build
  "
}

[ $# -eq 0 ] && show_help && exit 0

while (("$#")); do
  case "$1" in
  --help | -h)
    show_help
    exit 0
    ;;
  --mock-template | -m)
    mock_template="$2"
    shift 2
    ;;
  --workdir | -w)
    workdir="$2"
    shift 2
    ;;
  --package | -p)
    package="$2"
    shift 2
    ;;
  --packages-file | -P)
    packages_file="$2"
    shift 2
    ;;
  --script | -s)
    script="$2"
    script_param="$3"
    shift 3
    ;;
  --thread | -t)
    thread="$2"
    shift 2
    ;;
  --timeout | -T)
    timeout="$2"
    shift 2
    ;;
  --clean-after | -c)
    clean_after="$2"
    shift 2
    ;;
  --profile | -p)
    profile="$2"
    shift 2
    ;;
  --tag | -t)
    tag="$2"
    shift 2
    ;;
  -* | --*=) # unsupported flags
    echo "Error: Unsupported flag $1" >&2
    exit 1
    ;;
  *) # preserve positional arguments
    PARAMS="$PARAMS $1"
    shift
    ;;
  esac
done

check_requirements || exit 1
[ -z "$branch" ] && echo "[-] Please specify branch." && exit 1
[ -z "$mock_template" ] && echo "[-] Please specify mock config file." && exit 1
[ -z "$workdir" ] && workdir="$HOME/mock-workdir"
[ -z "$package" ] && [ -z "$packages_file" ] && echo "[-] Please specify package or packages file." && exit 1
[ -n "$package" ] && [ -n "$packages_file" ] && echo "[-] Please specify package or packages file, not both." && exit 1
[ -n "$packages_file" ] && [ ! -f "$packages_file" ] && echo "[-] Packages file $packages_file not found." && exit 1
[ -z "$clean_after" ] && clean_after=75
[ -z "$profile" ] && profile=koji
[ -z "$tag" ] && tag=f38-build
[ -z "$thread" ] && thread=1
[ -z "$timeout" ] && timeout=86400

# Prepare environment
prepare_env() {
  # Create workdir
  mkdir -p "$workdir"/{rpm,result,packages,config,log}
  mkdir -p "$workdir"/result/{success,failed,backup,temp}
  mkdir -p "$workdir"/log/{build,mock}

  rm -rf "$workdir"/config/mock-*.cfg
  rm -rf "$workdir"/result/temp/*

  createrepo --update -v $workdir/rpm

  rm -f $workdir/npipe
  mkfifo $workdir/npipe
  exec 5<>$workdir/npipe

  for ((i = 1; i <= $thread; i++)); do
    echo $i
  done >&5

  if [ -n "$package" ]; then
    packages="$package"
  else
    packages=$(cat "$packages_file")
  fi
}

clean_mock_settings() {
  # Clean mock settings
  if [ -z "$noclean" ]; then
    mock -r $mock_config --clean
  fi
  mock -r $mock_config --umount
  rm -rf $mock_config
  rm -rf $resultdir
  echo "[?] sudo rm -rf /tmp/mock/*-$mock_id/"
}

init_mock_settings() {
  # Init mock settings
  mock_id=$1
  # Create mock config
  mock_config="$workdir"/config/mock-"$mock_id".cfg
  cp "$mock_template" "$mock_config"

  sed -i -e "s/@@ID@@/$mock_id/g" "$mock_config"
  sed -i -e "s#@@LOCAL_REPO@@#$workdir/rpm#g" "$mock_config"

  # check build dir
  used_inode=`df -i /tmp/mock | awk '{sub(/%/,"",$5); if(NR==2) print $5}'`
  used_part=`df -h /tmp/mock | awk '{sub(/%/,"",$5); if(NR==2) print $5}'`

  # check if inode or part greater than $clean-after
  if [ $used_inode -gt $clean_after ] || [ $used_part -gt $clean_after ]; then
    mock -r $mock_config --clean
  fi

  resultdir="$workdir"/result/temp/$mock_id
}

check_single_package() {
  package="$1"
  now=$(date)

  echo "[+] Checking package: ${package} at ${now}"
  build=$(koji -p $profile latest-build $tag $package | awk 'NR==3 {print $1}')
	if [ -z "$build" ]; then
		echo "the package $package didn't build?"
		echo "not found: $package" >> non_build.txt
		continue
	fi

	rpms=$(koji -p openkoji buildinfo $build | awk "$mode" | tr '\n' ' ')
	result=$(mock -r $mock_config --no-bootstrap-chroot --install $rpms)
	if [ $? -ne 0 ]; then
		echo "the package $package cannot be installed!"
		echo "$package" >> failed.txt
		continue
	fi
	echo "package $package no problem, next."
}

prepare_env || exit 1

echo "========================================"
echo "Packages: $(echo $packages | wc -w)"
echo "Threads: $thread"
echo "Koji Profile: $profile"
echo "Koji Tag: $tag"
echo "Workdir: $workdir"
echo "Mock template: $mock_template"
echo "Script: $script"
echo "Script param: $script_param"
echo "========================================"

# Check Koji Status
koji -p $profile hello || exit 1
koji -p $profile list-tags | grep $tag || exit 1

echo "[+] Start building packages after 5 seconds."
sleep 5

for package in $packages; do
  read -u5 
  {
    init_mock_settings $REPLY
    (
      set -e
      check_single_package "$package"
    )

    # clean_mock_settings

    echo $REPLY >&5
  } & 2>&1
done

wait
echo "[+] All Done."
rm -f "$mock_config"
