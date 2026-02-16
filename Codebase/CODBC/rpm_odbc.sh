#!/bin/bash

set -euo pipefail

trap cleanup_resource EXIT

MAKE_PARALLEL="${MAKE_PARALLEL:-4}"
BUILD_SLOT="${BUILD_SLOT:-0}"

# User config
IMAGE=fedora42
BUILD_IMAGE="quay.io/mariadb-foundation/bb-worker:$IMAGE"
export GIT_REPO=https://github.com/MariaDB-Corporation/mariadb-connector-odbc.git
export GIT_BRANCH=master
export GIT_COMMIT=5c60284c988638acbb864468f23dc8b066db18e4
# Save tar / rpm artifacts to host
SAVE_TO_HOST_ARTIFACTS_DIR="/home/razvan/tmp/odbc-artifacts/$GIT_BRANCH/$GIT_COMMIT/$IMAGE"
SAVE_ARTIFACTS=0 # 1 to save, 0 to skip saving

# Sidecar config
SIDECAR=mariadb:lts
SIDECAR_NAME="sidecar-mariadb-server-$BUILD_SLOT"

# Test config
TEST_UID=root
TEST_PASSWORD=
TEST_PORT=3306
TEST_SERVER=$SIDECAR_NAME
TEST_SCHEMA=test
TEST_VERBOSE=true
TEST_DRIVER=maodbc_test
TEST_DSN=maodbc_test

# System config
export NETWORK_NAME="mariadb-connector-odbc-$BUILD_SLOT"
export VOLUME_NAME="mariadb-connector-odbc-$BUILD_SLOT"
export CONTAINER_NAME="mariadb-connector-odbc-$BUILD_SLOT"
export VOLUME_MOUNT_POINT=/home/buildbot
export BASE_DIR="$VOLUME_MOUNT_POINT/odbc_build"
export SOURCE_DIR="$BASE_DIR/source"
export BUILD_DIR="$BASE_DIR/build"
export BINTAR_DIR="$BUILD_DIR/bintar"
export RPM_DIR="$BUILD_DIR/rpm"

# SRPM CONFIG
SRPM_IMAGE="$BUILD_IMAGE-srpm" # Lighweight image without build tools
SRPM_DIR=$RPM_DIR
RPM_DIR=$RPM_DIR
SRPM_DEPS_SCRIPT="srpm_install_build_deps.sh"
SRPM_REBUILD_SCRIPT="srpm_rebuild.sh"
SRPM_COMPARE_SCRIPT="srpm_compare.sh"
SRPM_SCRIPT_DOWNLOAD_URLS=(
  "https://raw.githubusercontent.com/MariaDB/buildbot/refs/heads/dev/configuration/steps/commands/scripts/$SRPM_DEPS_SCRIPT"
  "https://raw.githubusercontent.com/MariaDB/buildbot/refs/heads/dev/configuration/steps/commands/scripts/$SRPM_REBUILD_SCRIPT"
  "https://raw.githubusercontent.com/MariaDB/buildbot/refs/heads/dev/configuration/steps/commands/scripts/$SRPM_COMPARE_SCRIPT"
)

cleanup_resource () {
  # Docker volume
  docker ps -a --filter "volume=$VOLUME_NAME" --format "{{.ID}}" | xargs -r docker rm -f
  docker volume rm $VOLUME_NAME || true 2> /dev/null
  # Docker network
  docker ps -a --filter "network=$NETWORK_NAME" --format "{{.ID}}" | xargs -r docker rm -f
  docker network rm $NETWORK_NAME || true 2> /dev/null
}

host_is_rhel() {
  # Host check: /etc/os-release is standard
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    # ID is typically "rhel" on RHEL, but we also accept "ID_LIKE=rhel"
    [[ "${ID:-}" == "rhel" ]] && return 0
    [[ "${ID_LIKE:-}" =~ (^|[[:space:]])rhel($|[[:space:]]) ]] && return 0
  fi
  return 1
}

RHEL_SECRET_MOUNTS=(
  -v /etc/rhsm:/etc/rhsm:ro
  -v /etc/pki/entitlement:/etc/pki/entitlement:ro
  -v /etc/yum.repos.d:/etc/yum.repos.d:ro
)

EXTRA_DOCKER_ARGS=()
require_rhel_host_if_rhel_image() {
  local IMAGE="${1:?missing IMAGE}"
  # Check if IMAGE contains "RHEL" (case-insensitive)
  shopt -s nocasematch
  if [[ "$IMAGE" == *rhel* ]]; then
    if ! host_is_rhel; then
      echo "ERROR: IMAGE='$IMAGE' looks like a RHEL image, but the host OS is not RHEL." >&2
      echo "You need an activated RHEL host for building C/ODBC on RHEL." >&2
      exit 1
    fi
    EXTRA_DOCKER_ARGS+=("${RHEL_SECRET_MOUNTS[@]}")
  fi
  shopt -u nocasematch
}

require_rhel_host_if_rhel_image $BUILD_IMAGE

