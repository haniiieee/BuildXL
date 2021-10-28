// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using System;
using System.Collections.Generic;
using System.Diagnostics.ContractsLight;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using BuildXL.Cache.ContentStore.Hashing;
using BuildXL.Cache.ContentStore.Interfaces.Extensions;
using BuildXL.Engine.Cache.Fingerprints;
using BuildXL.Ipc.Common;
using BuildXL.Ipc.ExternalApi;
using BuildXL.Ipc.ExternalApi.Commands;
using BuildXL.Ipc.Interfaces;
using BuildXL.Native.IO;
using BuildXL.Scheduler.Artifacts;
using BuildXL.Scheduler.Cache;
using BuildXL.Storage;
using BuildXL.Storage.Fingerprints;
using BuildXL.Tracing;
using BuildXL.Utilities;
using BuildXL.Utilities.Collections;
using BuildXL.Utilities.Instrumentation.Common;
using BuildXL.Utilities.Tasks;
using BuildXL.Utilities.Tracing;

namespace BuildXL.Scheduler
{
    /// <summary>
    /// IPC server providing an implementation for the BuildXL External API <see cref="BuildXL.Ipc.ExternalApi.Client"/>.
    /// </summary>
    public sealed class ApiServer : IIpcOperationExecutor, IDisposable
    {
        private const int GetBuildManifestHashFromLocalFileRetryMultiplierMs = 200; // Worst-case delay = 12.4 sec. Math.Pow(2, retryAttempt) * GetBuildManifestHashFromLocalFileRetryMultiplierMs
        private const int GetBuildManifestHashFromLocalFileRetryLimit = 6;          // Starts from 0, retry multiplier is applied upto (GetBuildManifestHashFromLocalFileRetryLimit - 1)

        private readonly FileContentManager m_fileContentManager;
        private readonly PipTwoPhaseCache m_pipTwoPhaseCache;
        private readonly IServer m_server;
        private readonly PipExecutionContext m_context;
        private readonly Tracing.IExecutionLogTarget m_executionLog;
        private readonly Tracing.BuildManifestGenerator m_buildManifestGenerator;
        private readonly ConcurrentBigMap<ContentHash, ContentHash> m_inMemoryBuildManifestStore;
        private readonly ConcurrentBigMap<string, long> m_receivedStatistics;
        private readonly bool m_verifyFileContentOnBuildManifestHashComputation;
        private LoggingContext m_loggingContext;
        // Build manifest requires HistoricMetadataCache. If it's not available, we need to log a warning on the
        // first build manifest API call. 
        private int m_historicMetadataCacheCheckComplete = 0;

        /// <summary>
        /// Counters for all ApiServer related statistics.
        /// </summary>
        public static readonly CounterCollection<ApiServerCounters> Counters = new CounterCollection<ApiServerCounters>();

        /// <summary>
        /// Counters for all Build Manifest related statistics within ApiServer.
        /// </summary>
        public static readonly CounterCollection<BuildManifestCounters> ManifestCounters = new CounterCollection<BuildManifestCounters>();

        /// <nodoc />
        public ApiServer(
            IIpcProvider ipcProvider,
            string ipcMonikerId,
            FileContentManager fileContentManager,
            PipExecutionContext context,
            IServerConfig config,
            PipTwoPhaseCache pipTwoPhaseCache,
            Tracing.IExecutionLogTarget executionLog,
            Tracing.BuildManifestGenerator buildManifestGenerator,
            bool verifyFileContentOnBuildManifestHashComputation)
        {
            Contract.Requires(ipcMonikerId != null);
            Contract.Requires(fileContentManager != null);
            Contract.Requires(context != null);
            Contract.Requires(config != null);
            Contract.Requires(pipTwoPhaseCache != null);
            Contract.Requires(executionLog != null);

            m_fileContentManager = fileContentManager;
            m_server = ipcProvider.GetServer(ipcProvider.LoadAndRenderMoniker(ipcMonikerId), config);
            m_context = context;
            m_executionLog = executionLog;
            m_buildManifestGenerator = buildManifestGenerator;
            m_pipTwoPhaseCache = pipTwoPhaseCache;
            m_inMemoryBuildManifestStore = new ConcurrentBigMap<ContentHash, ContentHash>();
            m_receivedStatistics = new ConcurrentBigMap<string, long>();
            m_verifyFileContentOnBuildManifestHashComputation = verifyFileContentOnBuildManifestHashComputation;
        }

