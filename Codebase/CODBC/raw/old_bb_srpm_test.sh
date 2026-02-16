#runvm --base-image=/kvm/vms/vm-rhel8-amd64-install.qcow2

cd buildbot
ls
rpm -qlp mariadb-connector-odbc-3.2.9-1.el8.src.rpm
rpm -qpR mariadb-connector-odbc-3.2.9-1.el8.src.rpm
if [ -f /usr/bin/subscription-manager ] ; then sudo subscription-manager refresh ;fi
sudo dnf --setopt=install_weak_deps=False install -y rpm-build perl-generators

# Installing server to run tests
if [ -e /usr/bin/apt ] ; then
  if ! sudo apt update ; then
    echo "Warning - apt update failed"
  fi
# This package is required to run following script
  sudo apt install -y apt-transport-https
  sudo apt install -y curl
fi

source /etc/os-release

SPACKAGE_NAME=MariaDB-server
if [ "$ID" = "rocky" ]; then
  SPACKAGE_NAME=mariadb-server
fi

case $HOSTNAME in rhel*)
  ID=rhel
  VERSION_ID=$(cat /etc/redhat-release | awk '{print $6}' | sed -e "s/\..*//g")

  sudo subscription-manager refresh
  ;; esac
if ! curl -LsS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash -s -- --skip-maxscale; then
  if [ -e /etc/fedora-release ]; then
    SPACKAGE_NAME=mariadb-server
    case $ID$VERSION_ID in fedora35)
        sudo sh -c "echo \"#galera test repo
[galera]
name = galera
baseurl = https://yum.mariadb.org/galera/repo4/rpm/$ID$VERSION_ID-amd64
gpgkey = https://yum.mariadb.org/RPM-GPG-KEY-MariaDB
gpgcheck = 1\" > /etc/yum.repos.d/galera.repo"
        VERSION_ID=34 ;; esac
    sudo sh -c "echo \"#MariaDB.Org repo
[mariadb]
name = MariaDB
#baseurl = http://yum.mariadb.org/10.5/$ID$VERSION_ID-amd64
baseurl = http://yum.mariadb.org/10.5/$ID$VERSION_ID-amd64
gpgkey = https://yum.mariadb.org/RPM-GPG-KEY-MariaDB
gpgcheck = 1\" > /etc/yum.repos.d/mariadb.repo"
    sudo rpm --import https://yum.mariadb.org/RPM-GPG-KEY-MariaDB
    sudo dnf remove -y mariadb-connector-c-config
  fi
  if grep -i xenial /etc/os-release ; then
    USEAPT=1
    sudo apt-get install -y software-properties-common gnupg-curl
    sudo apt-key adv --fetch-keys 'https://mariadb.org/mariadb_release_signing_key.asc'
    sudo add-apt-repository -y 'deb [arch=amd64,arm64,i386,ppc64el] https://mirrors.ukfast.co.uk/sites/mariadb/repo/11.0/ubuntu xenial main'
  fi
  if grep -i groovy /etc/os-release ; then
    USEAPT=1
    sudo apt-get install -y software-properties-common
    sudo apt-key adv --fetch-keys 'https://mariadb.org/mariadb_release_signing_key.asc'
    sudo add-apt-repository -y 'deb [arch=amd64,arm64,i386,ppc64el] https://mirrors.ukfast.co.uk/sites/mariadb/repo/11.0/ubuntu groovy main'
  fi
  if grep -i impish /etc/os-release ; then
    USEAPT=1
    sudo apt-get install -y software-properties-common
    sudo apt-key adv --fetch-keys 'https://mariadb.org/mariadb_release_signing_key.asc'
    sudo add-apt-repository -y 'deb [arch=amd64,arm64,i386,ppc64el] https://mirrors.ukfast.co.uk/sites/mariadb/repo/11.0/ubuntu impish main'
  fi
  if grep -i hirsute /etc/os-release ; then
    USEAPT=1
    sudo apt-get install -y software-properties-common
    sudo apt-key adv --fetch-keys 'https://mariadb.org/mariadb_release_signing_key.asc'
    sudo add-apt-repository -y 'deb [arch=amd64,arm64,i386,ppc64el] https://mirrors.ukfast.co.uk/sites/mariadb/repo/11.0/ubuntu hirsute main'
  fi
fi

