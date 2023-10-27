// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

import {Artifact, Cmd, Transformer} from "Sdk.Transformers";
import {CoreRT}                     from "Sdk.MacOS";

import * as Csc from "Sdk.Managed.Tools.Csc";
import * as Branding from "BuildXL.Branding";
import * as Deployment from "Sdk.Deployment";

import * as Managed from "Sdk.Managed";
import * as Native from "Sdk.Native";
import * as Shared from "Sdk.Managed.Shared";
import * as XUnit from "Sdk.Managed.Testing.XUnit";
import * as QTest from "Sdk.Managed.Testing.QTest";
import * as Frameworks from "Sdk.Managed.Frameworks";
import * as Net472 from "Sdk.Managed.Frameworks.Net472";
import * as BinarySigner from "Sdk.Managed.Tools.BinarySigner";

import * as ResXPreProcessor from "Sdk.BuildXL.Tools.ResXPreProcessor";
import * as LogGenerator from "Sdk.BuildXL.Tools.LogGenerator";
import * as ScriptSdkTestRunner from "Sdk.TestRunner";
import * as Contracts from "Tse.RuntimeContracts";
import * as NativeSdk from "Sdk.Native";
import * as Json from "Sdk.Json";

@@public
export * from "Sdk.Managed";

@@public
export const NetFx = Net472.withQualifier({targetFramework: "net472"}).NetFx;
    
export const publicKey = "0024000004800000940000000602000000240000525341310004000001000100BDD83CF6A918814F5B0395F20B6AA573B872FCDDB8B121F162BDD7D5EB302146B2EA6D7E6551279FF9D62E7BEA417ACAE39BADC6E6DECFE45BA7B3AD70AF432A1AA587343AA67647A4D402A0E2D011A9758AAB9F0F8D1C911D554331E8176BE34592BADC08BC94BBD892AF7BCB72AC613F37E4B57A6E18599535211FEF8A7EBA";

const envVarNamePrefix = Flags.envVarNamePrefix;

const brandingDefines = [
    { key: "ShortProductName", value: Branding.shortProductName},
    { key: "LongProductName", value: Branding.longProductName},
    { key: "ShortScriptName", value: Branding.shortScriptName},
    { key: "MainExecutableName", value: Branding.mainExecutableName},
];


@@public
export interface Arguments extends Managed.Arguments {
    /** Provide switch to turn skip tool that adds GetTypeInfo() calls to generated resource code, so the tool can be compiled */
    skipResourceTranslator?: boolean;

    /** Allows projects that should be added as default references to skip adding these to avoid cycles */
    skipDefaultReferences?: boolean;

    /** Root namespace.  If undefined, the value of the "assemblyName" field is used." */
    rootNamespace?: string;

    /** Whether to run LogGen. */
    generateLogs?: boolean;

    /** Whether to generate logs during the compilation process. */
    generateLogsInProc?: boolean;

    /**
     * Specify whether to emit compiler generated file to disk.
     * The compiler will write one file per generator and the file name depends on the type of the generator.
     * */
    emitCompilerGeneratedFiles?: boolean;

    /** If the log generation needs external references, one can explicitly declare them. */
    generateLogBinaryRefs?: Managed.Binary[];

    /** Disables assembly signing with the BuildXL key. */
    skipAssemblySigning?: boolean;

    /** Configures which asserts should be checked at runtime. All by default.*/
    contractsLevel?: Contracts.ContractsLevel;

    /** The assemblies that are internal visible for this assembly */
    internalsVisibleTo?: (string | InternalsVisibleToArguments)[];

    /**
     * Whether to use the compiler's strict mode or not.
     * In strict the compiler emits extra diagnostics for dangerous or invalid code.
     * For instance, the compiler will warn on empty lock statements or when a value type instance potentially may be used in lock statement etc.
     */
    strictMode?: boolean;

    /**
     * A set of source generators used by the project.
     */
    sourceGenerators?: NugetPackage[];

    /**
     * A set of Roslyn analyzers used by the project.
     */
    analyzers?: NugetPackage[];
}

@@public
export interface Result extends Managed.Assembly {
}

@@public
export interface TestArguments extends Arguments, Managed.TestArguments {
}

@@public
export interface TestResult extends Managed.TestResult {
    adminTestResults?: TestResult;
}

@@public
export interface InternalsVisibleToArguments {
    assembly: string,
    publicKey?: string,
}

/**
 * Returns true if the current qualifier is targeting .NET Core or .NET Standard
 */
@@public
export const isDotNetCoreOrStandard : boolean = qualifier.targetFramework === "netstandard2.0" || qualifier.targetFramework === "net6.0" || qualifier.targetFramework === "net7.0";

/**
 * Returns true if the current qualifier is targeting .NET Core
 */
@@public
export const isDotNetCore : boolean = qualifier.targetFramework === "net6.0" || qualifier.targetFramework === "net7.0";

@@public
export const isFullFramework : boolean = qualifier.targetFramework === "net472";

@@public
export const isTargetRuntimeOsx : boolean = qualifier.targetRuntime === "osx-x64";

@@public
export const isTargetRuntimeLinux : boolean = qualifier.targetRuntime === "linux-x64";

@@public
export const isHostOsOsx : boolean = Context.getCurrentHost().os === "macOS";