        /// <summary>
        /// Starts the server. <seealso cref="IServer.Start"/>
        /// </summary>
        public void Start(LoggingContext loggingContext)
        {
            Contract.Requires(loggingContext != null);

            m_loggingContext = loggingContext;
            m_server.Start(this);
        }

        /// <summary>
        /// Stops the server and waits until it is stopped.
        /// <seealso cref="IStoppable.RequestStop"/>, <seealso cref="IStoppable.Completion"/>.
        /// </summary>
        public Task Stop()
        {
            m_server.RequestStop();
            return m_server.Completion;
        }

        /// <inheritdoc/>
        public void Dispose()
        {
            m_server.Dispose();
        }

        /// <summary>
        /// Logs ApiServer's counters as well as the stats reported by server's clients
        /// </summary>
        public void LogStats()
        {
            Counters.LogAsStatistics("ApiServer", m_loggingContext);
            ManifestCounters.LogAsStatistics("ApiServer.BuildManifest", m_loggingContext);
            Logger.Log.BulkStatistic(m_loggingContext, m_receivedStatistics.ToDictionary(kvp => kvp.Key, kvp => kvp.Value));
        }

        private void StoreBuildManifestHash(ContentHash hash, ContentHash manifestHash)
        {
            using (ManifestCounters.StartStopwatch(BuildManifestCounters.InternalHashToHashCacheWriteDuration))
            {
                ManifestCounters.IncrementCounter(BuildManifestCounters.InternalHashToHashCacheWriteCount);
                m_pipTwoPhaseCache.TryStoreBuildManifestHash(hash, manifestHash);
            }
        }

        private ContentHash TryGetBuildManifestHashAsync(ContentHash hash)
        {
            if (Interlocked.CompareExchange(ref m_historicMetadataCacheCheckComplete, 1, 0) == 0)
            {
                // It's the first time this API is called. We need to check that the historic metadata cache is available.
                // The cache is vital to the perf of build manifest, so we need to emit a warning if it cannot be used.
                // CompareExchange ensures that we do this check at most one time.
                var hmc = m_pipTwoPhaseCache as HistoricMetadataCache;
                // Need to make sure the loading task is complete before checking whether the cache is valid.
                hmc?.StartLoading(waitForCompletion: true);
                if (hmc == null || !hmc.Valid)
                {
                    Tracing.Logger.Log.ApiServerReceivedWarningMessage(m_loggingContext, "Build manifest requires historic metadata cache; however, it is not available in this build. This will negatively affect build performance.");
                }
            }

            using (ManifestCounters.StartStopwatch(BuildManifestCounters.InternalHashToHashCacheReadDuration))
            {
                ManifestCounters.IncrementCounter(BuildManifestCounters.InternalHashToHashCacheReadCount);
                var buildManifestHash = m_pipTwoPhaseCache.TryGetBuildManifestHash(hash);
                return buildManifestHash;
            }
        }

