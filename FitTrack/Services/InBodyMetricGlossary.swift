import Foundation

/// One-tap explanation strings for every metric an InBody scan reports.
/// Surfaced behind the small `info.circle` button next to each row label in
/// `InBodyImportSheet`. Keep entries plain-English and 1–3 sentences — this
/// is consumer-facing, not a clinical reference.
///
/// Lookup is by the same row label string the import sheet renders, so
/// updating a row name there means updating the key here too. Missing keys
/// fall back to a generic "no explanation available" message rather than
/// crashing.
enum InBodyMetricGlossary {
    struct Info: Identifiable {
        let id: String
        let title: String
        let body: String
    }

    static func info(for label: String) -> Info {
        let body = entries[label] ?? "No description available for this metric."
        return Info(id: label, title: label, body: body)
    }

    private static let entries: [String: String] = [
        // Whole-body
        "Weight": "Total body weight in pounds. The single most-tracked metric — pairs with Body Fat % to tell whether weight changes are fat or lean tissue.",
        "BMI": "Body Mass Index = weight ÷ height². A rough screening number; ignores muscle vs fat composition, so athletes routinely score 'overweight' despite low body fat.",
        "Body Fat %": "Percentage of total body weight that is fat tissue. Healthier ranges: ~10–20% for men, ~18–28% for women — varies by age and goal.",
        "Body Fat Mass": "Pounds of fat tissue in your body (Weight × Body Fat %). Useful when tracking fat-loss progress in absolute terms.",
        "Lean Body Mass": "Everything that isn't fat: muscle, bone, organs, and body water. Going up while weight is flat means you traded fat for muscle.",
        "Skeletal Muscle Mass": "Pounds of muscle attached to your skeleton (the muscle you train in the gym). The key strength-training progress metric.",
        "Dry Lean Mass": "Lean body mass with the water subtracted out — i.e. protein + minerals. A more stable view of muscle that ignores hydration swings.",
        "Intracellular Water": "Water inside your cells. Higher ICW relative to ECW correlates with healthier, well-hydrated muscle tissue.",
        "Extracellular Water": "Water outside your cells (blood plasma, interstitial fluid). Elevated ECW can indicate inflammation or fluid retention.",
        "Total Body Water": "ICW + ECW. Adults are typically 50–60% water by weight; tracks day-to-day hydration.",
        "ECW/TBW": "Ratio of extracellular to total body water. Healthy range is roughly 0.36–0.39. Above 0.40 suggests inflammation, dehydration, or fluid imbalance.",
        "Visceral Fat Level": "InBody's 1–20 scale for fat around your organs (the dangerous kind). Below 10 is healthy; above 12 raises cardiovascular risk.",
        "Basal Metabolic Rate": "Calories your body burns at complete rest in 24 hours just to stay alive. Add activity on top to estimate daily calorie needs.",

        // Segmental — same explanation works for both Lean and Fat sides
        "Right Arm": "Lean (or fat) mass in the named limb. Compare left vs right to spot muscular asymmetries; legs typically hold more lean mass than arms.",
        "Left Arm": "Lean (or fat) mass in the named limb. Compare left vs right to spot muscular asymmetries; legs typically hold more lean mass than arms.",
        "Trunk": "Lean (or fat) mass in your torso (chest, back, abdomen). Trunk lean is usually the largest segment; trunk fat is what drives Visceral Fat Level.",
        "Right Leg": "Lean (or fat) mass in the named limb. Compare left vs right to spot muscular asymmetries; legs typically hold more lean mass than arms.",
        "Left Leg": "Lean (or fat) mass in the named limb. Compare left vs right to spot muscular asymmetries; legs typically hold more lean mass than arms."
    ]
}
