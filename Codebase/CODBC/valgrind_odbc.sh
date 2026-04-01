#!/bin/bash

set -euo pipefail

trap cleanup_resource EXIT

MAKE_PARALLEL="${MAKE_PARALLEL:-4}"
BUILD_SLOT="${BUILD_SLOT:-0}"

# User config
IMAGE=ubuntu26.04
BUILD_IMAGE="quay.io/mariadb-foundation/bb-worker:$IMAGE"
export GIT_REPO=https://github.com/MariaDB-Corporation/mariadb-connector-odbc.git
export GIT_BRANCH=odbc-3.1
export GIT_COMMIT=98013374570c6eb4ec7c66cb394d15cd90e2a258

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
export DEB_DIR="$BUILD_DIR/deb"

cleanup_resource () {
  # Docker volume
  docker ps -a --filter "volume=$VOLUME_NAME" --format "{{.ID}}" | xargs -r docker rm -f
  docker volume rm $VOLUME_NAME || true 2> /dev/null
  # Docker network
  docker ps -a --filter "network=$NETWORK_NAME" --format "{{.ID}}" | xargs -r docker rm -f
  docker network rm $NETWORK_NAME || true 2> /dev/null
}

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
    cmake -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCONC_WITH_UNIT_TESTS=Off -DPACKAGE_PLATFORM_SUFFIX=$HOSTNAME $SOURCE_DIR
    cmake --build . --config RelWithDebInfo --target package --parallel $MAKE_PARALLEL
    ls -l *.tar.gz
  '

echo "--------------------------------------------------------------"
echo "Test valgrind"
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
    cd "$BINTAR_DIR/test"
    export ODBCINI="$PWD/odbc.ini"
    export ODBCSYSINI="$PWD"
    export TEST_SKIP_UNSTABLE_TEST=1
    export MEMCHECK_SKIP_TEST=1

    sed -i "s/localhost/$SIDECAR_NAME/" odbc.ini

    sudo apt-get update && sudo apt-get install -y valgrind

    ulimit -n 4096

    failed=0
    success_tests=()
    failed_tests=()

    for odbctest in ./odbc_*; do
      [ -x "$odbctest" ] || continue

      name="$(basename "$odbctest")"
      log="valgrind-${name}.log"

      echo "VALGRIND_BEGIN::$odbctest::log=$log"

      valgrind \
        --leak-check=full \
        --show-leak-kinds=all \
        --error-limit=no \
        "$odbctest" \
        2> >(tee "$log" >&2) || true

      definite=$(awk "/definitely lost:/ {print \$4}" "$log" | tail -1 | tr -d ",")
      indirect=$(awk "/indirectly lost:/ {print \$4}" "$log" | tail -1 | tr -d ",")
      possible=$(awk "/possibly lost:/ {print \$4}" "$log" | tail -1 | tr -d ",")

      definite=${definite:-0}
      indirect=${indirect:-0}
      possible=${possible:-0}

      if [ "$definite" -ne 0 ] || [ "$indirect" -ne 0 ] || [ "$possible" -ne 0 ]; then
        failed=1
        failed_tests+=("$odbctest :: definite=$definite indirect=$indirect possible=$possible")
        echo "VALGRIND_FAILURE::$odbctest::definite=$definite::indirect=$indirect::possible=$possible"
      else
        success_tests+=("$odbctest :: no definite/indirect/possible leaks")
        echo "VALGRIND_SUCCESS::$odbctest"
      fi
    done

    echo
    echo "================ VALGRIND FINAL SUMMARY ================"
    echo "Successful programs:"
    if [ "${#success_tests[@]}" -gt 0 ]; then
      printf "%s\n" "${success_tests[@]}"
    else
      echo "(none)"
    fi

    echo
    echo "Failed programs:"
    if [ "${#failed_tests[@]}" -gt 0 ]; then
      printf "%s\n" "${failed_tests[@]}"
    else
      echo "(none)"
    fi
    echo "========================================================"

    exit "$failed"
  '
