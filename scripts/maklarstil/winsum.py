import json, numpy as np
W=json.load(open('windows.json'))
keys=['win_median','win_p99','win_p5','win_rel_wall','win_clip','win_std','win_detail','win_a','win_b','win_chroma','win_blue_frac','wall_b','halo_0_4','halo_4_10','halo_10_24']
print('n', len(W))
print('mått'.ljust(14), ''.join(s.rjust(16) for s in ['leverans','vår auto(enh)','vår HDR(pre)','Mäklarstil']))
for k in keys:
    row=[]
    for s in ['dst','ours_enh','ours_pre','ours_new']:
        v=[e[s][k] for e in W.values() if s in e and k in e[s]]
        row.append(f'{np.median(v):7.3f} ±{np.percentile(v,75)-np.percentile(v,25):5.3f}' if v else '-')
    print(k.ljust(14), ''.join(x.rjust(16) for x in row))
ranks=[e['best_frame_rank_from_dark'] for e in W.values() if 'best_frame_rank_from_dark' in e]
print('bästa ram (0=mörkast):', {r: ranks.count(r) for r in set(ranks)})
d0=[];d1=[]
for e in W.values():
    fr=sorted(e.get('frames',[]),key=lambda x:x['median'])
    if len(fr)>=2: d0.append(fr[0]['gcorr']); d1.append(fr[1]['gcorr'])
print('gradientkorrelation mörkast %.2f, näst mörkast %.2f'%(np.median(d0),np.median(d1)))
cl=[sorted(e['frames'],key=lambda x:x['median'])[0]['clip'] for e in W.values() if e.get('frames')]
print('mörkaste ramens klippning i fönstret: median %.3f'%np.median(cl))
