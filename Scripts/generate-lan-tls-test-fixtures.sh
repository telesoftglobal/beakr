#!/bin/bash

set -euo pipefail
umask 077

if ! command -v openssl >/dev/null 2>&1; then
    echo "OpenSSL is required." >&2
    exit 1
fi

output_directory="${1:-}"
if [[ -z "${output_directory}" ]]; then
    output_directory="$(mktemp -d "${TMPDIR:-/tmp}/beakrnet-mtls.XXXXXX")"
elif [[ -e "${output_directory}" ]]; then
    if [[ ! -d "${output_directory}" ]] || [[ -n "$(find "${output_directory}" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
        echo "Output path must be a new or empty directory: ${output_directory}" >&2
        exit 1
    fi
else
    mkdir -p "${output_directory}"
fi

output_directory="$(cd "${output_directory}" && pwd)"
password="${BEAKRNET_TEST_PKCS12_PASSWORD:-$(openssl rand -hex 24)}"

cat > "${output_directory}/leaf-extensions.cnf" <<'EOF'
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,clientAuth,serverAuth
subjectAltName = DNS:localhost,IP:127.0.0.1,IP:::1
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

openssl ecparam -name prime256v1 -genkey -noout -out "${output_directory}/authority-key.pem"
openssl req -new -x509 -sha256 -days 30 \
    -key "${output_directory}/authority-key.pem" \
    -subj "/CN=BeakrNet Integration Test Authority" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out "${output_directory}/authority-cert.pem"
openssl x509 -in "${output_directory}/authority-cert.pem" -outform DER \
    -out "${output_directory}/authority-cert.der"

issue_identity() {
    local name="$1"
    local common_name="$2"

    openssl ecparam -name prime256v1 -genkey -noout \
        -out "${output_directory}/${name}-key.pem"
    openssl req -new -sha256 \
        -key "${output_directory}/${name}-key.pem" \
        -subj "/CN=${common_name}" \
        -out "${output_directory}/${name}.csr"
    openssl x509 -req -sha256 -days 30 \
        -in "${output_directory}/${name}.csr" \
        -CA "${output_directory}/authority-cert.pem" \
        -CAkey "${output_directory}/authority-key.pem" \
        -CAcreateserial \
        -extfile "${output_directory}/leaf-extensions.cnf" \
        -out "${output_directory}/${name}-cert.pem"
    openssl pkcs12 -export \
        -inkey "${output_directory}/${name}-key.pem" \
        -in "${output_directory}/${name}-cert.pem" \
        -certfile "${output_directory}/authority-cert.pem" \
        -name "BeakrNet ${common_name}" \
        -passout "pass:${password}" \
        -out "${output_directory}/${name}.p12"
}

issue_identity "client" "Integration Client"
issue_identity "server" "Integration Server"

openssl ecparam -name prime256v1 -genkey -noout \
    -out "${output_directory}/expired-server-key.pem"
openssl req -new -sha256 \
    -key "${output_directory}/expired-server-key.pem" \
    -subj "/CN=Expired Integration Server" \
    -out "${output_directory}/expired-server.csr"
openssl x509 -req -sha256 -days 0 \
    -in "${output_directory}/expired-server.csr" \
    -CA "${output_directory}/authority-cert.pem" \
    -CAkey "${output_directory}/authority-key.pem" \
    -CAcreateserial \
    -extfile "${output_directory}/leaf-extensions.cnf" \
    -out "${output_directory}/expired-server-cert.pem"
openssl pkcs12 -export \
    -inkey "${output_directory}/expired-server-key.pem" \
    -in "${output_directory}/expired-server-cert.pem" \
    -certfile "${output_directory}/authority-cert.pem" \
    -name "BeakrNet Expired Integration Server" \
    -passout "pass:${password}" \
    -out "${output_directory}/expired-server.p12"

openssl ecparam -name prime256v1 -genkey -noout -out "${output_directory}/wrong-authority-key.pem"
openssl req -new -x509 -sha256 -days 30 \
    -key "${output_directory}/wrong-authority-key.pem" \
    -subj "/CN=BeakrNet Wrong Test Authority" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out "${output_directory}/wrong-authority-cert.pem"
openssl x509 -in "${output_directory}/wrong-authority-cert.pem" -outform DER \
    -out "${output_directory}/wrong-authority-cert.der"

openssl verify -CAfile "${output_directory}/authority-cert.pem" \
    "${output_directory}/client-cert.pem" \
    "${output_directory}/server-cert.pem"
openssl pkcs12 -in "${output_directory}/client.p12" -passin "pass:${password}" -noout
openssl pkcs12 -in "${output_directory}/server.p12" -passin "pass:${password}" -noout
openssl pkcs12 -in "${output_directory}/expired-server.p12" -passin "pass:${password}" -noout

cat > "${output_directory}/environment.sh" <<EOF
export BEAKRNET_RUN_SIGNED_MTLS_INTEGRATION=1
export BEAKRNET_TEST_PKCS12_PASSWORD='${password}'
export BEAKRNET_TEST_CLIENT_PKCS12='${output_directory}/client.p12'
export BEAKRNET_TEST_SERVER_PKCS12='${output_directory}/server.p12'
export BEAKRNET_TEST_EXPIRED_SERVER_PKCS12='${output_directory}/expired-server.p12'
export BEAKRNET_TEST_AUTHORITY_DER='${output_directory}/authority-cert.der'
export BEAKRNET_TEST_WRONG_AUTHORITY_DER='${output_directory}/wrong-authority-cert.der'
export BEAKRNET_TEST_CLIENT_PKCS12_BASE64='$(openssl base64 -A -in "${output_directory}/client.p12")'
export BEAKRNET_TEST_SERVER_PKCS12_BASE64='$(openssl base64 -A -in "${output_directory}/server.p12")'
export BEAKRNET_TEST_EXPIRED_SERVER_PKCS12_BASE64='$(openssl base64 -A -in "${output_directory}/expired-server.p12")'
export BEAKRNET_TEST_AUTHORITY_DER_BASE64='$(openssl base64 -A -in "${output_directory}/authority-cert.der")'
export BEAKRNET_TEST_WRONG_AUTHORITY_DER_BASE64='$(openssl base64 -A -in "${output_directory}/wrong-authority-cert.der")'
EOF
chmod 600 "${output_directory}/environment.sh"

echo "Created short-lived BeakrNet mutual-TLS fixtures."
echo "Environment file: ${output_directory}/environment.sh"
echo "Delete the fixture directory after the test run."