@@public
export const isHostOsWin : boolean = Context.getCurrentHost().os === "win";

@@public
export const isHostOsLinux : boolean = Context.getCurrentHost().os === "unix";

@@public
export const targetFrameworkMatchesCurrentHost = 
    (qualifier.targetRuntime === "win-x64" && isHostOsWin)
    || (qualifier.targetRuntime === "osx-x64" && isHostOsOsx)
    || (qualifier.targetRuntime === "linux-x64" && isHostOsLinux);

/** Only run unit tests for one qualifier and also don't run tests which target macOS on Windows */
@@public
export const restrictTestRunToSomeQualifiers =
    qualifier.configuration !== "debug" ||
    // Running tests for .NET Core App 3.0, .NET 5 and 4.7.2 frameworks only.
    (qualifier.targetFramework !== "net6.0" && qualifier.targetFramework !== "net7.0" && qualifier.targetFramework !== "net472") ||
    !targetFrameworkMatchesCurrentHost;

/***
* Whether service pip daemon tooling is included with the BuildXL deployment
*/
@@public
export const isDaemonToolingEnabled = Flags.isMicrosoftInternal && isDotNetCoreOrStandard;

/***
* Whether drop tooling is included with the BuildXL deployment
*/
@@public
export const isDropToolingEnabled = isDaemonToolingEnabled;

/***
* Whether symbol tooling is included with the BuildXL deployment
*/
@@public
export const isSymbolToolingEnabled = isDaemonToolingEnabled;

namespace Flags {
    export declare const qualifier: {};

    export const envVarNamePrefix = "[Sdk.BuildXL]";

    @@public
    export const isMicrosoftInternal = Environment.getFlag(envVarNamePrefix + "microsoftInternal");

    @@public
    export const isValidatingOsxRuntime = isMicrosoftInternal && Environment.getFlag(envVarNamePrefix + "validateOsxRuntime");

    @@public
    export const isVstsArtifactsEnabled = isMicrosoftInternal;

    /***
    * Whether tests are configured to run with QTest. Not whether QTest gets bundled with the BuildXL deployment
    */
    @@public
    export const isQTestEnabled = isMicrosoftInternal && Environment.getFlag(envVarNamePrefix + "useQTest");

    /**
     * Whether we are generating VS solution.
     * We are using this flag to filter out some deployment items that can cause race in the generated VS project files.
     */
    @@public
    export const genVSSolution = Environment.getFlag("[Sdk.BuildXL]GenerateVSSolution");

    /**
     * Whether to build BuildXL.Explorer during the build.
     * BuildXL.Explorer is barely used, but building it can take a long time in CB environment and makes our rolling
     * build unreliable currently. Thus, we make building BuildXL.Explorer optional based on the specified environment variable.
     */
    @@public
    export const buildBuildXLExplorer = Environment.getFlag("[Sdk.BuildXL]BuildBuildXLExplorer");

    /**
     * Build tests that require admin privilege in VM.
     */
    @@public
    export const buildRequiredAdminPrivilegeTestInVm = Environment.getFlag("[Sdk.BuildXL]BuildRequiredAdminPrivilegeTestInVm");

    /**
     * When running tests in VM, use the specified test framework; do not let BuildXL force the framework to XUnit.
     */
    @@public
    export const doNotForceXUnitFrameworkInVm = Environment.getFlag("[Sdk.BuildXL]DoNotForceXUnitFrameworkInVm");

    /**
     * Use shared compilation for csc calls. Experimental feature.
     */
    @@public
    export const useManagedSharedCompilation = Environment.getFlag("[Sdk.BuildXL]useManagedSharedCompilation");

    /**
     * Enable running crossgen (aka ReadyToRun) on managed assemblies when available. This option is only available
     * when targeting netcoreapp (and the netcoreapp framwors supports it) and for assemblies whose target runtime
     * matches the current machine runtime. Otherwise ignored.
     */
    @@public
    export const enableCrossgen = Environment.getFlag("[Sdk.BuildXL]enableCrossgen");

    /**
     * Gets the default value for whether to use the C# compiler's strict mode by default or not.
     * Note, the property can be overriden by the library or executable arguments. This defines the default value only.
     */
    @@public
    export const useCSharpCompilerStrictMode = Environment.getFlag("[Sdk.BuildXL]useStrictMode") || true;

    /**
     * Gets the default value for whether to embed pdbs into the final assemblies or not.
     * Note, the property can be overriden by the library or executable arguments. This defines the default value only.
     */
    @@public
    export const embedPdbs = Environment.hasVariable("[Sdk.BuildXL]embedPdbs") ? Environment.getFlag("[Sdk.BuildXL]embedPdbs") : true;

    /**
     * Gets the default value for whether to embed sources into pdbs.
     * Note, the property can be overriden by the library or executable arguments. This defines the default value only.
     */
    @@public
    export const embedSources = Environment.hasVariable("[Sdk.BuildXL]embedSources") ? Environment.getFlag("[Sdk.BuildXL]embedSources") : true;

    /**
     * Gets the default value for whether the C# compiler will report additional analyzer information, such as execution time.
     */
    @@public
    export const reportAnalyzer = Environment.getFlag("[Sdk.BuildXL]reportAnalyzer");

