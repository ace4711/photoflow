import json, numpy as np
EXT={'bergstigen-105/DSC_5546','bergstigen-105/DSC_5597','bergstigen-105/DSC_5663','DSC_9145','DSC_9154','DSC_9160','DSC_9173'}
R={}
for f in ['res-pilvinge-base.json','res-train3-base.json']: R.update(json.load(open(f)))
def ext(k): return k in EXT or k.startswith('pilottorget')
PIL_TEST={'DSC_9053','DSC_9074','DSC_9100','DSC_9117','DSC_9144','DSC_9160','DSC_9185'}  # ids[2::3]
for lab,sel in (('interiör',lambda k: not ext(k)),('exteriör',ext)):
    ks=[k for k in R if sel(k) and k not in PIL_TEST]
    print(f'== {lab} n={len(ks)}')
    for q in ('dst_p1','dst_p5','dst_p25','dst_p50','dst_p75','dst_p95','dst_p99','wall_dst_L','wall_dst_b','neutral_dst_b'):
        v=[R[k]['sources']['ours_pre'].get(q) for k in ks]; v=[x for x in v if x is not None]
        print(f'  {q:14s} med {np.median(v):.3f} IQR {np.percentile(v,75)-np.percentile(v,25):.3f}')
    for src in ('ours_pre','skicka'):
        sr=[R[k]['sources'][src]['sat_mean_dst']/R[k]['sources'][src]['sat_mean_src'] for k in ks if 'sat_mean_src' in R[k]['sources'].get(src,{})]
        line=f'  {src}: mean-chroma-kvot {np.median(sr):.2f} (IQR {np.percentile(sr,75)-np.percentile(sr,25):.2f}) |'
        for h in ['röd','orange','gul','grön','cyan','blå','lila','magenta']:
            v=[R[k]['sources'][src].get(f'hsl_{h}_sat') for k in ks]; v=[x for x in v if x is not None]
            line+=f' {h} {np.median(v):.2f}({len(v)})' if v else f' {h} -'
        print(line)
        for t in ('bp_texture_ratio','bp_clarity_ratio','bp_large_ratio','noise_dst','noise_src','chroma_noise_dst','chroma_noise_src','sharp_dst','sharp_src','vignette_corner_minus_center','visible_fraction'):
            v=[R[k]['sources'][src].get(t) for k in ks]; v=[x for x in v if x is not None]
            if v: print(f'    {t:28s} {np.median(v):.3f} IQR {np.percentile(v,75)-np.percentile(v,25):.3f}')
