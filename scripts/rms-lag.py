import csv, json, sys
audio=[(float(x['segment_start_unix'])+float(x['offset_in_segment']),float(x['speech']),float(x['music'])) for x in csv.DictReader(open(sys.argv[1]))]
# audio onsets: music window after >=2 consecutive speech windows
onsets=[]; sp=0
for t,s,m in audio:
    if s>=0.6: sp+=1
    else:
        if sp>=2 and m>=0.5: onsets.append(t)
        sp=0 if m>=0.5 or s<0.4 else sp
rows=[json.loads(l) for l in open(sys.argv[2])]
tracks={}
for r in rows:
    d=json.loads(r['body'])
    for x in d['data']:
        o=x['offset']
        if o['now_playing'] or True:
            tid=x['id']
            if tid not in tracks: tracks[tid]=dict(start=o['start'],end=o['end'],first=None,title=x['titles']['primary'])
            if o['now_playing'] and tracks[tid]['first'] is None: tracks[tid]['first']=r['polledAt']
tr=[v for v in tracks.values() if v['first']]
print(len(onsets),'audio onsets;',len(tr),'tracks first seen playing')
lo=min(v['first']-v['start'] for v in tr)
best=None
for d10 in range(-3000,300,2):               # P = lo + d, seconds
    P=lo+d10/10
    hits=sum(1 for v in tr if any(abs(P+v['start']-t)<3 for t in onsets))
    if best is None or hits>best[0]: best=(hits,P)
print('best alignment hits',best[0],'of',len(tr))
P=best[1]
diffs=[v['first']-(P+v['start']) for v in tr if any(abs(P+v['start']-t)<3 for t in onsets)]
print('first-seen minus audio start (s):',[round(x) for x in diffs])
if diffs: print('min',round(min(diffs)),'mean',round(sum(diffs)/len(diffs)),'(poll granularity 30 s: mean-15 is the estimate of API lag)')
