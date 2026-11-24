import jwt, time, os, json, urllib.request, urllib.error
k=open(os.path.expanduser('~/AuthKey.p8')).read()
now=int(time.time())
t=jwt.encode({"iss":os.environ["IID"],"iat":now,"exp":now+1100,"aud":"appstoreconnect-v1"},k,algorithm="ES256",headers={"kid":os.environ["KID"]})
def get(p):
    r=urllib.request.Request("https://api.appstoreconnect.apple.com"+p,headers={"Authorization":"Bearer "+t})
    try: return json.load(urllib.request.urlopen(r))
    except urllib.error.HTTPError as e: return {"error":e.code,"body":e.read().decode()[:600]}
out=[]
s=get("/v1/apps/6838561699/betaFeedbackCrashSubmissions?limit=4&sort=-createdDate")
if "error" in s: out.append(json.dumps(s))
for d in s.get("data",[]):
    a=d["attributes"]
    out.append("=== %s · %s · iOS %s · build? %s"%(a.get("createdDate"),a.get("deviceModel"),a.get("osVersion"),d.get("relationships",{}).get("build",{}).get("data")))
    c=get("/v1/betaFeedbackCrashSubmissions/%s/crashLog"%d["id"])
    log=(c.get("data",{}).get("attributes",{}).get("logText") or json.dumps(c))
    lines=[l for l in log.splitlines() if "@" not in l]   # never publish emails
    out.append("\n".join(lines[:140]))
open("crashes.txt","w").write("\n".join(out) or "no crash submissions yet")
