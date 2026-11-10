#!/usr/bin/env python3
"""Generate a dependency-free, conventional Xcode project; no generator needed to open it."""
from pathlib import Path
import hashlib
import plistlib
ROOT = Path(__file__).resolve().parent.parent

def uid(s): return hashlib.sha1(s.encode()).hexdigest()[:24].upper()
def q(s): return '"' + str(s).replace('\\', '\\\\').replace('"', '\\"') + '"'
objects = {}
def add(key, value): objects[uid(key)] = value; return uid(key)
def ref(k): return uid(k)
def arr(values): return '(' + ', '.join(values) + ', )' if values else '()'
files = sorted(str(p.relative_to(ROOT)) for folder in ['Qiming', 'Shared', 'QimingHelper', 'QimingTests'] for p in (ROOT / folder).rglob('*.swift'))
app_resources = ['Qiming/Resources/Localizable.xcstrings', 'Qiming/Resources/InfoPlist.xcstrings', 'Qiming/Resources/AppIcon.icon']
files += app_resources + ['Config/com.qiming.mac.helper.plist', 'Config/Info.plist', 'Config/Signing.xcconfig']
for path in files:
    typ = 'sourcecode.swift' if path.endswith('.swift') else 'text.json.xcstrings' if path.endswith('.xcstrings') else 'folder.iconcomposer' if path.endswith('.icon') else 'text.xcconfig' if path.endswith('.xcconfig') else 'text.plist.xml'
    add('file:'+path, '{isa = PBXFileReference; lastKnownFileType = '+typ+'; path = '+q(path)+'; name = '+q(Path(path).name)+'; sourceTree = SOURCE_ROOT; }')
products = [('Qiming','wrapper.application','Qiming.app'),('QimingHelper','compiled.mach-o.executable','QimingHelper'),('QimingTests','wrapper.cfbundle','QimingTests.xctest')]
for name,typ,path in products: add('product:'+name, '{isa = PBXFileReference; explicitFileType = '+typ+'; includeInIndex = 0; path = '+q(path)+'; sourceTree = BUILT_PRODUCTS_DIR; }')
add('products','{isa = PBXGroup; children = '+arr([ref('product:'+n) for n,_,_ in products])+'; name = Products; sourceTree = "<group>"; }')
for folder in ['Qiming', 'Shared', 'QimingHelper', 'QimingTests', 'Config']:
    add('group:'+folder, '{isa = PBXGroup; children = '+arr([ref('file:'+f) for f in files if f.startswith(folder+'/')])+'; name = '+q(folder)+'; sourceTree = "<group>"; }')
add('main','{isa = PBXGroup; children = '+arr([ref('group:'+f) for f in ['Qiming', 'Shared', 'QimingHelper', 'QimingTests', 'Config']]+[ref('products')])+'; sourceTree = "<group>"; }')
common = {'SDKROOT':'macosx','MACOSX_DEPLOYMENT_TARGET':'14.0','ARCHS':'arm64','SWIFT_VERSION':'6.0','SWIFT_STRICT_CONCURRENCY':'complete','CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES','ENABLE_HARDENED_RUNTIME':'YES','CODE_SIGN_STYLE':'Automatic','DEAD_CODE_STRIPPING':'YES','SWIFT_EMIT_LOC_STRINGS':'NO','LOCALIZATION_PREFERS_STRING_CATALOGS':'YES','CURRENT_PROJECT_VERSION':'1','MARKETING_VERSION':'0.1.0'}

