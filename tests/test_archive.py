from pathlib import Path
import zipfile,stat,subprocess,tempfile,sys
exe=Path(sys.argv[1]).resolve()
temporary=tempfile.TemporaryDirectory(prefix='archivehere-tests-')
base=Path(temporary.name)
def test(name,entries,ok):
 d=base/name;d.mkdir(exist_ok=True);z=d/'test.zip'
 with zipfile.ZipFile(z,'w') as f:
  for path,value,link in entries:
   i=zipfile.ZipInfo(path);i.create_system=3;i.external_attr=((stat.S_IFLNK|0o777) if link else (stat.S_IFREG|0o644))<<16
   f.writestr(i,value)
 r=subprocess.run([str(exe),'--extract',str(z)],capture_output=True,text=True)
 assert (r.returncode==0)==ok,(name,r.stdout,r.stderr)
 print('PASS',name, 'accepted' if ok else 'rejected')
test('normal',[('文档.txt','中文',False)],True)
test('internal-parent-link',[('App/Versions/1/file','abc',False),('App/Versions/Current','1',True),('App/file','Versions/Current/file',True),('App/Versions/1/link','../Current/file',True)],True)
test('relocated-root-link',[('App/link','..',True)],False)
test('absolute-link',[('link','/etc/passwd',True)],False)
test('escape-link',[('App/link','../../outside',True)],False)
test('traversal',[('../outside','bad',False)],False)
test('write-through-link',[('real/file','abc',False),('alias','real',True),('alias/evil','bad',False)],False)
test('cycle',[('a','b',True),('b','a',True)],False)
test('dangling',[('a','missing',True)],False)
# A .. segment after following a symlink can escape despite a lexical check.
test('chain-escape',[('a','.',True),('b/link','../a/../outside',True)],False)
# A symlink pointing into a different top-level item changes meaning when
# publishing a lone symlink only; require at least one regular target.
assert not (base/'outside').exists()
print('All archive regression tests passed')