# Precleanup
cleanup_resource > /dev/null 2>&1 || true
# Docker volume
echo "Creating docker volume $VOLUME_NAME"
docker volume create $VOLUME_NAME
# Docker network
echo "Creating docker network $NETWORK_NAME"
docker network create $NETWORK_NAME

# Sidecar
docker run \
  -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 \
  -e MARIADB_DATABASE=test \
  --network $NETWORK_NAME \
  --rm \
  --name $SIDECAR_NAME \
  -d \
  $SIDECAR

# Prepare source and CI tgz
bash create_source.sh

echo "--------------------------------------------------------------"
echo "Unpack CI tgz to prepare for build"
echo "--------------------------------------------------------------"
docker run \
  -e SOURCE_DIR=$SOURCE_DIR \
  -e VOLUME_MOUNT_POINT=$VOLUME_MOUNT_POINT \
  -v $VOLUME_NAME:$VOLUME_MOUNT_POINT \
  -w $VOLUME_MOUNT_POINT \
  --network $NETWORK_NAME \
  --rm \
  --name $CONTAINER_NAME \
  $BUILD_IMAGE \
  bash -ec '
    mkdir -p $SOURCE_DIR
    tar -xzf $VOLUME_MOUNT_POINT/odbc-src-with-cc-tests-*.tgz -C $SOURCE_DIR --strip-components=1
  '

echo "--------------------------------------------------------------"
echo "Build bintar"
echo "--------------------------------------------------------------"
docker run \
  -e MAKE_PARALLEL=$MAKE_PARALLEL \
  -e BINTAR_DIR=$BINTAR_DIR \
  -e SOURCE_DIR=$SOURCE_DIR \
  -v $VOLUME_NAME:$VOLUME_MOUNT_POINT \
  -w $VOLUME_MOUNT_POINT \
  --network $NETWORK_NAME \
  --rm \
  --name $CONTAINER_NAME \
  $BUILD_IMAGE \
  bash -ec '
    mkdir -p $BINTAR_DIR
    cd $BINTAR_DIR
    cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCONC_WITH_UNIT_TESTS=Off -DPACKAGE_PLATFORM_SUFFIX=$HOSTNAME $SOURCE_DIR
    cmake --build . --config RelWithDebInfo --target package --parallel $MAKE_PARALLEL
    ls -l *.tar.gz
  '


echo "--------------------------------------------------------------"
echo "Build rpm"
echo "--------------------------------------------------------------"

# To link against system libmariadb we need to install mariadb-devel
# and force the build to link against it by setting -DUSE_SYSTEM_INSTALLED_LIB=ON
# and also -DMARIADB_LINK_DYNAMIC=On to avoid linking against the static library if both static and dynamic are present.

docker run \
  -e MAKE_PARALLEL=$MAKE_PARALLEL \
  -e RPM_DIR=$RPM_DIR \
  -e SOURCE_DIR=$SOURCE_DIR \
  -v $VOLUME_NAME:$VOLUME_MOUNT_POINT \
    "${EXTRA_DOCKER_ARGS[@]}" \
  -w $VOLUME_MOUNT_POINT \
  --network $NETWORK_NAME \
  --rm \
  --name $CONTAINER_NAME \
  -u root \
  $BUILD_IMAGE \
  bash -ec '
      dnf install -y mariadb-devel || yum install -y MariaDB-devel || zypper install -y MariaDB-shared
      su - buildbot -c "
        set -e
        mkdir -p $RPM_DIR
        cd $RPM_DIR
        cmake -DRPM=On -DUSE_SYSTEM_INSTALLED_LIB=ON -DCPACK_GENERATOR=RPM -DCMAKE_BUILD_TYPE=RelWithDebInfo -DMARIADB_LINK_DYNAMIC=On -DPACKAGE_PLATFORM_SUFFIX=$HOSTNAME $SOURCE_DIR
        cmake --build . --config RelWithDebInfo --target package --parallel $MAKE_PARALLEL
        make package_source
        ls -l *rpm
        rpm -qpR *src.rpm
      "
  '

echo "--------------------------------------------------------------"
echo "Test bintar"
echo "--------------------------------------------------------------"
docker run \
  -e BINTAR_DIR=$BINTAR_DIR \
  -e TEST_UID=$TEST_UID \
  -e TEST_PASSWORD=$TEST_PASSWORD \
  -e TEST_PORT=$TEST_PORT \
  -e TEST_SERVER=$TEST_SERVER \
  -e TEST_SCHEMA=$TEST_SCHEMA \
  -e TEST_VERBOSE=$TEST_VERBOSE \
  -e TEST_DRIVER=$TEST_DRIVER \
  -e TEST_DSN=$TEST_DSN \
  -e SIDECAR_NAME=$SIDECAR_NAME \
  -v $VOLUME_NAME:$VOLUME_MOUNT_POINT \
  -w $VOLUME_MOUNT_POINT \
  --network $NETWORK_NAME \
  --rm \
  --name $CONTAINER_NAME \
  $BUILD_IMAGE \
  bash -ec '
    cd $BINTAR_DIR/test
    export ODBCINI="$PWD/odbc.ini"
    export ODBCSYSINI=$PWD
    export TEST_SKIP_UNSTABLE_TEST=1
    sed -i "s/localhost/$SIDECAR_NAME/" odbc.ini
    ctest --output-on-failure
  '

