"""UE 5.7.4 shader-task adapter for Dead as Disco CL-35029 base passes."""
from pathlib import Path
import argparse
import ctypes
import hashlib
import json
import os
import re
import struct

DLL = os.environ.get('LIMELIGHT_SHADER_OODLE')
OLD_HASH, NEW_HASH = 0x68f69cf4, 0x677b9998
LAYOUTS = {
    'TranslucentBasePass': (OLD_HASH, NEW_HASH, 'translucent-layout.json'),
    'OpaqueBasePass': (0x04a8df25, 0x1ec0cb1d, 'opaque-layout.json'),
}
NEW_RESOURCES = [(f'Shared_LightFunctionAtlas_SunGoboTexture{i}', 5, 352+i*8) for i in range(4)] + [('Shared_LightFunctionAtlas_SunGoboSampler', 8, 384)]

class Oodle:
    def __init__(self):
        if not DLL or not Path(DLL).is_file():
            raise RuntimeError('The cook must supply the current engine Oodle library.')
        self.dll=ctypes.WinDLL(DLL)
        self.decode=self.dll.OodleLZ_Decompress
        self.decode.argtypes=[ctypes.c_void_p,ctypes.c_ssize_t,ctypes.c_void_p,ctypes.c_ssize_t,ctypes.c_int,ctypes.c_int,ctypes.c_int,ctypes.c_void_p,ctypes.c_ssize_t,ctypes.c_void_p,ctypes.c_void_p,ctypes.c_void_p,ctypes.c_ssize_t,ctypes.c_int]
        self.decode.restype=ctypes.c_ssize_t
        self.bound=self.dll.OodleLZ_GetCompressedBufferSizeNeeded
        self.bound.argtypes=[ctypes.c_int,ctypes.c_ssize_t];self.bound.restype=ctypes.c_ssize_t
        self.encode=self.dll.OodleLZ_Compress
        self.encode.argtypes=[ctypes.c_int,ctypes.c_void_p,ctypes.c_ssize_t,ctypes.c_void_p,ctypes.c_int,ctypes.c_void_p,ctypes.c_void_p,ctypes.c_void_p,ctypes.c_void_p,ctypes.c_ssize_t]
        self.encode.restype=ctypes.c_ssize_t
    def decompress(self,raw,size):
        assert 0<size<512*1024*1024
        source=ctypes.create_string_buffer(raw);target=ctypes.create_string_buffer(size)
        assert self.decode(source,len(raw),target,size,1,0,0,None,0,None,None,None,0,3)==size
        return target.raw
    def compress(self,raw):
        source=ctypes.create_string_buffer(raw);target=ctypes.create_string_buffer(self.bound(8,len(raw)))
        size=self.encode(8,source,len(raw),target,3,None,None,None,None,0)
        assert 0<size<=len(target)
        return target.raw[:size]

class Reader:
    def __init__(self,data):self.data=data;self.pos=0
    def read(self,fmt):
        size=struct.calcsize('<'+fmt);assert self.pos+size<=len(self.data)
        values=struct.unpack_from('<'+fmt,self.data,self.pos);self.pos+=size
        return values[0] if len(values)==1 else values
    def count(self,maximum=1000000):
        value=self.read('i');assert 0<=value<=maximum;return value
    def take(self,size):
        assert 0<=size<=len(self.data)-self.pos
        raw=self.data[self.pos:self.pos+size];self.pos+=size;return raw
    def string(self):
        count=self.read('i');assert abs(count)<16*1024*1024
        return self.take(count if count>=0 else -count*2).decode('ascii' if count>=0 else 'utf-16-le').rstrip('\0')
    def strings(self):return [self.string() for _ in range(self.count())]

