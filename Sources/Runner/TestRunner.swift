import BuildArtifacts
import DeveloperDirLocator
import EmceeLogging
import EmceeLoggingModels
import Foundation
import MetricsExtensions
import ProcessController
import RunnerModels
import SimulatorPoolModels
import Tmp
import PathLib

public protocol TestRunnerRunningInvocation {
    var pidInfo: PidInfo { get }
    func cancel()
    func wait()
}

public protocol TestRunnerInvocation {
    func startExecutingTests() throws -> TestRunnerRunningInvocation
}

public protocol TestRunner {
    func additionalEnvironment(
        testRunnerWorkingDirectory: AbsolutePath
    ) -> [String: String]
    
    func prepareTestRun(
        buildArtifacts: AppleBuildArtifacts,
        developerDirLocator: DeveloperDirLocator,
        entriesToRun: [TestEntry],
        logger: ContextualLogger,
        specificMetricRecorder: SpecificMetricRecorder,
        testContext: AppleTestContext,
        testRunnerStream: TestRunnerStream
    ) throws -> TestRunnerInvocation
}