echo "--------------------------------------------------------------"
echo "Test rpm"
echo "--------------------------------------------------------------"

docker run \
  -e RPM_DIR=$RPM_DIR \
  -e TEST_UID=$TEST_UID \
  -e TEST_PASSWORD=$TEST_PASSWORD \
  -e TEST_PORT=$TEST_PORT \
  -e TEST_SERVER=$TEST_SERVER \
  -e TEST_SCHEMA=$TEST_SCHEMA \
  -e TEST_VERBOSE=$TEST_VERBOSE \
  -e TEST_DRIVER=$TEST_DRIVER \
  -e TEST_DSN=$TEST_DSN \
  -e SIDECAR_NAME=$SIDECAR_NAME \
  -v $VOLUME_NAME:$VOLUME_MOUNT_POINT \
    "${EXTRA_DOCKER_ARGS[@]}" \
  -w $VOLUME_MOUNT_POINT \
  --network $NETWORK_NAME \
  --rm \
  --name $CONTAINER_NAME \
  -u root \
  $SRPM_IMAGE \
  bash -ec '
    cd $RPM_DIR
    dnf install -y *rpm
    cd $RPM_DIR/test
    export ODBCINI="$PWD/odbc.ini"
    export ODBCSYSINI=$PWD
    export TEST_SKIP_UNSTABLE_TEST=1
    sed -i "s/localhost/$SIDECAR_NAME/" odbc.ini
    ./odbc_basic
  '

echo "--------------------------------------------------------------"
echo "Test SRPM"
echo "--------------------------------------------------------------"

docker run \
  -e RPM_DIR=$RPM_DIR \
  -e SRPM_DEPS_SCRIPT=$SRPM_DEPS_SCRIPT \
  -e SRPM_REBUILD_SCRIPT=$SRPM_REBUILD_SCRIPT \
  -e SRPM_COMPARE_SCRIPT=$SRPM_COMPARE_SCRIPT \
  -e MAKE_PARALLEL=$MAKE_PARALLEL \
  -e SRPM_SCRIPT_DOWNLOAD_URLS="${SRPM_SCRIPT_DOWNLOAD_URLS[*]}"\
  -e TEST_UID=$TEST_UID \
  -e TEST_PASSWORD=$TEST_PASSWORD \
  -e TEST_PORT=$TEST_PORT \
  -e TEST_SERVER=$TEST_SERVER \
  -e TEST_SCHEMA=$TEST_SCHEMA \
  -e TEST_VERBOSE=$TEST_VERBOSE \
  -e TEST_DRIVER=$TEST_DRIVER \
  -e TEST_DSN=$TEST_DSN \
  -e SIDECAR_NAME=$SIDECAR_NAME \
  -v $VOLUME_NAME:$VOLUME_MOUNT_POINT \
    "${EXTRA_DOCKER_ARGS[@]}" \
  -w $VOLUME_MOUNT_POINT \
  --network $NETWORK_NAME \
  --rm \
  --name $CONTAINER_NAME \
  -u root \
  $BUILD_IMAGE \
  bash -ec '
    for script_url in $SRPM_SCRIPT_DOWNLOAD_URLS; do
      script_name=$(basename "$script_url")
      echo "Downloading $script_name from $script_url"

      if ! wget -q "$script_url" -O "$script_name" < /dev/null; then
        echo "Failed to download $script_name from $script_url"
        exit 1
      fi
      chmod +x "$script_name"
    done
    ./$SRPM_DEPS_SCRIPT $RPM_DIR
    ./$SRPM_REBUILD_SCRIPT $RPM_DIR $MAKE_PARALLEL
     mkdir -p /tmp/ci
     cp -av $RPM_DIR/*rpm /tmp/ci/
     rm -f /tmp/ci/*src.rpm
    ./$SRPM_COMPARE_SCRIPT /tmp/ci /root/rpmbuild/RPMS

  '

if [ "$SAVE_ARTIFACTS" -eq 1 ]; then
    echo "--------------------------------------------------------------"
    echo "Copy artifacts to docker host"
    echo "--------------------------------------------------------------"

    mkdir -p "$SAVE_TO_HOST_ARTIFACTS_DIR"
    docker run --rm \
    -v "$VOLUME_NAME:$VOLUME_MOUNT_POINT:ro" \
    -v "$SAVE_TO_HOST_ARTIFACTS_DIR:/out" \
    $BUILD_IMAGE \
    bash -ec "
        set -euo pipefail
        mkdir -p /out/bintar /out/rpm
        cp -av $BINTAR_DIR/*.tar.gz /out/bintar/ 2>/dev/null || true
        cp -av $RPM_DIR/*rpm /out/rpm/ 2>/dev/null || true
        echo 'Copied artifacts to /out:'
        ls -lah /out/bintar /out/rpm || true
    "
fi

