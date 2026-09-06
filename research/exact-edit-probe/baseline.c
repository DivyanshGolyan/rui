/* Measurement control: executable/runtime + same hash library; no edit. */
#include <CommonCrypto/CommonDigest.h>
#include <stdio.h>
int main(void){unsigned char h[32];CC_SHA256("",0,h);for(int i=0;i<32;i++)printf("%02x",h[i]);puts("");fprintf(stderr,"sha256_context_bytes=%zu\n",sizeof(CC_SHA256_CTX));return 0;}
