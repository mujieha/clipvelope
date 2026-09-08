#!/usr/bin/env python3
"""Generates Clipvelope.xcodeproj.

The real build is SwiftPM plus scripts/bundle.sh. This project exists for one
job SwiftPM cannot do: automatic signing, which is what produces a provisioning
profile. A restricted entitlement such as keychain-access-groups has to be
authorised by a profile, and only Xcode will mint one.

Generated rather than committed by hand so the file list cannot drift from
Sources/, and so the whole thing can be regenerated after a rename.
"""
import hashlib
import os
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
BUNDLE_ID = "com.mujieha.Clipvelope"
DEPLOYMENT_TARGET = "26.0"


def oid(name: str) -> str:
    """A stable 24-hex object id, so regenerating gives the same file."""
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()


def main() -> int:
    team = sys.argv[1] if len(sys.argv) > 1 else ""

    sources = sorted(p.name for p in (ROOT / "Sources" / "Clipvelope").glob("*.swift"))
    if not sources:
        print("no sources found", file=sys.stderr)
        return 1

    build_files, file_refs, source_entries = [], [], []
    for name in sources:
        ref, build = oid("ref:" + name), oid("build:" + name)
        file_refs.append(
            f'\t\t{ref} /* {name} */ = {{isa = PBXFileReference; '
            f'lastKnownFileType = sourcecode.swift; path = {name}; '
            f'sourceTree = "<group>"; }};'
        )
        build_files.append(
            f'\t\t{build} /* {name} in Sources */ = {{isa = PBXBuildFile; '
            f'fileRef = {ref} /* {name} */; }};'
        )
        source_entries.append(f'\t\t\t\t{build} /* {name} in Sources */,')

    group_children = "\n".join(f'\t\t\t\t{oid("ref:" + n)} /* {n} */,' for n in sources)

    ids = {k: oid(k) for k in (
        "project", "target", "product", "sourcesPhase", "resourcesPhase",
        "frameworksPhase", "mainGroup", "sourcesGroup", "productsGroup",
        "resourcesGroup", "icon", "iconBuild", "projConfigList", "targetConfigList",
        "projDebug", "projRelease", "targetDebug", "targetRelease",
    )}

    signing = (
        f'\t\t\t\tCODE_SIGN_STYLE = Automatic;\n'
        f'\t\t\t\tDEVELOPMENT_TEAM = {team};\n' if team else
        '\t\t\t\tCODE_SIGN_STYLE = Automatic;\n'
    )

    target_settings = (
        '\t\t\t\tCODE_SIGN_ENTITLEMENTS = Resources/Clipvelope.entitlements;\n'
        + signing +
        f'\t\t\t\tCURRENT_PROJECT_VERSION = 1;\n'
        f'\t\t\t\tENABLE_HARDENED_RUNTIME = YES;\n'
        f'\t\t\t\tINFOPLIST_FILE = Resources/Info.plist;\n'
        f'\t\t\t\tMARKETING_VERSION = 0.1.0;\n'
        f'\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};\n'
        f'\t\t\t\tPRODUCT_NAME = Clipvelope;\n'
        f'\t\t\t\tSWIFT_VERSION = 5.0;\n'
    )

    project_settings = (
        f'\t\t\t\tMACOSX_DEPLOYMENT_TARGET = {DEPLOYMENT_TARGET};\n'
        f'\t\t\t\tSDKROOT = macosx;\n'
        f'\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;\n'
        f'\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;\n'
        f'\t\t\t\tSWIFT_EMIT_LOC_STRINGS = NO;\n'
    )

    pbx = f'''// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{
\t}};
\tobjectVersion = 56;
\tobjects = {{

/* Begin PBXBuildFile section */
{chr(10).join(build_files)}
\t\t{ids["iconBuild"]} /* AppIcon.icns in Resources */ = {{isa = PBXBuildFile; fileRef = {ids["icon"]} /* AppIcon.icns */; }};
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
{chr(10).join(file_refs)}
\t\t{ids["icon"]} /* AppIcon.icns */ = {{isa = PBXFileReference; lastKnownFileType = image.icns; name = AppIcon.icns; path = Resources/AppIcon.icns; sourceTree = "<group>"; }};
\t\t{ids["product"]} /* Clipvelope.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Clipvelope.app; sourceTree = BUILT_PRODUCTS_DIR; }};
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
\t\t{ids["frameworksPhase"]} = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
\t\t{ids["mainGroup"]} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{ids["sourcesGroup"]} /* Clipvelope */,
\t\t\t\t{ids["resourcesGroup"]} /* Resources */,
\t\t\t\t{ids["productsGroup"]} /* Products */,
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{ids["sourcesGroup"]} /* Clipvelope */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{group_children}
\t\t\t);
\t\t\tpath = Sources/Clipvelope;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{ids["resourcesGroup"]} /* Resources */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{ids["icon"]} /* AppIcon.icns */,
\t\t\t);
\t\t\tname = Resources;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{ids["productsGroup"]} /* Products */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{ids["product"]} /* Clipvelope.app */,
\t\t\t);
\t\t\tname = Products;
\t\t\tsourceTree = "<group>";
\t\t}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
\t\t{ids["target"]} /* Clipvelope */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {ids["targetConfigList"]};
\t\t\tbuildPhases = (
\t\t\t\t{ids["sourcesPhase"]},
\t\t\t\t{ids["frameworksPhase"]},
\t\t\t\t{ids["resourcesPhase"]},
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = Clipvelope;
\t\t\tproductName = Clipvelope;
\t\t\tproductReference = {ids["product"]} /* Clipvelope.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
\t\t{ids["project"]} = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 2600;
\t\t\t\tLastUpgradeCheck = 2600;
\t\t\t\tTargetAttributes = {{
\t\t\t\t\t{ids["target"]} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 26.0;
\t\t\t\t\t}};
\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {ids["projConfigList"]};
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {ids["mainGroup"]};
\t\t\tproductRefGroup = {ids["productsGroup"]} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{ids["target"]} /* Clipvelope */,
\t\t\t);
\t\t}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
\t\t{ids["resourcesPhase"]} = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{ids["iconBuild"]} /* AppIcon.icns in Resources */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
\t\t{ids["sourcesPhase"]} = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{chr(10).join(source_entries)}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
\t\t{ids["projDebug"]} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{project_settings}\t\t\t\tONLY_ACTIVE_ARCH = YES;
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{ids["projRelease"]} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{project_settings}\t\t\t}};
\t\t\tname = Release;
\t\t}};
\t\t{ids["targetDebug"]} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{target_settings}\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{ids["targetRelease"]} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{target_settings}\t\t\t}};
\t\t\tname = Release;
\t\t}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
\t\t{ids["projConfigList"]} = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{ids["projDebug"]} /* Debug */,
\t\t\t\t{ids["projRelease"]} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{ids["targetConfigList"]} = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{ids["targetDebug"]} /* Debug */,
\t\t\t\t{ids["targetRelease"]} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
/* End XCConfigurationList section */
\t}};
\trootObject = {ids["project"]};
}}
'''

    out = ROOT / "Clipvelope.xcodeproj"
    out.mkdir(exist_ok=True)
    (out / "project.pbxproj").write_text(pbx)
    print(f"wrote {out.relative_to(ROOT)}/project.pbxproj with {len(sources)} sources"
          + (f", team {team}" if team else ", no team set"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
