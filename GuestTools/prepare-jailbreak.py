"""Reproducible Cydia payload, excluding real-device untether exploits."""
import io, json, tarfile, urllib.request, hashlib, zipfile
from pathlib import Path
commit='33dcbfcf4d8791268292e1009e2955e3f02b4785'
url=f'https://raw.githubusercontent.com/LukeZGD/Legacy-iOS-Kit/{commit}/resources/jailbreak/freeze.tar.gz'
data=urllib.request.urlopen(url).read()
assert hashlib.sha256(data).hexdigest()=='15ed578226ffe74371ff7c3d2665a99f181c5597ed1aee5d95a9ef5da17a836f'
out=Path(__file__).resolve().parent.parent/'Podium/Resources/GuestTools/cydia-bootstrap.zip'
manifest=[]
with tarfile.open(fileobj=io.BytesIO(data),mode='r:gz') as tar, zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED) as z:
    for m in tar.getmembers():
        name=m.name.removeprefix('./').strip('/')
        if not name: continue
        if any(p in ('..','') for p in name.split('/')): raise ValueError(name)
        # /var and /etc are existing iOS aliases; never replace them.
        if name in ('var','etc','tmp'): continue
        for alias in ('var','etc','tmp'):
            if name.startswith(alias+'/'): name='private/'+name
        path='/'+name
        item={'path':path,'mode':m.mode,'uid':m.uid,'gid':m.gid}
        if m.isdir(): item['type']='directory'
        elif m.issym(): item.update(type='symlink',target=m.linkname)
        elif m.isfile() or m.islnk():
            item['type']='file'; z.writestr(name,tar.extractfile(m).read())
        else: raise ValueError('Unsupported bootstrap member '+m.name)
        manifest.append(item)
    z.writestr('manifest.json',json.dumps(manifest))
    z.writestr('ORIGIN.txt',f'{url}\nSHA256 {hashlib.sha256(data).hexdigest()}\nCydia: https://git.saurik.com/cydia.git\nAPT/dpkg and other dependencies retain their included copyright/license files.\n')
print(out, out.stat().st_size, hashlib.sha256(data).hexdigest())