    /**
     * Enable in-proc log generation globally.
     * If the project was using logs (i.e. generateLogs argument is true) then instead of using separate log-gen proccess
     * in-process log generation based on the C# compiler will be used.
     */
    @@public
    export const useInProcLogGen = Environment.getFlag("[Sdk.BuildXL]useInProcLogGen");

    /**
     * Gets the default value for whether to enable roslyn analyzer
     * We only want to enable it for PR builds not for local dev builds
     */
    @@public
    export const enableGuardian = Environment.hasVariable("TOOLPATH_GUARDIAN") && isMicrosoftInternal;

    /**
     * Enable ESRP Signing
     */
    @@public
    export const enableESRP = Environment.getFlag("ENABLE_ESRP");
}

@@public
export const devKey = f`BuildXL.DevKey.snk`;

@@public
export const cacheRuleSet = f`BuildXl.Cache.ruleset`;

@@public
export const dotNetFramework = isDotNetCoreOrStandard
    ? qualifier.targetRuntime
    : qualifier.targetFramework;

/**
 * Builds a BuildXL library project, resulting in a DLL.
 * Does so by invoking `build` specifying `library` as the target type.
 */
@@public
export function library(args: Arguments): Managed.Assembly {
    args = processArguments(args, "library");
    let result = Managed.library(args);
    return Flags.enableESRP ? Signing.esrpSignAssembly(result) : result;
}

/**
 * Gets runtime dependencies for a given nuget package.
 */
@@public
export function withWinRuntime(pkg: Shared.ManagedNugetPackage, rootDir: RelativePath): Shared.ManagedNugetPackage {
    if (qualifier.targetRuntime !== "win-x64")
    {
        return pkg;
    }

    return Managed.Factory.addRuntimeSpecificBinariesFromRootDir(pkg, rootDir);
}

/**
 * Builds a BuildXL executable project, resulting in an EXE.
 * Does so by invoking `build` specifying `exe` as the target type.
 */
@@public
export function executable(args: Arguments): Managed.Assembly {
    args = processArguments(args, "exe");
    args = args.merge({
        // Add standard assembly binding redirects to all BuildXL binaries
        assemblyBindingRedirects: [
            {
                name: "Newtonsoft.Json",
                publicKeyToken: "30ad4fe6b2a6aeed",
                culture: "neutral",
                oldVersion: "0.0.0.0-12.0.0.0",
                newVersion: "12.0.0.0",
            },
            {
                name: "Microsoft.VstsContentStore",
                publicKeyToken: "1055fbdf2d8b69e0",
                culture: "neutral",
                oldVersion: "0.0.0.0-1.3.0.0",
                newVersion: "1.3.0.0",
            },
            {
                name: "System.Collections.Immutable",
                publicKeyToken: "b03f5f7f11d50a3a",
                culture: "neutral",
                oldVersion: "0.0.0.0-1.5.0.0",
                newVersion: "1.5.0",
            },
            {
                name: "Microsoft.ContentStoreInterfaces",
                publicKeyToken: "1055fbdf2d8b69e0",
                culture: "neutral",
                oldVersion: "0.0.0.0-15.1280.0.0",
                newVersion: "1.0.0.0",
            },
            {
                name: "Microsoft.MemoizationStoreInterfaces",
                publicKeyToken: "1055fbdf2d8b69e0",
                culture: "neutral",
                oldVersion: "0.0.0.0-15.1280.0.0",
                newVersion: "1.0.0.0",
            },
            {
                name: "System.Net.Http.Formatting",
                publicKeyToken: "31bf3856ad364e35",
                culture: "neutral",
                oldVersion: "0.0.0.0-5.2.7.0",
                newVersion: "5.2.7.0",
            }
        ],
        tools: {
            csc: {
                platform: <"x64">"x64",
                win32Icon: Branding.iconFile
            },
        },
    });

    let result = Managed.executable(args);

    return Flags.enableESRP ? Signing.esrpSignAssembly(result) : result;
}

@@public
export function assembly(args: Arguments, targetType: Csc.TargetType) : Managed.Assembly {
    args = processArguments(args, targetType);
    return Managed.assembly(args, targetType);
}

/**
 * Builds and runs an xunit test
 */
@@public
export function test(args: TestArguments) : TestResult {
    args = processTestArguments(args);
    
    // Most of the tests relying on spans and System.Memory package references an older version of System.Runtime.CompilerServices.Unsafe assembly.
    if (args.assemblyBindingRedirects === undefined) {
        args = Object.merge<Managed.TestArguments>({
            assemblyBindingRedirects: bxlBindingRedirects()
        }, args);
    }

    let result = Managed.test(args);

    if (!args.skipTestRun) {
        if (Flags.buildRequiredAdminPrivilegeTestInVm) {
            
            let framework = args.testFramework;

            let executeTestUntracked = false;
            let forceXunitForAdminTests = false;
            if (args.runTestArgs && args.runTestArgs.unsafeTestRunArguments) {
                executeTestUntracked = args.runTestArgs.unsafeTestRunArguments.runWithUntrackedDependencies;
                forceXunitForAdminTests = args.runTestArgs.unsafeTestRunArguments.forceXunitForAdminTests;
            }
            if (!Flags.doNotForceXUnitFrameworkInVm || executeTestUntracked || forceXunitForAdminTests) {
                framework = importFrom("Sdk.Managed.Testing.XUnit").framework;
            }

            Contract.assert(args.testFramework !== undefined, "testFramework must have been set by processTestArguments");
            args = args.merge({
                testFramework: framework,
                runTestArgs: {
                    privilegeLevel: <"standard"|"admin">"admin",
                    limitGroups: ["RequiresAdmin"],
                    parallelGroups: undefined,
                    tags: ["RequiresAdminTest"],
                    unsafeTestRunArguments: {
                         // Some unit test assemblies may not have unit tests that require admin privilege.
                        allowForZeroTestCases: true
                    }
                }
            });
            const adminResult = Managed.runTestOnly(
                args, 
                /* compileArguments: */ true,
                /* testDeployment:   */ result.testDeployment);
            result = result.override<TestResult>({ adminTestResults: adminResult });
        }
    }

    return result;
}

