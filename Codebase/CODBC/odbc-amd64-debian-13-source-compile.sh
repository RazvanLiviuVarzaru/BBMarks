#!/bin/bash

set -euo pipefail

trap cleanup_resource EXIT

MAKE_PARALLEL="${MAKE_PARALLEL:-4}"
BUILD_SLOT="${BUILD_SLOT:-0}"

# User config
IMAGE=debian13
BUILD_IMAGE="quay.io/mariadb-foundation/bb-worker:$IMAGE"
export GIT_REPO=https://github.com/MariaDB-Corporation/mariadb-connector-odbc.git
export GIT_BRANCH=odbc-3.1
export GIT_COMMIT=3d62dc272b682247191730ba88a4a39d756fe39a

# System config
export NETWORK_NAME="mariadb-connector-odbc-$BUILD_SLOT"
export VOLUME_NAME="mariadb-connector-odbc-$BUILD_SLOT"
export CONTAINER_NAME="mariadb-connector-odbc-$BUILD_SLOT"
export VOLUME_MOUNT_POINT=/home/buildbot
export BASE_DIR="$VOLUME_MOUNT_POINT/odbc_build"
export SOURCE_DIR="$BASE_DIR/source"
export BUILD_DIR="$BASE_DIR/build"
export SOURCE_COMPILE_DIR="$BUILD_DIR/source_compile"

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
echo "Build from source"
echo "--------------------------------------------------------------"
docker run \
  -e MAKE_PARALLEL=$MAKE_PARALLEL \
  -e SOURCE_COMPILE_DIR=$SOURCE_COMPILE_DIR \
  -e SOURCE_DIR=$SOURCE_DIR \
  -v $VOLUME_NAME:$VOLUME_MOUNT_POINT \
  -w $VOLUME_MOUNT_POINT \
  --network $NETWORK_NAME \
  --rm \
  --name $CONTAINER_NAME \
  $BUILD_IMAGE \
  bash -ec '
    cd $SOURCE_DIR/libmariadb
    export CCINSTDIR=$SOURCE_COMPILE_DIR/cc
    cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo -DWITH_SSL=OPENSSL -DWITH_UNIT_TESTS=Off -DCMAKE_INSTALL_PREFIX=$CCINSTDIR .
    make -j $MAKE_PARALLEL
    make install

    export LIBRARY_PATH="${LIBRARY_PATH}:${CCINSTDIR}/lib:${CCINSTDIR}/lib/mariadb"
    export CPATH="${CPATH}:${CCINSTDIR}/include:${CCINSTDIR}/include/mariadb"

    mkdir -p $SOURCE_COMPILE_DIR
    cd $SOURCE_COMPILE_DIR
    rm -rf $SOURCE_DIR/libmariadb
    cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo -DWITH_OPENSSL=OFF -DCONC_WITH_UNIT_TESTS=Off -DWITH_UNIT_TESTS=Off -DMARIADB_LINK_DYNAMIC=1 $SOURCE_DIR
    make -j $MAKE_PARALLEL
  '