Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Git / file-reader child の内容は private input になり得るため、PowerShell の
# text pipeline を通さず byte stream のまま扱う。C# は in-process library として
# 読み込み、OS ごとの起動・process-tree 境界だけを担当させる。
$runnerTypeName = 'MultiAgentDelegation.PrivateMarkerBoundedProcess'
if ($null -eq ($runnerTypeName -as [type])) {
    $runnerSource = @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace MultiAgentDelegation
{
    public sealed class PrivateMarkerProcessResult
    {
        public int ExitCode;
        public byte[] StandardOutput;
        public byte[] StandardError;
    }

    // 1本のstreamをbounded Taskで読み、上限を超えるchunkをbufferへ追加しない。
    // LongRunning専用threadは完了直後もnative thread handleの解放が遅れるため
    // 使わず、完了Task自体を明示Disposeする。
    internal sealed class PrivateMarkerReadPump : IDisposable
    {
        private Stream source;
        private readonly int limit;
        private readonly string limitCode;
        private MemoryStream buffer;

        public volatile string ErrorCode;
        public Task Task;

        public PrivateMarkerReadPump(Stream source, int limit, string limitCode)
        {
            this.source = source;
            this.limit = limit;
            this.limitCode = limitCode;
            this.buffer = new MemoryStream();
            this.ErrorCode = null;
        }

        public void Start()
        {
            this.Task = System.Threading.Tasks.Task.Factory.StartNew(
                delegate
                {
                    byte[] chunk = new byte[8192];
                    try
                    {
                        while (true)
                        {
                            int count = this.source.Read(chunk, 0, chunk.Length);
                            if (count == 0)
                            {
                                break;
                            }
                            if (this.buffer.Length + count > this.limit)
                            {
                                this.ErrorCode = this.limitCode;
                                break;
                            }
                            this.buffer.Write(chunk, 0, count);
                        }
                    }
                    catch
                    {
                        this.ErrorCode = "process-stream-read-failed";
                    }
                },
                CancellationToken.None,
                TaskCreationOptions.None,
                TaskScheduler.Default
            );
        }

        public byte[] ToArray()
        {
            return this.buffer.ToArray();
        }

        public void Dispose()
        {
            // success pathではTask完了後に必ず呼ばれ、pipe/FileStream、Taskの
            // wait handle、MemoryStreamをGCへ委ねず回収する。failure pathで
            // taskが残っていてもsource closeでreadを解除し、bufferはrace中に
            // disposeしない。
            Stream ownedSource = this.source;
            this.source = null;
            if (ownedSource != null)
            {
                try
                {
                    ownedSource.Dispose();
                }
                catch
                {
                }
            }
            Task ownedTask = this.Task;
            if (ownedTask != null && ownedTask.IsCompleted)
            {
                try
                {
                    ownedTask.Dispose();
                }
                catch
                {
                }
                this.Task = null;
            }
            if (ownedTask == null || ownedTask.IsCompleted)
            {
                MemoryStream ownedBuffer = this.buffer;
                this.buffer = null;
                if (ownedBuffer != null)
                {
                    ownedBuffer.Dispose();
                }
            }
        }
    }

    // stdinもencoding変換せず、そのまま書いて必ずcloseする。closeがcat-file
    // --batch等のEOF契約になるため、空入力でもpumpを起動する。
    internal sealed class PrivateMarkerWritePump : IDisposable
    {
        private Stream destination;
        private readonly byte[] input;

        public volatile string ErrorCode;
        public Task Task;

        public PrivateMarkerWritePump(Stream destination, byte[] input)
        {
            this.destination = destination;
            this.input = input ?? new byte[0];
            this.ErrorCode = null;
        }

        public void Start()
        {
            this.Task = System.Threading.Tasks.Task.Factory.StartNew(
                delegate
                {
                    try
                    {
                        int offset = 0;
                        const int chunkSize = 4096;
                        while (offset < this.input.Length)
                        {
                            int count = Math.Min(chunkSize, this.input.Length - offset);
                            this.destination.Write(this.input, offset, count);
                            this.destination.Flush();
                            offset += count;
                        }
                    }
                    catch
                    {
                        this.ErrorCode = "process-stdin-write-failed";
                    }
                    finally
                    {
                        try
                        {
                            Stream ownedDestination = this.destination;
                            this.destination = null;
                            if (ownedDestination != null)
                            {
                                ownedDestination.Dispose();
                            }
                        }
                        catch
                        {
                            if (this.ErrorCode == null)
                            {
                                this.ErrorCode = "process-stdin-close-failed";
                            }
                        }
                    }
                },
                CancellationToken.None,
                TaskCreationOptions.None,
                TaskScheduler.Default
            );
        }

        public void Dispose()
        {
            Stream ownedDestination = this.destination;
            this.destination = null;
            if (ownedDestination != null)
            {
                try
                {
                    ownedDestination.Dispose();
                }
                catch
                {
                }
            }
            Task ownedTask = this.Task;
            if (ownedTask != null && ownedTask.IsCompleted)
            {
                try
                {
                    ownedTask.Dispose();
                }
                catch
                {
                }
                this.Task = null;
            }
        }
    }

    public static class PrivateMarkerBoundedProcess
    {
        private const int StartfUseStdHandles = 0x00000100;
        private const uint CreateSuspended = 0x00000004;
        private const uint CreateNoWindow = 0x08000000;
        private const uint CreateUnicodeEnvironment = 0x00000400;
        private const uint ExtendedStartupInfoPresent = 0x00080000;
        private const uint HandleFlagInherit = 0x00000001;
        private const uint Infinite = 0xffffffff;
        private const uint WaitObject0 = 0x00000000;
        private const uint WaitTimeout = 0x00000102;
        private const uint JobObjectLimitKillOnJobClose = 0x00002000;
        private const int JobObjectExtendedLimitInformationClass = 9;
        private const int SigTerm = 15;
        private const int SigKill = 9;
        private const int Esrch = 3;
        private const int Eperm = 1;

        private static readonly IntPtr ProcThreadAttributeHandleList =
            new IntPtr(0x00020002);

        // Windows の suspended-launch fault injection は self-test 専用。
        // production path では 0 のままにし、実在 target の PID を公開しない。
        public static int LastSyntheticFailureProcessId { get; private set; }
        public static bool LastSyntheticJobCloseRetrySucceeded {
            get;
            private set;
        }
        public static bool LastSyntheticTerminateProcessFallbackUsed {
            get;
            private set;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes
        {
            public int Length;
            public IntPtr SecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)]
            public bool InheritHandle;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct StartupInfo
        {
            public int Size;
            public string Reserved;
            public string Desktop;
            public string Title;
            public int X;
            public int Y;
            public int XSize;
            public int YSize;
            public int XCountChars;
            public int YCountChars;
            public int FillAttribute;
            public int Flags;
            public short ShowWindow;
            public short Reserved2Size;
            public IntPtr Reserved2;
            public IntPtr StandardInput;
            public IntPtr StandardOutput;
            public IntPtr StandardError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct StartupInfoEx
        {
            public StartupInfo StartupInfo;
            public IntPtr AttributeList;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInformation
        {
            public IntPtr Process;
            public IntPtr Thread;
            public int ProcessId;
            public int ThreadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JobObjectBasicLimitInformation
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JobObjectExtendedLimitInformation
        {
            public JobObjectBasicLimitInformation BasicLimitInformation;
            public IoCounters IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreatePipe(
            out IntPtr readPipe,
            out IntPtr writePipe,
            ref SecurityAttributes pipeAttributes,
            int size
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetHandleInformation(
            IntPtr handle,
            uint mask,
            uint flags
        );

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProcessW(
            string applicationName,
            StringBuilder commandLine,
            IntPtr processAttributes,
            IntPtr threadAttributes,
            [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
            uint creationFlags,
            IntPtr environment,
            string currentDirectory,
            ref StartupInfoEx startupInfo,
            out ProcessInformation processInformation
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr CreateJobObjectW(
            IntPtr jobAttributes,
            string name
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetInformationJobObject(
            IntPtr job,
            int informationClass,
            ref JobObjectExtendedLimitInformation information,
            int informationLength
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool AssignProcessToJobObject(
            IntPtr job,
            IntPtr process
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool TerminateJobObject(
            IntPtr job,
            uint exitCode
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool TerminateProcess(
            IntPtr process,
            uint exitCode
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint ResumeThread(IntPtr thread);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(
            IntPtr handle,
            uint milliseconds
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetExitCodeProcess(
            IntPtr process,
            out uint exitCode
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool InitializeProcThreadAttributeList(
            IntPtr attributeList,
            int attributeCount,
            int flags,
            ref IntPtr size
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UpdateProcThreadAttribute(
            IntPtr attributeList,
            uint flags,
            IntPtr attribute,
            IntPtr value,
            IntPtr size,
            IntPtr previousValue,
            IntPtr returnSize
        );

        [DllImport("kernel32.dll")]
        private static extern void DeleteProcThreadAttributeList(
            IntPtr attributeList
        );

        [DllImport("libc", SetLastError = true)]
        private static extern int kill(int processId, int signal);

        // Public entry point。OS 判定はprocess環境変数ではなくruntime値だけを使う。
        public static PrivateMarkerProcessResult Run(
            string fileName,
            string[] arguments,
            string workingDirectory,
            IDictionary environment,
            byte[] standardInput,
            int timeoutMilliseconds,
            int killWaitMilliseconds,
            int maxStandardOutputBytes,
            int maxStandardErrorBytes,
            string setsidPath,
            string windowsLaunchFailureMode
        )
        {
            ValidateArguments(
                fileName,
                arguments,
                workingDirectory,
                timeoutMilliseconds,
                killWaitMilliseconds,
                maxStandardOutputBytes,
                maxStandardErrorBytes
            );

            // process setup / startもoperation budgetへ含める。tree termination、
            // pipe drain、handle closeは別のkillWait budgetで必ず完走させる。
            Stopwatch operationStopwatch = Stopwatch.StartNew();
            bool isWindows =
                Environment.OSVersion.Platform == PlatformID.Win32NT;
            if (isWindows)
            {
                return RunWindows(
                    fileName,
                    arguments,
                    workingDirectory,
                    environment,
                    standardInput,
                    operationStopwatch,
                    timeoutMilliseconds,
                    killWaitMilliseconds,
                    maxStandardOutputBytes,
                    maxStandardErrorBytes,
                    windowsLaunchFailureMode
                );
            }

            if (!String.IsNullOrEmpty(windowsLaunchFailureMode))
            {
                throw new InvalidOperationException(
                    "windows-launch-failure-mode-invalid"
                );
            }
            if (String.IsNullOrEmpty(setsidPath))
            {
                throw new InvalidOperationException("trusted-setsid-missing");
            }
            return RunPosix(
                fileName,
                arguments,
                workingDirectory,
                environment,
                standardInput,
                operationStopwatch,
                timeoutMilliseconds,
                killWaitMilliseconds,
                maxStandardOutputBytes,
                maxStandardErrorBytes,
                setsidPath
            );
        }

        private static void ValidateArguments(
            string fileName,
            string[] arguments,
            string workingDirectory,
            int timeoutMilliseconds,
            int killWaitMilliseconds,
            int maxStandardOutputBytes,
            int maxStandardErrorBytes
        )
        {
            if (String.IsNullOrEmpty(fileName) || fileName.IndexOf('\0') >= 0)
            {
                throw new InvalidOperationException("process-path-invalid");
            }
            if (
                String.IsNullOrEmpty(workingDirectory) ||
                workingDirectory.IndexOf('\0') >= 0
            )
            {
                throw new InvalidOperationException("process-working-directory-invalid");
            }
            if (
                timeoutMilliseconds <= 0 ||
                killWaitMilliseconds <= 0 ||
                maxStandardOutputBytes < 0 ||
                maxStandardErrorBytes < 0
            )
            {
                throw new InvalidOperationException("process-limit-invalid");
            }
            if (arguments != null)
            {
                for (int index = 0; index < arguments.Length; index++)
                {
                    if (arguments[index] == null || arguments[index].IndexOf('\0') >= 0)
                    {
                        throw new InvalidOperationException("process-argument-invalid");
                    }
                }
            }
        }

        private static void ThrowIfOperationTimedOut(
            Stopwatch operationStopwatch,
            int timeoutMilliseconds
        )
        {
            if (
                operationStopwatch.ElapsedMilliseconds >=
                    timeoutMilliseconds
            )
            {
                throw new InvalidOperationException("process-timeout");
            }
        }

        private static PrivateMarkerProcessResult RunWindows(
            string fileName,
            string[] arguments,
            string workingDirectory,
            IDictionary environment,
            byte[] standardInput,
            Stopwatch operationStopwatch,
            int timeoutMilliseconds,
            int killWaitMilliseconds,
            int maxStandardOutputBytes,
            int maxStandardErrorBytes,
            string launchFailureMode
        )
        {
            if (
                !String.IsNullOrEmpty(launchFailureMode) &&
                !String.Equals(
                    launchFailureMode,
                    "assign",
                    StringComparison.Ordinal
                ) &&
                !String.Equals(
                    launchFailureMode,
                    "resume",
                    StringComparison.Ordinal
                ) &&
                !String.Equals(
                    launchFailureMode,
                    "job-close",
                    StringComparison.Ordinal
                )
            )
            {
                throw new InvalidOperationException(
                    "windows-launch-failure-mode-invalid"
                );
            }
            if (!String.IsNullOrEmpty(launchFailureMode))
            {
                LastSyntheticFailureProcessId = 0;
                LastSyntheticJobCloseRetrySucceeded = false;
                LastSyntheticTerminateProcessFallbackUsed = false;
            }

            IntPtr stdoutRead = IntPtr.Zero;
            IntPtr stdoutWrite = IntPtr.Zero;
            IntPtr stderrRead = IntPtr.Zero;
            IntPtr stderrWrite = IntPtr.Zero;
            IntPtr stdinRead = IntPtr.Zero;
            IntPtr stdinWrite = IntPtr.Zero;
            IntPtr attributeList = IntPtr.Zero;
            IntPtr inheritedHandleList = IntPtr.Zero;
            IntPtr environmentBlock = IntPtr.Zero;
            IntPtr job = IntPtr.Zero;
            ProcessInformation processInformation = new ProcessInformation();
            FileStream stdoutStream = null;
            FileStream stderrStream = null;
            FileStream stdinStream = null;
            bool processCreated = false;
            bool processAssigned = false;
            bool attributeListInitialized = false;

            try
            {
                SecurityAttributes pipeAttributes = new SecurityAttributes();
                pipeAttributes.Length = Marshal.SizeOf(typeof(SecurityAttributes));
                pipeAttributes.SecurityDescriptor = IntPtr.Zero;
                pipeAttributes.InheritHandle = true;

                CreateBoundedPipe(
                    ref pipeAttributes,
                    out stdoutRead,
                    out stdoutWrite,
                    true
                );
                CreateBoundedPipe(
                    ref pipeAttributes,
                    out stderrRead,
                    out stderrWrite,
                    true
                );
                CreateBoundedPipe(
                    ref pipeAttributes,
                    out stdinRead,
                    out stdinWrite,
                    false
                );

                job = CreateJobObjectW(IntPtr.Zero, null);
                if (job == IntPtr.Zero)
                {
                    throw new InvalidOperationException("windows-job-create-failed");
                }
                JobObjectExtendedLimitInformation jobInformation =
                    new JobObjectExtendedLimitInformation();
                jobInformation.BasicLimitInformation.LimitFlags =
                    JobObjectLimitKillOnJobClose;
                if (
                    !SetInformationJobObject(
                        job,
                        JobObjectExtendedLimitInformationClass,
                        ref jobInformation,
                        Marshal.SizeOf(typeof(JobObjectExtendedLimitInformation))
                    )
                )
                {
                    throw new InvalidOperationException("windows-job-configure-failed");
                }

                IntPtr attributeSize = IntPtr.Zero;
                InitializeProcThreadAttributeList(
                    IntPtr.Zero,
                    1,
                    0,
                    ref attributeSize
                );
                if (attributeSize == IntPtr.Zero)
                {
                    throw new InvalidOperationException("windows-handle-list-size-failed");
                }
                attributeList = Marshal.AllocHGlobal(attributeSize);
                if (
                    !InitializeProcThreadAttributeList(
                        attributeList,
                        1,
                        0,
                        ref attributeSize
                    )
                )
                {
                    throw new InvalidOperationException("windows-handle-list-init-failed");
                }
                attributeListInitialized = true;

                inheritedHandleList = Marshal.AllocHGlobal(IntPtr.Size * 3);
                Marshal.WriteIntPtr(inheritedHandleList, 0, stdinRead);
                Marshal.WriteIntPtr(inheritedHandleList, IntPtr.Size, stdoutWrite);
                Marshal.WriteIntPtr(
                    inheritedHandleList,
                    IntPtr.Size * 2,
                    stderrWrite
                );
                if (
                    !UpdateProcThreadAttribute(
                        attributeList,
                        0,
                        ProcThreadAttributeHandleList,
                        inheritedHandleList,
                        new IntPtr(IntPtr.Size * 3),
                        IntPtr.Zero,
                        IntPtr.Zero
                    )
                )
                {
                    throw new InvalidOperationException("windows-handle-list-update-failed");
                }

                StartupInfoEx startupInfo = new StartupInfoEx();
                startupInfo.StartupInfo.Size = Marshal.SizeOf(typeof(StartupInfoEx));
                startupInfo.StartupInfo.Flags = StartfUseStdHandles;
                startupInfo.StartupInfo.StandardInput = stdinRead;
                startupInfo.StartupInfo.StandardOutput = stdoutWrite;
                startupInfo.StartupInfo.StandardError = stderrWrite;
                startupInfo.AttributeList = attributeList;

                environmentBlock = BuildWindowsEnvironmentBlock(environment);
                StringBuilder commandLine = new StringBuilder(
                    BuildCommandLine(fileName, arguments)
                );
                uint creationFlags =
                    CreateSuspended |
                    CreateNoWindow |
                    CreateUnicodeEnvironment |
                    ExtendedStartupInfoPresent;
                ThrowIfOperationTimedOut(
                    operationStopwatch,
                    timeoutMilliseconds
                );
                if (
                    !CreateProcessW(
                        fileName,
                        commandLine,
                        IntPtr.Zero,
                        IntPtr.Zero,
                        true,
                        creationFlags,
                        environmentBlock,
                        workingDirectory,
                        ref startupInfo,
                        out processInformation
                    )
                )
                {
                    throw new InvalidOperationException("windows-process-create-failed");
                }
                processCreated = true;
                if (!String.IsNullOrEmpty(launchFailureMode))
                {
                    LastSyntheticFailureProcessId =
                        processInformation.ProcessId;
                }

                // child側pipe handleはCreateProcess直後に親から閉じる。これにより
                // descendantがJob内で終了した時点のEOFを正しく観測できる。
                CloseRawHandle(ref stdinRead);
                CloseRawHandle(ref stdoutWrite);
                CloseRawHandle(ref stderrWrite);

                // Assign 前の synthetic failure でも target は suspended のまま。
                // catch で terminate / wait の native result を確認してから返す。
                if (
                    String.Equals(
                        launchFailureMode,
                        "assign",
                        StringComparison.Ordinal
                    )
                )
                {
                    throw new InvalidOperationException(
                        "synthetic-windows-job-assign-failed"
                    );
                }
                if (!AssignProcessToJobObject(job, processInformation.Process))
                {
                    throw new InvalidOperationException("windows-job-assign-failed");
                }
                processAssigned = true;

                stdoutStream = TakeReadStream(ref stdoutRead);
                stderrStream = TakeReadStream(ref stderrRead);
                stdinStream = TakeWriteStream(ref stdinWrite);

                // Job 割当後も resume 前に止め、target code を一度も実行せず
                // kill-on-job cleanup を PID / sentinel fixture から検証する。
                if (
                    String.Equals(
                        launchFailureMode,
                        "resume",
                        StringComparison.Ordinal
                    )
                )
                {
                    throw new InvalidOperationException(
                        "synthetic-windows-process-resume-failed"
                    );
                }
                if (
                    String.Equals(
                        launchFailureMode,
                        "job-close",
                        StringComparison.Ordinal
                    )
                )
                {
                    throw new InvalidOperationException(
                        "synthetic-windows-job-close-failed"
                    );
                }
                // targetはまだsuspendedである。setupがbudgetを使い切った場合は
                // user codeを一度も実行せず、catchのkill/wait/closeへ渡す。
                ThrowIfOperationTimedOut(
                    operationStopwatch,
                    timeoutMilliseconds
                );
                if (ResumeThread(processInformation.Thread) == Infinite)
                {
                    throw new InvalidOperationException("windows-process-resume-failed");
                }

                PrivateMarkerProcessResult result = MonitorWindowsProcess(
                    processInformation.Process,
                    job,
                    stdoutStream,
                    stderrStream,
                    stdinStream,
                    standardInput,
                    operationStopwatch,
                    timeoutMilliseconds,
                    killWaitMilliseconds,
                    maxStandardOutputBytes,
                    maxStandardErrorBytes
                );
                return result;
            }
            catch (Exception launchFailure)
            {
                Exception cleanupFailure = null;
                if (processCreated)
                {
                    if (processAssigned)
                    {
                        // Job API failureだけでcleanup経路を終えない。launch中は
                        // targetがsuspendedなので、direct process fallbackで
                        // 少なくとも直下processを確実に停止し、Job closeは
                        // finallyで保持中handleから再試行する。
                        bool forceJobTerminationFailure = String.Equals(
                            launchFailureMode,
                            "job-close",
                            StringComparison.Ordinal
                        );
                        if (
                            forceJobTerminationFailure ||
                            !TerminateJobObject(job, 137)
                        )
                        {
                            cleanupFailure = AppendCleanupFailure(
                                cleanupFailure,
                                new InvalidOperationException(
                                    "windows-launch-job-termination-failed"
                                )
                            );
                            if (
                                !TerminateProcess(
                                    processInformation.Process,
                                    137
                                )
                            )
                            {
                                cleanupFailure = AppendCleanupFailure(
                                    cleanupFailure,
                                    new InvalidOperationException(
                                        "windows-launch-process-fallback-termination-failed"
                                    )
                                );
                            }
                            else if (forceJobTerminationFailure)
                            {
                                LastSyntheticTerminateProcessFallbackUsed =
                                    true;
                            }
                        }
                    }
                    else
                    {
                        // Job割当て前のsuspended processは一度もresumeせず、
                        // process handleから直接終了する。handle closeだけでは
                        // suspended processが残るため、TerminateProcess成功も検査する。
                        if (
                            !TerminateProcess(
                                processInformation.Process,
                                137
                            )
                        )
                        {
                            cleanupFailure = AppendCleanupFailure(
                                cleanupFailure,
                                new InvalidOperationException(
                                    "windows-suspended-process-termination-failed"
                                )
                            );
                        }
                    }
                    uint launchCleanupWait = WaitForSingleObject(
                        processInformation.Process,
                        (uint)killWaitMilliseconds
                    );
                    if (launchCleanupWait != WaitObject0)
                    {
                        cleanupFailure = AppendCleanupFailure(
                            cleanupFailure,
                            new InvalidOperationException(
                                "windows-launch-process-rewait-failed"
                            )
                        );
                    }
                }
                if (cleanupFailure != null)
                {
                    throw new AggregateException(
                        "windows-launch-cleanup-failed",
                        launchFailure,
                        cleanupFailure
                    );
                }
                throw;
            }
            finally
            {
                Exception handleCleanupFailure = null;
                DisposeStream(ref stdoutStream);
                DisposeStream(ref stderrStream);
                DisposeStream(ref stdinStream);
                CloseRawHandleForCleanup(
                    ref stdoutRead,
                    "windows-stdout-read-handle-close-failed",
                    ref handleCleanupFailure
                );
                CloseRawHandleForCleanup(
                    ref stdoutWrite,
                    "windows-stdout-write-handle-close-failed",
                    ref handleCleanupFailure
                );
                CloseRawHandleForCleanup(
                    ref stderrRead,
                    "windows-stderr-read-handle-close-failed",
                    ref handleCleanupFailure
                );
                CloseRawHandleForCleanup(
                    ref stderrWrite,
                    "windows-stderr-write-handle-close-failed",
                    ref handleCleanupFailure
                );
                CloseRawHandleForCleanup(
                    ref stdinRead,
                    "windows-stdin-read-handle-close-failed",
                    ref handleCleanupFailure
                );
                CloseRawHandleForCleanup(
                    ref stdinWrite,
                    "windows-stdin-write-handle-close-failed",
                    ref handleCleanupFailure
                );
                CloseRawHandleForCleanup(
                    ref processInformation.Thread,
                    "windows-thread-handle-close-failed",
                    ref handleCleanupFailure
                );
                CloseRawHandleForCleanup(
                    ref processInformation.Process,
                    "windows-process-handle-close-failed",
                    ref handleCleanupFailure
                );
                // success時も残存descendantをkill-on-closeで必ず回収する。
                // synthetic failureでは初回closeだけを失敗させ、handleを
                // 0化せず同じfinally内のbounded retryで実closeを確認する。
                bool forceFirstJobCloseFailure = String.Equals(
                    launchFailureMode,
                    "job-close",
                    StringComparison.Ordinal
                ) && job != IntPtr.Zero;
                CloseRawHandleForCleanup(
                    ref job,
                    "windows-job-handle-close-failed",
                    ref handleCleanupFailure,
                    forceFirstJobCloseFailure
                );
                if (
                    forceFirstJobCloseFailure &&
                    job == IntPtr.Zero
                )
                {
                    LastSyntheticJobCloseRetrySucceeded = true;
                }
                if (attributeList != IntPtr.Zero)
                {
                    if (attributeListInitialized)
                    {
                        DeleteProcThreadAttributeList(attributeList);
                    }
                    Marshal.FreeHGlobal(attributeList);
                }
                if (inheritedHandleList != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(inheritedHandleList);
                }
                if (environmentBlock != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(environmentBlock);
                }
                if (handleCleanupFailure != null)
                {
                    throw handleCleanupFailure;
                }
            }
        }

        private static PrivateMarkerProcessResult MonitorWindowsProcess(
            IntPtr process,
            IntPtr job,
            FileStream stdoutStream,
            FileStream stderrStream,
            FileStream stdinStream,
            byte[] standardInput,
            Stopwatch operationStopwatch,
            int timeoutMilliseconds,
            int killWaitMilliseconds,
            int maxStandardOutputBytes,
            int maxStandardErrorBytes
        )
        {
            PrivateMarkerReadPump stdout = new PrivateMarkerReadPump(
                stdoutStream,
                maxStandardOutputBytes,
                "process-stdout-limit-exceeded"
            );
            PrivateMarkerReadPump stderr = new PrivateMarkerReadPump(
                stderrStream,
                maxStandardErrorBytes,
                "process-stderr-limit-exceeded"
            );
            PrivateMarkerWritePump stdin = new PrivateMarkerWritePump(
                stdinStream,
                standardInput
            );
            stdout.Start();
            stderr.Start();
            stdin.Start();
            try
            {
                string failure = null;

                while (true)
                {
                    if (
                        operationStopwatch.ElapsedMilliseconds >=
                            timeoutMilliseconds
                    )
                    {
                        failure = "process-timeout";
                        break;
                    }
                    uint wait = WaitForSingleObject(process, 0);
                    bool exited = wait == WaitObject0;
                    if (wait != WaitObject0 && wait != WaitTimeout)
                    {
                        failure = "windows-process-wait-failed";
                        break;
                    }
                    failure = GetPumpFailure(stdout, stderr, stdin, exited);
                    if (failure != null)
                    {
                        break;
                    }
                    if (
                        exited &&
                        stdout.Task.IsCompleted &&
                        stderr.Task.IsCompleted &&
                        stdin.Task.IsCompleted
                    )
                    {
                        break;
                    }
                    Thread.Sleep(10);
                }

                if (failure != null)
                {
                    if (!TerminateJobObject(job, 137))
                    {
                        throw new InvalidOperationException(
                            "windows-process-tree-termination-failed"
                        );
                    }
                    if (
                        WaitForSingleObject(process, (uint)killWaitMilliseconds) !=
                        WaitObject0
                    )
                    {
                        throw new InvalidOperationException(
                            "windows-process-tree-rewait-failed"
                        );
                    }
                    WaitPumpsBounded(
                        stdout,
                        stderr,
                        stdin,
                        killWaitMilliseconds
                    );
                    throw new InvalidOperationException(failure);
                }

                uint exitCode;
                if (!GetExitCodeProcess(process, out exitCode))
                {
                    throw new InvalidOperationException(
                        "windows-exit-code-read-failed"
                    );
                }
                return new PrivateMarkerProcessResult
                {
                    ExitCode = unchecked((int)exitCode),
                    StandardOutput = stdout.ToArray(),
                    StandardError = stderr.ToArray()
                };
            }
            finally
            {
                // successでもFileStream・pipe・long-running Task・bufferを明示
                // disposeする。RunWindows側も所有参照をnull化せずfinallyで
                // idempotent disposeし、将来のearly-returnでも回収を保つ。
                stdout.Dispose();
                stderr.Dispose();
                stdin.Dispose();
            }
        }

        private static PrivateMarkerProcessResult RunPosix(
            string fileName,
            string[] arguments,
            string workingDirectory,
            IDictionary environment,
            byte[] standardInput,
            Stopwatch operationStopwatch,
            int timeoutMilliseconds,
            int killWaitMilliseconds,
            int maxStandardOutputBytes,
            int maxStandardErrorBytes,
            string setsidPath
        )
        {
            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = setsidPath;
            startInfo.Arguments = BuildArgumentString(
                PrependArguments(new string[] { "--wait", "--", fileName }, arguments)
            );
            startInfo.WorkingDirectory = workingDirectory;
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            startInfo.RedirectStandardInput = true;
            startInfo.RedirectStandardOutput = true;
            startInfo.RedirectStandardError = true;
            ApplyProcessEnvironment(startInfo, environment);

            Process process = new Process();
            process.StartInfo = startInfo;
            bool started = false;
            PrivateMarkerReadPump stdout = null;
            PrivateMarkerReadPump stderr = null;
            PrivateMarkerWritePump stdin = null;
            try
            {
                ThrowIfOperationTimedOut(
                    operationStopwatch,
                    timeoutMilliseconds
                );
                if (!process.Start())
                {
                    throw new InvalidOperationException("posix-process-create-failed");
                }
                started = true;
                int processGroupId = process.Id;
                stdout = new PrivateMarkerReadPump(
                    process.StandardOutput.BaseStream,
                    maxStandardOutputBytes,
                    "process-stdout-limit-exceeded"
                );
                stderr = new PrivateMarkerReadPump(
                    process.StandardError.BaseStream,
                    maxStandardErrorBytes,
                    "process-stderr-limit-exceeded"
                );
                stdin = new PrivateMarkerWritePump(
                    process.StandardInput.BaseStream,
                    standardInput
                );
                stdout.Start();
                stderr.Start();
                stdin.Start();
                string failure = null;

                while (true)
                {
                    if (
                        operationStopwatch.ElapsedMilliseconds >=
                            timeoutMilliseconds
                    )
                    {
                        failure = "process-timeout";
                        break;
                    }
                    bool exited = process.HasExited;
                    failure = GetPumpFailure(stdout, stderr, stdin, exited);
                    if (failure != null)
                    {
                        break;
                    }
                    if (
                        exited &&
                        stdout.Task.IsCompleted &&
                        stderr.Task.IsCompleted &&
                        stdin.Task.IsCompleted
                    )
                    {
                        break;
                    }
                    Thread.Sleep(10);
                }

                if (failure != null)
                {
                    TerminatePosixGroup(
                        processGroupId,
                        process,
                        killWaitMilliseconds
                    );
                    WaitPumpsBounded(
                        stdout,
                        stderr,
                        stdin,
                        killWaitMilliseconds
                    );
                    throw new InvalidOperationException(failure);
                }

                // direct childがexitしてpipeもEOFでも、close済みpipeを持たない
                // background descendantが残る可能性をprocess-group probeで拒否する。
                if (PosixGroupExists(processGroupId))
                {
                    TerminatePosixGroup(
                        processGroupId,
                        process,
                        killWaitMilliseconds
                    );
                    throw new InvalidOperationException(
                        "posix-descendant-survived"
                    );
                }

                return new PrivateMarkerProcessResult
                {
                    ExitCode = process.ExitCode,
                    StandardOutput = stdout.ToArray(),
                    StandardError = stderr.ToArray()
                };
            }
            finally
            {
                Exception cleanupFailure = null;
                if (started)
                {
                    try
                    {
                        if (!process.HasExited)
                        {
                            // finally の tree termination failure も成功へ
                            // downgradeせず、cleanup failureとして保持する。
                            TerminatePosixGroup(
                                process.Id,
                                process,
                                killWaitMilliseconds
                            );
                        }
                    }
                    catch (Exception terminationFailure)
                    {
                        cleanupFailure = AppendCleanupFailure(
                            cleanupFailure,
                            terminationFailure
                        );
                    }
                }
                // POSIXでもProcess.Dispose任せにせず、pumpが所有するstream /
                // Task / bufferを成功・失敗の両経路で明示回収する。
                DisposePumps(stdout, stderr, stdin);
                WaitPumpsBounded(
                    stdout,
                    stderr,
                    stdin,
                    killWaitMilliseconds
                );
                // 1回目のstream closeで解除されたTaskをwait後に再度Disposeし、
                // Taskとread bufferもGCへ残さない。
                DisposePumps(stdout, stderr, stdin);
                try
                {
                    // termination が失敗しても managed/native handle の dispose
                    // 自体は必ず試し、両方失敗した場合は情報を集約する。
                    process.Dispose();
                }
                catch (Exception disposeFailure)
                {
                    cleanupFailure = AppendCleanupFailure(
                        cleanupFailure,
                        disposeFailure
                    );
                }
                if (cleanupFailure != null)
                {
                    throw new AggregateException(
                        "posix-process-cleanup-failed",
                        cleanupFailure
                    );
                }
            }
        }

        private static void TerminatePosixGroup(
            int processGroupId,
            Process process,
            int killWaitMilliseconds
        )
        {
            SendPosixGroupSignal(processGroupId, SigTerm);
            // operation deadlineをcleanupへ流用しない。termination/re-waitは
            // 呼出し時点から独立したkillWait slackでboundedに完遂する。
            Stopwatch cleanupStopwatch = Stopwatch.StartNew();
            int grace = Math.Min(250, killWaitMilliseconds);
            while (
                cleanupStopwatch.ElapsedMilliseconds < grace &&
                PosixGroupExists(processGroupId)
            )
            {
                Thread.Sleep(10);
            }
            if (PosixGroupExists(processGroupId))
            {
                SendPosixGroupSignal(processGroupId, SigKill);
            }
            while (
                cleanupStopwatch.ElapsedMilliseconds < killWaitMilliseconds &&
                PosixGroupExists(processGroupId)
            )
            {
                Thread.Sleep(10);
            }
            if (PosixGroupExists(processGroupId))
            {
                throw new InvalidOperationException(
                    "posix-process-tree-rewait-failed"
                );
            }
            if (!process.HasExited)
            {
                if (
                    !process.WaitForExit(
                        Math.Max(
                            1,
                            killWaitMilliseconds -
                                (int)cleanupStopwatch.ElapsedMilliseconds
                        )
                    )
                )
                {
                    throw new InvalidOperationException(
                        "posix-process-direct-rewait-failed"
                    );
                }
            }
        }

        private static void SendPosixGroupSignal(int processGroupId, int signal)
        {
            int result = kill(-processGroupId, signal);
            if (result == 0)
            {
                return;
            }
            int error = Marshal.GetLastWin32Error();
            if (error == Esrch)
            {
                return;
            }
            if (error == Eperm)
            {
                throw new InvalidOperationException(
                    "posix-process-tree-permission-denied"
                );
            }
            throw new InvalidOperationException(
                "posix-process-tree-signal-failed"
            );
        }

        private static bool PosixGroupExists(int processGroupId)
        {
            int result = kill(-processGroupId, 0);
            if (result == 0)
            {
                return true;
            }
            int error = Marshal.GetLastWin32Error();
            if (error == Esrch)
            {
                return false;
            }
            if (error == Eperm)
            {
                throw new InvalidOperationException(
                    "posix-process-tree-permission-denied"
                );
            }
            throw new InvalidOperationException(
                "posix-process-tree-probe-failed"
            );
        }

        private static string GetPumpFailure(
            PrivateMarkerReadPump stdout,
            PrivateMarkerReadPump stderr,
            PrivateMarkerWritePump stdin,
            bool processExited
        )
        {
            if (stdout.ErrorCode != null)
            {
                return stdout.ErrorCode;
            }
            if (stderr.ErrorCode != null)
            {
                return stderr.ErrorCode;
            }
            if (stdin.ErrorCode != null && !processExited)
            {
                return stdin.ErrorCode;
            }
            return null;
        }

        private static void WaitPumpsBounded(
            PrivateMarkerReadPump stdout,
            PrivateMarkerReadPump stderr,
            PrivateMarkerWritePump stdin,
            int milliseconds
        )
        {
            try
            {
                List<Task> tasks = new List<Task>();
                if (stdout != null && stdout.Task != null)
                {
                    tasks.Add(stdout.Task);
                }
                if (stderr != null && stderr.Task != null)
                {
                    tasks.Add(stderr.Task);
                }
                if (stdin != null && stdin.Task != null)
                {
                    tasks.Add(stdin.Task);
                }
                if (tasks.Count > 0)
                {
                    Task.WaitAll(tasks.ToArray(), milliseconds);
                }
            }
            catch
            {
                // primary fixed failure codeを保持する。
            }
        }

        private static void DisposePumps(
            PrivateMarkerReadPump stdout,
            PrivateMarkerReadPump stderr,
            PrivateMarkerWritePump stdin
        )
        {
            if (stdout != null)
            {
                stdout.Dispose();
            }
            if (stderr != null)
            {
                stderr.Dispose();
            }
            if (stdin != null)
            {
                stdin.Dispose();
            }
        }

        private static void CreateBoundedPipe(
            ref SecurityAttributes attributes,
            out IntPtr readPipe,
            out IntPtr writePipe,
            bool parentReads
        )
        {
            if (!CreatePipe(out readPipe, out writePipe, ref attributes, 0))
            {
                throw new InvalidOperationException("windows-pipe-create-failed");
            }
            IntPtr parentHandle = parentReads ? readPipe : writePipe;
            if (!SetHandleInformation(parentHandle, HandleFlagInherit, 0))
            {
                throw new InvalidOperationException(
                    "windows-pipe-inheritance-configure-failed"
                );
            }
        }

        private static FileStream TakeReadStream(ref IntPtr handle)
        {
            SafeFileHandle safe = new SafeFileHandle(handle, true);
            handle = IntPtr.Zero;
            return new FileStream(safe, FileAccess.Read, 4096, false);
        }

        private static FileStream TakeWriteStream(ref IntPtr handle)
        {
            SafeFileHandle safe = new SafeFileHandle(handle, true);
            handle = IntPtr.Zero;
            return new FileStream(safe, FileAccess.Write, 4096, false);
        }

        private static void CloseRawHandle(ref IntPtr handle)
        {
            if (handle != IntPtr.Zero)
            {
                if (!CloseHandle(handle))
                {
                    throw new InvalidOperationException(
                        "windows-raw-handle-close-failed"
                    );
                }
                handle = IntPtr.Zero;
            }
        }

        private static Exception AppendCleanupFailure(
            Exception current,
            Exception next
        )
        {
            if (current == null)
            {
                return next;
            }
            return new AggregateException(current, next);
        }

        private static void CloseRawHandleForCleanup(
            ref IntPtr handle,
            string failureCode,
            ref Exception cleanupFailure,
            bool forceFirstFailure = false
        )
        {
            if (handle == IntPtr.Zero)
            {
                return;
            }

            // Close失敗前に0化するとretryもJob kill-on-closeも失う。最大2回の
            // bounded attemptで、成功を確認した場合だけ所有handleを手放す。
            for (int attempt = 0; attempt < 2; attempt++)
            {
                bool forceFailure = forceFirstFailure && attempt == 0;
                if (!forceFailure && CloseHandle(handle))
                {
                    handle = IntPtr.Zero;
                    return;
                }
            }
            cleanupFailure = AppendCleanupFailure(
                cleanupFailure,
                new InvalidOperationException(failureCode)
            );
        }

        private static void DisposeStream(ref FileStream stream)
        {
            if (stream != null)
            {
                try
                {
                    stream.Dispose();
                }
                catch
                {
                }
                stream = null;
            }
        }

        private static IntPtr BuildWindowsEnvironmentBlock(IDictionary environment)
        {
            List<string> entries = new List<string>();
            if (environment != null)
            {
                foreach (DictionaryEntry entry in environment)
                {
                    string name = Convert.ToString(entry.Key);
                    string value = Convert.ToString(entry.Value);
                    if (
                        String.IsNullOrEmpty(name) ||
                        name.IndexOf('\0') >= 0 ||
                        name.IndexOf('=') >= 0 ||
                        value.IndexOf('\0') >= 0
                    )
                    {
                        throw new InvalidOperationException(
                            "process-environment-invalid"
                        );
                    }
                    entries.Add(name + "=" + value);
                }
            }
            entries.Sort(StringComparer.OrdinalIgnoreCase);
            StringBuilder block = new StringBuilder();
            for (int index = 0; index < entries.Count; index++)
            {
                block.Append(entries[index]);
                block.Append('\0');
            }
            block.Append('\0');
            return Marshal.StringToHGlobalUni(block.ToString());
        }

        private static void ApplyProcessEnvironment(
            ProcessStartInfo startInfo,
            IDictionary environment
        )
        {
            startInfo.EnvironmentVariables.Clear();
            if (environment == null)
            {
                return;
            }
            foreach (DictionaryEntry entry in environment)
            {
                string name = Convert.ToString(entry.Key);
                string value = Convert.ToString(entry.Value);
                if (
                    String.IsNullOrEmpty(name) ||
                    name.IndexOf('\0') >= 0 ||
                    name.IndexOf('=') >= 0 ||
                    value.IndexOf('\0') >= 0
                )
                {
                    throw new InvalidOperationException(
                        "process-environment-invalid"
                    );
                }
                startInfo.EnvironmentVariables[name] = value;
            }
        }

        private static string BuildCommandLine(
            string fileName,
            string[] arguments
        )
        {
            List<string> values = new List<string>();
            values.Add(fileName);
            if (arguments != null)
            {
                values.AddRange(arguments);
            }
            return BuildArgumentString(values.ToArray());
        }

        private static string BuildArgumentString(string[] arguments)
        {
            StringBuilder result = new StringBuilder();
            for (int index = 0; index < arguments.Length; index++)
            {
                if (index > 0)
                {
                    result.Append(' ');
                }
                result.Append(QuoteArgument(arguments[index]));
            }
            return result.ToString();
        }

        private static string[] PrependArguments(
            string[] prefix,
            string[] arguments
        )
        {
            int suffixLength = arguments == null ? 0 : arguments.Length;
            string[] combined = new string[prefix.Length + suffixLength];
            Array.Copy(prefix, combined, prefix.Length);
            if (suffixLength > 0)
            {
                Array.Copy(arguments, 0, combined, prefix.Length, suffixLength);
            }
            return combined;
        }

        // CommandLineToArgvW/.NET ProcessStartInfoの双方で空白・quote・末尾
        // backslashを保持する標準的なinverse quoting。
        private static string QuoteArgument(string value)
        {
            if (value.Length == 0)
            {
                return "\"\"";
            }
            bool quote = false;
            for (int index = 0; index < value.Length; index++)
            {
                char character = value[index];
                if (Char.IsWhiteSpace(character) || character == '"')
                {
                    quote = true;
                    break;
                }
            }
            if (!quote)
            {
                return value;
            }

            StringBuilder result = new StringBuilder();
            result.Append('"');
            int backslashes = 0;
            for (int index = 0; index < value.Length; index++)
            {
                char character = value[index];
                if (character == '\\')
                {
                    backslashes++;
                    continue;
                }
                if (character == '"')
                {
                    result.Append('\\', (backslashes * 2) + 1);
                    result.Append('"');
                    backslashes = 0;
                    continue;
                }
                if (backslashes > 0)
                {
                    result.Append('\\', backslashes);
                    backslashes = 0;
                }
                result.Append(character);
            }
            if (backslashes > 0)
            {
                result.Append('\\', backslashes * 2);
            }
            result.Append('"');
            return result.ToString();
        }
    }
}
'@

    Add-Type -TypeDefinition $runnerSource -Language CSharp
}

function Get-PrivateMarkerTrustedSetsidPath {
    # macOS等でtrusted setsidがない環境を暗黙のdirect-killへdowngradeしない。
    foreach ($candidate in @('/usr/bin/setsid', '/bin/setsid')) {
        if ([System.IO.File]::Exists($candidate)) {
            return $candidate
        }
    }
    return ''
}

function ConvertTo-PrivateMarkerBoundedInteger {
    param(
        [AllowNull()]
        [object]$Value
    )

    # PowerShellの[int] parameter binderは1.5を2へ丸める。公開境界ではraw
    # scalarを保持し、ASCII整数文字列またはCLR整数型だけを明示的に受理する。
    $parsed = 0
    if ($Value -is [string]) {
        $text = [string]$Value
        if (
            $text -notmatch '^[0-9]+$' -or
            -not [int]::TryParse(
                $text,
                [System.Globalization.NumberStyles]::None,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref]$parsed
            )
        ) {
            throw 'process-limit-invalid'
        }
        return $parsed
    }

    $isClrInteger = (
        $Value -is [sbyte] -or
        $Value -is [byte] -or
        $Value -is [int16] -or
        $Value -is [uint16] -or
        $Value -is [int32] -or
        $Value -is [uint32] -or
        $Value -is [int64] -or
        $Value -is [uint64]
    )
    if (-not $isClrInteger) {
        throw 'process-limit-invalid'
    }

    $wideValue = [decimal]$Value
    if (
        $wideValue -lt 0 -or
        $wideValue -gt [int]::MaxValue
    ) {
        throw 'process-limit-invalid'
    }
    return [int]$wideValue
}

function Invoke-PrivateMarkerBoundedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$Arguments = @(),

        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$EnvironmentVariables,

        [byte[]]$StandardInput = [byte[]]@(),

        [object]$TimeoutMilliseconds = 15000,

        [object]$KillWaitMilliseconds = 5000,

        [object]$MaxStandardOutputBytes = 8MB,

        [object]$MaxStandardErrorBytes = 1MB,

        # suspended launch の native cleanup を検査する self-test 専用。
        [ValidateSet('', 'assign', 'resume', 'job-close')]
        [string]$ForceWindowsLaunchFailure = ''
    )

    $timeoutValue = ConvertTo-PrivateMarkerBoundedInteger `
        -Value $TimeoutMilliseconds
    $killWaitValue = ConvertTo-PrivateMarkerBoundedInteger `
        -Value $KillWaitMilliseconds
    $maxStandardOutputValue = ConvertTo-PrivateMarkerBoundedInteger `
        -Value $MaxStandardOutputBytes
    $maxStandardErrorValue = ConvertTo-PrivateMarkerBoundedInteger `
        -Value $MaxStandardErrorBytes

    $setsidPath = if (
        [Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
    ) {
        ''
    } else {
        Get-PrivateMarkerTrustedSetsidPath
    }

    $nativeResult = [MultiAgentDelegation.PrivateMarkerBoundedProcess]::Run(
        $FilePath,
        [string[]]$Arguments,
        $WorkingDirectory,
        $EnvironmentVariables,
        [byte[]]$StandardInput,
        $timeoutValue,
        $killWaitValue,
        $maxStandardOutputValue,
        $maxStandardErrorValue,
        $setsidPath,
        $ForceWindowsLaunchFailure
    )

    return [pscustomobject]@{
        ExitCode = [int]$nativeResult.ExitCode
        StandardOutputBytes = [byte[]]$nativeResult.StandardOutput
        StandardErrorBytes = [byte[]]$nativeResult.StandardError
    }
}

Export-ModuleMember -Function @(
    'Get-PrivateMarkerTrustedSetsidPath',
    'Invoke-PrivateMarkerBoundedProcess'
)