const codeAnalysis = p`PolySharpAttributes/System.Diagnostics.CodeAnalysis`;
const compilerServices = p`PolySharpAttributes/System.Runtime.CompilerServices`;

// Needed for .net standard and full framework
@@public
export const notNullAttributesFile = f`${codeAnalysis}/NotNullAttributes.cs`;

@@public
export const polySharpAttributes = {
    // Needed for .net standard and full framework
    notNull: notNullAttributesFile,
    isExternalInit: f`${compilerServices}/IsExternalInit.cs`,
    skipLocalInit: f`${compilerServices}/SkipLocalInitAttribute.cs`,
    moduleInitializer: f`${compilerServices}/ModuleInitializerAttribute.cs`,
    callerArgumentExpression: f`${compilerServices}/CallerArgumentExpressionAttribute.cs`,
    interpolatedStringHandlerArgument: f`${compilerServices}/InterpolatedStringHandlerArgumentAttribute.cs`,
    interpolatedStringHandler: f`${compilerServices}/InterpolatedStringHandlerAttribute.cs`,
    stackTraceHidden: f`PolySharpAttributes/System.Diagnostics/StackTraceHiddenAttribute.cs`,

    // Needed for pre .net 7
    required: f`${compilerServices}/RequiredAttribute.cs`,
    setsRequiredMembers: f`${codeAnalysis}/SetsRequiredMembersAttribute.cs`,
    compilerFeatureRequired: f`${compilerServices}/CompilerFeatureRequiredAttribute.cs`,
    stringSyntax: f`${codeAnalysis}/StringSyntaxAttribute.cs`
};

/**
 * Builds and runs an xunit test
 */
@@public
export function cacheTest(args: TestArguments) : TestResult {
    args = Object.merge<Managed.TestArguments>({
        // Cache tests don't use QTest because QTest doesn't support skipGroups and skipGroups is needed because cache tests fail otherwise.
        testFramework: XUnit.framework,
        runTestArgs: {
            skipGroups: [ "QTestSkip", "Performance", "Simulation", ...(isDotNetCore ? [ "SkipDotNetCore" ] : []) ],
            tags: [ "cacheTest" ]
        },
    }, args);

    // Adding binding redirects to allow running the tests in the IDE.
    if (args.assemblyBindingRedirects === undefined) {
        args = Object.merge<Managed.TestArguments>({
            assemblyBindingRedirects: cacheBindingRedirects()
        }, args);
    }

    // Adding 'Tasks.Extensions' because this assembly is required by all the cache tests.
    args = Object.merge<Managed.TestArguments>({
        references: [
            ...addIf(qualifier.targetFramework === "net472", importFrom("System.Threading.Tasks.Extensions").pkg)
        ]
    }, args);

    return test(args);
}

/**
 * Gets binding redirects required for running tests from the IDE.
 */
@@public
export function bxlBindingRedirects() {
    return [
            // Different packages reference different version of this assembly.
            {
                name: "System.Runtime.CompilerServices.Unsafe",
                publicKeyToken: "b03f5f7f11d50a3a",
                culture: "neutral",
                oldVersion: "0.0.0.0-5.0.0.0",
                newVersion: "5.0.0.0",  // Corresponds to: { id: "System.Runtime.CompilerServices.Unsafe", version: "5.0.0" },
            },
        ];
}

/**
 * Gets binding redirects required for running tests from the IDE.
 */