        private async Task<Possible<ContentHash>> TryGetBuildManifestHashFromLocalFileAsync(string fullFilePath, ContentHash hash, int retryAttempt = 0)
        {
            if (retryAttempt >= GetBuildManifestHashFromLocalFileRetryLimit)
            {
                string message = $"GetBuildManifestHashFromLocalFileRetryLimit exceeded at path '{fullFilePath}'";
                Tracing.Logger.Log.ApiServerForwardedIpcServerMessage(m_loggingContext, "BuildManifest", message);
                return new Failure<string>(message);
            }

            if (retryAttempt > 0)
            {
                await Task.Delay(TimeSpan.FromMilliseconds(Math.Pow(2, retryAttempt) * GetBuildManifestHashFromLocalFileRetryMultiplierMs));
            }

            if (File.Exists(fullFilePath))
            {
                try
                {
                    ContentHash buildManifestHash;
                    if (m_verifyFileContentOnBuildManifestHashComputation)
                    {
                        using (var fs = FileUtilities.CreateFileStream(fullFilePath, FileMode.Open, FileAccess.Read, FileShare.Delete | FileShare.Read, FileOptions.SequentialScan))
                        {
                            StreamWithLength stream = fs.AssertHasLength();
                            using (var hashingStream = ContentHashingUtilities.GetContentHasher(ContentHashingUtilities.BuildManifestHashType).CreateReadHashingStream(stream))
                            {
                                var actualHash = await ContentHashingUtilities.HashContentStreamAsync(hashingStream.AssertHasLength());
                                buildManifestHash = hashingStream.GetContentHash();

                                if (hash != actualHash)
                                {
                                    return new Failure<string>($"Unexpected file content during build manifest hash computation. Path: '{fullFilePath}', expected hash '{hash}', actual hash '{actualHash}'.");
                                }
                            }
                        }
                    }
                    else
                    {
                        buildManifestHash = await ContentHashingUtilities.HashFileAsync(fullFilePath, ContentHashingUtilities.BuildManifestHashType);
                    }

                    return buildManifestHash;
                }
                catch (Exception ex) when (ex is BuildXLException || ex is IOException)
                {
                    Tracing.Logger.Log.ApiServerForwardedIpcServerMessage(m_loggingContext, "BuildManifest",
                        $"Local file found at path '{fullFilePath}' but threw exception while computing BuildManifest Hash. Retry attempt {retryAttempt} out of {GetBuildManifestHashFromLocalFileRetryLimit}. Exception: {ex}");
                    return await TryGetBuildManifestHashFromLocalFileAsync(fullFilePath, hash, retryAttempt + 1);
                }
            }

            Tracing.Logger.Log.ApiServerForwardedIpcServerMessage(m_loggingContext, "BuildManifest", $"Local file not found at path '{fullFilePath}' while computing BuildManifest Hash. Trying other methods to obtain hash.");
            return new Failure<string>($"File doesn't exist: '{fullFilePath}'");
        }

        /// <summary>
        /// Compute the SHA-256 hash for file stored in Cache. Required for Build Manifest generation.
        /// </summary>
        private async Task<Possible<ContentHash>> ComputeBuildManifestHashFromCacheAsync(BuildManifestEntry buildManifestEntry)
        {
            if (!File.Exists(buildManifestEntry.FullFilePath))
            {
                // Ensure file is materialized locally
                if (!AbsolutePath.TryCreate(m_context.PathTable, buildManifestEntry.FullFilePath, out AbsolutePath path))
                {
                    return new Failure<string>($"Invalid absolute path: '{buildManifestEntry.FullFilePath}'");
                }

                // TODO(1859065): Fix the how FileArtifact is created - we cannot blindly assign rewrite count of 1 (it's ok to treat this as an output due to the condition above)
                // Maybe call materialization on existing files as well? (this will trigger source validation for source files)
                MaterializeFileCommand materializeCommand = new MaterializeFileCommand(FileArtifact.CreateOutputFile(path), buildManifestEntry.FullFilePath);
                IIpcResult materializeResult = await ExecuteMaterializeFileAsync(materializeCommand);
                if (!materializeResult.Succeeded)
                {
                    return new Failure<string>($"Unable to materialize file: '{buildManifestEntry.FullFilePath}' with hash: '{buildManifestEntry.Hash.Serialize()}'. Failure: {materializeResult.Payload}");
                }
            }

            return await TryGetBuildManifestHashFromLocalFileAsync(buildManifestEntry.FullFilePath, buildManifestEntry.Hash);
        }

        async Task<IIpcResult> IIpcOperationExecutor.ExecuteAsync(int id, IIpcOperation op)
        {
            Contract.Requires(op != null);

            Tracing.Logger.Log.ApiServerOperationReceived(m_loggingContext, op.Payload);
            var maybeIpcResult = await TryDeserialize(op.Payload)
                .ThenAsync(cmd => TryExecuteCommand(cmd));

            return maybeIpcResult.Succeeded
                ? maybeIpcResult.Result
                : new IpcResult(IpcResultStatus.ExecutionError, maybeIpcResult.Failure.Describe());
        }

