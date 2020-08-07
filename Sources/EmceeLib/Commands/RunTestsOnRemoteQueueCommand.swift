import ArgLib
import BucketQueue
import DateProvider
import Deployer
import DeveloperDirLocator
import DistDeployer
import EmceeVersion
import FileSystem
import Foundation
import Logging
import LoggingSetup
import PathLib
import PluginManager
import PortDeterminer
import ProcessController
import QueueClient
import QueueCommunication
import QueueModels
import QueueServer
import RemotePortDeterminer
import RequestSender
import ResourceLocationResolver
import SignalHandling
import SimulatorPool
import SocketModels
import SynchronousWaiter
import TemporaryStuff
import TestArgFile
import TestDiscovery
import UniqueIdentifierGenerator

public final class RunTestsOnRemoteQueueCommand: Command {
    public let name = "runTestsOnRemoteQueue"
    public let description = "Starts queue server on remote machine if needed and runs tests on the remote queue. Waits for resuls to come back."
    public let arguments: Arguments = [
        ArgumentDescriptions.emceeVersion.asOptional,
        ArgumentDescriptions.jobGroupId.asOptional,
        ArgumentDescriptions.jobGroupPriority.asOptional,
        ArgumentDescriptions.jobId.asRequired,
        ArgumentDescriptions.junit.asOptional,
        ArgumentDescriptions.queueServerConfigurationLocation.asRequired,
        ArgumentDescriptions.remoteCacheConfig.asOptional,
        ArgumentDescriptions.tempFolder.asRequired,
        ArgumentDescriptions.testArgFile.asRequired,
        ArgumentDescriptions.trace.asOptional,
    ]
    
    private let dateProvider: DateProvider
    private let developerDirLocator: DeveloperDirLocator
    private let fileSystem: FileSystem
    private let pluginEventBusProvider: PluginEventBusProvider
    private let processControllerProvider: ProcessControllerProvider
    private let requestSenderProvider: RequestSenderProvider
    private let resourceLocationResolver: ResourceLocationResolver
    private let uniqueIdentifierGenerator: UniqueIdentifierGenerator
    private let runtimeDumpRemoteCacheProvider: RuntimeDumpRemoteCacheProvider
    
    public init(
        dateProvider: DateProvider,
        developerDirLocator: DeveloperDirLocator,
        fileSystem: FileSystem,
        pluginEventBusProvider: PluginEventBusProvider,
        processControllerProvider: ProcessControllerProvider,
        requestSenderProvider: RequestSenderProvider,
        resourceLocationResolver: ResourceLocationResolver,
        uniqueIdentifierGenerator: UniqueIdentifierGenerator,
        runtimeDumpRemoteCacheProvider: RuntimeDumpRemoteCacheProvider
    ) {
        self.dateProvider = dateProvider
        self.developerDirLocator = developerDirLocator
        self.fileSystem = fileSystem
        self.pluginEventBusProvider = pluginEventBusProvider
        self.processControllerProvider = processControllerProvider
        self.requestSenderProvider = requestSenderProvider
        self.resourceLocationResolver = resourceLocationResolver
        self.uniqueIdentifierGenerator = uniqueIdentifierGenerator
        self.runtimeDumpRemoteCacheProvider = runtimeDumpRemoteCacheProvider
    }
    
