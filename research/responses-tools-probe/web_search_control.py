import json, os, sys
sys.argv=[sys.argv[0]]
exec(open("probe.py").read().split("results = []")[0])
q=[{"role":"user","content":"You must call the web_search tool now: search for 'Zig 0.17 release date'. Then answer in one line."}]
for label, body in (("top", dict(base(q), tools=[WEB])), ("head", base(head+q)), ("head_only_web", base([{"type":"additional_tools","role":"developer","tools":[WEB]}]+q))):
    for n in range(2):
        r=post(body)
        kinds=[i.get("type") for i in r["body"]["output"]] if r["status"]==200 else r["body"][:300]
        print(label, n, r["status"], kinds)
json.dump(raw, open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "web-search-raw.json"), "w"), indent=1)
