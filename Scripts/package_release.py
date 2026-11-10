#!/usr/bin/env python3
"""Package a signed Release app with the illustrated user guide; no notarization implied."""
from pathlib import Path
import argparse, datetime, hashlib, json, os, plistlib, re, shutil, subprocess, tempfile
ROOT=Path(__file__).resolve().parent.parent

def run(args):
    return subprocess.run([str(x) for x in args],check=True,capture_output=True,text=True).stdout

def package(app, out):
    info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    assert info['CFBundleIdentifier']=='com.qiming.mac' and info['CFBundleName']=='Qiming'
    localized_info = app / 'Contents/Resources/en.lproj/InfoPlist.strings'
    display_name = info.get('CFBundleDisplayName', info['CFBundleName'])
    if localized_info.is_file():
        display_name = run(['plutil', '-extract', 'CFBundleDisplayName', 'raw', localized_info]).strip()
    version=info['CFBundleShortVersionString']; stem=f'Qiming-{version}-macOS-arm64'
    out.mkdir(parents=True,exist_ok=True)
    targets=[out/(stem+'.dmg'),out/(stem+'-使用包.zip')]
    if any(p.exists() for p in targets): raise SystemExit('Output already exists; choose another output directory.')
    signing=subprocess.run(['codesign','-dv','--verbose=4',str(app)],check=True,capture_output=True,text=True).stderr
    authorities=[s.split('=',1)[1] for s in signing.splitlines() if s.startswith('Authority=')]
    team=next((s.split('=',1)[1] for s in signing.splitlines() if s.startswith('TeamIdentifier=')),None)
    # This workflow uses the configured local development certificate; it does not submit to Apple.
    assert any(s.startswith('Apple Development:') for s in authorities), authorities
    run(['codesign','--verify','--deep','--strict',app])
    guide=ROOT/'Documentation/使用手册'
    md=(guide/'Qiming使用手册.md').read_text()
    for ref in re.findall(r'!\[[^\]]*\]\(([^)]+)\)',md): assert (guide/ref).is_file(),ref
    with tempfile.TemporaryDirectory(prefix='.package-',suffix='.noindex',dir=out) as temp:
        stage=Path(temp)/'Qiming使用包'; stage.mkdir()
        run(['/usr/bin/ditto',app,stage/'Qiming.app'])
        shutil.copytree(guide,stage/'使用手册')
        os.symlink('/Applications',stage/'Applications')
        (stage/'先读我.md').write_text(f'''# {display_name} 使用包\n\nDMG：将 Qiming.app 拖到 Applications，然后推出映像并从应用程序启动。\nZIP：解压后将 Qiming.app 放入应用程序。\n\n详细操作请阅读 [使用手册](使用手册/Qiming使用手册.md)，保留 assets 插图目录。\n\n更新前先结束会话、确认恢复并退出旧版。首次使用按提示批准后台辅助组件。\n\n本包为 Apple Development 签名的 Release 本机使用包，未做 Developer ID 分发签名或 Apple 公证；跨设备可用性和完整合盖实机行为尚未验收。不要将它视为已经公证的公开发行版。\n''')
        report={'version':version,'build':info['CFBundleVersion'],'architecture':'arm64','minimum_macos':info['LSMinimumSystemVersion'],'configuration':'Release','signing_authorities':authorities,'team_identifier':team,'strict_signature_verified':True,'notarized':False,'distribution_status':'Local Apple Development signed usage package; not a notarized public release','physical_lid_validation':'Not completed; see manual','guide_image_count':len(re.findall(r'!\[',md)), 'rule_tests':json.loads((guide/'测试结果.json').read_text())}
        notes=f'# {display_name} 发布说明\n\n版本：'+version+'\n\n- Apple Silicon / macOS '+info['LSMinimumSystemVersion']+'+。\n- Release 主程序及内嵌辅助组件已通过严格签名验证。\n- 签名类型：Apple Development；未做 Developer ID 分发签名、公证或跨设备安装验收。\n- 包含完整 Markdown 使用手册、PNG 插图和 SVG 源图。\n- 菜单栏左键单击即时展开／收起；右键无会话时开启策略 2，有会话时结束。\n- 面板开关、策略内容与高度采用轻量过渡，遵循减少动态效果设置。\n- 首次使用需要系统批准辅助组件。\n- 物理合盖显示、长期无人值守及全局睡眠设置竞争场景仍有验收缺口，详见手册。\n'
        (stage/'发布说明.md').write_text(notes)
        (stage/'验证信息.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
        run(['codesign','--verify','--deep','--strict',stage/'Qiming.app'])
        run(['/usr/bin/ditto','-c','-k','--sequesterRsrc','--keepParent',stage,targets[1]])
        run(['hdiutil','create','-quiet','-volname',f'{display_name} {version}','-srcfolder',stage,'-format','UDZO',targets[0]])
        run(['hdiutil','verify',targets[0]])
        # Verify an extracted usage package, including the signature and referenced images.
        extracted=Path(temp)/'verify'; extracted.mkdir()
        run(['/usr/bin/ditto','-x','-k',targets[1],extracted])
        restored=extracted/stage.name
        run(['codesign','--verify','--deep','--strict',restored/'Qiming.app'])
        assert (restored/'使用手册/Qiming使用手册.md').read_text()==md
        for ref in re.findall(r'!\[[^\]]*\]\(([^)]+)\)',md):
            assert (restored/'使用手册'/ref).read_bytes()==(guide/ref).read_bytes()
    report['artifacts']=[{'name':p.name,'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in targets]
    (out/'打包验证.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    (out/'SHA256SUMS.txt').write_text(''.join(f"{a['sha256']}  {a['name']}\n" for a in report['artifacts']))
    for artifact in report['artifacts']:
        print(f"{artifact['name']}: {artifact['bytes']:,} bytes")

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app',type=Path)
    parser.add_argument('--output',type=Path,default=ROOT/'dist')
    parser.add_argument('--refresh', action='store_true', help='Replace the generated contents of the latest-package folder.')
    args=parser.parse_args()
    app, out = args.app.resolve(), args.output.resolve()
    if not args.refresh:
        package(app, out)
        return
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.refresh-', suffix='.noindex', dir=out.parent) as temp:
        staging = Path(temp)
        package(app, staging)
        filenames = {path.name for path in staging.iterdir()}
        for name in sorted(filenames):
            os.replace(staging / name, out / name)
        for path in out.iterdir():
            if path.name not in filenames and re.fullmatch(r'Qiming-[\w.+-]+-macOS-arm64(?:\.dmg|-使用包\.zip)', path.name) and path.is_file():
                path.unlink()
    print(f'Latest installation packages: {out}')

if __name__=='__main__': main()
