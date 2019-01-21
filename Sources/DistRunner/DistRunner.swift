import BalancingBucketQueue
import Deployer
import DistDeployer
import EventBus
import Foundation
import LocalHostDeterminer
import Logging
import Models
import PortDeterminer
import QueueServer
import ResourceLocationResolver
import ScheduleStrategy
import TempFolder
import Version

public final class DistRunner {    
    private let distRunConfiguration: DistRunConfiguration
    private let eventBus: EventBus
    private let localPortDeterminer: LocalPortDeterminer
    private let localQueueVersionProvider: VersionProvider
    private let resourceLocationResolver: ResourceLocationResolver
    private let tempFolder: TempFolder
    
    public init(
        distRunConfiguration: DistRunConfiguration,
        eventBus: EventBus,
        localPortDeterminer: LocalPortDeterminer,
        localQueueVersionProvider: VersionProvider,
        resourceLocationResolver: ResourceLocationResolver,
        tempFolder: TempFolder)
    {
        self.distRunConfiguration = distRunConfiguration
        self.eventBus = eventBus
        self.localPortDeterminer = localPortDeterminer
        self.localQueueVersionProvider = localQueueVersionProvider
        self.resourceLocationResolver = resourceLocationResolver
        self.tempFolder = tempFolder
    }
    
    public func run() throws -> [TestingResult] {
        let queueServer = QueueServer(
            eventBus: eventBus,
            workerConfigurations: createWorkerConfigurations(),
            reportAliveInterval: distRunConfiguration.reportAliveInterval,
            checkAgainTimeInterval: distRunConfiguration.checkAgainTimeInterval,
            localPortDeterminer: localPortDeterminer,
            nothingToDequeueBehavior: NothingToDequeueBehaviorWaitForAllQueuesToDeplete(checkAfter: distRunConfiguration.checkAgainTimeInterval),
            bucketSplitter: distRunConfiguration.remoteScheduleStrategyType.bucketSplitter(),
            bucketSplitInfo: BucketSplitInfo(
                numberOfWorkers: UInt(distRunConfiguration.destinations.count),
                toolResources: distRunConfiguration.auxiliaryResources.toolResources,
                simulatorSettings: distRunConfiguration.simulatorSettings
            ),
            queueVersionProvider: localQueueVersionProvider
        )
        queueServer.schedule(
            testEntryConfigurations: distRunConfiguration.testEntryConfigurations,
            jobId: distRunConfiguration.runId
        )
        let queuePort = try queueServer.start()
        
        let workersStarter = RemoteWorkersStarter(
            deploymentId: distRunConfiguration.runId.value,
            deploymentDestinations: distRunConfiguration.destinations,
            pluginLocations: distRunConfiguration.auxiliaryResources.plugins,
            queueAddress: SocketAddress(host: LocalHostDeterminer.currentHostAddress, port: queuePort),
            tempFolder: tempFolder
        )
        try workersStarter.deployAndStartWorkers()
        
        return try queueServer.waitForJobToFinish(jobId: distRunConfiguration.runId).testingResults
    }
    
    private func createWorkerConfigurations() -> WorkerConfigurations {
        let configurations = WorkerConfigurations()
        for destination in distRunConfiguration.destinations {
            configurations.add(
                workerId: destination.identifier,
                configuration: distRunConfiguration.workerConfiguration(destination: destination))
        }
        return configurations
    }
}