@@public
export function cacheBindingRedirects() {
    return [
        ...bxlBindingRedirects(),
            // System.Memory 4.5.5 is a bit weird, because net461 version references System.Buffer.dll v.4.0.3.0
            // but System.Memory.dll from netstandard2.0 references System.Buffer.dll v.4.0.2.0!
            // And the rest of the world references System.Buffer.dll v.4.0.3.0
            // So we need to have a redirect to solve this problem.
            {
                name: "System.Buffers",
                publicKeyToken: "cc7b13ffcd2ddd51",
                culture: "neutral",
                oldVersion: "0.0.0.0-5.0.0.0",
                newVersion: "4.0.3.0", // Corresponds to: { id: "System.Buffers", version: "4.5.1" },
            },
            {
                name: "System.Numerics.Vectors",
                publicKeyToken: "b03f5f7f11d50a3a",
                culture: "neutral",
                oldVersion: "0.0.0.0-4.1.4.0",
                newVersion: "4.1.4.0", // Corresponds to: { id: "System.Numerics.Vectors", version: "4.5.0" },
            },

            {
                name: "Microsoft.Bcl.AsyncInterfaces",
                publicKeyToken: "cc7b13ffcd2ddd51",
                culture: "neutral",
                oldVersion: "0.0.0.0-6.0.0.0",
                newVersion: "6.0.0.0", // Corresponds to: { id: "Microsoft.Bcl.AsyncInterfaces", version: "6.0.0" },
            },
            {
                name: "System.Threading.Tasks.Extensions", // Version=4.2.0.1, Culture=neutral, PublicKeyToken=cc7b13ffcd2ddd51
                publicKeyToken: "cc7b13ffcd2ddd51",
                culture: "neutral",
                oldVersion: "0.0.0.0-4.99.99.99",
                newVersion: "4.2.0.1", // Corresponds to: { id: "System.Threading.Tasks.Extensions" },
            },
            {
                name: "System.Memory",
                publicKeyToken: "cc7b13ffcd2ddd51",
                culture: "neutral",
                oldVersion: "0.0.0.0-4.0.1.2",
                newVersion: "4.0.1.2", // Corresponds to: { id: "System.Memory", version: "4.5.5", dependentPackageIdsToSkip: ["System.Runtime.CompilerServices.Unsafe", "System.Numerics.Vectors"] },
            },
            {
                name: "System.Interactive.Async",
                publicKeyToken: "94bc3704cddfc263",
                culture: "neutral",
                oldVersion: "0.0.0.0-3.0.3000.0",
                newVersion: "3.0.3000.0",
            },
            {
                name: "System.Text.Encodings.Web",
                publicKeyToken: "cc7b13ffcd2ddd51",
                culture: "neutral",
                oldVersion: "0.0.0.0-4.0.5.1",
                newVersion: "4.0.5.1", // Corresponds to { id: "System.Text.Encodings.Web", version: "4.7.2" },
            },
            {
                name: "protobuf-net",
                publicKeyToken: "257b51d87d2e4d67",
                culture: "neutral",
                oldVersion: "0.0.0.0-3.0.0.0",
                newVersion: "3.0.0.0", // Corresponds to { id: "System.Text.Encodings.Web", version: "4.7.2" },
            },
            {
                name: "System.IO.Pipelines",
                publicKeyToken: "cc7b13ffcd2ddd51",
                culture: "neutral",
                oldVersion: "0.0.0.0-7.0.0.0",
                newVersion: "7.0.0.0", // Corresponds to { id: "System.IO.Pipelines", version: "7.0.0"...
            },
            {
                name: "System.Threading.Channels",
                publicKeyToken: "cc7b13ffcd2ddd51",
                culture: "neutral",
                oldVersion: "0.0.0.0-7.0.0.0",
                newVersion: "7.0.0.0", // Corresponds to { id: "System.Threading.Channels", version: "7.0.0"...
            },
        ];
}

/**
 * Used in the DScript tests to determine which Xunit to run the test
 */
@@public
export function sdkTest(testFiles:ScriptSdkTestRunner.TestArguments): Managed.TestResult {
    return ScriptSdkTestRunner.test(testFiles);
}

export const assemblyInfo: Managed.AssemblyInfo = {
    productName: Branding.longProductName,
    company: Branding.company,
    copyright: Branding.copyright,
    neutralResourcesLanguage: "en-US",
    version: Branding.Managed.assemblyVersion,
    configuration: qualifier.configuration,
    fileVersion: Branding.Managed.safeFileVersion, // we only rev the fileversion of the main executable to maintain incremental builds.
};

