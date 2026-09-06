from pathlib import Path
import hashlib, json, subprocess, tarfile, urllib.request
root=Path('/tmp/onepage-stock-curl-qualification');root.mkdir(exist_ok=True)
archive=root/'curl-8.22.0.tar.xz'
with urllib.request.urlopen('https://curl.se/download/curl-8.22.0.tar.xz') as response: archive.write_bytes(response.read())
with tarfile.open(archive) as tar: tar.extractall(root,filter='data')
source=root/'curl-8.22.0'
args=['./configure','--disable-shared','--enable-static','--with-openssl=/opt/homebrew/opt/openssl@3','--with-apple-sectrust','--without-libpsl','--without-libidn2','--without-librtmp','--without-libssh2','--without-brotli','--without-zstd','--without-nghttp2','--disable-ldap','--disable-ldaps']
(root/'metadata.json').write_text(json.dumps(dict(url='https://curl.se/download/curl-8.22.0.tar.xz',sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),configure=args),indent=2)+'\n')
with (root/'build.log').open('w') as log:
 subprocess.run(args,cwd=source,stdout=log,stderr=subprocess.STDOUT,check=True)
 subprocess.run(['make','-C','lib','-j4'],cwd=source,stdout=log,stderr=subprocess.STDOUT,check=True)
print(source)
