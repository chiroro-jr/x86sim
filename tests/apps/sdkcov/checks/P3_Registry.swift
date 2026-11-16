// sdkcov P3: app extensions, system services, communication and parental controls (P3_*.swift)
extension Registry {
    static var p3: [Check] { p3_extensions + p3_services + p3_family }
}
