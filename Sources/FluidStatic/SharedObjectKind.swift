import FluidJS
import FluidDatastore
import FluidMap
import FluidCounter
import FluidCell
import FluidRegisterCollection
import FluidSharedSummaryBlock
import FluidPactMap
import FluidTaskManager
import FluidOrderedCollection
import FluidLegacyDDS
import FluidSequence
import FluidMatrix

/// Ports shared-object-base/src/sharedObject.ts `ISharedObjectKind` (the public `SharedObjectKind`
/// is its opaque view). TS exports one kind value per DDS, made by `createSharedObjectKind(factory)`;
/// here the DDS class itself is the kind, so a schema names `SharedMap.self` where TS names
/// `SharedMap`.
///
/// It lives in FluidStatic, not FluidSharedObjectBase, because `ChannelFactory` (the Swift
/// `IChannelFactory`) is declared in FluidDatastore, which depends on FluidSharedObjectBase.
public protocol SharedObjectKind: AnyObject {
    static func getFactory() -> ChannelFactory
}

/// map/src/mapFactory.ts `MapFactory.Attributes`.
extension SharedMap: SharedObjectKind {
    public static func getFactory() -> ChannelFactory {
        ChannelFactory(SharedMap.self, snapshotFormatVersion: "0.2")
    }
}

/// map/src/directoryFactory.ts `DirectoryFactory.Attributes`.
extension SharedDirectory: SharedObjectKind {
    public static func getFactory() -> ChannelFactory {
        ChannelFactory(SharedDirectory.self, snapshotFormatVersion: "0.1")
    }
}

/// counter/src/counterFactory.ts `CounterFactory.Attributes`.
extension SharedCounter: SharedObjectKind {
    public static func getFactory() -> ChannelFactory {
        ChannelFactory(SharedCounter.self, snapshotFormatVersion: "0.1")
    }
}

/// cell/src/cellFactory.ts `CellFactory.Attributes`.
extension SharedCell: SharedObjectKind {
    public static func getFactory() -> ChannelFactory {
        ChannelFactory(SharedCell.self, snapshotFormatVersion: "0.1")
    }
}

/// register-collection/src/consensusRegisterCollectionFactory.ts `ConsensusRegisterCollectionFactory.Attributes`.
extension ConsensusRegisterCollection: SharedObjectKind {
    public static func getFactory() -> ChannelFactory {
        ChannelFactory(ConsensusRegisterCollection.self, snapshotFormatVersion: "0.1")
    }
}

/// shared-summary-block/src/sharedSummaryBlockFactory.ts `SharedSummaryBlockFactory.Attributes`.
extension SharedSummaryBlockClass: SharedObjectKind {
    public static func getFactory() -> ChannelFactory {
        ChannelFactory(SharedSummaryBlockClass.self, snapshotFormatVersion: "0.1")
    }
}

/// pact-map/src/pactMapFactory.ts `PactMapFactory.Attributes`.
extension PactMapClass: SharedObjectKind {
    public static func getFactory() -> ChannelFactory {
        ChannelFactory(PactMapClass.self, snapshotFormatVersion: "0.1")
    }
}

/// task-manager/src/taskManagerFactory.ts `TaskManagerFactory.Attributes`.
extension TaskManagerClass: SharedObjectKind {
    public static func getFactory() -> ChannelFactory {
        ChannelFactory(TaskManagerClass.self, snapshotFormatVersion: "0.1")
    }
}

/// ordered-collection/src/consensusOrderedCollectionFactory.ts `ConsensusQueueFactory.Attributes`.
extension ConsensusQueue: SharedObjectKind {
    public static func getFactory() -> ChannelFactory {
        ChannelFactory(ConsensusQueue.self, snapshotFormatVersion: "0.1")
    }
}

/// legacy-dds/src/array/sharedArrayFactory.ts `SharedArrayFactory.Attributes`.
extension SharedArrayClass: SharedObjectKind {
    public static func getFactory() -> ChannelFactory {
        ChannelFactory(SharedArrayClass.self, snapshotFormatVersion: "0.1")
    }
}

/// legacy-dds/src/signal/sharedSignalFactory.ts `SharedSignalFactory.Attributes`.
extension SharedSignalClass: SharedObjectKind {
    public static func getFactory() -> ChannelFactory {
        ChannelFactory(SharedSignalClass.self, snapshotFormatVersion: "0.1")
    }
}

/// sequence/src/sequenceFactory.ts `SharedStringFactory.Attributes`.
extension SharedString: SharedObjectKind {
    public static func getFactory() -> ChannelFactory {
        ChannelFactory(SharedString.self, snapshotFormatVersion: "0.1")
    }
}

/// matrix/src/runtime.ts `SharedMatrixFactory.Attributes`.
extension SharedMatrix: SharedObjectKind {
    public static func getFactory() -> ChannelFactory {
        ChannelFactory(SharedMatrix.self, snapshotFormatVersion: "0.1")
    }
}
