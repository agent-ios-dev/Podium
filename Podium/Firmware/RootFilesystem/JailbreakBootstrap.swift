import Foundation
import CryptoKit

/// Installs a reviewed bootstrap, not arbitrary DEB maintainer scripts.
/// Real-device exploits/untether daemons are deliberately unnecessary:
/// the guest kernel already boots with signing enforcement disabled.
enum JailbreakBootstrap {
    static func apply(to builder: RootFilesystemBuilder) throws {
        guard builder.contains("/Applications/MobileSafari.app/MobileSafari"),
              let url=Bundle.main.url(forResource:"cydia-bootstrap",withExtension:"zip") else { return }
        let archive=try ZipArchiveReader(fileURL:url)
        guard let manifestEntry=archive.entry(named:"manifest.json") else { throw HFSPlusError.corrupt("Missing Cydia bootstrap manifest") }
        let manifest=try JSONSerialization.jsonObject(with:archive.data(for:manifestEntry)) as! [[String:Any]]
        func directory(_ path: String) throws {
            if path=="/" || builder.contains(path) { return }
            let parent=(path as NSString).deletingLastPathComponent
            try directory(parent); try builder.addFolder(path,owner:0,group:0,mode:0o755)
        }
        for item in manifest.sorted(by:{ ($0["path"] as! String).count < ($1["path"] as! String).count }) {
            let path=item["path"] as! String
            guard path.hasPrefix("/"), !path.split(separator:"/").contains("..") else { throw HFSPlusError.corrupt("Invalid bootstrap path") }
            let resolved=try builder.resolvedPath(path,resolvingFinalComponent:false)
            try directory((resolved as NSString).deletingLastPathComponent)
            let mode=UInt16(item["mode"] as! Int), uid=UInt32(item["uid"] as! Int), gid=UInt32(item["gid"] as! Int)
            switch item["type"] as! String {
            case "directory": if !builder.contains(resolved) { try builder.addFolder(resolved,owner:uid,group:gid,mode:mode) }
            case "symlink":
                if builder.contains(resolved) { try builder.remove(resolved) }
                try builder.addSymbolicLink(resolved,target:item["target"] as! String,owner:uid,group:gid,template:"/private/etc/fstab")
            default:
                guard let entry=archive.entry(named:String(path.dropFirst())) else { throw HFSPlusError.corrupt("Missing bootstrap file: \(path)") }
                try builder.addFile(resolved,contents:[UInt8](try archive.data(for:entry)),template:"/usr/libexec/keybagd",mode:mode)
            }
        }
        try builder.addFile("/.cydia_no_stash",contents:[],template:"/private/etc/fstab")
        if let tool=Bundle.main.url(forResource:"podium_netd",withExtension:"bin") {
            try builder.addFile("/usr/libexec/podium_netd",contents:[UInt8](try Data(contentsOf:tool)),template:"/usr/libexec/keybagd",mode:0o755)
            let daemon:[String:Any] = ["Label":"com.podium.netd","ProgramArguments":["/usr/libexec/podium_netd"],"RunAtLoad":true,"KeepAlive":true,"ThrottleInterval":30]
            let data=try PropertyListSerialization.data(fromPropertyList:daemon,format:.binary,options:0)
            try builder.addFile("/System/Library/LaunchDaemons/com.podium.netd.plist",contents:[UInt8](data),template:"/System/Library/LaunchDaemons/com.apple.mobile.keybagd.plist")
        }
    }
}
