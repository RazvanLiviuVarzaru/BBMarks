#!/bin/bash

set -euo pipefail

trap cleanup_resource EXIT

MAKE_PARALLEL="${MAKE_PARALLEL:-4}"
BUILD_SLOT="${BUILD_SLOT:-0}"

# User config
IMAGE=ubuntu24.04
DEB_CLEAN_IMAGE=ubuntu:24.04
BUILD_IMAGE="quay.io/mariadb-foundation/bb-worker:$IMAGE"
export GIT_REPO=https://github.com/MariaDB-Corporation/mariadb-connector-odbc.git
export GIT_BRANCH=odbc-3.1
export GIT_COMMIT=3d62dc272b682247191730ba88a4a39d756fe39a

# Save tar / deb artifacts to host
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
    cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCONC_WITH_UNIT_TESTS=Off -DPACKAGE_PLATFORM_SUFFIX=$HOSTNAME $SOURCE_DIR
    cmake --build . --config RelWithDebInfo --target package --parallel $MAKE_PARALLEL
    ls -l *.tar.gz
  '


echo "--------------------------------------------------------------"
echo "Build deb"
echo "--------------------------------------------------------------"


# To link against system libmariadb we need to install libmariadb-dev
# and force the build to link against it by setting -DUSE_SYSTEM_INSTALLED_LIB=ON
# and also -DMARIADB_LINK_DYNAMIC=On to avoid linking against the static library if both static and dynamic are present.

# C/C needs to be a recent version, otherwise C/ODBC build will fail if distro default C/C is old enough.
# This is why libmariadb-dev is installed from mariadb.org repositories

docker run \
  -e MAKE_PARALLEL=$MAKE_PARALLEL \
  -e DEB_DIR=$DEB_DIR \
  -e SOURCE_DIR=$SOURCE_DIR \
  -v $VOLUME_NAME:$VOLUME_MOUNT_POINT \
  -w $VOLUME_MOUNT_POINT \
  --network $NETWORK_NAME \
  --rm \
  --name $CONTAINER_NAME \
  -u root \
  $BUILD_IMAGE \
  bash -ec '
      source /etc/os-release
      baseurl="https://deb.mariadb.org/11.8"
      sh -c "echo \"deb $baseurl/$ID $VERSION_CODENAME main\" >/etc/apt/sources.list.d/mariadb.list"
      tee /etc/apt/preferences.d/mariadb >/dev/null <<EOF
Package: *
Pin: origin deb.mariadb.org
Pin-Priority: 700
EOF
      wget https://mariadb.org/mariadb_release_signing_key.asc -O /etc/apt/trusted.gpg.d/mariadb_release_signing_key.asc

      apt-get update
      apt install -y libmariadb-dev
      su - buildbot -c "
        set -e
        mkdir -p $DEB_DIR
        cd $DEB_DIR
        cmake -DDEB=On -DUSE_SYSTEM_INSTALLED_LIB=ON -DCPACK_GENERATOR=DEB -DCMAKE_BUILD_TYPE=RelWithDebInfo -DMARIADB_LINK_DYNAMIC=On -DPACKAGE_PLATFORM_SUFFIX=$HOSTNAME $SOURCE_DIR
        cmake --build . --config RelWithDebInfo --target package --parallel $MAKE_PARALLEL --verbose
        ls -l *deb
        dpkg -I *deb || true
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
echo "Test deb"
echo "--------------------------------------------------------------"

# apt install -y libodbc2 is needed by odbc_basic test because
# driver itself doesn't have dependency of DM runtime,
# only on libodbcinst that is installer library from unixodbc.

docker run \
  -e DEB_DIR=$DEB_DIR \
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
  -u root \
  $DEB_CLEAN_IMAGE \
  bash -ec '
      apt-get update && apt-get install -y wget
      source /etc/os-release
      baseurl="https://deb.mariadb.org/11.8"
      sh -c "echo \"deb $baseurl/$ID $VERSION_CODENAME main\" >/etc/apt/sources.list.d/mariadb.list"
      tee /etc/apt/preferences.d/mariadb >/dev/null <<EOF
Package: *
Pin: origin deb.mariadb.org
Pin-Priority: 700
EOF
      wget https://mariadb.org/mariadb_release_signing_key.asc -O /etc/apt/trusted.gpg.d/mariadb_release_signing_key.asc

      apt-get update

    cd $DEB_DIR
    apt install -y ./*.deb
    apt install -y libodbc2
    cd $DEB_DIR/test
    export ODBCINI="$PWD/odbc.ini"
    export ODBCSYSINI=$PWD
    export TEST_SKIP_UNSTABLE_TEST=1
    sed -i "s/localhost/$SIDECAR_NAME/" odbc.ini
    ./odbc_basic
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
        cp -av $DEB_DIR/*.deb /out/deb/ 2>/dev/null || true
        echo 'Copied artifacts to /out:'
        ls -lah /out/bintar /out/deb || true
    "
fi
