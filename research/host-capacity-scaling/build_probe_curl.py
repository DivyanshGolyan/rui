"""Build a temporary experimental curl with poll enabled; never install it."""
import hashlib, pathlib, subprocess, sys, tarfile, urllib.request
root=pathlib.Path(sys.argv[1]).resolve(); root.mkdir(parents=True,exist_ok=True)
archive=root/'curl-8.7.1.tar.xz'
url='https://curl.se/download/curl-8.7.1.tar.xz'
expected='6fea2aac6a4610fbd0400afb0bcddbe7258a64c63f1f68e5855ebc0c659710cd'
if not archive.exists(): urllib.request.urlretrieve(url,archive)
assert hashlib.sha256(archive.read_bytes()).hexdigest()==expected
with tarfile.open(archive) as tar: tar.extractall(root,filter='data')
build=root/'curl-8.7.1'
flags=['--disable-shared','--enable-static','--with-secure-transport','--without-openssl','--without-libpsl','--without-libidn2','--without-librtmp','--without-libssh2','--without-brotli','--without-zstd','--without-nghttp2','--disable-ldap','--disable-ldaps']
with (root/'configure.log').open('w') as log: subprocess.run(['./configure',*flags],cwd=build,stdout=log,stderr=subprocess.STDOUT,check=True)
config=build/'lib/curl_config.h'; text=config.read_text(); assert '/* #undef HAVE_POLL_FINE */' in text
config.write_text(text.replace('/* #undef HAVE_POLL_FINE */','#define HAVE_POLL_FINE 1'))
with (root/'make.log').open('w') as log: subprocess.run(['make','-C','lib','-j4'],cwd=build,stdout=log,stderr=subprocess.STDOUT,check=True)
print(build)
