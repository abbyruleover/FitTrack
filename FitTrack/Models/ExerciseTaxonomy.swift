import Foundation

enum MovementPattern: String, CaseIterable, Codable {
    case push, pull, squat, hinge, lunge, carry, core, conditioning, mobility
    var displayName: String { rawValue.capitalized }
}

enum Equipment: String, CaseIterable, Codable {
    case barbell, dumbbell, kettlebell, body, machine, cable, band,
         sled, rower, bike, ski, sandbag, medicineBall, bosu, trx, landmine, box

    var displayName: String {
        switch self {
        case .medicineBall: return "Medicine Ball"
        case .trx: return "TRX"
        case .bosu: return "BOSU"
        default: return rawValue.capitalized
        }
    }
}
