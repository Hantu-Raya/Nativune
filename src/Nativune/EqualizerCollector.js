(async () => {
    'use strict';
    if (globalThis.__nativuneEqCollect) return { installed: true };
    const graph = globalThis.__nativuneEq?.__graph();
    if (!graph?.source || !graph.ctx) throw new Error('EQ graph is not attached');
    const { ctx, source, filters, preamp } = graph;
    const frequencies = [31.5,63,125,250,500,1000,2000,4000,8000,16000,45,90,180,375,750,1500,3000,6000,12000];
    // Worklet retains only recurrence/energy statistics, never PCM or sample arrays.
    const worklet = `class EqStatistics extends AudioWorkletProcessor {
      constructor() { super(); this.port.onmessage=e=>this.reset(e.data); this.reset({}); }
      reset(o) {
        this.id=o.id||0; this.freq=o.frequencies||[63];
        this.skip=Math.round(sampleRate*(o.settle??0.35)); this.n=Math.round(sampleRate*(o.seconds??4));
        this.at=0; this.energy=[0,0]; this.wetEnergy=[0,0]; this.wetPeak=[0,0];
        this.nullEnergy=[0,0]; this.click=0; this.previous=[[0,0],[0,0]];
        this.coeff=this.freq.map(f=>2*Math.cos(2*Math.PI*f/sampleRate));
        this.s=Array.from({length:4},()=>this.freq.map(()=>[0,0])); this.done=false;
      }
      process(inputs) {
        if(this.done) return true;
        const a=inputs[0], b=inputs[1];
        if(!a?.[0] || !b?.[0]) return true;
        for(let i=0;i<a[0].length;i++) {
          if(this.skip>0){this.skip--;continue;}
          const weight=0.5-0.5*Math.cos(2*Math.PI*this.at/(this.n-1));
          for(let ch=0;ch<2;ch++) {
            const dry=(a[ch]||a[0])[i], wet=(b[ch]||b[0])[i], diff=wet-dry;
            this.energy[ch]+=dry*dry; this.nullEnergy[ch]+=diff*diff;
            this.wetEnergy[ch]+=wet*wet; this.wetPeak[ch]=Math.max(this.wetPeak[ch],Math.abs(wet));
            const p=this.previous[ch]; this.click=Math.max(this.click,Math.abs(diff-2*p[0]+p[1]));
            p[1]=p[0];p[0]=diff;
            for(let k=0;k<this.freq.length;k++) for(let path=0;path<2;path++) {
              const s=this.s[path*2+ch][k], v=(path?wet:dry)*weight+this.coeff[k]*s[0]-s[1];
              s[1]=s[0];s[0]=v;
            }
          }
          if(++this.at>=this.n) {
            const mag=this.s.map(row=>row.map((s,k)=>Math.sqrt(Math.max(0,s[0]*s[0]+s[1]*s[1]-this.coeff[k]*s[0]*s[1]))));
            this.port.postMessage({id:this.id,complete:true,frames:this.at,sampleRate,frequencies:this.freq,
              dry:mag.slice(0,2),wet:mag.slice(2),dryRms:this.energy.map(x=>Math.sqrt(x/this.n)),
              wetRms:this.wetEnergy.map(x=>Math.sqrt(x/this.n)),wetPeak:this.wetPeak,
              nullDb:this.nullEnergy.map((x,ch)=>10*Math.log10(Math.max(1e-30,x)/Math.max(1e-30,this.energy[ch]))),
              clickRatio:this.click/Math.max(1e-15,...this.energy.map(x=>Math.sqrt(x/this.n)))});
            this.done=true;break;
          }
        }
        return true;
      }
    }; registerProcessor('nativune-eq-statistics',EqStatistics);`;
    const url = URL.createObjectURL(new Blob([worklet], { type:'text/javascript' }));
    try { await ctx.audioWorklet.addModule(url); } finally { URL.revokeObjectURL(url); }
    const collector = new AudioWorkletNode(ctx, 'nativune-eq-statistics', {
        numberOfInputs:2, numberOfOutputs:1, outputChannelCount:[2], channelCount:2, channelCountMode:'explicit'
    });
    const sink = ctx.createGain(); sink.gain.value = 0;
    collector.connect(sink); sink.connect(ctx.destination);
    source.connect(collector,0,0); preamp.connect(collector,0,1);
    let id=0, result={complete:false}, mode='none';
    collector.port.onmessage=e=>{if(e.data.id===id)result=e.data;};
    const originalTargets = new Map([preamp.gain,...filters.map(f=>f.gain)].map(p=>[p,p.setTargetAtTime]));
    function mutant(name) {
        if(!['none','parallel','zero-ramp','preamp-ignored','duplicate-path'].includes(name)) throw new Error('mutant');
        for(const [p,fn] of originalTargets) p.setTargetAtTime=fn;
        source.disconnect(); filters.forEach(f=>f.disconnect());
        source.connect(filters[0]); filters.forEach((f,i)=>f.connect(filters[i+1]||preamp));
        source.connect(collector,0,0);
        if(name==='parallel') {
            source.disconnect(filters[0]); filters.forEach(f=>f.disconnect());
            filters.forEach(f=>{source.connect(f);f.connect(preamp);});
        } else if(name==='duplicate-path') source.connect(preamp);
        else if(name==='zero-ramp') for(const [p] of originalTargets)
            p.setTargetAtTime=function(value,time){this.cancelScheduledValues(time);this.setValueAtTime(value,time);return this;};
        else if(name==='preamp-ignored') {
            preamp.gain.cancelScheduledValues(ctx.currentTime); preamp.gain.setValueAtTime(1,ctx.currentTime);
            preamp.gain.setTargetAtTime=function(_value,time){this.setValueAtTime(1,time);return this;};
        }
        mode=name;return {mutant:mode};
    }
    function reset(options={}) {
        const fs=options.frequencies||frequencies, seconds=options.seconds??4, settle=options.settle??0.35;
        if(!Array.isArray(fs)||fs.length<1||fs.length>64||fs.some(f=>!Number.isFinite(f)||f<=0||f>=ctx.sampleRate/2)||
            !Number.isFinite(seconds)||seconds<0.1||seconds>10||!Number.isFinite(settle)||settle<0||settle>3)throw new Error('collection bounds');
        result={complete:false,id:++id}; collector.port.postMessage({id,frequencies:fs,seconds,settle});
        return {reset:true,id,sampleRate:ctx.sampleRate};
    }
    function read() {
        const fs=result.frequencies||frequencies, hz=new Float32Array(fs), mag=new Float32Array(fs.length), phase=new Float32Array(fs.length);
        const response=fs.map(()=>20*Math.log10(Math.max(1e-30,preamp.gain.value)));
        filters.forEach(f=>{f.getFrequencyResponse(hz,mag,phase);mag.forEach((m,i)=>response[i]+=20*Math.log10(Math.max(1e-30,m)));});
        return {...result,frequencyResponseDb:response,mutant:mode,contextState:ctx.state};
    }
    globalThis.__nativuneEqCollect={read,reset,mutant};
    return {installed:true};
})();
