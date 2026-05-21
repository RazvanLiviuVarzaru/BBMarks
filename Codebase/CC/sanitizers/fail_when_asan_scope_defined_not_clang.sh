#!/bin/bash

set -euo pipefail

trap cleanup_resource EXIT

MAKE_PARALLEL="${MAKE_PARALLEL:-4}"
BUILD_SLOT="${BUILD_SLOT:-0}"

# User config
IMAGE=ubuntu24.04
BUILD_IMAGE="quay.io/mariadb-foundation/bb-worker:$IMAGE"
export GIT_REPO=https://github.com/RazvanLiviuVarzaru/mariadb-connector-c.git
export GIT_BRANCH=msan-ubsan-asan-test
export GIT_COMMIT=c81d3947654717d4a62efab15548452f82ce8a48

# Save tar / deb artifacts to host
SAVE_TO_HOST_ARTIFACTS_DIR="/home/razvan/tmp/cpp-artifacts/$GIT_BRANCH/$GIT_COMMIT/$IMAGE"
SAVE_ARTIFACTS=1 # 1 to save, 0 to skip saving

# Sidecar config
SIDECAR=mariadb:lts
SIDECAR_NAME="sidecar-mariadb-server-$BUILD_SLOT"

# Test config
MYSQL_TEST_USER=root
MYSQL_TEST_PASSWD=
MYSQL_TEST_PORT=3306
MYSQL_TEST_HOST=$SIDECAR_NAME
MYSQL_TEST_DB=test
MYSQL_TEST_VERBOSE=true
MARIADB_CC_TEST=1
MYSQL_TEST_TLS=0
MYSQL_TEST_SSL_PORT=

# System config
export NETWORK_NAME="mariadb-connector-cpp-$BUILD_SLOT"
export VOLUME_NAME="mariadb-connector-cpp-$BUILD_SLOT"
export CONTAINER_NAME="mariadb-connector-cpp-$BUILD_SLOT"
export VOLUME_MOUNT_POINT=/home/buildbot
export BASE_DIR="$VOLUME_MOUNT_POINT/cpp_build"
export SOURCE_DIR="$BASE_DIR/source"
export BUILD_DIR="$BASE_DIR/build"
export BINTAR_DIR="$BUILD_DIR/bintar"

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
bash ../create_source.sh


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
    tar -xzf $VOLUME_MOUNT_POINT/cc-src-*.tgz -C $SOURCE_DIR --strip-components=1
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
    cmake -DWITH_ASAN=ON -DWITH_ASAN_SCOPE=ON -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache -DCMAKE_BUILD_TYPE=RelWithDebInfo -DWITH_DOCS=ON -DPACKAGE_PLATFORM_SUFFIX=$HOSTNAME $SOURCE_DIR
    cmake --build . --config RelWithDebInfo --target package --parallel $MAKE_PARALLEL
    ls -l *.tar.gz
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
        mkdir -p /out/bintar /out/deb
        cp -av $BINTAR_DIR/*.tar.gz /out/bintar/ 2>/dev/null || true
        echo 'Copied artifacts to /out:'
        ls -lah /out/bintar /out/deb || true
    "
fi
