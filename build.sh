#!/usr/bin/env bash
# Build the patched KOReader APK from the official v2023.06.1 release.
#   KEYSTORE=<file> KEYSTORE_PASS=<password> [KEY_ALIAS=icarus] build.sh <koreader-android-arm-v2023.06.1.apk> <out.apk>
# Needs java and jarsigner (JDK 8 or newer, from JAVA_HOME or PATH), openssl, python3,
# patch, and smali/baksmali 2.5.2 (SMALI_JAR, BAKSMALI_JAR; default: tools/ next to this script).
#
# Disassembles classes.dex, applies smali/*.diff, adds the new classes in smali/, and
# reassembles it into the APK. Signing: jarsigner writes MANIFEST.MF/ICARUS.SF, then the
# signature block is redone with openssl without signed attributes, because
# Android 4.2's JarUtils rejects modern jarsigner blocks ("Incorrect signature").
set -euo pipefail
orig=$1 out=$2
here=$(cd "$(dirname "$0")" && pwd)
: "${KEYSTORE:?set KEYSTORE to your PKCS12 keystore (see README)}"
: "${KEYSTORE_PASS:?set KEYSTORE_PASS to the keystore password}"
alias=${KEY_ALIAS:-icarus}
baksmali=${BAKSMALI_JAR:-$here/tools/baksmali-2.5.2.jar}
smali=${SMALI_JAR:-$here/tools/smali-2.5.2.jar}
jarsigner=${JAVA_HOME:+$JAVA_HOME/bin/}jarsigner
orig_sha256=3b52a2ce39605896e273337dde8b27dae0ec33439ed8df8cd3225b5299ad1a50
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [[ $(sha256sum "$orig" | cut -d' ' -f1) != "$orig_sha256" ]]; then
    echo "$orig is not the official koreader-android-arm-v2023.06.1.apk" >&2
    exit 1
fi

python3 -I -c 'import sys, zipfile; open(sys.argv[2], "wb").write(zipfile.ZipFile(sys.argv[1]).read("classes.dex"))' \
    "$orig" "$work/orig.dex"
java -jar "$baksmali" d -o "$work/smali" "$work/orig.dex"
for diff in "$here"/smali/*.diff; do
    patch -s -p1 --fuzz=0 -d "$work/smali" < "$diff"
done
cp "$here"/smali/*.smali "$work/smali/org/koreader/launcher/"
java -jar "$smali" a -a 15 -o "$work/classes.dex" "$work/smali"

printf 'jdk.jar.disabledAlgorithms=\njdk.security.legacyAlgorithms=\n' > "$work/sha1.security"
sec=-J-Djava.security.properties=$work/sha1.security

python3 -I "$here/repack.py" strip "$orig" "$work/classes.dex" "$work/unsigned.apk"
"$jarsigner" "$sec" -keystore "$KEYSTORE" -storepass:env KEYSTORE_PASS -sigfile ICARUS \
    -digestalg SHA1 -sigalg SHA1withRSA -signedjar "$work/signed.apk" "$work/unsigned.apk" "$alias" >/dev/null

python3 -I -c 'import sys, zipfile; open(sys.argv[2], "wb").write(zipfile.ZipFile(sys.argv[1]).read("META-INF/ICARUS.SF"))' \
    "$work/signed.apk" "$work/ICARUS.SF"
openssl pkcs12 -in "$KEYSTORE" -passin env:KEYSTORE_PASS -nocerts -nodes -out "$work/key.pem"
openssl pkcs12 -in "$KEYSTORE" -passin env:KEYSTORE_PASS -nokeys -out "$work/cert.pem"
openssl smime -sign -binary -noattr -md sha1 -outform DER -signer "$work/cert.pem" -inkey "$work/key.pem" \
    -in "$work/ICARUS.SF" -out "$work/ICARUS.RSA"
openssl smime -verify -noverify -binary -inform DER -in "$work/ICARUS.RSA" -content "$work/ICARUS.SF" >/dev/null 2>&1

python3 -I "$here/repack.py" put "$work/signed.apk" META-INF/ICARUS.RSA "$work/ICARUS.RSA" "$work/signed2.apk"
python3 -I "$here/repack.py" align "$work/signed2.apk" "$out"
sha256sum "$out"