def pack_string(text):
    try:raw=text.encode('ascii')+b'\0';return struct.pack('<i',len(raw))+raw
    except UnicodeEncodeError:
        raw=(text+'\0').encode('utf-16-le');return struct.pack('<i',-len(raw)//2)+raw

def read_environment(r):
    for _ in range(r.count()):
        r.string();kind=r.read('B');assert kind<5
        r.string() if kind==4 else r.read('I')
    r.read('Q')
    for _ in range(r.count()):r.read('IB')
    resource_start=r.pos
    resources=[{'prefix':r.read('B'),'type':r.read('B'),'index':r.read('H')} for _ in range(r.count())]
    resource_end=r.pos
    buffers={};names=[]
    for _ in range(r.count()):
        key,slot=r.string(),r.string();member_start=r.pos
        count=r.count();raw_names=r.take(count*2);member_end=r.pos
        members=raw_names.decode('utf-16-le').rstrip('\0').split('\0') if count else []
        assert all(name.startswith(key+'_') for name in members)
        hash_offset=r.pos;layout_hash,flags,usage=r.read('IBB')
        buffers[key]={'names':members,'hash':layout_hash,'memberStart':member_start,'memberEnd':member_end,'hashOffset':hash_offset}
        names.extend(members)
    assert len(resources)==len(names)
    for resource,name in zip(resources,names):resource['name']=name
    r.read('IBI')
    for _ in range(8):r.string();r.read('I')
    r.read('I')
    return {'resourceStart':resource_start,'resourceEnd':resource_end,'resources':resources,'buffers':buffers}

def read_metadata(r):
    for _ in range(r.count(10000)):
        r.string();r.string();r.string();r.read('B');r.string();r.read('II')
        for _ in range(r.count(100000)):
            r.string();r.string();r.read('IIBBIIIi')

def read_input(r):
    frequency,platform=r.read('II')
    names=[r.string() for _ in range(7)]
    r.read('I');r.strings()
    root_start=r.pos;r.string();root_end=r.pos
    path_start=r.pos;r.string();path_end=r.pos
    r.read('B');r.string();group=r.string();r.string();r.take(32)
    environment=read_environment(r)
    r.read('I');r.string();r.read('B');r.string();r.read('III')
    r.read('BBIII')
    return {'frequency':frequency,'platform':platform,'format':names[0],'virtualPath':names[4],'shaderType':names[6],'group':group,'environment':environment,'debugRoot':(root_start,root_end),'debugPath':(path_start,path_end)}

def read_preprocess(r,oodle):
    r.read('II')
    for _ in range(r.count()):
        for _ in range(5):r.string()
    r.strings()
    source_start=r.pos;char_count=r.count(128*1024*1024)
    raw=r.take(r.count(128*1024*1024));source_end=r.pos
    decoded=oodle.decompress(raw,char_count) if char_count else raw
    for _ in range(r.count()):r.read('I');r.string()
    return {'start':source_start,'end':source_end,'source':decoded.rstrip(b'\0').decode('latin1')}

def read_job(r,oodle):
    job=read_input(r);job['preprocess']=[read_preprocess(r,oodle)]
    if r.read('I'):job['preprocess'].append(read_preprocess(r,oodle))
    job['sharedEnvironment'],job['rootMetadata']=r.read('ii')
    return job

def patch_source(source,buffer_name='TranslucentBasePass'):
    match=re.search(r'\bcbuffer\s+'+re.escape(buffer_name)+r'\s*\{',source)
    if not match:return None
    end=re.search(r'\}\s*;',source[match.end():]);assert end
    stop=match.end()+end.end();body=source[match.start():stop]
    body=body.replace(buffer_name,'TranslucentBasePass')
    assert 'SunGobo' not in body
    assert re.search(r'\bfloat\s+TranslucentBasePass_Shared_LightFunctionAtlas_Slot_UVSize\s*;',body)
    body=re.sub(r'TranslucentBasePass_Padding(\d+)',lambda m:'TranslucentBasePass_Padding'+str(int(m[1])+368 if int(m[1])>=1696 else int(m[1])),body)
    fields=['uint TranslucentBasePass_Shared_LightFunctionAtlas_SunGoboCount;','float4 TranslucentBasePass_Shared_LightFunctionAtlas_SunGoboData[20];']
    for name,kind,offset in NEW_RESOURCES:
        prefix='BindlessSampler_' if kind==8 else 'BindlessSRV_'
        fields += [f'uint {prefix}TranslucentBasePass_{name};',f'uint TranslucentBasePass_Padding{1664+offset+4};']
    fields += ['float TranslucentBasePass_Padding2056;','float TranslucentBasePass_Padding2060;']
    body,count=re.subn(r'\bfloat\s+TranslucentBasePass_Padding1692\s*;','\n'.join(fields),body)
    assert count==1
    body=body.replace('TranslucentBasePass',buffer_name)
    return source[:match.start()]+body+source[stop:]

def patch_environment(env,buffer_name='TranslucentBasePass'):
    return patch_environments(env,[buffer_name])

def patch_environments(env,buffer_names):
    edits=[]
    for buffer_name in buffer_names:
        edits += patch_buffer_members(env,buffer_name)
    rows=[];inserted=set()
    for row in env['resources']:
        item=dict(row)
        for buffer_name in buffer_names:
            if not row['name'].startswith(buffer_name+'_') or row['index']<33:continue
            if buffer_name not in inserted:
                assert row['index']==33
                rows += [{'prefix':row['prefix'],'type':kind,'index':33+i} for i,(_,kind,_) in enumerate(NEW_RESOURCES)]
                inserted.add(buffer_name)
            item['index']+=5
        rows.append(item)
    assert inserted==set(buffer_names)
    encoded=struct.pack('<i',len(rows))+b''.join(struct.pack('<BBH',row['prefix'],row['type'],row['index']) for row in rows)
    return [(env['resourceStart'],env['resourceEnd'],encoded)]+edits

def patch_buffer_members(env,buffer_name):
    old_hash,new_hash,manifest=LAYOUTS[buffer_name]
    buffer=env['buffers'][buffer_name];assert buffer['hash']==old_hash, 'Unknown '+buffer_name+' layout hash'
    names=buffer['names']
    expected=json.loads(Path(__file__).with_name(manifest).read_text())
    assert names==[row['name'] for row in expected], 'Unexpected '+buffer_name+' resource names'
    actual=[row for row in env['resources'] if row['name'].startswith(buffer_name+'_')]
    assert [{key:row[key] for key in ('name','type','index')} for row in actual]==expected, 'Unexpected '+buffer_name+' resource types or indices'
    assert names[32]==buffer_name+'_Shared_LightFunctionAtlas_LightFunctionAtlasSampler'
    new_names=names[:33]+[buffer_name+'_'+name for name,_,_ in NEW_RESOURCES]+names[33:]
    name_bytes=('\0'.join(new_names)+'\0').encode('utf-16-le')
    return [(buffer['memberStart'],buffer['memberEnd'],struct.pack('<i',len(name_bytes)//2)+name_bytes),(buffer['hashOffset'],buffer['hashOffset']+4,struct.pack('<I',new_hash))]

def adapt(raw,embed_source=None,diagnostic_dir=None,enable_patch=True):
    oodle=Oodle();header=Reader(raw)
    assert header.read('I')==32,'Unexpected SCW protocol version'
    compression=header.string()
    if compression=='Oodle':
        size=header.count(512*1024*1024);compressed=header.take(header.count(512*1024*1024))
        assert header.pos==len(raw)
        data=oodle.decompress(compressed,size)
    else:
        assert compression=='None';data=header.take(len(raw)-header.pos)
        # I check the live format versions before normalizing its implicit FNames.
        versions=json.loads(Path(__file__).with_name('format-versions.json').read_text())
        live=Reader(data);count=live.count(128)
        values=[live.read('I') for _ in range(count)]
        assert values==[value for name,value in versions], 'Shader format versions changed'
        named=struct.pack('<i',count)+b''.join(pack_string(name)+struct.pack('<I',value) for name,value in versions)
        data=named+data[live.pos:]
    r=Reader(data)
    for _ in range(r.count()):r.string();r.read('I')
    shared=[read_environment(r) for _ in range(r.count())]
    read_metadata(r)
    assert r.read('I')==ord('S')
    jobs=[read_job(r,oodle) for _ in range(r.count())]
    assert r.read('I')==ord('P')
    for _ in range(r.count()):
        r.string();jobs += [read_job(r,oodle) for _ in range(r.count())]
    assert r.pos==len(data),(r.pos,len(data))
    if embed_source is not None:assert len(jobs)==1
    edits=[];changed=[];pending_environments={}
    for job in jobs:
        if diagnostic_dir is not None:
            for start,end in [job['debugRoot'],job['debugPath']]:edits.append((start,end,pack_string(str(diagnostic_dir).replace('\\','/'))))
        eligible=job['format'] in ('PCD3D_SM6','PCD3D_SM5')
        patched_sources=[];patched_buffers=set()
        for pre in job['preprocess']:
            text=embed_source if embed_source is not None else pre['source']
            source_changed=False
            if enable_patch and eligible:
                for buffer_name in LAYOUTS:
                    corrected=patch_source(text,buffer_name)
                    if corrected is not None:
                        text=corrected;source_changed=True;patched_buffers.add(buffer_name)
            if source_changed:patched_sources.append(hashlib.sha256(text.encode('latin1')).hexdigest())
            if source_changed or embed_source is not None:
                source_bytes=text.encode('latin1')+b'\0'*15
                edits.append((pre['start'],pre['end'],struct.pack('<ii',0,len(source_bytes))+source_bytes))
        if patched_sources:
            assert job['rootMetadata']==-1,'Refusing to patch a shader using root metadata'
            assert job['format'] in ('PCD3D_SM6','PCD3D_SM5')
            assert len(patched_buffers)==1,'Refusing a shader with multiple base-pass layouts'
            buffer_name=next(iter(patched_buffers))
            env=job['environment']
            if buffer_name not in env['buffers']:
                index=job['sharedEnvironment'];assert index>=0;env=shared[index]
            key=env['resourceStart']
            if key not in pending_environments:pending_environments[key]=(env,set())
            pending_environments[key][1].add(buffer_name)
            changed.append({'group':job['group'],'shaderType':job['shaderType'],'format':job['format'],'frequency':job['frequency'],'buffer':buffer_name,'expectedLayoutHash':hex(LAYOUTS[buffer_name][1]),'sourceHashes':patched_sources,'inputHashPreserved':True})
    for env,buffer_names in pending_environments.values():edits += patch_environments(env,sorted(buffer_names))
    edits.sort(key=lambda e:e[0]);assert all(a[1]<=b[0] for a,b in zip(edits,edits[1:]))
    if not edits:return raw,{'jobs':len(jobs),'patched':[],'passThrough':True}
    for start,end,replacement in reversed(edits):data=data[:start]+replacement+data[end:]
    compressed=oodle.compress(data)
    output=struct.pack('<I',32)+pack_string('Oodle')+struct.pack('<ii',len(data),len(compressed))+compressed
    return output,{'jobs':len(jobs),'patched':changed,'passThrough':False}

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('input',type=Path);parser.add_argument('output',type=Path);parser.add_argument('report',type=Path)
    parser.add_argument('--embed-debug-source',type=Path);parser.add_argument('--diagnostic-dir',type=Path);parser.add_argument('--no-patch',action='store_true')
    args=parser.parse_args()
    source=args.embed_debug_source.read_text(encoding='utf-8-sig') if args.embed_debug_source else None
    output,report=adapt(args.input.read_bytes(),source,args.diagnostic_dir,not args.no_patch)
    args.output.write_bytes(output);args.report.write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps({'jobs':report['jobs'],'patched':len(report['patched']),'passThrough':report['passThrough']}))

if __name__=='__main__':main()
