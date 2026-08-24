#!/bin/sh
# Generates a throwaway CA + server cert for exercising SpiceSee's TLS path against a real
# OpenSSL endpoint. Nothing here is a secret; the key never leaves the dev machine.
set -eu
DIR="${1:-.dev-tls}"
SUBJECT="/OU=PVE Cluster Node/O=Proxmox Virtual Environment/CN=pve1.example.com"
mkdir -p "$DIR"
cd "$DIR"

if [ ! -f ca.pem ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/O=PVE Cluster Manager CA/CN=Proxmox Virtual Environment Cluster Manager CA" \
    -keyout ca.key -out ca.pem 2>/dev/null
fi

if [ ! -f server.pem ]; then
  openssl req -newkey rsa:2048 -nodes -subj "$SUBJECT" -keyout server.key -out server.csr 2>/dev/null
  openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
    -days 3650 -out server.pem 2>/dev/null
  cat server.key server.pem > server-bundle.pem
fi

# A second CA the server does NOT use, for the "wrong CA is rejected" test.
if [ ! -f other-ca.pem ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/O=Someone Else/CN=Someone Else CA" -keyout other-ca.key -out other-ca.pem 2>/dev/null
fi

echo "CA:            $DIR/ca.pem"
echo "server bundle: $DIR/server-bundle.pem"
echo "host-subject:  OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=pve1.example.com"
echo
echo "On the dev box, wrap the SPICE port in TLS:"
echo "  socat OPENSSL-LISTEN:5931,cert=server-bundle.pem,verify=0,reuseaddr,fork TCP:127.0.0.1:5930"