function processArguments(args: Arguments, targetType: Csc.TargetType) : Arguments {
    Contract.requires(
        args !== undefined,
        "BuildXLSdk arguments must not be undefined."
    );

    let framework = Frameworks.framework;
    let assemblyName = args.assemblyName || Context.getLastActiveUseNamespace();
    let title = `${assemblyName}.${targetType === "exe" ? "exe" : "dll"}`;
    let rootNamespace = args.rootNamespace || assemblyName;

    args = Contracts.withRuntimeContracts(args, args.contractsLevel);
    
    let features = [];
    // Using strict mode if its enabled explicitely or if its not disabled explicitly,
    // but enabled by default.
    if (args.strictMode === true || (args.strictMode !== false && Flags.useCSharpCompilerStrictMode === true)) {
        features = features.push('strict');
    }

    if (args.embedPdbs !== false && Flags.embedPdbs === true) {
        args = args.merge<Managed.Arguments>({embedPdbs: true});
    }

    if (Flags.useInProcLogGen && args.generateLogs === true) {
        // If the global flag is set, using in-proc log generation instead of using the external one.
        args = args.merge<Managed.Arguments>({generateLogs: false, generateLogsInProc: true});
    }

    let embedSources = args.embedSources !== false && Flags.embedSources === true;

    let sourceGenerators = args.sourceGenerators || [];

    let analyzers = [
        ...getAnalyzers(args), 
        ...(args.sourceGenerators !== undefined ? args.sourceGenerators.mapMany(s => getAnalyzerDlls(s.contents)) : []),
        ...(args.analyzers !== undefined ? args.analyzers.mapMany(s => getAnalyzerDlls(s.contents)) : [])
        ];

    if (args.generateLogsInProc) {
        // We use custom-built source generators for in-proc log gen that requires special logic here.
        analyzers = [...analyzers, ...getInProcLogGenerators()];
    }

    let ruleset : File = undefined;

    // Required for v2.x Roslyn compilers
    // Flow analysis is used to infer the nullability of variables within executable code. The inferred nullability of a variable is independent of the variable's declared nullability.
    // Method calls are analyzed even when they are conditionally omitted. For instance, `Debug.Assert` in release mode.
    features = features.push("flow-analysis");
    ruleset = f`BuildXL.Recommend.Required.Error.ruleset`;

    args = Object.merge<Arguments>(
        {
            framework: framework,
            assemblyInfo: Object.merge(assemblyInfo, {title: title}, args.assemblyInfo),
            defineConstants: [
                "DEFTEMP",

                ...addIf(isDotNetCoreOrStandard,
                    "FEATURE_SAFE_PROCESS_HANDLE",
                    "DISABLE_FEATURE_VSEXTENSION_INSTALL_CHECK",
                    "DISABLE_FEATURE_EXTENDED_ENCODING"
                ),
                ...addIf(Flags.isMicrosoftInternal,
                    "FEATURE_ARIA_TELEMETRY",
                    "FEATURE_ANYBUILD_PROCESS_REMOTING"
                ),
                ...addIf(isTargetRuntimeOsx,
                    "FEATURE_THROTTLE_EVAL_SCHEDULER"
                ),
            ],
            references: [
                ...(args.skipDefaultReferences ? [] : [
                    ...(isDotNetCoreOrStandard ? [] : [
                        NetFx.System.Threading.Tasks.dll,
                    ]),
                    ...(args.generateLogs || args.generateLogsInProc ? [
                        importFrom("BuildXL.Utilities.Instrumentation").Tracing.dll
                    ] : []),
                ]),
            ],
            // TODO ST: the source gen can emit spans for .net core to avoid having unsafe
            allowUnsafeBlocks: args.allowUnsafeBlocks || args.generateLogs || args.generateLogsInProc, // When we generate logs we must add /unsafe since we generate unsafe code
            tools: {
                csc: {
                    noWarnings: [1701, 1702],
                    warningLevel: "level 4",
                    subSystemVersion: "6.00",
                    languageVersion: "preview", // Allow us using new features like non-nullable types and switch expressions.

                    // TODO: Make analyzers supported in regular references by undestanding the structure in nuget packages
                    analyzers: analyzers,
                    errorlog: Flags.enableGuardian ? r`${assemblyName}/roslyn.csproj.diagnostics.sarif` : undefined,
                    enableGuardian: Flags.enableGuardian,

                    features: features,
                    codeAnalysisRuleset: ruleset,
                    keyFile: args.skipAssemblySigning ? undefined : devKey,
                    shared: Flags.useManagedSharedCompilation,
                    embed: embedSources,
                    reportAnalyzer: Flags.reportAnalyzer,
                    emitCompilerGeneratedFiles: args.emitCompilerGeneratedFiles,
                }
            },
            runCrossgenIfSupported: Flags.enableCrossgen,
        },
        args);

    // If there are any resX files in the arguments, we want to preprocess them so we can
    // parameterize the product name.
    if (args.embeddedResources) {
        args = args.override({
            embeddedResources: args.embeddedResources.map(resource => {
                if (resource.resX) {
                    return resource.override({
                        resX: ResXPreProcessor
                            .withQualifier(Managed.TargetFrameworks.MachineQualifier.current)
                            .preProcess({
                                resX: resource.resX,
                                defines: brandingDefines,
                            })
                            .resX
                    });
                }

                return resource;
            })
        });
    }

    if (args.generateLogs || args.generateLogsInProc) {
        let compileClosure = args.generateLogBinaryRefs !== undefined
            ? [
                ...args.generateLogBinaryRefs,
                ...Managed.Helpers.computeCompileClosure(framework, framework.standardReferences),
            ] : [
                importFrom("BuildXL.Utilities").Utilities.Core.dll.compile,
                importFrom("BuildXL.Utilities.Instrumentation").Tracing.dll.compile,
                ...Managed.Helpers.computeCompileClosure(framework, framework.standardReferences),
            ];
        
        if (args.generateLogs) {
            // $TODO: We have some ugglyness here in that there is not a good way to do a 'under' path check from the sdk
            // without the caller passing in the path. BuildXL.Tracing doesn't follow the proper loggen pattern either with
            // subfolders hence the ugly logic here for now.
            let sources = args.sources.filter(f => f.parent.name === a`Tracing` || f.parent.parent.name === a`Tracing`);

            let extraSourceFile = LogGenerator.generate({
                references: compileClosure,
                sources: sources,
                outputFile: "log.g.cs",
                generationNamespace: rootNamespace,
                defines: args.defineConstants,
                aliases: brandingDefines,
                targetFramework: qualifier.targetFramework,
                targetRuntime: qualifier.targetRuntime,
            });
            
            args = args.merge({
                sources: [extraSourceFile],
            });
        }
        else {
            // generateInPocLogs case
            // Need to create a configuration file to pass required data to the source-based log generator.
            const logGenConfigFolder = Context.getNewOutputDirectory("LogGenConfig");
            const logGenConfig = p`${logGenConfigFolder}/logGen.config`;

            const config = {
                "aliases": brandingDefines,
                "generationNamespace": rootNamespace,
                "targetFramework": qualifier.targetFramework,
                "targetRuntime": qualifier.targetRuntime,
            };
            
            const logGenFile = Json.write(logGenConfig, config, '"');

            args = args.merge({
                tools: {
                    csc: {
                            additionalFiles: [logGenFile]
                    }
                }
            });
        }

    }

    let polySharpAttributeFiles : File[] = [];

    // Add the file with non-nullable attributes for non-dotnet core projects
    // if nullable flag is set, but a special flag is false.
    if (args.addNotNullAttributeFile !== false && !isDotNetCore) {
        if ( (args.nullable || args.addNotNullAttributeFile === true)) {
            polySharpAttributeFiles = polySharpAttributeFiles.push(polySharpAttributes.notNull);
        }
    }

    // Adding attributes required for pre .net6
    if (!isDotNetCore) {
        // Adding 'CallerArgumentExpressionAttribute' unless specified not to.
        if (args.addPolySharpAttributes !== false) {
            polySharpAttributeFiles = polySharpAttributeFiles.push(polySharpAttributes.callerArgumentExpression);
        }

        if (args.addStackTraceHiddenAttribute) {
            polySharpAttributeFiles = polySharpAttributeFiles.push(polySharpAttributes.stackTraceHidden);
        }

        if (args.addPolySharpAttributes !== false) {
            // New interpolated string attributes.
            polySharpAttributeFiles = polySharpAttributeFiles.concat([
                polySharpAttributes.interpolatedStringHandlerArgument,
                polySharpAttributes.interpolatedStringHandler,
                polySharpAttributes.skipLocalInit,
                polySharpAttributes.moduleInitializer]);
        }
    }

    // isExtenalInit is very special.
    // Unlike other attributes, isExternalInit is used by the runtime as well.
    // Consider the following scenario:
    // QuickBuild (net7.0) ---> Cache Aggregator (netstandard2.0) ---> BxlCache (net7.0 & netstandard2.0)
    // When Cache Aggregator is compiled, it uses netstandard2.0 version of BxlCache,
    // but because QuickBuild is net7.0 and it references BxlCache the actual deployment looks like this:
    // QuickBuild - net7.0
    // CacheAggregator - netstandard2.0
    // BxlCache - net7.0
    // So here is the problem:
    // If CacheAggreator uses BxlCache like `new MyRecord() {Prop = 42}` where `Prop` is init-only property,
    // then CacheAggregator will embed the following in the IL:
    // `callvirt instance void modreq([Bxl.Cache]System.Runtime.CompilerServices.IsExternalInit)`
    // 
    // So, if we embed `IsExternalInit` only for netstandard2.0 and not for net7.0,
    // then the .net7 application won't be able to use the intermediate library (CacheAggregator in this case),
    // because `IsExternalInit` in .net7 would be coming from .net core itself and not from Bxl.
    // And an attemp to use a completely legit code would fail with 'MissingMethodException'.
    // 
    // And to workaround this problem we should always include `IsExtenralInit` attribute since in this case
    // the executable will use `IsExternalInit` from the bxl as well.
    if (args.addPolySharpAttributes !== false) {
        polySharpAttributeFiles = polySharpAttributeFiles.concat([polySharpAttributes.isExternalInit]);
    }

    // Required members is needed for non .net7 target frameworks.
    // Uncomment once the .net7 PR is in.
    if (qualifier.targetFramework !== "net7.0" && args.addPolySharpAttributes !== false) {
        polySharpAttributeFiles = polySharpAttributeFiles.concat([polySharpAttributes.required, polySharpAttributes.setsRequiredMembers, polySharpAttributes.compilerFeatureRequired, polySharpAttributes.stringSyntax]);
    }

    args = args.merge({sources: polySharpAttributeFiles});

    // Handle internalsVisibleTo
    if (args.internalsVisibleTo) {
        const internalsVisibleToFile = Transformer.writeAllLines({
            outputPath: p`${Context.getNewOutputDirectory("internalsvisibleto")}/AssemblyInfo.InternalsVisibleTo.g.cs`,
            lines: [
                "using System.Runtime.CompilerServices;",
                "",
                ...args.internalsVisibleTo.map(declaration =>
                {
                    if (typeof(declaration) === "string")
                    {
                        return `[assembly: InternalsVisibleTo("${declaration}, PublicKey=${publicKey}")]`;
                    }
                    
                    let dec = declaration as InternalsVisibleToArguments;
                    return dec.publicKey === undefined
                        ? `[assembly: InternalsVisibleTo("${dec.assembly}")]`
                        : `[assembly: InternalsVisibleTo("${dec.assembly}, PublicKey=${dec.publicKey}")]`;
                })
            ]
        });

        args = args.merge({
            sources: [
                internalsVisibleToFile
            ]
        });
    }

    // Add esrp arguments
    if (Flags.enableESRP) {
        args = args.merge({
            esrpSignConfiguration: Signing.createEsrpConfiguration()
        });
    }

    return args;
}