        /// <summary>
        /// Generic ExecuteCommand.  Pattern matches <paramref name="cmd"/> and delegates
        /// to a specific Execute* method based on the commands type.
        /// </summary>
        private async Task<Possible<IIpcResult>> TryExecuteCommand(Command cmd)
        {
            Contract.Requires(cmd != null);

            var materializeFileCmd = cmd as MaterializeFileCommand;
            if (materializeFileCmd != null)
            {
                using (Counters.StartStopwatch(ApiServerCounters.MaterializeFileCallsDuration))
                {
                    var result = await ExecuteCommandWithStats(ExecuteMaterializeFileAsync, materializeFileCmd, ApiServerCounters.MaterializeFileCalls);
                    return new Possible<IIpcResult>(result);
                }

            }

            var registerBuildManifestHashesCmd = cmd as RegisterFilesForBuildManifestCommand;
            if (registerBuildManifestHashesCmd != null)
            {
                using (ManifestCounters.StartStopwatch(BuildManifestCounters.RegisterHashesDuration))
                {
                    var result = await ExecuteCommandWithStats(ExecuteRecordBuildManifestHashesAsync, registerBuildManifestHashesCmd, BuildManifestCounters.BatchedRegisterHashesCalls);
                    return new Possible<IIpcResult>(result);
                }
            }

            var generateBuildManifestDataCmd = cmd as GenerateBuildManifestFileListCommand;
            if (generateBuildManifestDataCmd != null)
            {
                var result = await ExecuteCommandWithStats(ExecuteGenerateBuildManifestFileListAsync, generateBuildManifestDataCmd, BuildManifestCounters.TotalGenerateBuildManifestFileListCalls);
                return new Possible<IIpcResult>(result);
            }

            var reportStatisticsCmd = cmd as ReportStatisticsCommand;
            if (reportStatisticsCmd != null)
            {
                var result = await ExecuteCommandWithStats(ExecuteReportStatistics, reportStatisticsCmd, ApiServerCounters.TotalReportStatisticsCalls);
                return new Possible<IIpcResult>(result);
            }

            var getSealedDirectoryFilesCmd = cmd as GetSealedDirectoryContentCommand;
            if (getSealedDirectoryFilesCmd != null)
            {
                using (Counters.StartStopwatch(ApiServerCounters.GetSealedDirectoryContentDuration))
                {
                    var result = await ExecuteCommandWithStats(ExecuteGetSealedDirectoryContent, getSealedDirectoryFilesCmd, ApiServerCounters.TotalGetSealedDirectoryContentCalls);
                    return new Possible<IIpcResult>(result);
                }
            }

            var logMessageCmd = cmd as LogMessageCommand;
            if (logMessageCmd != null)
            {
                var result = await ExecuteCommandWithStats(ExecuteLogMessage, logMessageCmd, ApiServerCounters.TotalLogMessageCalls);
                return new Possible<IIpcResult>(result);
            }

            var errorMessage = "Unimplemented command: " + cmd.GetType().FullName;
            Contract.Assert(false, errorMessage);
            return new Failure<string>(errorMessage);
        }