    public func run(payload: CommandPayload) throws {
        let commonReportOutput = ReportOutput(
            junit: try payload.optionalSingleTypedValue(argumentName: ArgumentDescriptions.junit.name),
            tracingReport: try payload.optionalSingleTypedValue(argumentName: ArgumentDescriptions.trace.name)
        )

        let queueServerConfigurationLocation: QueueServerConfigurationLocation = try payload.expectedSingleTypedValue(argumentName: ArgumentDescriptions.queueServerConfigurationLocation.name)
        let queueServerConfiguration = try ArgumentsReader.queueServerConfiguration(
            location: queueServerConfigurationLocation,
            resourceLocationResolver: resourceLocationResolver
        )

        let jobId: JobId = try payload.expectedSingleTypedValue(argumentName: ArgumentDescriptions.jobId.name)
        let jobGroupId: JobGroupId = try payload.optionalSingleTypedValue(argumentName: ArgumentDescriptions.jobGroupId.name) ?? JobGroupId(value: jobId.value)
        let emceeVersion: Version = try payload.optionalSingleTypedValue(argumentName: ArgumentDescriptions.emceeVersion.name) ?? EmceeVersion.version
        
        let tempFolder = try TemporaryFolder(containerPath: try payload.expectedSingleTypedValue(argumentName: ArgumentDescriptions.tempFolder.name))
        let testArgFile = try ArgumentsReader.testArgFile(try payload.expectedSingleTypedValue(argumentName: ArgumentDescriptions.testArgFile.name))
        let jobGroupPriority: Priority = try payload.optionalSingleTypedValue(argumentName: ArgumentDescriptions.jobGroupPriority.name) ?? testArgFile.priority

        let remoteCacheConfig = try ArgumentsReader.remoteCacheConfig(
            try payload.optionalSingleTypedValue(argumentName: ArgumentDescriptions.remoteCacheConfig.name)
        )

        let runningQueueServerAddress = try detectRemotelyRunningQueueServerPortsOrStartRemoteQueueIfNeeded(
            emceeVersion: emceeVersion,
            queueServerDeploymentDestination: queueServerConfiguration.queueServerDeploymentDestination,
            queueServerConfigurationLocation: queueServerConfigurationLocation,
            jobId: jobId,
            tempFolder: tempFolder
        )
        let jobResults = try runTestsOnRemotelyRunningQueue(
            jobGroupId: jobGroupId,
            jobGroupPriority: jobGroupPriority,
            jobId: jobId,
            queueServerAddress: runningQueueServerAddress,
            remoteCacheConfig: remoteCacheConfig,
            tempFolder: tempFolder,
            testArgFile: testArgFile,
            version: emceeVersion
        )
        let resultOutputGenerator = ResultingOutputGenerator(
            testingResults: jobResults.testingResults,
            commonReportOutput: commonReportOutput,
            testDestinationConfigurations: testArgFile.testDestinationConfigurations
        )
        try resultOutputGenerator.generateOutput()
    }
    
    private func detectRemotelyRunningQueueServerPortsOrStartRemoteQueueIfNeeded(
        emceeVersion: Version,
        queueServerDeploymentDestination: DeploymentDestination,
        queueServerConfigurationLocation: QueueServerConfigurationLocation,
        jobId: JobId,
        tempFolder: TemporaryFolder
    ) throws -> SocketAddress {
        Logger.info("Searching for queue server on '\(queueServerDeploymentDestination.host)' with queue version \(emceeVersion)")
        let remoteQueueDetector = DefaultRemoteQueueDetector(
            emceeVersion: emceeVersion,
            remotePortDeterminer: RemoteQueuePortScanner(
                host: queueServerDeploymentDestination.host,
                portRange: EmceePorts.defaultQueuePortRange,
                requestSenderProvider: requestSenderProvider
            )
        )
        var suitablePorts = try remoteQueueDetector.findSuitableRemoteRunningQueuePorts(timeout: 10)
        if !suitablePorts.isEmpty {
            let socketAddress = SocketAddress(
                host: queueServerDeploymentDestination.host,
                port: try selectPort(ports: suitablePorts)
            )
            Logger.info("Found queue server at '\(socketAddress)'")
            return socketAddress
        }
        
        Logger.info("No running queue server has been found. Will deploy and start remote queue.")
        let remoteQueueStarter = RemoteQueueStarter(
            deploymentId: jobId.value,
            deploymentDestination: queueServerDeploymentDestination,
            emceeVersion: emceeVersion,
            processControllerProvider: processControllerProvider,
            queueServerConfigurationLocation: queueServerConfigurationLocation,
            tempFolder: tempFolder,
            uniqueIdentifierGenerator: uniqueIdentifierGenerator
        )
        let deployQueue = DispatchQueue(label: "RunTestsOnRemoteQueueCommand.deployQueue", attributes: .concurrent)
        deployQueue.async {
            do {
                try remoteQueueStarter.deployAndStart()
            } catch {
                Logger.error("Failed to deploy: \(error)")
            }
        }
        
        try SynchronousWaiter().waitWhile(pollPeriod: 1.0, timeout: 30.0, description: "Wait for remote queue to start") {
            suitablePorts = try remoteQueueDetector.findSuitableRemoteRunningQueuePorts(timeout: 10)
            return suitablePorts.isEmpty
        }
        
        let queueServerAddress = SocketAddress(
            host: queueServerDeploymentDestination.host,
            port: try selectPort(ports: suitablePorts)
        )
        Logger.info("Found queue server at '\(queueServerAddress)'")

        return queueServerAddress
    }
    
