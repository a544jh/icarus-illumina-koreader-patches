#!/usr/bin/env bash
# Build the patched KOReader APK from the official v2023.06.1 release.
#   KEYSTORE=<file> KEYSTORE_PASS=<password> [KEY_ALIAS=icarus] build.sh <koreader-android-arm-v2023.06.1.apk> <out.apk>
# Needs java and jarsigner (JDK 8 or newer, from JAVA_HOME or PATH), openssl, python3,
# patch, 7-Zip (7z, or set SEVENZIP), and smali/baksmali 2.5.2 (SMALI_JAR, BAKSMALI_JAR;
# default: tools/ next to this script).
#
# Disassembles classes.dex, applies smali/*.diff, adds the new classes in smali/, and
# reassembles it into the APK. Writes this build's version label (below) into
# assets/module/version.txt and git-rev inside assets/module/koreader.7z. Signing:
# jarsigner writes MANIFEST.MF/ICARUS.SF, then the signature block is redone with openssl
# without signed attributes, because Android 4.2's JarUtils rejects modern jarsigner
# blocks ("Incorrect signature").
set -euo pipefail

# Version label; bump it for every release. The launcher unpacks koreader.7z again only
# when version.txt differs from files/git-rev, which is unpacked from koreader.7z. With the
# same label in both, an update unpacks once (recreating the sdcv link that dictionary
# lookups use), and later starts skip it as usual. KOReader parses this label to the same
# version number as v2023.06.1.
version=v2023.06.1-icarus2

orig=$1 out=$2
here=$(cd "$(dirname "$0")" && pwd)
: "${KEYSTORE:?set KEYSTORE to your PKCS12 keystore (see README)}"
: "${KEYSTORE_PASS:?set KEYSTORE_PASS to the keystore password}"
alias=${KEY_ALIAS:-icarus}
baksmali=${BAKSMALI_JAR:-$here/tools/baksmali-2.5.2.jar}
smali=${SMALI_JAR:-$here/tools/smali-2.5.2.jar}
sevenzip=${SEVENZIP:-7z}
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

# Version label: replace git-rev in koreader.7z, keeping its timestamp. Updating it
# recompresses its solid block; keep the original method (LZMA2, 64 MB dictionary, no
# filter) so the launcher's 7z decoder sees nothing new.
python3 -I -c 'import sys, zipfile; open(sys.argv[2], "wb").write(zipfile.ZipFile(sys.argv[1]).read("assets/module/koreader.7z"))' \
    "$orig" "$work/koreader.7z"
mkdir "$work/rev"
(cd "$work/rev" && "$sevenzip" x -y ../koreader.7z git-rev >/dev/null)
touch -r "$work/rev/git-rev" "$work/git-rev.time"
printf '%s\n' "$version" > "$work/rev/git-rev"
touch -r "$work/git-rev.time" "$work/rev/git-rev"
(cd "$work/rev" && "$sevenzip" u -mx=9 -m0=LZMA2:d26 -mf=off ../koreader.7z git-rev >/dev/null)
[[ $("$sevenzip" x -so "$work/koreader.7z" git-rev) == "$version" ]]
printf '%s\n' "$version" > "$work/version.txt"

printf 'jdk.jar.disabledAlgorithms=\njdk.security.legacyAlgorithms=\n' > "$work/sha1.security"
sec=-J-Djava.security.properties=$work/sha1.security

python3 -I "$here/repack.py" strip "$orig" "$work/classes.dex" "$work/stripped.apk"
python3 -I "$here/repack.py" put "$work/stripped.apk" assets/module/koreader.7z "$work/koreader.7z" "$work/bundle.apk"
python3 -I "$here/repack.py" put "$work/bundle.apk" assets/module/version.txt "$work/version.txt" "$work/unsigned.apk"
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