        /// <summary>
        /// Executes <see cref="MaterializeFileCommand"/>.  First check that <see cref="MaterializeFileCommand.File"/>
        /// and <see cref="MaterializeFileCommand.FullFilePath"/> match, then delegates to <see cref="FileContentManager.TryMaterializeFileAsync(FileArtifact)"/>.
        /// If provided <see cref="MaterializeFileCommand.File"/> is not valid, no checks are done, and the call is delegated
        /// to <see cref="FileContentManager.TryMaterializeSealedFileAsync(AbsolutePath)"/>
        /// </summary>
        private async Task<IIpcResult> ExecuteMaterializeFileAsync(MaterializeFileCommand cmd)
        {
            Contract.Requires(cmd != null);

            // If the FileArtifact was provided, for extra safety, check that provided file path and file id match
            AbsolutePath filePath;
            bool isValidPath = AbsolutePath.TryCreate(m_context.PathTable, cmd.FullFilePath, out filePath);
            if (cmd.File.IsValid && (!isValidPath || !cmd.File.Path.Equals(filePath)))
            {
                return new IpcResult(
                    IpcResultStatus.ExecutionError,
                    "file path ids differ; file = " + cmd.File.Path.ToString(m_context.PathTable) + ", file path = " + cmd.FullFilePath);
            }
            // If only path was provided, check that it's a valid path.
            else if (!cmd.File.IsValid && !filePath.IsValid)
            {
                return new IpcResult(
                   IpcResultStatus.ExecutionError,
                   $"failed to create AbsolutePath from '{cmd.FullFilePath}'");
            }

            var result = cmd.File.IsValid
                ? await m_fileContentManager.TryMaterializeFileAsync(cmd.File)
                // If file artifact is unknown, try materializing using only the file path.
                // This method has lower chance of success, since it depends on FileContentManager's
                // ability to infer FileArtifact associated with this path.
                : await m_fileContentManager.TryMaterializeSealedFileAsync(filePath);
            bool succeeded = result == ArtifactMaterializationResult.Succeeded;
            string absoluteFilePath = cmd.File.Path.ToString(m_context.PathTable);

            // if file materialization failed, log an error here immediately, so that this errors gets picked up as the root cause 
            // (i.e., the "ErrorBucket") instead of whatever fallout ends up happening (e.g., IPC pip fails)
            if (!succeeded)
            {
                // For sealed files, materialization might not have succeeded because a path is not known to BXL.
                // In such a case, do not log an error, and let the caller deal with the failure.
                if (cmd.File.IsValid)
                {
                    Tracing.Logger.Log.ErrorApiServerMaterializeFileFailed(m_loggingContext, absoluteFilePath, cmd.File.IsValid, result.ToString());
                }
            }
            else
            {
                Tracing.Logger.Log.ApiServerMaterializeFileSucceeded(m_loggingContext, absoluteFilePath);
            }

            return IpcResult.Success(cmd.RenderResult(succeeded));
        }

        private Task<IIpcResult> ExecuteGenerateBuildManifestFileListAsync(GenerateBuildManifestFileListCommand cmd)
            => Task.FromResult(ExecuteGenerateBuildManifestFileList(cmd));

        /// <summary>
        /// Executes <see cref="GenerateBuildManifestFileListCommand"/>. Generates a list of file hashes required for BuildManifest.json file
        /// for given <see cref="GenerateBuildManifestFileListCommand.DropName"/>.
        /// </summary>
        private IIpcResult ExecuteGenerateBuildManifestFileList(GenerateBuildManifestFileListCommand cmd)
        {
            Contract.Requires(cmd != null);
            Contract.Requires(m_buildManifestGenerator != null, "Build Manifest data can only be generated on orchestrator");

            if (!m_buildManifestGenerator.TryGenerateBuildManifestFileList(cmd.DropName, out string error, out var buildManifestFileList))
            {
                return new IpcResult(IpcResultStatus.ExecutionError, error);
            }

            return IpcResult.Success(cmd.RenderResult(buildManifestFileList));
        }

        /// <summary>
        /// Executes <see cref="RegisterFilesForBuildManifestCommand"/>. Checks if Cache contains SHA-256 Hashes for given <see cref="BuildManifestEntry"/>.
        /// Else checks if local files exist and computes their ContentHash.
        /// Returns an empty array on success. Any failing BuildManifestEntries are returned for logging.
        /// If SHA-256 ContentHashes do not exists, the files are materialized using <see cref="ExecuteMaterializeFileAsync"/>, the build manifest hashes are computed and stored into cache.
        /// </summary>
        private async Task<IIpcResult> ExecuteRecordBuildManifestHashesAsync(RegisterFilesForBuildManifestCommand cmd)
        {
            Contract.Requires(cmd != null);

            var tasks = cmd.BuildManifestEntries
                .Select(buildManifestEntry => ExecuteRecordBuildManifestHashWithXlgAsync(cmd.DropName, buildManifestEntry))
                .ToArray();

            var result = await TaskUtilities.SafeWhenAll(tasks);

            if (result.Any(value => !value.IsValid))
            {
                BuildManifestEntry[] failures = result.Where(value => !value.IsValid)
                    .Select(value => new BuildManifestEntry(value.RelativePath, value.AzureArtifactsHash, "Invalid")) // FullFilePath is unused by the caller
                    .ToArray();

                return IpcResult.Success(cmd.RenderResult(failures));
            }
            else
            {
                m_executionLog.RecordFileForBuildManifest(new Tracing.RecordFileForBuildManifestEventData(result.ToList()));

                return IpcResult.Success(cmd.RenderResult(Array.Empty<BuildManifestEntry>()));
            }
        }

