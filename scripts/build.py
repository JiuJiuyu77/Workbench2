#!/usr/bin/env python3
"""Build a simulator app or unsigned device IPA with the embedded iOS toolchain."""
import argparse
import os
import pathlib
import plistlib
import shutil
import subprocess
import tarfile
import zipfile
import hashlib
import time
import gzip
import json
from build_sdk import select_sdk
from signing_profiles import load_profile, signing_plan

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--simulator', action='store_true')
parser.add_argument('--sdk-root', type=pathlib.Path, help='Real platform SDK used for compilation and linking (not the embedded tweak SDK)')
parser.add_argument('--identity', default='-')
parser.add_argument('--profile', type=pathlib.Path)
parser.add_argument('--share-profile', type=pathlib.Path, help='Provisioning profile for the Share Extension')
parser.add_argument('--activity-profile', type=pathlib.Path, help='Provisioning profile for the Live Activity Extension')
parser.add_argument('--bundle-id', default='com.HuQing.Workbench')
args = parser.parse_args()
profile_rights = None
if not args.simulator and args.identity != '-':
    if not all([args.profile, args.share_profile, args.activity_profile]):
        parser.error('证书签名必须提供 --profile、--share-profile 和 --activity-profile；主应用和扩展需要分别匹配的描述文件。')
    try:
        profile_rights = signing_plan(args.bundle_id, *[load_profile(p) for p in [args.profile, args.share_profile, args.activity_profile]])
    except (ValueError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        parser.error(str(error))
elif any([args.profile, args.share_profile, args.activity_profile]):
    parser.error('描述文件仅用于真实证书签名，请同时设置 --identity；模拟器/待重签名包不嵌入描述文件。')
platform = 'simulator' if args.simulator else 'device'
sdk = 'iphonesimulator' if args.simulator else 'iphoneos'
arch = 'x86_64' if args.simulator else 'arm64'
installed_sdk = pathlib.Path(subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip())
bundled_sdk = pathlib.Path(os.environ.get('WORKBENCH_SDK_26_0', str(ROOT.parent / 'SDKDownloads/iOS-SDKs-26/iPhoneOS26.0.sdk')))
try:
    actual_sdk, sdk_settings = select_sdk(sdk, installed_sdk, bundled_sdk, args.sdk_root)
except ValueError as error:
    parser.error(str(error))
if actual_sdk != installed_sdk.resolve():
    args.sdk_root = actual_sdk
sysroot = str(actual_sdk)

app = ROOT / 'build' / platform / 'Workbench.app'
if app.exists():
    shutil.rmtree(app)
app.mkdir(parents=True, exist_ok=True)
shutil.copyfile(ROOT / 'LICENSE', app / 'Dylix-LICENSE.txt')
# 内置 SDK 只用于给 Theos 的 Toolchain/sdks 补一份 16.5（见上方 BundledToolchain 段），
# 不再往 App 里塞 SDK.zip：进程内编译已移除。
pinned_resources = json.loads((ROOT / 'Resources/DownloadResources.json').read_text())
pinned_sdk26 = next(row for row in pinned_resources if row['id'] == 'sdk26')
(app / 'SDK26Resource.plist').write_bytes(plistlib.dumps({'version': '26.0', 'sha256': pinned_sdk26['sha256']}))
resources = ['CompatibilityRules', 'ThirdPartyNotices', 'GitHelp', 'HelpArticles', 'Editor', 'GitDiff', 'RemoteWeb', 'Include', 'SampleProject', 'SampleObjectiveC', 'SampleMultiProject', 'FLEXProject', 'VendorFrameworks', 'Terminal']
if args.simulator:
    resources.append('SampleLogosGenerated')
    resources.append('SampleMultiObjectiveC')
# RemoteWeb / FLEXProject 体积大且改动少，仓库里以压缩包形式保存（Resources/BundledUIAssets.tar.gz），
# 构建时解到 build/assets 再按资源复制，避免仓库里几千个文件拖慢 checkout。
_assets_dir = ROOT / 'build' / 'assets'
_assets_tar = ROOT / 'Resources/BundledUIAssets.tar.gz'
if _assets_tar.is_file():
    if not (_assets_dir / 'Resources/RemoteWeb').is_dir():
        shutil.rmtree(_assets_dir, ignore_errors=True)
        _assets_dir.mkdir(parents=True, exist_ok=True)
        with tarfile.open(_assets_tar, 'r:gz') as _tf:
            _tf.extractall(_assets_dir)
_missing_res = []
for resource in resources:
    _src = ROOT / 'Resources' / resource
    if not _src.is_dir():
        _src = _assets_dir / 'Resources' / resource
    if not _src.is_dir():
        _missing_res.append(resource)
        continue
    shutil.copytree(_src, app / resource, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns('.git', '*.bundle', '*.dylib', '*.a', '*.o'))
if _missing_res:
    print('warn: 以下资源目录缺失，已跳过：' + ', '.join(_missing_res))
# 全内置的 Work1 工具链（Theos + OLLVM + 逆向工具 + SDK），由 CI 下载后放在 BundledToolchain/。
# 直接进 App 包，SPToolchainInstaller 会优先使用包内这份（不复制到 Documents）。
# 构建引擎随之走 Theos/make 新协议，不再回退进程内编译。
_bundled_tc = ROOT / 'BundledToolchain'
if _bundled_tc.is_dir() and any(_bundled_tc.iterdir()):
    _tc_dest = app / 'Toolchain'
    if _tc_dest.exists():
        shutil.rmtree(_tc_dest)
    shutil.copytree(_bundled_tc, _tc_dest, symlinks=True)
    (_tc_dest / 'manifest.json').write_text(json.dumps({
        'builtAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'source': 'SparkTheosRuntimeV3',
    }, ensure_ascii=False))
    _sz = sum(f.stat().st_size for f in _bundled_tc.rglob('*') if f.is_file() and not f.is_symlink())
    print('Bundled toolchain: %d files, %.1f MB (swiftc=%s)' % (
        sum(1 for _ in _tc_dest.rglob('*')), _sz / 1048576.0,
        'yes' if (_tc_dest / 'swift-toolchain/usr/bin/swiftc').exists() else 'no'))
    # Theos 需要 $THEOS/sdks 下有真实 SDK。运行时包没带时，用仓库里的 16.5 SDK 补上，
    # 保证「全内置」在离线环境也能直接 make。
    _sdks = _tc_dest / 'sdks'
    if not any(_sdks.glob('iPhoneOS*.sdk')):
        _sdks.mkdir(parents=True, exist_ok=True)
        with tarfile.open(ROOT / 'Resources/SDK16.5.tar.gz', 'r:gz') as _tf:
            _tf.extractall(_sdks)
        _inner = list(_sdks.glob('iPhoneOS*.sdk'))
        if len(_inner) == 1 and _inner[0].parent != _sdks:
            for _child in _inner[0].iterdir():
                shutil.move(str(_child), str(_sdks / _child.name))
            _inner[0].rmdir()
        print('Bundled SDK: %s' % ', '.join(p.name for p in _sdks.glob('iPhoneOS*.sdk')))

# Alpine userspace and signed offline developer kit used by the embedded runtime.
ish_rootfs = ROOT / 'Resources' / 'iSH'
if ish_rootfs.exists():
    for stem, helper in [('developer-tools','fetch_ish_packages.py'),('reverse-tools','fetch_reverse_tools.py')]:
        kit=ish_rootfs/(stem+'.tar');index=ish_rootfs/(stem+'.json')
        # Optional tool archives are downloaded after installation; validate local copies when present.
        if kit.is_file():
            manifest=json.loads(index.read_text())
            if manifest.get('architecture')!='aarch64' or hashlib.sha256(kit.read_bytes()).hexdigest()!=manifest.get('sha256'):
                raise SystemExit('Offline '+stem+' manifest/hash mismatch')
    shutil.copytree(ish_rootfs, app / 'iSH', dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns('developer-tools.tar', 'reverse-tools.tar', 'GuestTools'))
from prepare_download_resources import prepare as prepare_optional_resources
(app / 'DownloadResources.json').write_text(json.dumps(prepare_optional_resources(), ensure_ascii=False, indent=2))
# FLEX 插件是可选资源：仓库精简后可能不随源码分发，
# 缺失时跳过而不是中断整个构建（App 本身不依赖它启动）。
flex_source = ROOT / 'Resources/FLEXPlugin'
if (flex_source / 'manifest.json').is_file():
    flex_manifest = json.loads((flex_source / 'manifest.json').read_text(encoding='utf-8'))
    flex_dest = app / 'FLEXPlugin'
    flex_dest.mkdir(exist_ok=True)
    for entry in flex_manifest['files'].values():
        source = flex_source / entry['name']
        if source.name != entry['name'] or hashlib.sha256(source.read_bytes()).hexdigest() != entry['sha256']:
            raise SystemExit('Bundled FLEX package is missing or does not match manifest: ' + str(source))
        shutil.copy2(source, flex_dest / source.name)
    shutil.copy2(flex_source / 'manifest.json', flex_dest / 'manifest.json')
else:
    print('warn: Resources/FLEXPlugin 缺失，跳过 FLEX 插件打包')
if args.profile:
    shutil.copy2(args.profile, app / 'embedded.mobileprovision')
# Precompressed offline editor assets reduce LAN transfer latency.
for asset in (app / 'RemoteWeb' / 'monaco').rglob('*'):
    if asset.suffix in ('.js', '.css') and asset.stat().st_size > 1024:
        asset.with_name(asset.name + '.gz').write_bytes(gzip.compress(asset.read_bytes(), compresslevel=6, mtime=0))

info = {
    'CFBundleExecutable': 'Workbench', 'CFBundleIdentifier': args.bundle_id,
    'CFBundleName': 'Workbench', 'CFBundleDisplayName': 'Workbench',
    'CFBundleDevelopmentRegion': 'zh-Hans', 'CFBundleLocalizations': ['zh-Hans', 'en'],
    'NSCameraUsageDescription': '拍摄照片用于项目文件、截图记录与问题反馈。', 'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '1.2.5', 'CFBundleVersion': '290', 'WorkbenchEdition': 'opensource',
    'CFBundleDocumentTypes': [{'CFBundleTypeName':'Workbench Files','CFBundleTypeRole':'Editor','LSHandlerRank':'Alternate','LSItemContentTypes':['public.data','public.archive','public.source-code']}],
    'CFBundleURLTypes': [{'CFBundleURLName':'Workbench Incoming','CFBundleURLSchemes':['workbench', 'workbench']}],
    'BGTaskSchedulerPermittedIdentifiers': ['com.HuQing.Workbench.ai.processing'],
    'UIBackgroundModes': ['processing', 'audio'],
    'NSSupportsLiveActivities': True,
    'UIApplicationSceneManifest': {
        'UIApplicationSupportsMultipleScenes': False,
        'UISceneConfigurations': {
            'UIWindowSceneSessionRoleApplication': [{
                'UISceneConfigurationName': 'Workbench',
                'UISceneClassName': 'UIWindowScene',
                'UISceneDelegateClassName': 'WorkbenchSceneDelegate',
            }],
        },
    },
    'MinimumOSVersion': '15.0', 'UIDeviceFamily': [1, 2],
    'NSAppTransportSecurity': {'NSAllowsArbitraryLoads': True},
    'NSLocalNetworkUsageDescription': '开启局域网远程工作台时，允许同一 Wi-Fi 中经你配对的设备访问。',
    'UILaunchScreen': {}, 'UIFileSharingEnabled': True, 'LSSupportsOpeningDocumentsInPlace': True,
    'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'],
    'CFBundleSupportedPlatforms': ['iPhoneSimulator' if args.simulator else 'iPhoneOS'],
}
icon_info = ROOT / 'build' / platform / 'icons-info.plist'
asset_result = subprocess.run(['xcrun', 'actool', '--compile', str(app), '--platform', sdk,
                '--minimum-deployment-target', '15.0', '--app-icon', 'AppIcon',
                '--target-device', 'iphone', '--target-device', 'ipad',
                '--output-partial-info-plist', str(icon_info),
                str(ROOT / 'Resources/Assets.xcassets')])
