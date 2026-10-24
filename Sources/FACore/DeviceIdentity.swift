import Foundation

public enum DeviceIdentity {
    public static func resolve(storedID: String?, storedMachineHash: String?, currentMachineHash: String?) -> (id: String, machineHash: String?) {
        guard let current = currentMachineHash else {
            return (storedID ?? newID(), storedMachineHash)
        }
        if let storedID, storedMachineHash == nil || storedMachineHash == current {
            return (storedID, current)
        }
        return (newID(), current)
    }

    private static func newID() -> String { UUID().uuidString.lowercased() }
}
