import json, numpy as np, pf, sys
from groupstats import ext, PIL_TEST
B={}
for f in ['res-pilvinge-base.json','res-train3-base.json','res-test-base.json']: B.update(json.load(open(f)))
N=json.load(open(sys.argv[1] if len(sys.argv)>1 else 'res-all-new.json'))
def tilt(path):
    im=pf.load(path,1600); a,l,x=pf.vertical_tilts(im,min_len_frac=0.08,max_dev=6)
    if a.size<3: return None
    o=np.argsort(np.abs(a)); c=np.cumsum(l[o]); return float(np.abs(a[o])[np.searchsorted(c,c[-1]/2)])
rows=[]
for k,n in N.items():
    b=B[k]['sources']; nn=n['sources']['ours_new']
    shoot=k.split('/')[0] if '/' in k else 'pilvinge-77'
    split='test' if (k in PIL_TEST or shoot.startswith('varmfront')) else 'train'
    r=dict(k=k,shoot=shoot,split=split,ext=ext(k),
      dE_base=b['ours_enh']['dE_median'],dE_new=nn['dE_median'],p90_base=b['ours_enh']['dE_p90'],p90_new=nn['dE_p90'],
      emd_base=b['ours_enh']['hist_emd'],emd_new=nn['hist_emd'],
      wallL_base=b['ours_enh'].get('wall_src_L'),wallL_new=nn.get('wall_src_L'),wallL_dst=nn.get('wall_dst_L'),
      wallb_base=b['ours_enh'].get('wall_src_b'),wallb_new=nn.get('wall_src_b'),wallb_dst=nn.get('wall_dst_b'),
      noise_base=b['ours_enh'].get('noise_src'),noise_new=nn.get('noise_src'),noise_dst=nn.get('noise_dst'),
      cn_base=b['ours_enh'].get('chroma_noise_src'),cn_new=nn.get('chroma_noise_src'),cn_dst=nn.get('chroma_noise_dst'),
      sat_base=b['ours_enh']['sat_mean_src'],sat_new=nn['sat_mean_src'],sat_dst=nn['sat_mean_dst'],
      tilt_base=tilt(b['ours_enh']['path']),tilt_new=tilt(nn['path']),tilt_dst=tilt(n['delivery']),
      vis_new=nn.get('visible_fraction'),vis_base=b['ours_enh'].get('visible_fraction'))
    rows.append(r)
json.dump(rows,open('compare.json','w'),indent=1)
def agg(sel,label):
    s=[r for r in rows if sel(r)]
    if not s: return
    def m(key): v=[r[key] for r in s if r[key] is not None]; return np.median(v) if v else float('nan')
    print(f'{label:28s} n={len(s):2d} dE {m("dE_base"):5.2f} → {m("dE_new"):5.2f} | p90 {m("p90_base"):5.1f} → {m("p90_new"):5.1f} | EMD {m("emd_base"):.3f} → {m("emd_new"):.3f} | lodlinje {m("tilt_base"):.2f}° → {m("tilt_new"):.2f}° (lev {m("tilt_dst"):.2f}°) | brus {m("noise_base"):.2f}→{m("noise_new"):.2f} (lev {m("noise_dst"):.2f}) | kromabrus {m("cn_base"):.3f}→{m("cn_new"):.3f} (lev {m("cn_dst"):.3f}) | vägg L {m("wallL_base"):.1f}→{m("wallL_new"):.1f} (lev {m("wallL_dst"):.1f})')
agg(lambda r:r['split']=='train','träning')
agg(lambda r:r['split']=='test','test (alla)')
agg(lambda r:r['shoot']=='pilvinge-77' and r['split']=='test','test Pilvinge (7)')
agg(lambda r:r['shoot'].startswith('varmfront'),'test Varmfrontsg. (hel adress)')
for sh in ['pilvinge-77','bergstigen-105','pilottorget-3','ballonggatan-7','varmfrontsgatan-11']:
    agg(lambda r,sh=sh:r['shoot']==sh,sh)
agg(lambda r:r['ext'],'exteriörer')
agg(lambda r:not r['ext'],'interiörer')
better=sum(1 for r in rows if r['dE_new']<r['dE_base']); print('bättre ΔE:',better,'av',len(rows))
