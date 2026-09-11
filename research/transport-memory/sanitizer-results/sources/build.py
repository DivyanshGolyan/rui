#!/usr/bin/env python3
"""Experimental pins only; does not change OnePage production dependencies."""
import argparse,hashlib,pathlib,subprocess,tarfile,urllib.request
p=argparse.ArgumentParser();p.add_argument('--build',type=pathlib.Path,default=pathlib.Path('/tmp/onepage-transport-memory-build'));a=p.parse_args();b=a.build.resolve();b.mkdir(parents=True,exist_ok=True)
ssl=pathlib.Path('/opt/homebrew/Cellar/openssl@3/3.6.3')
assert (ssl/'lib/libssl.3.dylib').exists(),'Requires exact OpenSSL 3.6.3 installation; do not substitute system curl/TLS'
def run(argv,cwd,log):
 with open(b/log,'w') as f:subprocess.run(argv,cwd=cwd,stdout=f,stderr=subprocess.STDOUT,check=True)
for name,url,sha in [('nghttp2-1.70.0','https://github.com/nghttp2/nghttp2/releases/download/v1.70.0/nghttp2-1.70.0.tar.xz','e05cb1388eaca3830aded4ccf20044b6e1ac1a61411dcca11b0437c4285c8bc2'),('curl-8.22.0','https://curl.se/download/curl-8.22.0.tar.xz','f7ef3ae8a22e521f289803fe93543eb64c329b58aa73a9e224dfd915a2a5f4f7')]:
 archive=b/(name+'.tar.xz')
 if not archive.exists():urllib.request.urlretrieve(url,archive)
 assert hashlib.sha256(archive.read_bytes()).hexdigest()==sha
 if not (b/name).exists():
  with tarfile.open(archive) as t:t.extractall(b,filter='data')
 if name.startswith('ng'):
  flags=['./configure','--prefix='+str(b/'ng'),'--enable-lib-only','--disable-shared']
  if not (b/'ng/lib/libnghttp2.a').exists():
   run(flags,b/name,'ng-config.log');run(['make','-j2'],b/name,'ng-build.log');run(['make','install'],b/name,'ng-install.log')
 else:
  flags=['./configure','--disable-shared','--enable-static','--with-openssl='+str(ssl),'--with-apple-sectrust','--without-libpsl','--without-libidn2','--without-librtmp','--without-libssh2','--without-brotli','--without-zstd','--with-nghttp2='+str(b/'ng'),'--disable-ldap','--disable-ldaps']
  if not (b/name/'lib/.libs/libcurl.a').exists():run(flags,b/name,'curl-config.log');run(['make','-C','lib','-j2'],b/name,'curl-build.log')
run(['python3','-m','venv',str(b/'venv')],b,'venv.log')
run([str(b/'venv/bin/pip'),'install','h2==4.3.0','hpack==4.2.0','hyperframe==6.1.0'],b,'pip.log')
print(b)