if LSB_VID=$(lsb_release -sr 2> /dev/null); then
  VERSION_ID=$(sed -e "s/\.//g" <<< "$LSB_VID")
  ID=$(lsb_release -si  | tr '[:upper:]' '[:lower:]')
  ID=${ID:0:3}
fi

sudo dnf --setopt=install_weak_deps=False builddep -y mariadb-connector-odbc-3.2.9-1.el8.src.rpm || true
rpmbuild --rebuild mariadb-connector-odbc-3.2.9-1.el8.src.rpm
# removing source rpm - it's not needed any more
ls
rm mariadb-connector-odbc-3.2.9-1.el8.src.rpm
ls ./*.rpm ./rpmbuild/RPMS || true
# compare requirements to ensure rebuilt rpms got all libraries right
echo rpms/*.rpm           |xargs -n1 rpm -q --requires -p|sed -e 's/>=.*/>=/; s/([A-Z0-9._]*)([0-9]*bit)$//; /MariaDB-compat/d'|sort -u>requires-vendor.txt
echo ~/rpmbuild/RPMS/*.rpm|xargs -n1 rpm -q --requires -p|sed -e 's/>=.*/>=/; s/([A-Z0-9._]*)([0-9]*bit)$//                   '|sort -u>requires-rebuilt.txt
cat requires-vendor.txt
echo "------------------------"
cat requires-rebuilt.txt
diff -u requires-*.txt

# check if rpm filenames match (won't be true on centos7)
# and if they do, compare more, e.g. file lists and scriptlets

echo "All done"
if ! odbcinst -i -d ; then
  cat /etc/odbcinst.ini || true
fi

# At least uid has to be exported before cmake run
export TEST_UID=root
export TEST_PASSWORD=
export TEST_PORT=3306
export TEST_SERVER=localhost
export TEST_SCHEMA=test
export TEST_VERBOSE=true


export TEST_DRIVER=maodbc_test
export TEST_DSN=maodbc_test
ls /usr/lib*/*maria* /usr/lib*/*maodbc* /usr/include/maria* || true

DISABLEFB="/etc/my.cnf.d/disable-feedback.cnf"
if [ -e "/etc/yum.repos.d/mariadb.repo" ]; then
  if sudo touch "$DISABLEFB"; then
    echo "[mariadb]" | sudo tee "$DISABLEFB"
    echo "feedback=OFF" | sudo tee -a "$DISABLEFB"
  fi
  if ! sudo dnf install -y $SPACKAGE_NAME; then
    sudo yum install -y $SPACKAGE_NAME
  fi
  sudo systemctl start mariadb
fi

if [ ! -z "$USEAPT" ] || [ -e "/etc/apt/sources.list.d/mariadb.list" ]; then
  if ! sudo apt update ; then
    echo "Warning - apt update failed"
  fi
#  sudo apt install -y apt-transport-https
  sudo DEBIAN_FRONTEND=noninteractive apt install -y mariadb-server
fi

if [ -e "/etc/zypp/repos.d/mariadb.repo" ]; then
  if sudo touch "$DISABLEFB"; then
    echo "[mariadb]" | sudo tee "$DISABLEFB"
    echo "feedback=OFF" | sudo tee -a "$DISABLEFB"
  fi
  #sudo zypper refresh
  VERSIONS_LIST=$(zypper --non-interactive search --details "MariaDB-server")
  echo $VERSIONS_LIST
  LATEST_PACKAGE_VER=$(echo $VERSIONS_LIST | awk '/^v / {print $2" "$3}' | sort -V |sort -V | tail -n 1)
  read -r ACTUAL_PACKAGE_NAME LATEST_VERSION <<< "$LATEST_PACKAGE_VER"

  sudo zypper --auto-agree-with-licenses install -y "MariaDB-servera=${LATEST_VERSION}"
  sudo systemctl start mariadb
fi

sudo mariadb -u root -e "select version(),@@port, @@socket"
sudo mariadb -u root -e "set password=\"\""
sudo mariadb -u root -e "DROP DATABASE IF EXISTS test"
sudo mariadb -u root -e "CREATE DATABASE test"
sudo mariadb -u root -e "SELECT * FROM mysql.user"
SOCKETPATH=$(mariadb -u root test -N -B -e "select @@socket")
echo $SOCKETPATH

cd ..

cd buildbot || true
export ODBCINI=$PWD/odbc.ini
export ODBCSYSINI=$PWD
cat $ODBCINI
cat $ODBCSYSINI/odbcinst.ini
ldd ./odbc_basic
#./odbc_basic