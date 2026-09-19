#!/bin/sh
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_directory=$(CDPATH= cd -- "$script_directory/.." && pwd)
certificate_directory="${MAC_VNC_SERVER_SIGNING_DIRECTORY:-$repository_directory/.mac-vnc-server-signing}"
certificate_path="$certificate_directory/macos-signing.p12"
password_path="$certificate_directory/macos-signing-password"
certificate_validity_days=7305
certificate_subject="/CN=mac-vnc-server macOS Signing/O=mac-vnc-server"
signing_identity="mac-vnc-server macOS Signing"

if [ -f "$certificate_path" ] && [ -f "$password_path" ]; then
    printf 'macOS signing certificate ready at %s\n' "$certificate_path"
    printf 'macOS signing password stored at %s\n' "$password_path"
    exit 0
fi

if [ -e "$certificate_path" ] && [ ! -f "$password_path" ]; then
    printf 'The macOS signing certificate exists but its password file is missing: %s\n' "$password_path" >&2
    exit 1
fi

umask 077
mkdir -p "$certificate_directory"

if [ -f "$password_path" ]; then
    password=$(tr -d '\r\n' < "$password_path")
    if [ -z "$password" ]; then
        printf 'The macOS signing password file is empty: %s\n' "$password_path" >&2
        exit 1
    fi
else
    password=$(openssl rand -hex 32)
    printf '%s\n' "$password" > "$password_path"
fi

temporary_directory=$(mktemp -d "$certificate_directory/.generation.XXXXXX")
private_key_path="$temporary_directory/private-key.pem"
certificate_pem_path="$temporary_directory/certificate.pem"
temporary_certificate_path="$temporary_directory/macos-signing.p12"

cleanup() {
    rm -f "$private_key_path" "$certificate_pem_path" "$temporary_certificate_path"
    rmdir "$temporary_directory" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

openssl req \
    -x509 \
    -newkey rsa:3072 \
    -sha256 \
    -days "$certificate_validity_days" \
    -nodes \
    -subj "$certificate_subject" \
    -addext "basicConstraints=critical,CA:true" \
    -addext "keyUsage=critical,keyCertSign,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    -keyout "$private_key_path" \
    -out "$certificate_pem_path"

openssl pkcs12 \
    -export \
    -out "$temporary_certificate_path" \
    -inkey "$private_key_path" \
    -in "$certificate_pem_path" \
    -name "$signing_identity" \
    -keypbe PBE-SHA1-3DES \
    -certpbe PBE-SHA1-3DES \
    -macalg sha1 \
    -passout "file:$password_path"

mv "$temporary_certificate_path" "$certificate_path"
chmod 600 "$certificate_path" "$password_path"

printf 'macOS signing certificate ready at %s\n' "$certificate_path"
printf 'macOS signing password stored at %s\n' "$password_path"