function getInProcLogGenerators() {
    const sourceLogGen = importFrom("BuildXL.Utilities.Instrumentation").LogGenerator.withQualifier({targetFramework: "netstandard2.0"}).deployed;
    return getRootContent(sourceLogGen.contents);
}

function getRootContent(contents: StaticDirectory): Managed.Binary[] {
    // Getting only the dlls from the root of static directory.
    const root = contents.root.path;
    return contents
        .getContent()
        .filter(file => file.extension === a`.dll` && file.parent === root)
        .map(file => Managed.Factory.createBinary(contents, file));
}

/** Generates a csharp file with an attribute that turns on BuildXL-specific Xunit extension. */
const testFrameworkOverrideAttribute = Transformer.writeAllLines({
    outputPath: Context.getNewOutputDirectory("TestFrameworkOverride").combine("TestFrameworkOverride.g.cs"),
    lines: [
        '[assembly: Test.BuildXL.TestUtilities.XUnit.Extensions.TestFrameworkOverride]'
    ]
});

/** Returns true if test should use QTest framework. */
function shouldUseQTest(runTestArgs: Managed.TestRunArguments) : boolean {
    return Flags.isQTestEnabled                               // Flag to use QTest is enabled.
        && !isDotNetCore                                      // Disable QTest for .net 6 & 7 for now.
        && !(runTestArgs && runTestArgs.parallelBucketCount); // QTest does not support passing environment variables to the underlying process
}

