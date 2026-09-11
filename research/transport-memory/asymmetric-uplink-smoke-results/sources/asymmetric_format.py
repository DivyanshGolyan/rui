"""Complete staged JSON request fixture, streamed independently of response size."""
import hashlib
PREFIX=b'{"model":"fixture","input":[{"role":"user","content":[{"type":"input_text","text":"'
SUFFIX=b'"}]}]}'
def request_size(base,burst,identifier,growth,mixed):
 size=base*([1,4,16,4][burst] if growth else 1)
 return max(1024,size//64) if mixed and identifier%2 else size

def request_hash(size):
 assert size>=len(PREFIX)+len(SUFFIX)
 h=hashlib.sha256();h.update(PREFIX);left=size-len(PREFIX)-len(SUFFIX)
 while left:
  take=min(left,16384);h.update(b'a'*take);left-=take
 h.update(SUFFIX);return h.digest()
