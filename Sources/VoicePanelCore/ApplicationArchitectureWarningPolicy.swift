public enum ApplicationArchitectureWarningPolicy {
    public static func shouldWarnAboutRosetta(
        executableIsIntel: Bool,
        hostSupportsAppleSilicon: Bool,
        processIsTranslated: Bool
    ) -> Bool {
        executableIsIntel && hostSupportsAppleSilicon && processIsTranslated
    }
}