        /// <summary>
        /// Returns an invalid <see cref="Tracing.BuildManifestEntry"/> when file read or hash computation fails. 
        /// Else returns a valid <see cref="Tracing.BuildManifestEntry"/> on success.
        /// </summary>
        private async Task<Tracing.BuildManifestEntry> ExecuteRecordBuildManifestHashWithXlgAsync(string dropName, BuildManifestEntry buildManifestEntry)
        {
            await Task.Yield(); // Yield to ensure hashing happens asynchronously

            // (1) Attempt hash read from in-memory store
            if (m_inMemoryBuildManifestStore.TryGetValue(buildManifestEntry.Hash, out var buildManifestHash))
            {
                return new Tracing.BuildManifestEntry(dropName, buildManifestEntry.RelativePath, buildManifestEntry.Hash, buildManifestHash);
            }

            // (2) Attempt hash read from cache
            ContentHash hashFromCache = TryGetBuildManifestHashAsync(buildManifestEntry.Hash);
            if (hashFromCache.IsValid)
            {
                m_inMemoryBuildManifestStore.TryAdd(buildManifestEntry.Hash, hashFromCache);
                return new Tracing.BuildManifestEntry(dropName, buildManifestEntry.RelativePath, buildManifestEntry.Hash, hashFromCache);
            }

            // (3) Attempt to compute hash for locally existing file (Materializes non-existing files)
            using (ManifestCounters.StartStopwatch(BuildManifestCounters.InternalComputeHashLocallyDuration))
            {
                ManifestCounters.IncrementCounter(BuildManifestCounters.InternalComputeHashLocallyCount);
                var computeHashResult = await ComputeBuildManifestHashFromCacheAsync(buildManifestEntry);
                if (computeHashResult.Succeeded)
                {
                    m_inMemoryBuildManifestStore.TryAdd(buildManifestEntry.Hash, computeHashResult.Result);
                    StoreBuildManifestHash(buildManifestEntry.Hash, computeHashResult.Result);
                    return new Tracing.BuildManifestEntry(dropName, buildManifestEntry.RelativePath, buildManifestEntry.Hash, computeHashResult.Result);
                }

                Tracing.Logger.Log.ErrorApiServerGetBuildManifestHashFromLocalFileFailed(m_loggingContext, buildManifestEntry.Hash.Serialize(), computeHashResult.Failure.DescribeIncludingInnerFailures());
            }

            ManifestCounters.IncrementCounter(BuildManifestCounters.TotalHashFileFailures);
            return new Tracing.BuildManifestEntry(dropName, buildManifestEntry.RelativePath, buildManifestEntry.Hash, new ContentHash(HashType.Unknown));
        }

        /// <summary>
        /// Executes <see cref="ReportStatisticsCommand"/>.
        /// </summary>
        private Task<IIpcResult> ExecuteReportStatistics(ReportStatisticsCommand cmd)
        {
            Contract.Requires(cmd != null);

            Tracing.Logger.Log.ApiServerReportStatisticsExecuted(m_loggingContext, cmd.Stats.Count);
            foreach (var statistic in cmd.Stats)
            {
                // we aggregate the stats based on their name
                m_receivedStatistics.AddOrUpdate(
                    statistic.Key,
                    statistic.Value,
                    static (key, value) => value,
                    static (key, newValue, oldValue) => newValue + oldValue);
            }

            return Task.FromResult(IpcResult.Success(cmd.RenderResult(true)));
        }

