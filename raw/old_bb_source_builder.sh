
mkdir ../cc
git submodule init
git submodule update
cd libmariadb
cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo -DWITH_SSL=OPENSSL -DWITH_UNIT_TESTS=Off -DCMAKE_INSTALL_PREFIX=$CCINSTDIR .
make
make install
cd ..
ls $CCINSTDIR
echo $LIBRARY_PATH
echo $CPATH
export LIBRARY_PATH="${LIBRARY_PATH}:${CCINSTDIR}/lib:${CCINSTDIR}/lib/mariadb"
export CPATH="${CPATH}:${CCINSTDIR}/include:${CCINSTDIR}/include/mariadb"
# We need it deleted for source package generation
rm -rf ./libmariadb
cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo -DWITH_OPENSSL=OFF -DGIT_BUILD_SRCPKG=1 .
ls -l ./mariadb*odbc*src*tar.gz ./mariadb*odbc*src*.zip
SRC_PACK_NAME=`ls ./mariadb*src*tar.gz`
tar ztf $SRC_PACK_NAME
cd ..
tar zxf build/$SRC_PACK_NAME
ls
cd mariadb*src*
cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo -DWITH_OPENSSL=OFF -DCONC_WITH_UNIT_TESTS=Off -DWITH_UNIT_TESTS=Off -DMARIADB_LINK_DYNAMIC=1 .
make