    private func runTestsOnRemotelyRunningQueue(
        jobGroupId: JobGroupId,
        jobGroupPriority: Priority,
        jobId: JobId,
        queueServerAddress: SocketAddress,
        remoteCacheConfig: RuntimeDumpRemoteCacheConfig?,
        tempFolder: TemporaryFolder,
        testArgFile: TestArgFile,
        version: Version
    ) throws -> JobResults {
        let onDemandSimulatorPool = OnDemandSimulatorPoolFactory.create(
            dateProvider: dateProvider,
            developerDirLocator: developerDirLocator,
            fileSystem: fileSystem,
            processControllerProvider: processControllerProvider,
            resourceLocationResolver: resourceLocationResolver,
            tempFolder: tempFolder,
            uniqueIdentifierGenerator: uniqueIdentifierGenerator,
            version: version
        )
        defer { onDemandSimulatorPool.deleteSimulators() }
        let testDiscoveryQuerier = TestDiscoveryQuerierImpl(
            dateProvider: dateProvider,
            developerDirLocator: developerDirLocator,
            fileSystem: fileSystem,
            numberOfAttemptsToPerformRuntimeDump: 5,
            onDemandSimulatorPool: onDemandSimulatorPool,
            pluginEventBusProvider: pluginEventBusProvider,
            processControllerProvider: processControllerProvider,
            remoteCache: runtimeDumpRemoteCacheProvider.remoteCache(config: remoteCacheConfig),
            resourceLocationResolver: resourceLocationResolver,
            tempFolder: tempFolder,
            testRunnerProvider: DefaultTestRunnerProvider(
                dateProvider: dateProvider,
                processControllerProvider: processControllerProvider,
                resourceLocationResolver: resourceLocationResolver
            ),
            uniqueIdentifierGenerator: UuidBasedUniqueIdentifierGenerator(),
            version: version
        )
        
        let queueClient = SynchronousQueueClient(queueServerAddress: queueServerAddress)
        
        defer {
            Logger.info("Will delete job \(jobId)")
            do {
                _ = try queueClient.delete(jobId: jobId)
            } catch {
                Logger.error("Failed to delete job \(jobId): \(error)")
            }
        }

        let testEntriesValidator = TestEntriesValidator(
            testArgFileEntries: testArgFile.entries,
            testDiscoveryQuerier: testDiscoveryQuerier
        )
        
        _ = try testEntriesValidator.validatedTestEntries { testArgFileEntry, validatedTestEntry in
            let testEntryConfigurationGenerator = TestEntryConfigurationGenerator(
                validatedEntries: validatedTestEntry,
                testArgFileEntry: testArgFileEntry
            )
            let testEntryConfigurations = testEntryConfigurationGenerator.createTestEntryConfigurations()
            Logger.info("Will schedule \(testEntryConfigurations.count) tests to queue server at \(queueServerAddress)")
            
            do {
                _ = try queueClient.scheduleTests(
                    prioritizedJob: PrioritizedJob(
                        jobGroupId: jobGroupId,
                        jobGroupPriority: jobGroupPriority,
                        jobId: jobId,
                        jobPriority: testArgFile.priority
                    ),
                    scheduleStrategy: testArgFileEntry.scheduleStrategy,
                    testEntryConfigurations: testEntryConfigurations,
                    requestId: RequestId(value: uniqueIdentifierGenerator.generate())
                )
            } catch {
                Logger.error("Failed to schedule tests: \(error)")
                throw error
            }
        }
        
        var caughtSignal = false
        SignalHandling.addSignalHandler(signals: [.int, .term]) { signal in
            Logger.info("Caught \(signal) signal")
            Logger.info("Will delete job \(jobId)")
            _ = try? queueClient.delete(jobId: jobId)
            caughtSignal = true
        }
        
        Logger.info("Will now wait for job queue to deplete")
        try SynchronousWaiter().waitWhile(pollPeriod: 30.0, description: "Wait for job queue to deplete") {
            if caughtSignal { return false }
            let jobState = try queueClient.jobState(jobId: jobId)
            switch jobState.queueState {
            case .deleted:
                return false
            case .running(let runningQueueState):
                BucketQueueStateLogger(runningQueueState: runningQueueState).logQueueSize()
                return !runningQueueState.isDepleted
            }
        }
        Logger.info("Will now fetch job results")
        return try queueClient.jobResults(jobId: jobId)
    }
    
    private func selectPort(ports: Set<SocketModels.Port>) throws -> SocketModels.Port {
        enum PortScanningError: Error, CustomStringConvertible {
            case noQueuePortDetected
            
            var description: String {
                switch self {
                case .noQueuePortDetected:
                    return "No running queue server found"
                }
            }
        }
        
        guard let port = ports.sorted().last else { throw PortScanningError.noQueuePortDetected }
        return port
    }
}