        private async Task<IIpcResult> ExecuteGetSealedDirectoryContent(GetSealedDirectoryContentCommand cmd)
        {
            Contract.Requires(cmd != null);

            // for extra safety, check that provided directory path and directory id match
            AbsolutePath dirPath;
            bool isValidPath = AbsolutePath.TryCreate(m_context.PathTable, cmd.FullDirectoryPath, out dirPath);
            if (!isValidPath || !cmd.Directory.Path.Equals(dirPath))
            {
                return new IpcResult(
                    IpcResultStatus.ExecutionError,
                    "directory path ids differ, or could not create AbsolutePath; directory = " + cmd.Directory.Path.ToString(m_context.PathTable) + ", directory path = " + cmd.FullDirectoryPath);
            }

            var files = m_fileContentManager.ListSealedDirectoryContents(cmd.Directory);

            Tracing.Logger.Log.ApiServerGetSealedDirectoryContentExecuted(m_loggingContext, cmd.Directory.Path.ToString(m_context.PathTable), files.Length);

            var inputContentsTasks = files
                .Select(f => m_fileContentManager.TryQuerySealedOrUndeclaredInputContentAsync(f.Path, nameof(ApiServer), allowUndeclaredSourceReads: true))
                .ToArray();

            var inputContents = await TaskUtilities.SafeWhenAll(inputContentsTasks);

            var results = new List<BuildXL.Ipc.ExternalApi.SealedDirectoryFile>();
            var failedResults = new List<string>();

            for (int i = 0; i < files.Length; ++i)
            {
                // If the content has no value or has unknown length, then we have some inconsistency wrt the sealed directory content
                // Absent files are an exception since it is possible to have sealed directories with absent files (shared opaques is an example of this). 
                // In those cases we leave the consumer to deal with them.
                if (!inputContents[i].HasValue || (inputContents[i].Value.Hash != WellKnownContentHashes.AbsentFile && !inputContents[i].Value.HasKnownLength))
                {
                    failedResults.Add(files[i].Path.ToString(m_context.PathTable));
                }
                else
                {
                    results.Add(new BuildXL.Ipc.ExternalApi.SealedDirectoryFile(
                        files[i].Path.ToString(m_context.PathTable),
                        files[i],
                        inputContents[i].Value));
                }
            }

            if (failedResults.Count > 0)
            {
                return new IpcResult(
                    IpcResultStatus.ExecutionError,
                    string.Format("Could not find content information for {0} out of {1} files inside of '{4}':{2}{3}",
                        failedResults.Count,
                        files.Length,
                        Environment.NewLine,
                        string.Join("; ", failedResults),
                        cmd.Directory.Path.ToString(m_context.PathTable)));
            }

            return IpcResult.Success(cmd.RenderResult(results));
        }

        /// <summary>
        /// Executes <see cref="LogMessageCommand"/>.
        /// </summary>
        private Task<IIpcResult> ExecuteLogMessage(LogMessageCommand cmd)
        {
            Contract.Requires(cmd != null);

            if (cmd.IsWarning)
            {
                Tracing.Logger.Log.ApiServerReceivedWarningMessage(m_loggingContext, cmd.Message);
            }
            else
            {
                Tracing.Logger.Log.ApiServerReceivedMessage(m_loggingContext, cmd.Message);
            }

            return Task.FromResult(IpcResult.Success(cmd.RenderResult(true)));
        }

        private Possible<Command> TryDeserialize(string operation)
        {
            try
            {
                return Command.Deserialize(operation);
            }
            catch (Exception e)
            {
                Tracing.Logger.Log.ApiServerInvalidOperation(m_loggingContext, operation, e.ToStringDemystified());
                return new Failure<string>("Invalid operation: " + operation);
            }
        }

        private static Task<IIpcResult> ExecuteCommandWithStats<TCommand>(Func<TCommand, Task<IIpcResult>> executor, TCommand cmd, ApiServerCounters totalCounter)
            where TCommand : Command
        {
            Counters.IncrementCounter(totalCounter);
            return executor(cmd);
        }

