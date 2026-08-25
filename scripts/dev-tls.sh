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

# A SAN-bearing certificate from the same CA, for the no-`host-subject` path: there the dialled
# hostname is what gets verified, and `SecPolicyCreateSSL` matches a DNS SAN, never the CN — so the
# certificate above, which has no extensions at all, cannot exercise that path. Apple's TLS rules
# apply even to a pinned anchor: without `serverAuth`, SecTrust says "not permitted for this usage",
# and over 398 days of validity it says "not standards compliant" — hence 397 days, which means this
# one (and `Tests/SpiceCoreTests/Fixtures/test-server-san.pem` copied from it) expires in ~13 months.
# Delete both and re-run to re-mint.
if [ ! -f server-san.pem ]; then
  openssl req -newkey rsa:2048 -nodes -subj "/CN=spice.test" \
    -keyout server-san.key -out server-san.csr 2>/dev/null
  printf 'subjectAltName=DNS:spice.test\nbasicConstraints=critical,CA:FALSE\n%s\nextendedKeyUsage=serverAuth\n' \
    'keyUsage=critical,digitalSignature,keyEncipherment' > server-san.ext
  openssl x509 -req -in server-san.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
    -days 397 -extfile server-san.ext -out server-san.pem 2>/dev/null
  cat server-san.key server-san.pem > server-san-bundle.pem
fi

# A second CA the server does NOT use, for the "wrong CA is rejected" test.
if [ ! -f other-ca.pem ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/O=Someone Else/CN=Someone Else CA" -keyout other-ca.key -out other-ca.pem 2>/dev/null
fi

echo "CA:            $DIR/ca.pem"
echo "server bundle: $DIR/server-bundle.pem"
echo "SAN bundle:    $DIR/server-san-bundle.pem (CN=spice.test, DNS:spice.test — no host-subject)"
echo "host-subject:  OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=pve1.example.com"
echo
echo "On the dev box, wrap the SPICE port in TLS:"
echo "  socat OPENSSL-LISTEN:5931,cert=server-bundle.pem,verify=0,reuseaddr,fork TCP:127.0.0.1:5930"
