#!/bin/bash
set -euo pipefail

PREFIX_OPENSSL=/usr/local/openssl-gost
PREFIX_OPENVPN=/usr/local/openvpn-gost
SECURITY_DIR=~/security
BUILD_DIR=~/gostvpn-build
SERVER_IP="${1:-SERVER_IP}"

mkdir -p "$SECURITY_DIR"
SECURITY_DIR="$(readlink -f "$SECURITY_DIR")"

mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR"

# Deps
cp /etc/apt/sources.list /etc/apt/sources.list.bak
tee /etc/apt/sources.list >/dev/null <<'EOF'
deb [trusted=yes] http://archive.debian.org/debian buster main contrib non-free
deb [trusted=yes] http://archive.debian.org/debian-security buster/updates main contrib non-free
EOF
apt update
apt install -y build-essential zlib1g-dev perl make pkg-config git wget curl liblzo2-dev libpam0g-dev

# Build OpenSSL+GOST
if [ ! -d "openssl-1.1.1u" ]; then wget -q https://www.openssl.org/source/openssl-1.1.1u.tar.gz; tar -xf openssl-1.1.1u.tar.gz
fi
cd openssl-1.1.1u
./config enable-gost --prefix=$PREFIX_OPENSSL --openssldir=$PREFIX_OPENSSL/ssl
make -j"$(nproc)"
make install_sw
cd "$BUILD_DIR"
echo "/usr/local/openssl-gost/lib" | tee /etc/ld.so.conf.d/openssl-gost.conf >/dev/null
ldconfig

# Auto-load GOST engine
mkdir -p /usr/local/openssl-gost/ssl
tee "$PREFIX_OPENSSL/ssl/openssl.cnf" >/dev/null <<'CNF'
openssl_conf = openssl_def
[openssl_def]
engines = engine_section
[engine_section]
gost = gost_section
[gost_section]
engine_id = gost
default_algorithms = ALL
init = 1
[req]
distinguished_name = req_distinguished_name
prompt = no
[req_distinguished_name]
CN = default
CNF

# Build CMake 3.27.9

cd "$BUILD_DIR"
if [ ! -x /usr/local/cmake/bin/cmake ]; then wget -q https://github.com/Kitware/CMake/releases/download/v3.27.9/cmake-3.27.9.tar.gz; tar -xf cmake-3.27.9.tar.gz; cd cmake-3.27.9; ./bootstrap --prefix=/usr/local/cmake -- -DCMAKE_USE_OPENSSL=OFF; make -j"$(nproc)"; make install; cd "$BUILD_DIR"
fi
export PATH=/usr/local/cmake/bin:$PATH

# Build GOST engine
if [ ! -d "gost-engine" ]; then git clone -b openssl_1_1_1 https://github.com/gost-engine/engine.git gost-engine
fi
cd gost-engine && mkdir -p build-cmake && cd build-cmake
cmake .. -DOPENSSL_ROOT_DIR="$PREFIX_OPENSSL" -DOPENSSL_ENGINES_DIR="$PREFIX_OPENSSL/lib/engines-1.1" -DCMAKE_INSTALL_PREFIX="$PREFIX_OPENSSL"
make -j"$(nproc)"
make install
cd "$BUILD_DIR"

if ! grep -q 'OPENSSL_CONF=' /etc/environment; then echo "OPENSSL_CONF=$PREFIX_OPENSSL/ssl/openssl.cnf" | tee -a /etc/environment >/dev/null
fi
export OPENSSL_CONF="$PREFIX_OPENSSL/ssl/openssl.cnf"

# Build OpenVPN

if [ ! -d "openvpn-2.5.9" ]; then wget -q https://swupdate.openvpn.org/community/releases/openvpn-2.5.9.tar.gz; tar -xf openvpn-2.5.9.tar.gz
fi
cd openvpn-2.5.9
./configure --prefix=$PREFIX_OPENVPN --with-crypto-library=openssl LDFLAGS="-L$PREFIX_OPENSSL/lib" CPPFLAGS="-I$PREFIX_OPENSSL/include"
make -j"$(nproc)"
make install
cd "$BUILD_DIR"


# Directory for security materials copied from server

mkdir -p $SECURITY_DIR

# Copy security materials from server

echo "Copying security materials from $SERVER_IP ..."
scp -r root@$SERVER_IP:/etc/openvpn/security/* "$SECURITY_DIR"/

# Client config

tee ~/client.ovpn >/dev/null <<EOF
client
dev tun
proto tcp4
nobind
pull
resolv-retry infinite
remote $SERVER_IP 1194
auth md_gost12_256
ca $SECURITY_DIR/certs/ca.crt
cert $SECURITY_DIR/certs/client.crt
key $SECURITY_DIR/private/client.key
cipher grasshopper-cbc
data-ciphers grasshopper-cbc
tls-version-min 1.2
tls-cipher GOST2012-GOST8912-GOST8912
tls-auth $SECURITY_DIR/private/ta.key 1
tls-client
persist-key
persist-tun
verify-x509-name server name
verb 3
EOF

if ! grep -q 'alias gostvpn-client=' ~/.bashrc 2>/dev/null; then echo "alias gostvpn-client='$PREFIX_OPENVPN/sbin/openvpn --config ~/client.ovpn'" >> ~/.bashrc
fi
source ~/.bashrc
echo "Client setup complete."
echo "After starting server side, run with:"
echo " gostvpn-client"