/** Gets test framework. */
function getTestFramework(args: Managed.TestArguments) : Managed.TestFramework {
    return args.testFramework || (shouldUseQTest(args.runTestArgs) ? QTest.getFramework(XUnit.framework) : XUnit.framework);
}

function processTestArguments(args: Managed.TestArguments) : Managed.TestArguments {
    args = processArguments(args, "library");

    let xunitSemaphoreLimit = Environment.hasVariable(envVarNamePrefix + "xunitSemaphoreCount")
        ? Environment.getNumberValue(envVarNamePrefix + "xunitSemaphoreCount")
        : undefined;
    let testFramework = getTestFramework(args);

    args = Object.merge<Managed.TestArguments>({
        testFramework: testFramework,
        skipDocumentationGeneration: true,
        sources: [
            testFrameworkOverrideAttribute,
        ],
        references: [
            importFrom("BuildXL.Utilities.UnitTests").TestUtilities.dll,
            importFrom("BuildXL.Utilities.UnitTests").TestUtilities.XUnit.dll,
            ...addIf(isFullFramework,
                importFrom("System.Runtime.Serialization.Primitives").pkg
            ),
            ...addIf(isFullFramework,
                NetFx.System.Collections.Concurrent.dll,
                NetFx.System.ObjectModel.dll)
        ],
        skipTestRun: !targetFrameworkMatchesCurrentHost,
        runTestArgs: {
            // Adding this path here to resolve the DFA's related to the SRM package of credscan library.
            unsafeTestRunArguments: {
                untrackedScopes: [
                    d`${p`SRM`}`,
                ]
            },
            // TODO: When BuildXL has proper threadsafe logging infrastructure we can go back to the default or parallel.
            parallel: "none",
            tools: {
                exec: {
                    weight: 2,
                    acquireSemaphores: xunitSemaphoreLimit !== undefined
                        ? [ {name: "BuildXL.xunit_semaphore", incrementBy: 1, limit: xunitSemaphoreLimit} ]
                        : undefined,
                    errorRegex: " \b",
                    unsafe: {
                        // allowing process dumps to be written to /cores on macOS
                        untrackedScopes: isHostOsOsx ?  [ d`/cores` ] : []
                    },
                    // Need to let BuildXL know all the paths where the sources are located, because some assertions 
                    // libraries (like FluentAssertion) may decide to read the source file while the test runs in order
                    // to make error messages more descriptive.
                    dependencies: args.sources,
                }
            }
        },
        runtimeContentToSkip: [
            // Don't deploy the branding manifest for unittest so that updating the version number does not affect the unittests.
            importFrom("BuildXL.Utilities").Branding.Manifest.file,
        ]
    }, 
    args);

    return args;
}

namespace Native {
    export declare const qualifier: PlatformDependentQualifier;

    /** Build a native dll. ESRP signs the file if enabled. */
    @@public
    export function library(args: NativeSdk.Dll.Arguments): NativeSdk.Dll.NativeDllImage {
        Contract.requires(
            args !== undefined,
            "Signing.buildDll arguments must not be undefined."
        );
        
        let result = NativeSdk.Dll.build(args);

        if (Flags.enableESRP) {
            return result.override<NativeSdk.Dll.NativeDllImage>({
                binaryFile : Signing.esrpSignFile(result.binaryFile)
            });
        }
        
        return result;
    }

    /** Build a native exe. ESRP signs the file if enabled.*/
    @@public
    export function executable(args: NativeSdk.Exe.Arguments): NativeSdk.Exe.NativeExeImage {
        Contract.requires(
            args !== undefined,
            "Signing.buildExe arguments must not be undefined."
        );
        
        let result = NativeSdk.Exe.build(args);

        if (Flags.enableESRP) {
            return result.override<NativeSdk.Exe.NativeExeImage>({
                binaryFile : Signing.esrpSignFile(result.binaryFile)
            });
        }

        return result;
    }
}