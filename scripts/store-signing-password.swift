// сохраняет пароль в Keychain через Security API: в аргументах только путь к защищённому файлу
import Foundation
import Security

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: store-signing-password.swift <protected-password-file>\n".utf8))
    exit(2)
}

let passwordURL = URL(fileURLWithPath: CommandLine.arguments[1])
let password: Data
do { password = try Data(contentsOf: passwordURL).filter { $0 != 10 && $0 != 13 } }
catch {
    FileHandle.standardError.write(Data("файл пароля не прочитан: code=\((error as NSError).code)\n".utf8))
    exit(1)
}
guard !password.isEmpty else {
    FileHandle.standardError.write(Data("пустой файл пароля\n".utf8))
    exit(2)
}
var trusted: SecTrustedApplication?
var access: SecAccess?
let trustedStatus = SecTrustedApplicationCreateFromPath("/usr/bin/security", &trusted)
guard trustedStatus == errSecSuccess, let trusted else {
    FileHandle.standardError.write(Data("доверенное приложение не задано: OSStatus=\(trustedStatus)\n".utf8))
    exit(1)
}
let accessStatus = SecAccessCreate("Kampsis release signing" as CFString, [trusted] as CFArray, &access)
guard accessStatus == errSecSuccess, let access else {
    FileHandle.standardError.write(Data("доступ к записи Keychain не задан: OSStatus=\(accessStatus)\n".utf8))
    exit(1)
}
let status = SecItemAdd([
    kSecClass: kSecClassGenericPassword,
    kSecAttrService: "io.github.boundlessend.kampsis.signing",
    kSecAttrAccount: "release",
    kSecAttrAccess: access,
    kSecValueData: password,
] as CFDictionary, nil)
guard status == errSecSuccess else {
    FileHandle.standardError.write(Data("пароль не сохранён: OSStatus=\(status)\n".utf8))
    exit(1)
}