if asset_result.returncode:
    previous_ipa = ROOT / 'build' / f"Workbench-1.0.5-build141-unsigned.ipa"
    catalog = ROOT / 'Resources/Assets.xcassets'
    newest_asset = max((p.stat().st_mtime for p in catalog.rglob('*') if p.is_file()), default=0)
    if not previous_ipa.exists() or previous_ipa.stat().st_mtime < newest_asset or not icon_info.exists():
        raise SystemExit('Asset catalog compilation failed and no current packaged assets are available')
    with zipfile.ZipFile(previous_ipa) as previous:
        (app / 'Assets.car').write_bytes(previous.read('Payload/Workbench.app/Assets.car'))
    print('actool failed; reused unchanged Assets.car from the previous IPA', flush=True)
info.update(plistlib.loads(icon_info.read_bytes()))
(app / 'Info.plist').write_bytes(plistlib.dumps(info))
if args.simulator:
    # Disposable ARM64 fixture is data only, used by offline AI tool regression.
    fixture = ROOT / 'build' / 'classdump-fixture.dylib'
    subprocess.run(['xcrun', '--sdk', 'iphoneos', 'clang', '-arch', 'arm64', '-miphoneos-version-min=15.0', '-fobjc-arc', '-dynamiclib', '-Wl,-no_objc_category_merging', '-framework', 'Foundation', str(ROOT / 'tests/TFClassDumpFixture.m'), '-o', str(fixture)], check=True)
    with zipfile.ZipFile(app / 'AIClassDumpFixture.ipa', 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.write(fixture, 'Payload/Fixture.app/Fixture')
sdk_version = sdk_settings['Version']
if args.sdk_root and sdk not in sdk_settings.get('SupportedTargets', {}):
    parser.error('SDK platform does not match build target: ' + sdk)
info['DTSDKName'] = sdk + sdk_version
info['DTPlatformVersion'] = sdk_version
(app / 'Info.plist').write_bytes(plistlib.dumps(info))
print('Build SDK: ' + sysroot + ' (' + sdk_version + ')', flush=True)
gitlib = ROOT / 'build' / ('git-' + platform) / 'libgit2.a'
if not gitlib.exists():
    subprocess.run(['python3', str(ROOT / 'scripts/build_git.py'), '--platform', platform], check=True)
classdumplib = ROOT / 'build' / ('classdump-' + platform) / 'libworkbench_classdump.a'
subprocess.run(['python3', str(ROOT / 'scripts/build_classdump.py'), '--platform', platform], check=True)
cmd = ['xcrun', '--sdk', sdk, 'clang', '-arch', arch, '-isysroot', sysroot,
       '-mios-simulator-version-min=15.0' if args.simulator else '-miphoneos-version-min=15.0',
       '-fobjc-arc', '-fmodules', '-framework', 'Network', '-framework', 'CoreImage', '-I' + str(ROOT / 'Vendor/libgit2/include'), '-weak_framework', 'BackgroundTasks', '-framework', 'AVFoundation', '-framework', 'UserNotifications', '-framework', 'AuthenticationServices', '-framework', 'Security', '-framework', 'CoreFoundation', '-liconv', '-framework', 'UIKit', '-framework', 'CoreGraphics', '-framework', 'QuartzCore', '-framework', 'Foundation', '-framework', 'UniformTypeIdentifiers', '-framework', 'WebKit', '-framework', 'JavaScriptCore', '-larchive',
       str(ROOT / 'App/main.m'), str(ROOT / 'App/RuntimeDiagnostics.m'), str(ROOT / 'App/WorkbenchHealth.m'), str(ROOT / 'App/WBTheosToolsController.m'), str(ROOT / 'App/WBToolsController.m'), str(ROOT / 'App/WBReverseController.m'), str(ROOT / 'App/WBRemoteController.m'), str(ROOT / 'App/SPJIT.m'), str(ROOT / 'App/SPJITService.m'), str(ROOT / 'App/SPDiagnostics.m'), str(ROOT / 'App/SPHeaderExport.m'), str(ROOT / 'App/SPRemoteServer.m'), str(ROOT / 'App/SPCompat.m'), str(ROOT / 'App/SPModels.m'), str(ROOT / 'App/SPSession.m'), str(ROOT / 'App/SPAOJIT.m'), str(ROOT / 'App/SPStore.m'), str(ROOT / 'App/SPOutputNaming.m'), str(ROOT / 'App/SPToolchain.m'), str(ROOT / 'App/SPToolchainInstaller.m'), str(ROOT / 'App/SPToolchainDownloader.m'), str(ROOT / 'App/SPProcessGuard.m'), str(ROOT / 'App/SPNetworkMonitor.m'), str(ROOT / 'App/SPBuilder.m'), str(ROOT / 'App/SPIShell.m'), str(ROOT / 'App/SPTrollStoreFix.m'), str(ROOT / 'App/WBCloudBuild.m'), str(ROOT / 'App/ArchiveImport.m'), str(ROOT / 'App/TheosMakefile.m'), str(ROOT / 'App/DebPackage.m'), str(ROOT / 'App/OutputNaming.m'), str(ROOT / 'App/CompatibilityRepair.m'), str(ROOT / 'App/Studio.m'), str(ROOT / 'App/StorageSpace.m'), str(ROOT / 'App/ProjectSafety.m'), str(ROOT / 'App/ProjectTrash.m'), str(ROOT / 'App/GlassSupport.m'), str(ROOT / 'App/GitService.m'), str(ROOT / 'App/GitUI.m'), str(ROOT / 'App/GitHubRepositories.m'), str(ROOT / 'App/GitPATGuide.m'), str(ROOT / 'App/LinkSupport.m'), str(ROOT / 'App/HelpArticle.m'), str(ROOT / 'App/GitAutomation.m'), str(ROOT / 'App/GitDiffView.m'), str(gitlib), str(ROOT / 'Vendor/MBProgressHUD/MBProgressHUD.m'), '-o', str(app / 'Workbench')]
# iSH host objects are ARM64 only; never link macOS or device archives into a simulator.
ish_enabled = arch == 'arm64'
if ish_enabled:
    ish_dir = ROOT / 'build/ish' / platform
    manifest_path = ish_dir / 'manifest.json'
    from build_ish import source_digest
    cached = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    if cached.get('sourceDigest') != source_digest():
        # iSH 沙盒是可选能力：需要 LLVM 的 ld.lld 链接 guest ELF。
        # CI runner 上没有该工具时，整体构建不应该因此失败 ——
        # App 主体（编译、Git、逆向、类导出）都不依赖它。
        try:
            subprocess.run(['python3', str(ROOT / 'scripts/build_ish.py'), '--platform', platform], check=True)
        except subprocess.CalledProcessError as _ish_err:
            print('warn: iSH 沙盒构建失败（缺 ld.lld？），跳过该组件：%s' % _ish_err)
            print('warn: App 仍可正常使用，但「终端」功能会提示沙盒未就绪')
    # iSH 构建可能整体降级：manifest 不存在时不要硬链接 iSH 库，
    # 也不要拷贝 runtime-manifest.json —— 之前这里直接 copy 会抛
    # FileNotFoundError 把整个构建打断（终端功能本该是可选的）。
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    if not manifest:
        print('warn: iSH manifest 缺失，本次构建不含终端沙盒（-DWORKBENCH_HAS_ISH=0）')
        cmd.append('-DWORKBENCH_HAS_ISH=0')
    else:
        if (manifest.get('platform') != sdk or manifest.get('architecture') != arch or manifest.get('jit') is not False):
            raise SystemExit('iSH platform/architecture manifest does not match app target')
        for name, digest in (manifest.get('libraries') or {}).items():
            library = ish_dir / name
            if hashlib.sha256(library.read_bytes()).hexdigest() != digest:
                raise SystemExit('iSH library digest mismatch: ' + name)
            cmd.append(str(library))
        cmd.extend(['-DWORKBENCH_HAS_ISH=1', '-I' + str(ROOT / 'Vendor/iSH'), '-I' + str(ish_dir / 'meson'), '-lsqlite3', '-lresolv'])
        for name, dest in [('LICENSE.md', 'iSH-LICENSE.md'),
                           ('LICENSE.IOS', 'iSH-LICENSE.IOS'),
                           ('DYLIX-NOTICE.md', 'iSH-NOTICE.md')]:
            source = ROOT / 'Vendor/iSH' / name
            if source.is_file():
                shutil.copy2(source, app / dest)
        shutil.copy2(manifest_path, app / 'iSH/runtime-manifest.json')
else:
    cmd.append('-DWORKBENCH_HAS_ISH=0')
cmd.extend(str(p) for p in sorted((ROOT / 'App/Runtime').rglob('*.m')))
if args.simulator:
    for regression in ['Integration165IOSRegression.m', 'AgentIOSRegression.m', 'ToolRegistryIOSRegression.m']:
        source = ROOT / 'tests' / regression
        if source.exists():
            cmd.append(str(source))
            if regression == 'Integration165IOSRegression.m':
                cmd.append('-DWORKBENCH_HAS_INTEGRATION165=1')
cmd.extend(str(p) for p in sorted((ROOT / 'App/Remote').glob('*.m')))
cmd.append(str(ROOT / 'App/SDKResources.m'))
cmd.extend(str(p) for p in sorted((ROOT / 'App/Incoming').glob('*.m')))
cmd.extend([str(classdumplib), '-framework', 'PhotosUI', '-framework', 'ImageIO'])
if args.sdk_root:
    # Xcode 16's module loader predates DarwinFoundation's SDK 26 module map.
    # Textual public headers work with this Objective-C app without SDK edits.
    cmd[cmd.index('-fmodules')] = '-fno-modules'
    subframeworks = pathlib.Path(sysroot) / 'System/Library/SubFrameworks'
    if subframeworks.exists():
        cmd.extend(['-F' + str(subframeworks)])
if args.simulator:
    # Simulator Security reads simulated iOS entitlements from this Mach-O section.
    # Keep the host macOS ad-hoc code signature free of restricted entitlements.
    simulated = ROOT / 'build' / 'simulator' / 'simulated-entitlements.plist'
    simulated.write_bytes(plistlib.dumps({
        'application-identifier': 'TMCLOCAL01.' + args.bundle_id,
        'keychain-access-groups': ['TMCLOCAL01.' + args.bundle_id],
    }))
    cmd.extend(['-Xlinker', '-sectcreate', '-Xlinker', '__TEXT', '-Xlinker', '__entitlements', '-Xlinker', str(simulated)])
subprocess.run(cmd, check=True)
# JIT 授权 helper：iOS 不允许进程同步调试自己，必须由独立进程对主 App
# 做 PT_ATTACHEXC / PT_DETACH（TrollStore RootHelper 同款）。源码见 Native/jitd。
# 缺失时不影响构建：SPJIT 会退回主进程 mmap 探测。
_jit_src = ROOT / 'Native/jitd/spark-jitd.c'
if _jit_src.is_file():
    _bin = app / 'bin'
    _bin.mkdir(parents=True, exist_ok=True)
    _helper = _bin / 'spark-jitd'
    subprocess.run(['xcrun', '--sdk', sdk, 'clang', '-arch', arch, '-isysroot', sysroot,
                    '-mios-simulator-version-min=15.0' if args.simulator else '-miphoneos-version-min=15.0',
                    '-O2', '-Wall', '-Wno-unused-result', str(_jit_src), '-o', str(_helper)], check=True)
    _helper.chmod(0o755)
    subprocess.run(['codesign', '--force', '--sign', args.identity, str(_helper)], check=True)
    print('JIT helper: ' + str(_helper))
# Share Extension passes copied files through an explicitly entitled App Group.
# Re-signing must preserve matching group rights in both provisioning profiles.
share = app / 'PlugIns/WorkbenchShare.appex'
share.mkdir(parents=True, exist_ok=True)
share_info = {
 'CFBundleExecutable':'WorkbenchShare','CFBundleIdentifier':args.bundle_id + '.share',
 'CFBundleName':'WorkbenchShare','CFBundleDisplayName':'Workbench','CFBundlePackageType':'XPC!',
 'CFBundleShortVersionString':'1.2.0','CFBundleVersion':info['CFBundleVersion'],
 'MinimumOSVersion':'15.0','UIDeviceFamily':[1,2],
 'CFBundleSupportedPlatforms':info['CFBundleSupportedPlatforms'],
 'DTSDKName':info['DTSDKName'],'DTPlatformVersion':info['DTPlatformVersion'],
 'NSExtension':{'NSExtensionPointIdentifier':'com.apple.share-services',
 'NSExtensionPrincipalClass':'ShareViewController',
 'NSExtensionAttributes':{'NSExtensionActivationRule':{'NSExtensionActivationSupportsFileWithMaxCount':20}}},
}
(share / 'Info.plist').write_bytes(plistlib.dumps(share_info))
share_cmd=['xcrun','--sdk',sdk,'clang','-arch',arch,'-isysroot',sysroot,
 '-mios-simulator-version-min=15.0' if args.simulator else '-miphoneos-version-min=15.0',
 '-fobjc-arc','-fapplication-extension','-framework','UIKit','-framework','Foundation','-framework','UniformTypeIdentifiers',
 '-Wl,-e,_NSExtensionMain',str(ROOT / 'ShareExtension/ShareViewController.m'),str(ROOT / 'ShareExtension/TFShareLauncher.m'),str(ROOT / 'ShareExtension/TFShareFileProvider.m'),str(ROOT / 'ShareExtension/TFShareFolderArchive.m'),'-larchive',str(ROOT / 'App/Incoming/TFShareTransfer.m'),str(ROOT / 'App/Incoming/TFShareGroups.m'),'-o',str(share / 'WorkbenchShare')]
if args.sdk_root:
    share_cmd.append('-F' + str(pathlib.Path(sysroot) / 'System/Library/SubFrameworks'))
if args.share_profile:
    shutil.copy2(args.share_profile, share / 'embedded.mobileprovision')
subprocess.run(share_cmd,check=True)
share_entitlements=ROOT / 'build' / platform / 'share-entitlements.plist'
share_entitlements.write_bytes(plistlib.dumps(profile_rights[1] if profile_rights else {'com.apple.security.application-groups':['group.com.xuegao.workbench.share']}))
sign_flags=[] if args.simulator else ['--entitlements',str(share_entitlements)]
subprocess.run(['codesign','--force','--sign',args.identity,*sign_flags,str(share)],check=True)
activity_flags=[]
main_sign_flags=sign_flags
if profile_rights:
    main_rights=ROOT / 'build' / platform / 'main-entitlements.plist'
    activity_rights=ROOT / 'build' / platform / 'activity-entitlements.plist'
    main_rights.write_bytes(plistlib.dumps(profile_rights[0]))
    activity_rights.write_bytes(plistlib.dumps(profile_rights[2]))
    main_sign_flags=['--entitlements',str(main_rights)]
    activity_flags=['--profile',str(args.activity_profile),'--entitlements',str(activity_rights)]
subprocess.run(['python3',str(ROOT / 'scripts/build_live_activity.py'),'--app',str(app),'--build',info['CFBundleVersion'],'--identity',args.identity,'--bundle-id',args.bundle_id + '.activity']+activity_flags+(['--simulator'] if args.simulator else []),check=True)
def _macho(path):
    try:
        with open(path, 'rb') as handle:
            magic = handle.read(4)
    except OSError:
        return False
    return magic in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')

if (_bundled_tc.is_dir() and any(_bundled_tc.iterdir()) and not args.simulator):
    _signed = 0
    for _path in (app / 'Toolchain').rglob('*'):
        if not _path.is_file() or _path.is_symlink() or not _macho(_path):
            continue
        subprocess.run(['codesign', '--force', '--sign', args.identity, str(_path)],
                       check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        _signed += 1
    print('Bundled toolchain Mach-O signed: %d' % _signed)
subprocess.run(['codesign','--force','--sign',args.identity,*main_sign_flags,str(app)],check=True)
if not args.simulator:
    package_kind = 'signed' if profile_rights else 'unsigned'
    ipa = ROOT / 'build' / f"Workbench-{info['CFBundleShortVersionString']}-build{info['CFBundleVersion']}-opensource-{package_kind}.ipa"
    with zipfile.ZipFile(ipa, 'w', zipfile.ZIP_DEFLATED) as out:
        for path in app.rglob('*'):
            if path.is_file(): out.write(path, pathlib.Path('Payload') / app.name / path.relative_to(app))
    print(ipa)
else:
    print(app)
