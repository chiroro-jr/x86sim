// sdkcov P10: the coverage gaps that needed new app extensions or an Objective-C @try (P10_*.swift)
extension Registry {
    static var p10: [Check] { p10_extensions + p10_answers }
}