        private static Task<IIpcResult> ExecuteCommandWithStats<TCommand>(Func<TCommand, Task<IIpcResult>> executor, TCommand cmd, BuildManifestCounters totalCounter)
            where TCommand : Command
        {
            ManifestCounters.IncrementCounter(totalCounter);
            return executor(cmd);
        }
    }

    /// <summary>
    /// Counter types for all ApiServer statistics.
    /// </summary>
    public enum ApiServerCounters
    {
        /// <summary>
        /// Number of <see cref="MaterializeFileCommand"/> calls
        /// </summary>
        [CounterType(CounterType.Numeric)]
        MaterializeFileCalls,

        /// <summary>
        /// Time spent on <see cref="MaterializeFileCommand"/> calls
        /// </summary>
        [CounterType(CounterType.Stopwatch)]
        MaterializeFileCallsDuration,

        /// <summary>
        /// Number of <see cref="ReportStatisticsCommand"/> calls
        /// </summary>
        [CounterType(CounterType.Numeric)]
        TotalReportStatisticsCalls,

        /// <summary>
        /// Number of <see cref="GetSealedDirectoryContentCommand"/> calls
        /// </summary>
        [CounterType(CounterType.Numeric)]
        TotalGetSealedDirectoryContentCalls,

        /// <summary>
        /// Time spent on <see cref="GetSealedDirectoryContentCommand"/> calls
        /// </summary>
        [CounterType(CounterType.Stopwatch)]
        GetSealedDirectoryContentDuration,

        /// <summary>
        /// Time spent on <see cref="LogMessageCommand"/> calls
        /// </summary>
        [CounterType(CounterType.Numeric)]
        TotalLogMessageCalls
    }

    /// <summary>
    /// Counter types for all BuildManifest statistics within ApiServer.
    /// </summary>
    public enum BuildManifestCounters
    {
        /// <summary>
        /// Time spent obtaining hash to hash mappings from cache for build manifest
        /// </summary>
        [CounterType(CounterType.Stopwatch)]
        InternalHashToHashCacheReadDuration,

        /// <summary>
        /// Number of calls for obtaining hash to hash mappings from cache for build manifest
        /// </summary>
        [CounterType(CounterType.Numeric)]
        InternalHashToHashCacheReadCount,

        /// <summary>
        /// Time spent obtaining hash to hash mappings from cache for build manifest
        /// </summary>
        [CounterType(CounterType.Stopwatch)]
        InternalHashToHashCacheWriteDuration,

        /// <summary>
        /// Number of calls for obtaining hash to hash mappings from cache for build manifest
        /// </summary>
        [CounterType(CounterType.Numeric)]
        InternalHashToHashCacheWriteCount,

        /// <summary>
        /// Time spent computing hashes for build manifest (includes materialization times for non-existing files)
        /// </summary>
        [CounterType(CounterType.Stopwatch)]
        InternalComputeHashLocallyDuration,

        /// <summary>
        /// Number of calls for computing hashes for build manifest (includes materialization times for non-existing files)
        /// </summary>
        [CounterType(CounterType.Numeric)]
        InternalComputeHashLocallyCount,

        /// <summary>
        /// Number of <see cref="RegisterFilesForBuildManifestCommand"/> calls
        /// </summary>
        [CounterType(CounterType.Numeric)]
        BatchedRegisterHashesCalls,

        /// <summary>
        /// Time spent on <see cref="RegisterFilesForBuildManifestCommand"/> calls
        /// </summary>
        [CounterType(CounterType.Stopwatch)]
        RegisterHashesDuration,

        /// <summary>
        /// Number of <see cref="GenerateBuildManifestFileListCommand"/> calls
        /// </summary>
        [CounterType(CounterType.Numeric)]
        TotalGenerateBuildManifestFileListCalls,

        /// <summary>
        /// Number of failed file hash computations during <see cref="GenerateBuildManifestFileListCommand"/> calls
        /// </summary>
        [CounterType(CounterType.Numeric)]
        TotalHashFileFailures,
    }
}
