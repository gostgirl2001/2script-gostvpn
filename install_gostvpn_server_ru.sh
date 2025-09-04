#!/bin/bash
set -euo pipefail

# Paths
PREFIX_OPENSSL=/usr/local/openssl-gost
PREFIX_OPENVPN=/usr/local/openvpn-gost
SECURITY_DIR=/etc/openvpn/security
BUILD_DIR=~/gostvpn-build

mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR"

# Deps
apt update
apt install -y build-essential zlib1g-dev perl make pkg-config git wget curl liblzo2-dev libpam0g-dev iptables-persistent

# Build OpenSSL-1.1.1u with GOST
if [ ! -d "openssl-1.1.1u" ]; then wget -q https://www.openssl.org/source/openssl-1.1.1u.tar.gz; tar -xf openssl-1.1.1u.tar.gz
fi
cd openssl-1.1.1u
./config enable-gost --prefix=$PREFIX_OPENSSL --openssldir=$PREFIX_OPENSSL/ssl
make -j"$(nproc)"
make install_sw
echo "/usr/local/openssl-gost/lib" | tee /etc/ld.so.conf.d/openssl-gost.conf >/dev/null
ldconfig
cd "$BUILD_DIR"

# Auto-load GOST engine
mkdir -p /usr/local/openssl-gost/ssl
tee /usr/local/openssl-gost/ssl/openssl.cnf >/dev/null <<'CNF'
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

# Build CMake (>= 3.18)
if [ ! -x /usr/local/cmake/bin/cmake ]; then [ -d cmake-3.27.9 ] || wget -q https://github.com/Kitware/CMake/releases/download/v3.27.9/cmake-3.27.9.tar.gz; tar -xf cmake-3.27.9.tar.gz; cd cmake-3.27.9; ./bootstrap --prefix=/usr/local/cmake -- -DCMAKE_USE_OPENSSL=OFF; make -j"$(nproc)"; make install; cd "$BUILD_DIR"
fi
export PATH=/usr/local/cmake/bin:$PATH

# Build GOST engine
if [ ! -d "gost-engine" ]; then git clone -b openssl_1_1_1 https://github.com/gost-engine/engine.git gost-engine
fi
cd gost-engine && mkdir -p build-cmake && cd build-cmake
cmake .. -DOPENSSL_ROOT_DIR=$PREFIX_OPENSSL -DOPENSSL_ENGINES_DIR=$PREFIX_OPENSSL/lib/engines-1.1 -DCMAKE_INSTALL_PREFIX=$PREFIX_OPENSSL
make -j"$(nproc)"
make install
cd "$BUILD_DIR"

# Build OpenVPN 2.5.9
if [ ! -d "openvpn-2.5.9" ]; then wget -q https://swupdate.openvpn.org/community/releases/openvpn-2.5.9.tar.gz; tar -xf openvpn-2.5.9.tar.gz
fi
cd openvpn-2.5.9
./configure --prefix=$PREFIX_OPENVPN --with-crypto-library=openssl LDFLAGS="-L$PREFIX_OPENSSL/lib" CPPFLAGS="-I$PREFIX_OPENSSL/include"
make -j"$(nproc)"
make install
cd "$BUILD_DIR"

# Security directory
mkdir -p $SECURITY_DIR/{certs,private,csr}
chmod 700 $SECURITY_DIR/private

# Generate CA
$PREFIX_OPENSSL/bin/openssl genpkey -engine gost -algorithm gost2012_256 -pkeyopt paramset:A -out $SECURITY_DIR/private/ca.key
$PREFIX_OPENSSL/bin/openssl req -engine gost -new -x509 -days 3650 -key $SECURITY_DIR/private/ca.key -out $SECURITY_DIR/certs/ca.crt -subj "/C=RU/ST=Moscow/L=Moscow/O=GOSTVPN/CN=GOST Root CA"

# Server cert
$PREFIX_OPENSSL/bin/openssl genpkey -engine gost -algorithm gost2012_256 -pkeyopt paramset:A -out $SECURITY_DIR/private/server.key
$PREFIX_OPENSSL/bin/openssl req -engine gost -new -key $SECURITY_DIR/private/server.key -out $SECURITY_DIR/csr/server.csr -subj "/CN=server"
$PREFIX_OPENSSL/bin/openssl x509 -req -in $SECURITY_DIR/csr/server.csr -CA $SECURITY_DIR/certs/ca.crt -CAkey $SECURITY_DIR/private/ca.key -CAcreateserial -out $SECURITY_DIR/certs/server.crt -days 3650 -extensions v3_req -extfile /usr/lib/ssl/openssl.cnf -engine gost
$PREFIX_OPENVPN/sbin/openvpn --genkey --secret $SECURITY_DIR/private/ta.key
$PREFIX_OPENSSL/bin/openssl dhparam -out $SECURITY_DIR/certs/dh.pem 2048

# Client cert
$PREFIX_OPENSSL/bin/openssl genpkey -engine gost -algorithm gost2012_256 -pkeyopt paramset:A -out $SECURITY_DIR/private/client.key
$PREFIX_OPENSSL/bin/openssl req -engine gost -new -key $SECURITY_DIR/private/client.key -out $SECURITY_DIR/csr/client.csr -subj "/CN=client"
$PREFIX_OPENSSL/bin/openssl x509 -req -in $SECURITY_DIR/csr/client.csr -CA $SECURITY_DIR/certs/ca.crt -CAkey $SECURITY_DIR/private/ca.key -CAcreateserial -out $SECURITY_DIR/certs/client.crt -days 3650 -extensions v3_req -extfile /usr/lib/ssl/openssl.cnf -engine gost

# Permission changes
chmod 600 $SECURITY_DIR/private/* 2>/dev/null || true
chmod 644 $SECURITY_DIR/certs/*.crt 2>/dev/null || true

if ! grep -q 'OPENSSL_CONF=' /etc/environment; then echo 'OPENSSL_CONF=/usr/local/openssl-gost/ssl/openssl.cnf' | tee -a /etc/environment >/dev/null
fi
export OPENSSL_CONF=/usr/local/openssl-gost/ssl/openssl.cnf

# Server config
tee /etc/openvpn/server.ovpn >/dev/null <<EOF
port 1194
proto tcp4
dev tun
keepalive 10 120
ca $SECURITY_DIR/certs/ca.crt
cert $SECURITY_DIR/certs/server.crt
key $SECURITY_DIR/private/server.key
auth md_gost12_256
cipher grasshopper-cbc
data-ciphers grasshopper-cbc
tls-version-min 1.2
tls-cipher GOST2012-GOST8912-GOST8912
tls-auth $SECURITY_DIR/private/ta.key 0
tls-server
dh $SECURITY_DIR/certs/dh.pem
topology subnet
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 77.88.8.8"
server 10.8.0.0 255.255.255.0
persist-key
persist-tun
verb 3
EOF

# Enable IP forwarding + NAT
sed -i 's/^#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sysctl -p
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$(ip route get 8.8.8.8 | awk '{print $5}')" -j MASQUERADE
netfilter-persistent save

# Allow inbound TCP/1194
iptables -A INPUT -p tcp --dport 1194 -j ACCEPT
netfilter-persistent save || true

# Alias for convenience
if ! grep -q 'alias gostvpn-server=' ~/.bashrc 2>/dev/null; then echo "alias gostvpn-server='$PREFIX_OPENVPN/sbin/openvpn --config /etc/openvpn/server.ovpn'" >> ~/.bashrc
fi

echo "Server setup complete. Start with:"
echo " gostvpn-server"
