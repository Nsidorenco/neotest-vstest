#r "nuget: Microsoft.TestPlatform.TranslationLayer, 17.11.0"
#r "nuget: Microsoft.TestPlatform.ObjectModel, 17.11.0"
#r "nuget: Microsoft.VisualStudio.TestPlatform, 14.0.0"
#r "nuget: MSTest.TestAdapter, 3.3.1"
#r "nuget: MSTest.TestFramework, 3.3.1"
#r "nuget: Newtonsoft.Json, 13.0.0"

open System
open System.IO
open System.Threading
open System.Threading.Tasks
open Newtonsoft.Json
open System.Collections.Generic
open System.Collections.Concurrent
open Microsoft.TestPlatform.VsTestConsole.TranslationLayer
open Microsoft.VisualStudio.TestPlatform.ObjectModel
open Microsoft.VisualStudio.TestPlatform.ObjectModel.Client
open Microsoft.VisualStudio.TestPlatform.ObjectModel.Client.Interfaces
open Microsoft.VisualStudio.TestPlatform.ObjectModel.Logging

type NeoTestResultError = { message: string }

type NoeTestDiscoveryTestCaseDto =
    { Id: Guid
      CodeFilePath: string
      DisplayName: string
      LineNumber: int
      FullyQualifiedName: string }

type NeoTestDiscoveryResult =
    { File: string
      Test: NoeTestDiscoveryTestCaseDto }

type NeotestResult =
    { status: string
      short: string
      output: string
      errors: NeoTestResultError array }

