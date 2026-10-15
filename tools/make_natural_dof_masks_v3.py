from __future__ import annotations
import argparse, json, os, pathlib, subprocess
import cv2, numpy as np, onnxruntime as ort
from render_bokeh import read_depth_file, read_frame_map, interpolate_depths, temporal_median, probe_video, read_exact, guided_filter_gray

def smoothstep(a,b,x):
    t=np.clip((x-a)/max(b-a,1e-6),0,1); return t*t*(3-2*t)

def u2net_alpha(sess,name,frame):
    img=cv2.resize(frame,(320,320),interpolation=cv2.INTER_AREA)
    rgb=cv2.cvtColor(img,cv2.COLOR_BGR2RGB).astype(np.float32)/255.0
    mean=np.array([.485,.456,.406],np.float32); std=np.array([.229,.224,.225],np.float32)
    x=((rgb-mean)/std).transpose(2,0,1)[None]
    y=sess.run(None,{name:x})[0][0,0]
    y=(y-y.min())/max(float(y.max()-y.min()),1e-6)
    return np.clip(cv2.resize(y,(frame.shape[1],frame.shape[0]),interpolation=cv2.INTER_CUBIC),0,1).astype(np.float32)

def warp(prev,prev_gray,gray):
    flow=cv2.calcOpticalFlowFarneback(prev_gray,gray,None,0.5,3,15,2,5,1.1,0)
    h,w=gray.shape; gx,gy=np.meshgrid(np.arange(w,dtype=np.float32),np.arange(h,dtype=np.float32))
    return cv2.remap(prev,gx-flow[...,0],gy-flow[...,1],cv2.INTER_LINEAR,borderMode=cv2.BORDER_REPLICATE)

