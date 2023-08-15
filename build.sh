#!/bin/bash

check_requirements() {
  local cmds=(curl mock git sed fedpkg)
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
  --nocheck
      Do not run %check stage during packaging.

  --branch (-b) <fedora_branch>
      Checkout specified branch during packaging.

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
  "
}

[ $# -eq 0 ] && show_help && exit 0

while (("$#")); do
  case "$1" in
  --nocheck)
    nocheck=1
    shift
    ;;
  --branch | -b)
    branch="$2"
    shift 2
    ;;
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
  --noclean)
    noclean=1
    shift
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

  resultdir="$workdir"/result/temp/$mock_id
}

build_single_package() {
  package="$1"
  now=$(date)
  ret_code=0

  echo "[+] Building package: ${package} at ${now}"
  cd "$workdir"/packages
  rm -rf "$workdir"/packages/"${package}"
  fedpkg co -a "${package}" > "$workdir"/log/build/"${package}".log 2>&1
  cd "${package}"
  git checkout "$branch"
  fedpkg sources >> "$workdir"/log/build/"${package}".log 2>&1

  # Change release number
  sed -i -e 's@%{?dist}@.rvmock0%{?dist}@g' "${package}".spec ||
    sed -i -e 's@%autorelease@%autorelease -e rvmock0@g' "${package}".spec

  rm *.src.rpm || true
  fedpkg srpm

  mock_command="mock -r $mock_config --rebuild *.src.rpm --resultdir=$resultdir --rpmbuild_timeout $timeout"
  if [ -n "$nocheck" ]; then
    mock_command="$mock_command --nocheck"
  fi

  if [ -n "$noclean" ]; then
    mock_command="$mock_command --no-clean --no-cleanup-after"
  fi

  echo "[+] Running command: $mock_command"
  echo "[+] Check log at $workdir/log/build/${package}.log"
  $mock_command >> "$workdir"/log/build/"${package}".log 2>&1 || ret_code=$?

  if [ $ret_code -eq 0 ]; then
    echo "[+] Build ${package} success."
    mkdir -p "$workdir"/result/success/"${package}"
    cp -rv "$resultdir"/* "$workdir"/result/success/"${package}"
    cp -v "$resultdir"/*.rpm "$workdir"/rpm
    createrepo --update -v $workdir/rpm
    if [ -n "$script" ]; then
      echo "[+] Running script: $script"
      cd "$workdir"/result/success
      $script "${script_param//@@PACKAGE@@/$package}"
    fi
  else
    echo "[-] Build ${package} failed."
    mkdir -p "$workdir"/result/failed/"${package}"
    cp -rv "$resultdir"/* "$workdir"/result/failed/"${package}"
  fi

}

prepare_env || exit 1

echo "========================================"
echo "Packages: $(echo $packages | wc -w)"
echo "Threads: $thread"
echo "Branch: $branch"
echo "Workdir: $workdir"
echo "Mock template: $mock_template"
echo "Script: $script"
echo "Script param: $script_param"
echo "========================================"

echo "[+] Start building packages after 5 seconds."
sleep 5

for package in $packages; do
  read -u5 
  {
    init_mock_settings $REPLY
    (
      set -e
      build_single_package "$package"
    )

    clean_mock_settings

    echo $REPLY >&5
  } & 2>&1
done

wait
echo "[+] All Done."
rm -f "$mock_config"