def config_list(key, extra):
    ids=[]
    for mode in ['Debug','Release']:
        settings=common | {'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if mode=='Debug' else '-Osize','DEBUG_INFORMATION_FORMAT':'dwarf' if mode=='Debug' else 'dwarf-with-dsym','ENABLE_TESTABILITY':'YES' if mode=='Debug' else 'NO','ONLY_ACTIVE_ARCH':'YES','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG' if mode=='Debug' else ''} | extra
        if key == 'Qiming':
            settings['PRODUCT_NAME'] = 'Qiming Dev' if mode == 'Debug' else 'Qiming'
            settings['PRODUCT_MODULE_NAME'] = 'Qiming'
        ids.append(add(key+mode,'{isa = XCBuildConfiguration; baseConfigurationReference = '+ref('file:Config/Signing.xcconfig')+'; buildSettings = {'+' '.join(k+' = '+q(v)+';' for k,v in settings.items())+'}; name = '+mode+'; }'))
    return add('configs:'+key,'{isa = XCConfigurationList; buildConfigurations = '+arr(ids)+'; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }')
config_list('project',{})
for name,_,_ in products:
    paths = [f for f in files if f.endswith('.swift') and ((name=='Qiming' and (f.startswith('Qiming/') or f.startswith('Shared/'))) or (name=='QimingHelper' and (f.startswith('QimingHelper/') or f.startswith('Shared/'))) or (name=='QimingTests' and (f.startswith('QimingTests/') or f.startswith('Shared/') or f=='QimingHelper/HelperService.swift')))]
    builds=[]
    for f in paths:
        builds.append(add('build:'+name+f,'{isa = PBXBuildFile; fileRef = '+ref('file:'+f)+'; }'))
    phases=[add('sources:'+name,'{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = '+arr(builds)+'; runOnlyForDeploymentPostprocessing = 0; }')]
    resources=[]
    if name=='Qiming':
        for key, path in zip(('strings', 'infoStrings', 'icon'), app_resources):
            resources.append(add(key, '{isa = PBXBuildFile; fileRef = '+ref('file:'+path)+'; }'))
    phases.append(add('resources:'+name,'{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = '+arr(resources)+'; runOnlyForDeploymentPostprocessing = 0; }'))
    deps=[]
    if name=='Qiming':
        add('embedHelper','{isa = PBXBuildFile; fileRef = '+ref('product:QimingHelper')+'; settings = {ATTRIBUTES = (CodeSignOnCopy, ); }; }')
        phases.append(add('copyHelper','{isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = Contents/Library/HelperTools; dstSubfolderSpec = 1; files = ('+ref('embedHelper')+', ); name = "Embed power helper"; runOnlyForDeploymentPostprocessing = 0; }'))
        add('embedPlist','{isa = PBXBuildFile; fileRef = '+ref('file:Config/com.qiming.mac.helper.plist')+'; }')
        phases.append(add('copyPlist','{isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = Contents/Library/LaunchDaemons; dstSubfolderSpec = 1; files = ('+ref('embedPlist')+', ); name = "Embed launch daemon configuration"; runOnlyForDeploymentPostprocessing = 0; }'))
        proxy=add('proxy','{isa = PBXContainerItemProxy; containerPortal = '+ref('project')+'; proxyType = 1; remoteGlobalIDString = '+ref('target:QimingHelper')+'; remoteInfo = QimingHelper; }')
        deps.append(add('dependency','{isa = PBXTargetDependency; target = '+ref('target:QimingHelper')+'; targetProxy = '+proxy+'; }'))
    extra={'PRODUCT_NAME':name,'PRODUCT_BUNDLE_IDENTIFIER':{'Qiming':'com.qiming.mac','QimingHelper':'com.qiming.mac.helper','QimingTests':'com.qiming.mac.tests'}[name]}
    if name=='Qiming': extra |= {'INFOPLIST_FILE':'Config/Info.plist','GENERATE_INFOPLIST_FILE':'NO','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/../Frameworks','ENABLE_APP_SANDBOX':'NO','ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon'}
    elif name=='QimingHelper': extra |= {'SKIP_INSTALL':'YES','ENABLE_APP_SANDBOX':'NO','CREATE_INFOPLIST_SECTION_IN_BINARY':'YES','INFOPLIST_FILE':'Config/HelperInfo.plist'}
    else: extra |= {'GENERATE_INFOPLIST_FILE':'YES','CODE_SIGNING_ALLOWED':'NO'}
    configs=config_list(name,extra)
    typ={'Qiming':'com.apple.product-type.application','QimingHelper':'com.apple.product-type.tool','QimingTests':'com.apple.product-type.bundle.unit-test'}[name]
    add('target:'+name,'{isa = PBXNativeTarget; buildConfigurationList = '+configs+'; buildPhases = '+arr(phases)+'; buildRules = (); dependencies = '+arr(deps)+'; name = '+name+'; productName = '+name+'; productReference = '+ref('product:'+name)+'; productType = '+q(typ)+'; }')
add('project','{isa = PBXProject; attributes = {BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2720; }; buildConfigurationList = '+ref('configs:project')+'; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, "zh-Hans", Base, ); mainGroup = '+ref('main')+'; productRefGroup = '+ref('products')+'; projectDirPath = ""; projectRoot = ""; targets = '+arr([ref('target:'+n) for n,_,_ in products])+'; }')
(ROOT/'Qiming.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(i+' = '+value+';' for i,value in objects.items())+'\n}; rootObject = '+ref('project')+'; }\n')
app = ref('target:Qiming'); test=ref('target:QimingTests')
scheme=f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2720" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app}" BuildableName="Qiming.app" BlueprintName="Qiming" ReferencedContainer="container:Qiming.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test}" BuildableName="QimingTests.xctest" BlueprintName="QimingTests" ReferencedContainer="container:Qiming.xcodeproj"/></TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app}" BuildableName="Qiming.app" BlueprintName="Qiming" ReferencedContainer="container:Qiming.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app}" BuildableName="Qiming.app" BlueprintName="Qiming" ReferencedContainer="container:Qiming.xcodeproj"/></BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>'''
scheme = '\n'.join(line.replace('BuildableName="Qiming.app"', 'BuildableName="Qiming Dev.app"') if line.startswith(('<BuildAction ', '<LaunchAction ')) else line for line in scheme.split('\n'))
(ROOT/'Qiming.xcodeproj/xcshareddata/xcschemes/Qiming.xcscheme').write_text(scheme)
for path, data in {
'Config/Info.plist': {'CFBundleDevelopmentRegion':'en','CFBundleExecutable':'$(EXECUTABLE_NAME)','CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)','CFBundleInfoDictionaryVersion':'6.0','CFBundleName':'$(PRODUCT_NAME)','CFBundleDisplayName':'$(PRODUCT_NAME)','CFBundlePackageType':'APPL','CFBundleShortVersionString':'$(MARKETING_VERSION)','CFBundleVersion':'$(CURRENT_PROJECT_VERSION)','LSMinimumSystemVersion':'$(MACOSX_DEPLOYMENT_TARGET)','LSUIElement':True,'NSPrincipalClass':'NSApplication','NSHighResolutionCapable':True,'LSMultipleInstancesProhibited':True},
'Config/HelperInfo.plist': {'CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)','CFBundleName':'QimingHelper','CFBundleVersion':'$(CURRENT_PROJECT_VERSION)'},
'Config/com.qiming.mac.helper.plist': {'Label':'com.qiming.mac.helper','BundleProgram':'Contents/Library/HelperTools/QimingHelper','MachServices':{'com.qiming.mac.helper':True},'RunAtLoad':True,'KeepAlive':True,'ProcessType':'Background','ThrottleInterval':30}
}.items():
    with (ROOT/path).open('wb') as f: plistlib.dump(data,f)
print('Generated Qiming.xcodeproj')
