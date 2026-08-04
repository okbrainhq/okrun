import Foundation

/// Safety checks around destructive project operations.
///
/// A VM project folder is deleted recursively when a VM is deleted. These guards
/// make sure the folder a project points to never contains anything besides the
/// project's own files, so deleting one VM can never remove other VMs or user data.
enum ProjectSafety {
    /// The only entries allowed at the root of a deletable project folder.
    /// Everything else means the folder is shared with other data.
    static let allowedRootEntries: Set<String> = ["okrun-vm.json", "vm", ".DS_Store"]

    /// Validates that the project at `root` can be deleted recursively.
    ///
    /// Throws when the folder contains unexpected entries (other VMs, user files),
    /// when another registered project is nested inside it, or when the path is
    /// too broad to remove (filesystem root or the user's home directory).
    static func validateProjectDeletable(at root: URL, registeredProjects: [String]) throws {
        let fileManager = FileManager.default
        let standardRoot = root.standardizedFileURL.resolvingSymlinksInPath()

        let homePath = fileManager.homeDirectoryForCurrentUser
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        guard standardRoot.path != "/", standardRoot.path != homePath else {
            throw AppError(
                "Refusing to delete \(standardRoot.path): the location is too broad to remove. Nothing was deleted."
            )
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            // The folder is already gone; removing the registry entry is safe.
            return
        }

        let rootPath = standardRoot.path
        for registered in registeredProjects {
            let registeredPath = URL(fileURLWithPath: registered, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
            if registeredPath != rootPath, registeredPath.hasPrefix(rootPath + "/") {
                throw AppError(
                    "Refusing to delete \(rootPath): it contains another registered VM (\(registeredPath)). Nothing was deleted."
                )
            }
        }

        let entries = try fileManager.contentsOfDirectory(atPath: rootPath)
        let unexpected = entries.filter { !allowedRootEntries.contains($0) }.sorted()
        guard unexpected.isEmpty else {
            throw AppError(
                "Refusing to delete \(rootPath): the folder contains other data (\(unexpected.joined(separator: ", "))). Nothing was deleted."
            )
        }
    }

    /// Validates that a new project can be created at `url`.
    ///
    /// The folder must either not exist yet or be completely empty, so the project
    /// never takes ownership of a folder that already holds other VMs or data.
    static func validateNewProjectLocation(at url: URL) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return
        }

        guard isDirectory.boolValue else {
            throw AppError("Cannot create a VM at \(url.path): a file already exists at that path.")
        }

        let entries = try fileManager.contentsOfDirectory(atPath: url.path)
        guard entries.isEmpty else {
            throw AppError(
                "Cannot create a VM in \(url.path): the folder is not empty. Choose an empty or new folder so deleting this VM later cannot remove other data."
            )
        }
    }
}