def subject_depth(depth_low,alpha,last):
    a=cv2.resize(alpha,(depth_low.shape[1],depth_low.shape[0]),interpolation=cv2.INTER_AREA)
    core=(a>0.72)&np.isfinite(depth_low)&(depth_low>0.2)&(depth_low<8.0)
    vals=depth_low[core]
    if last is not None and vals.size:
        tight=vals[(vals>last-0.40)&(vals<last+0.40)]
        if tight.size>=120: vals=tight
    if vals.size<120:
        return last if last is not None else 1.0
    lo,hi=np.percentile(vals,[10,90]); vals=vals[(vals>=lo)&(vals<=hi)]
    measured=float(np.median(vals)) if vals.size else (last if last is not None else 1.0)
    if last is not None: measured=float(np.clip(measured,last-0.22,last+0.22))
    return measured

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('package',type=pathlib.Path); ap.add_argument('prefix',type=pathlib.Path)
    ap.add_argument('--width',type=int,default=960); ap.add_argument('--limit',type=int,default=0)
    ap.add_argument('--model', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1] / 'models' / 'u2net_human_seg.onnx')
    ap.add_argument('--segment-every',type=int,default=3)
    args=ap.parse_args(); pkg=args.package; movie=pkg/'master.mov'
    rows=[r for r in read_frame_map(pkg/'frames.jsonl') if r.get('video_appended')]
    depths=temporal_median(interpolate_depths(rows,read_depth_file(pkg/'depth.bin')),radius=1)
    sw,sh,fps,probed=probe_video(movie); ow=min(args.width,sw); oh=round(sh*ow/sw); ow-=ow%2; oh-=oh%2
    dur=float(subprocess.check_output(['ffprobe','-v','error','-show_entries','format=duration','-of','default=nw=1:nk=1',str(movie)],text=True).strip())
    count=min(len(rows),len(depths),probed or len(rows),int(round(dur*fps)))
    if args.limit>0: count=min(count,args.limit)

    so=ort.SessionOptions(); so.graph_optimization_level=ort.GraphOptimizationLevel.ORT_ENABLE_ALL; so.intra_op_num_threads=max(1,min(12,os.cpu_count() or 8))
    sess=ort.InferenceSession(str(args.model),sess_options=so,providers=['CPUExecutionProvider']); name=sess.get_inputs()[0].name
    dec=subprocess.Popen(['ffmpeg','-v','error','-noautorotate','-i',str(movie),'-map','0:v:0','-frames:v',str(count),'-vf',f'scale={ow}:{oh}:flags=area','-f','rawvideo','-pix_fmt','bgr24','pipe:1'],stdout=subprocess.PIPE)
    encs=[]
    for suffix in ('soft','mid','far','subject'):
        path=pathlib.Path(str(args.prefix)+f'_{suffix}.mkv'); path.parent.mkdir(parents=True,exist_ok=True)
        e=subprocess.Popen(['ffmpeg','-y','-v','error','-f','rawvideo','-pix_fmt','gray','-s',f'{ow}x{oh}','-r',f'{fps:.8f}','-i','pipe:0','-c:v','ffv1','-level','3','-pix_fmt','gray',str(path)],stdin=subprocess.PIPE); encs.append((path,e))

    prev_alpha=prev_gray=None; focus_ema=None; fbytes=ow*oh*3
    try:
        for i in range(count):
            raw=read_exact(dec.stdout,fbytes)
            if len(raw)!=fbytes: count=i; break
            frame=np.frombuffer(raw,np.uint8).reshape(oh,ow,3); gray=cv2.cvtColor(frame,cv2.COLOR_BGR2GRAY)
            if prev_alpha is None or i%args.segment_every==0:
                model=u2net_alpha(sess,name,frame)
                if prev_alpha is None:
                    alpha=model
                else:
                    tracked=warp(prev_alpha,prev_gray,gray)
                    alpha=np.clip(0.90*model+0.10*tracked,0,1)
            else:
                alpha=np.clip(warp(prev_alpha,prev_gray,gray),0,1)

            guide=gray.astype(np.float32)/255.0
            alpha=np.clip(guided_filter_gray(guide,alpha.astype(np.float32),5,0.004),0,1)
            alpha=cv2.GaussianBlur(alpha,(0,0),0.55)

            measured=subject_depth(depths[i],alpha,focus_ema)
            focus_ema=measured if focus_ema is None else 0.90*focus_ema+0.10*measured
            d=cv2.resize(depths[i].astype(np.float32),(ow,oh),interpolation=cv2.INTER_LINEAR); delta=d-focus_ema

            # Fuse human segmentation with real geometry: reject model false positives behind subject plane.
            depth_gate=1.0-smoothstep(0.28,0.70,delta)
            alpha*=np.clip(0.03+0.97*depth_gate,0,1)
            # Preserve only tiny local holes near the existing matte; do not grow foreground from depth alone.
            core=(alpha>0.68).astype(np.uint8); near=np.abs(delta)<0.26
            alpha=np.maximum(alpha,np.where((cv2.dilate(core,np.ones((5,5),np.uint8),iterations=1)>0)&near,0.80,0).astype(np.float32))
            alpha=np.clip(alpha,0,1)

            hard=(alpha>0.46).astype(np.uint8)
            protect=cv2.dilate((alpha*255).astype(np.uint8),np.ones((9,9),np.uint8),iterations=1)
            protect=cv2.GaussianBlur(protect,(0,0),3.2).astype(np.float32)/255.0
            outside=cv2.distanceTransform(1-hard,cv2.DIST_L2,5)
            edge_ramp=smoothstep(2.0,18.0,outside)

            safe_focus=max(focus_ema,0.12)
            safe_depth=np.maximum(d,0.12)
            bg_inv=np.maximum(0.0,(1.0/safe_focus)-(1.0/safe_depth))
            fg_inv=np.maximum(0.0,(1.0/safe_depth)-(1.0/safe_focus))
            bg_amount=smoothstep(0.24,1.55,delta)*np.clip(bg_inv*0.90,0,1)*0.56
            foreground_delta=-delta
            fg_amount=smoothstep(0.16,0.90,foreground_delta)*np.clip(fg_inv*0.58,0,1)*0.40
            amount=np.maximum(bg_amount,fg_amount)
            amount*=edge_ramp
            amount*=1.0-protect*0.997
            amount=guided_filter_gray(guide,amount.astype(np.float32),5,0.006)
            amount=cv2.GaussianBlur(amount.astype(np.float32),(0,0),1.35)
            amount=np.clip(amount,0,1)

            # Nested subtle depth layers; these drive fixed Gaussian blurs, not variable-radius warping.
            m1=smoothstep(0.015,0.16,amount)
            m2=smoothstep(0.20,0.38,amount)
            m3=smoothstep(0.42,0.62,amount)
            for arr,(_,e) in zip((m1,m2,m3,alpha),encs):
                e.stdin.write(np.clip(arr*255+0.5,0,255).astype(np.uint8).tobytes())
            prev_alpha=alpha; prev_gray=gray
            if i==0 or (i+1)%30==0 or i+1==count:
                print(f'{i+1}/{count} focus={focus_ema:.3f}m subject={alpha.mean():.3f} blur={amount.mean():.3f} max={amount.max():.3f}',flush=True)
    finally:
        if dec.stdout: dec.stdout.close(); dec.wait()
        for _,e in encs:
            if e.stdin: e.stdin.close()
            if e.wait()!=0: raise SystemExit('mask encoder failed')
    meta={'frames':count,'fps':fps,'width':ow,'height':oh,'segment_every':args.segment_every,'model':str(args.model),'method':'U2Net person matte + optical-flow tracking + RGB edge refinement + LiDAR gating + bidirectional subtle layered DOF'}
    pathlib.Path(str(args.prefix)+'_meta.json').write_text(json.dumps(meta,indent=2),'utf-8')
    print(json.dumps(meta),flush=True)
if __name__=='__main__': main()
