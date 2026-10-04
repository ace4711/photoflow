import json, numpy as np, cv2, glob, os, pf
from groupstats import ext
def outdoor(im):
    h,w=im.shape[:2]
    hsv=cv2.cvtColor(np.clip(im,0,1).astype(np.float32),cv2.COLOR_RGB2HSV)  # H 0-360
    H,S,V=hsv[...,0],hsv[...,1],hsv[...,2]
    y=pf.luma(im)
    veg=(H>60)&(H<170)&(S>0.25)&(y>0.08)&(y<0.85)
    sky=(H>190)&(H<250)&(S>0.12)&(y>0.4)
    top=np.zeros_like(veg); top[:h//2]=True
    return float(veg.mean()), float((sky&top).mean())
rows=[]
for f in sorted(glob.glob(os.path.expanduser('~/PhotoFlowBenchmark/pilvinge/reg/*__ours_pre.png'))+glob.glob(os.path.expanduser('~/PhotoFlowBenchmark/shoots/reg/*__ours_pre.png'))):
    k=os.path.basename(f).replace('__ours_pre.png','').replace('__','/')
    im=cv2.cvtColor(cv2.imread(f,cv2.IMREAD_UNCHANGED),cv2.COLOR_BGR2RGB).astype(np.float32)/65535
    v,s=outdoor(cv2.resize(im,(512,341)))
    rows.append((ext(k),v,s,v+s,k))
for r in sorted(rows,key=lambda r:r[3]): print(int(r[0]),'%.3f %.3f %.3f'%r[1:4],r[4])