module TestDiscovery =
    // every command is `<command> <session> <args...>`, where each session is one test project
    let parseArgs (args: string) =
        args.Split(" ", StringSplitOptions.TrimEntries &&& StringSplitOptions.RemoveEmptyEntries)
        |> Array.tail

    [<return: Struct>]
    let (|DiscoveryRequest|_|) (str: string) =
        if str.StartsWith("discover") then
            let args = parseArgs str

            {| Session = args[0]
               OutputPath = args[1]
               WaitFile = args[2]
               RunSettings = args[3]
               Sources = args[4..] |}
            |> ValueOption.Some
        else
            ValueOption.None

    [<return: Struct>]
    let (|RunTests|_|) (str: string) =
        if str.StartsWith("run-tests") then
            let args = parseArgs str

            {| Session = args[0]
               StreamPath = args[1]
               OutputPath = args[2]
               ProcessOutput = args[3]
               OutputDirPath = args[4]
               RunSettings = args[5]
               Ids = args[6..] |> Array.map Guid.Parse |}
            |> ValueOption.Some
        else
            ValueOption.None

    [<return: Struct>]
    let (|DebugTests|_|) (str: string) =
        if str.StartsWith("debug-tests") then
            let args = parseArgs str

            {| Session = args[0]
               PidPath = args[1]
               AttachedPath = args[2]
               StreamPath = args[3]
               OutputPath = args[4]
               ProcessOutput = args[5]
               OutputDirPath = args[6]
               RunSettings = args[7]
               Ids = args[8..] |> Array.map Guid.Parse |}
            |> ValueOption.Some
        else
            ValueOption.None

    [<return: Struct>]
    let (|EndSession|_|) (str: string) =
        if str.StartsWith("end-session") then
            ValueOption.Some((parseArgs str).[0])
        else
            ValueOption.None

    /// Neovim reads a file as soon as it exists, so it is written elsewhere and moved into place
    /// only once complete.
    let writeFileAtomically (path: string) (content: string) =
        let tempPath = path + ".tmp"
        File.WriteAllText(tempPath, content)
        File.Move(tempPath, path, true)

    let logHandler (level: TestMessageLevel) (message: string) =
        if not <| String.IsNullOrWhiteSpace message then
            if level = TestMessageLevel.Error then
                Console.Error.WriteLine(message)
            else
                Console.WriteLine(message)

    /// A vstest console for one test project. Projects share this script's process,
    /// which is slow to start, but each keeps its own console and discovered tests.
    type Session(console: string, parameters: ConsoleParameters) =
        let wrapper = VsTestConsoleWrapper(console, parameters)
        do wrapper.StartSession()

        member _.Wrapper = wrapper

        /// replaced as a whole once a discovery completes, so runs never see a partial discovery
        member val Tests = ConcurrentDictionary<Guid, TestCase>() with get, set

    let getTestCases (tests: ConcurrentDictionary<Guid, TestCase>) (ids: Guid seq) =
        ids
        |> Seq.choose (fun id ->
            match tests.TryGetValue id with
            | true, testCase -> Some testCase
            | _ -> None)
        |> Seq.toArray

    type PlaygroundTestDiscoveryHandler
        (waitFile: string, outputFile: string, publish: ConcurrentDictionary<Guid, TestCase> -> unit) =
        let discoveredTests = ConcurrentDictionary<Guid, TestCase>()

        interface ITestDiscoveryEventsHandler2 with
            member _.HandleDiscoveredTests(discoveredTestCases: IEnumerable<TestCase>) =
                Console.WriteLine($"Discovered tests: {Seq.length discoveredTestCases}")

                discoveredTestCases
                |> Seq.iter (fun testCase ->
                    if String.IsNullOrWhiteSpace testCase.CodeFilePath then
                        testCase.CodeFilePath <- testCase.Source

                    discoveredTests.TryAdd(testCase.Id, testCase) |> ignore)

            member _.HandleDiscoveryComplete(_, _) =
                let testFiles =
                    discoveredTests.Values
                    |> Seq.map (fun test -> test.CodeFilePath)
                    |> Seq.distinct
                    |> String.concat ", "

                Console.WriteLine($"Discovered tests for: {testFiles}")

                do
                    use testsWriter = new StreamWriter(outputFile, append = false)

                    discoveredTests.Values
                    |> Seq.sortBy (fun testCase -> testCase.CodeFilePath, testCase.LineNumber)
                    |> Seq.map (fun testCase ->
                        { File = testCase.CodeFilePath
                          Test =
                            { Id = testCase.Id
                              CodeFilePath = testCase.CodeFilePath
                              DisplayName = testCase.DisplayName
                              LineNumber = testCase.LineNumber
                              FullyQualifiedName = testCase.FullyQualifiedName } })
                    |> Seq.iter (JsonConvert.SerializeObject >> testsWriter.WriteLine)

                publish discoveredTests

                use waitFileWriter = new StreamWriter(waitFile, append = false)
                waitFileWriter.WriteLine("1")

                Console.WriteLine($"Wrote test results to {outputFile}")

            member __.HandleLogMessage(level, message) = logHandler level message

            member __.HandleRawMessage(_) = ()

    type PlaygroundTestRunHandler(streamOutputPath, outputFilePath, processOutputPath, outputDirPath) =
        let resultsDictionary = ConcurrentDictionary()
        let processOutputWriter = new StreamWriter(processOutputPath, append = true)

        interface ITestRunEventsHandler with
            member _.HandleTestRunComplete
                (_testRunCompleteArgs, _lastChunkArgs, _runContextAttachments, _executorUris)
                =
                let output =
                    resultsDictionary
                    |> Seq.map (fun kv -> {| id = kv.Key; result = kv.Value |} |> JsonConvert.SerializeObject)
                    |> String.concat Environment.NewLine

                writeFileAtomically outputFilePath output

            member __.HandleLogMessage(_level, message) =
                if not <| String.IsNullOrWhiteSpace message then
                    processOutputWriter.WriteLine(message)

            member __.HandleRawMessage(_rawMessage) = ()

            member __.HandleTestRunStatsChange(testRunChangedArgs: TestRunChangedEventArgs) : unit =
                let toNeoTestStatus (outcome: TestOutcome) =
                    match outcome with
                    | TestOutcome.Passed -> "passed"
                    | TestOutcome.Failed -> "failed"
                    | _ -> "skipped"

                let results =
                    testRunChangedArgs.NewTestResults
                    |> Seq.map (fun result ->
                        let outcome = toNeoTestStatus result.Outcome

                        let errorMessage =
                            let message = result.ErrorMessage |> Option.ofObj
                            let stackTrace = result.ErrorStackTrace |> Option.ofObj

                            match message, stackTrace with
                            | Some message, Some stackTrace -> Some $"{message}{Environment.NewLine}{stackTrace}"
                            | Some message, None -> Some message
                            | None, Some stackTrace -> Some stackTrace
                            | None, None -> None

                        let errors =
                            match errorMessage with
                            | Some error -> [| { message = error } |]
                            | None -> [||]

                        let id = result.TestCase.Id

                        let neoTestResult =
                            { status = outcome
                              short = $"{result.TestCase.DisplayName}:{outcome}"
                              output = Path.Join(outputDirPath, Guid.NewGuid().ToString())
                              errors = errors }

                        File.WriteAllText(neoTestResult.output, result.ToString())

                        resultsDictionary.AddOrUpdate(id, neoTestResult, (fun _ _ -> neoTestResult))
                        |> ignore

                        (id, neoTestResult))

                use streamWriter = new StreamWriter(streamOutputPath, append = true)

                for (id, result) in results do
                    {| id = id; result = result |}
                    |> JsonConvert.SerializeObject
                    |> streamWriter.WriteLine

            member __.LaunchProcessWithDebuggerAttached(_testProcessStartInfo) = 1

        interface IDisposable with
            member _.Dispose() = processOutputWriter.Dispose()

    type DebugLauncher(pidFile: string, attachedFile: string) =
        interface ITestHostLauncher2 with
            member this.LaunchTestHost(defaultTestHostStartInfo: TestProcessStartInfo) =
                (this :> ITestHostLauncher).LaunchTestHost(defaultTestHostStartInfo, CancellationToken.None)

            member _.LaunchTestHost(_defaultTestHostStartInfo: TestProcessStartInfo, _ct: CancellationToken) = 1

            member this.AttachDebuggerToProcess(pid: int) =
                (this :> ITestHostLauncher2).AttachDebuggerToProcess(pid, CancellationToken.None)

            member _.AttachDebuggerToProcess(pid: int, ct: CancellationToken) =
                use cts = CancellationTokenSource.CreateLinkedTokenSource(ct)
                cts.CancelAfter(TimeSpan.FromSeconds(450.))

                do
                    Console.WriteLine($"spawned test process with pid: {pid}")
                    writeFileAtomically pidFile (string pid)

                while not (cts.Token.IsCancellationRequested || File.Exists(attachedFile)) do
                    ()

                let attached = File.Exists(attachedFile)

                Console.WriteLine($"Debugger attached: {attached}")

                attached

            member __.IsDebug = true


    let main (argv: string[]) =
        if argv.Length <> 1 then
            invalidArg "CommandLineArgs" "Usage: fsi script.fsx <vstest-console-path>"

        let console = argv[0]

        let nullSettings =
            """
        <RunSettings>
        </RunSettings>
        """

        let environmentVariables =
            Map.empty
            |> Map.add "VSTEST_CONNECTION_TIMEOUT" "999"
            |> Map.add "VSTEST_DEBUG_NOBP" "1"
            |> Map.add "VSTEST_RUNNER_DEBUG_ATTACHVS" "0"
            |> Map.add "VSTEST_HOST_DEBUG_ATTACHVS" "0"
            |> Map.add "VSTEST_DATACOLLECTOR_DEBUG_ATTACHVS" "0"
            |> Map.add "DOTNET_ROLL_FORWARD" "Major"
            |> Dictionary

        let options = TestPlatformOptions(CollectMetrics = false)

        let testSession = TestSessionInfo()

        let sessions = ConcurrentDictionary<string, Lazy<Session>>()

        let getSession (id: string) =
            let session =
                sessions.GetOrAdd(
                    id,
                    fun _ -> lazy (Session(console, ConsoleParameters(EnvironmentVariables = environmentVariables)))
                )

            try
                session.Value
            with e ->
                // drop the failed session so the next command retries it
                sessions.TryRemove(KeyValuePair(id, session)) |> ignore
                // lines with this prefix are shown to the user by neovim
                Console.WriteLine($"neotest-vstest-error: failed to start vstest console: {e.Message}")
                reraise ()

        // commands run off the read loop so that one project's command never holds up another's.
        // The returned task never fails, so later commands can wait on it.
        let spawn (name: string) (work: unit -> Task) : Task =
            Task.Run(fun () ->
                task {
                    try
                        do! work ()
                    with e ->
                        Console.WriteLine($"failed to {name}. Exception: {e}")
                }
                :> Task)

        /// the latest discovery sent for each session. Only the read loop touches this, so a command
        /// waits for exactly the discoveries that were sent before it.
        let discoveries = Dictionary<string, Task>()

        let discoveryFor (id: string) =
            match discoveries.TryGetValue id with
            | true, discovery -> discovery
            | _ -> Task.CompletedTask

        let mutable loop = true

        while loop do
            match Console.ReadLine() with
            | DiscoveryRequest args ->
                let sourcesStr = args.Sources |> String.concat " "
                let previous = discoveryFor args.Session

                discoveries[args.Session] <-
                    spawn $"discover tests for {sourcesStr}" (fun () ->
                        task {
                            // a session discovers one at a time, in the order the discoveries were sent
                            do! previous
                            let session = getSession args.Session

                            let discoveryHandler =
                                PlaygroundTestDiscoveryHandler(
                                    args.WaitFile,
                                    args.OutputPath,
                                    fun tests -> session.Tests <- tests
                                )
                                :> ITestDiscoveryEventsHandler2

                            let settings =
                                if (args.RunSettings.CompareTo "nil" <> 0) then
                                    System.IO.File.ReadAllText(args.RunSettings)
                                else
                                    nullSettings

                            Console.WriteLine($"Discovering tests for: {sourcesStr}")
                            session.Wrapper.DiscoverTests(args.Sources, settings, options, testSession, discoveryHandler)
                            Console.WriteLine($"Discovering tests for: {sourcesStr}")
                        })

            | RunTests args ->
                let discovery = discoveryFor args.Session

                spawn "run tests" (fun () ->
                    task {
                        do! discovery
                        let session = getSession args.Session
                        let testCases = getTestCases session.Tests args.Ids

                        use testHandler =
                            new PlaygroundTestRunHandler(
                                args.StreamPath,
                                args.OutputPath,
                                args.ProcessOutput,
                                args.OutputDirPath
                            )

                        let settings =
                            if (args.RunSettings.CompareTo "nil" <> 0) then
                                System.IO.File.ReadAllText(args.RunSettings)
                            else
                                nullSettings

                        do! session.Wrapper.RunTestsAsync(testCases, settings, testHandler)
                        Console.WriteLine($"Done running tests for ids: ")

                        for id in args.Ids do
                            Console.Write($"{id} ")
                    })
                |> ignore
            | DebugTests args ->
                let discovery = discoveryFor args.Session

                spawn "debug tests" (fun () ->
                    task {
                        do! discovery
                        let session = getSession args.Session
                        let testCases = getTestCases session.Tests args.Ids

                        use testHandler =
                            new PlaygroundTestRunHandler(
                                args.StreamPath,
                                args.OutputPath,
                                args.ProcessOutput,
                                args.OutputDirPath
                            )

                        let settings =
                            if (args.RunSettings.CompareTo "nil" <> 0) then
                                System.IO.File.ReadAllText(args.RunSettings)
                            else
                                nullSettings

                        let debugLauncher = DebugLauncher(args.PidPath, args.AttachedPath)
                        Console.WriteLine($"Starting {Seq.length testCases} tests in debug-mode")

                        session.Wrapper.RunTestsWithCustomTestHost(testCases, settings, testHandler, debugLauncher)
                    })
                |> ignore
            | EndSession id ->
                let discovery = discoveryFor id
                discoveries.Remove id |> ignore

                match sessions.TryRemove id with
                | true, session when session.IsValueCreated ->
                    spawn "end session" (fun () ->
                        task {
                            do! discovery
                            session.Value.Wrapper.EndSession()
                        })
                    |> ignore
                | _ -> ()
            | input ->
                Console.WriteLine($"Unknown command: {input}. Terminating process.")
                Environment.ExitCode <- 1
                loop <- false

        for session in sessions.Values do
            if session.IsValueCreated then
                session.Value.Wrapper.EndSession()

        Environment.ExitCode

    let args = fsi.CommandLineArgs |> Array.tail

    main args
