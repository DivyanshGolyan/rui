#!/usr/bin/env python3
"""Rebuild the sibling transport experiment's pins, without Python HTTP/2 dependencies.

Experimental build only. OpenSSL remains an exact external machine prerequisite.
"""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tarfile
import urllib.request

p=argparse.ArgumentParser()
p.add_argument('--build',type=Path,default=Path('/tmp/onepage-execution-lifetimes-deps'))
a=p.parse_args()
b=a.build.resolve()
b.mkdir(parents=True,exist_ok=True)
ssl=Path('/opt/homebrew/Cellar/openssl@3/3.6.3')
assert (ssl/'lib/libssl.3.dylib').exists(),'Requires exact OpenSSL 3.6.3 installation'
def run(args,cwd,log):
    with (b/log).open('w') as f:
        subprocess.run(args,cwd=cwd,stdout=f,stderr=subprocess.STDOUT,check=True)
for name,url,sha in [
    ('nghttp2-1.70.0','https://github.com/nghttp2/nghttp2/releases/download/v1.70.0/nghttp2-1.70.0.tar.xz','e05cb1388eaca3830aded4ccf20044b6e1ac1a61411dcca11b0437c4285c8bc2'),
    ('curl-8.22.0','https://curl.se/download/curl-8.22.0.tar.xz','f7ef3ae8a22e521f289803fe93543eb64c329b58aa73a9e224dfd915a2a5f4f7')]:
    archive=b/(name+'.tar.xz')
    if not archive.exists(): urllib.request.urlretrieve(url,archive)
    assert hashlib.sha256(archive.read_bytes()).hexdigest()==sha
    if not (b/name).exists():
        with tarfile.open(archive) as tar: tar.extractall(b,filter='data')
    if name.startswith('ng'):
        if not (b/'ng/lib/libnghttp2.a').exists():
            run(['./configure','--prefix='+str(b/'ng'),'--enable-lib-only','--disable-shared'],b/name,'ng-config.log')
            run(['make','-j2'],b/name,'ng-build.log')
            run(['make','install'],b/name,'ng-install.log')
    elif not (b/name/'lib/.libs/libcurl.a').exists():
        run(['./configure','--disable-shared','--enable-static','--with-openssl='+str(ssl),'--with-apple-sectrust','--without-libpsl','--without-libidn2','--without-librtmp','--without-libssh2','--without-brotli','--without-zstd','--with-nghttp2='+str(b/'ng'),'--disable-ldap','--disable-ldaps'],b/name,'curl-config.log')
        run(['make','-C','lib','-j2'],b/name,'curl-build.log')
print(b)
