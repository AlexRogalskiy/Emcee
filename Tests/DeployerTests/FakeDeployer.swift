@testable import Deployer
import Foundation
import PathLib

class FakeDeployer: Deployer {
    var pathsAskedToBeDeployed: [AbsolutePath: DeployableItem] = [:]
    
    override func deployToDestination(pathToDeployable: [AbsolutePath : DeployableItem]) throws {
        pathsAskedToBeDeployed = pathToDeployable
    }
}
