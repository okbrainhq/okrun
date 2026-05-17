# ASIF Import Workflow

## Objective

Add an import flow for existing `.asif` Linux VM disks. The user selects an ASIF disk image, Okrun copies it into a new project, generates the Okrun-owned metadata, registers the project, and selects it in the app.

This workflow intentionally supports only `.asif` files. Importing full Okrun project folders, RAW disks, and other VM formats can be separate future work.

## User-Facing Behavior

The user chooses **Import VM** from the app UI, selects a `.asif` disk, then chooses a destination project directory or accepts a suggested destination. Okrun creates:

```text
<project>/
  okrun-vm.json
  vm/
    linux.asif
    efi.variables
    machine.identifier
```

After a successful import, the project appears in the sidebar and becomes the selected VM. The VM is ready to start without requiring the user to edit JSON.

The import flow should say that Okrun generates a fresh EFI variable store. Most standard Linux installs should boot, but a disk that depends on custom EFI boot entries may require bootloader repair from a rescue ISO.

## Generated Project Config

Generate `okrun-vm.json` with conservative defaults and imported disk metadata:

```json
{
  "cpuCount": 4,
  "memoryGB": 4,
  "diskGB": 64,
  "diskFormat": "asif",
  "diskIO": {
    "caching": "cached",
    "synchronization": "full"
  },
  "installerISOPath": null,
  "privateNetwork": {
    "enabled": true
  },
  "sharedDirectories": []
}
```

`diskGB` should come from the ASIF virtual size, not the host-allocated size:

```text
diskutil image info --plist /path/to/source.asif
```

Use the same parsing path as `DiskImageCreator.virtualSize(url:format:)`. Convert bytes to GiB with ceiling division so Okrun never tries to shrink the imported disk. If the ASIF virtual size is not an exact GiB, the first storage preparation may expand the disk to the next GiB; this is acceptable and should be mentioned in logs.

## Import Steps

1. Open an `NSOpenPanel` configured for files with the `.asif` extension.
2. Validate that the selected source exists, is readable, and passes `diskutil image info --plist`.
3. Read the ASIF virtual size and compute `diskGB`.
4. Ask for, or derive, a new project directory.
5. Stage the import in a temporary sibling directory.
6. Create the staged `vm/` directory.
7. Copy the source ASIF to `vm/linux.asif`.
8. Generate `okrun-vm.json` with `diskFormat: "asif"` and detected `diskGB`.
9. Generate `vm/machine.identifier` with `VZGenericMachineIdentifier`.
10. Generate `vm/efi.variables` with `VZEFIVariableStore(creatingVariableStoreAt:)`.
11. Atomically move the staged directory to the final project path.
12. Add the final project path to the project registry and select it.
13. Refresh the sidebar and show the imported VM as ready.

## Copy Semantics

The import should copy the ASIF disk, not move it. The source file remains untouched.

Prefer an APFS clone-style copy when source and destination support it, because imported ASIF images can be large and sparse. Fall back to a normal copy when cloning is unavailable. The UI should show progress for slow copies.

Before copying, check destination volume capacity using the best available allocated-size estimate:

- Prefer source `totalFileAllocatedSize` or `fileAllocatedSize`.
- Fall back to source apparent size when allocated size is unavailable.
- Warn or fail early when free space is clearly insufficient.

## Validation Rules

- Only accept `.asif`.
- Require ASIF support on the current macOS version.
- Require `diskutil image info --plist` to return a positive virtual size.
- Reject destination paths that already contain an Okrun project unless the user picks a different directory.
- Reject destination paths inside the source ASIF file path or otherwise self-overlapping.
- Do not update the registry until the staged project has been fully created and moved into place.

## Failure Handling

Use a staging directory so partial imports do not appear as real projects. If any step fails before the final move, remove the staging directory and show a clear error.

If the registry update fails after the final project is created, leave the project directory in place and show its path so the user can import or select it again later.

If the first boot fails because the generated EFI store does not contain the required boot entry, guide the user to boot a Linux installer or rescue ISO and reinstall the EFI bootloader.

## UI Placement

Add **Import VM** near the existing project creation flow:

- Sidebar add menu or adjacent import button.
- File menu item: **Import VM...**.
- Empty-state action when no projects exist.

The final screen should summarize:

- source ASIF path
- destination project path
- detected disk size
- generated CPU and memory defaults
- fresh EFI store caveat

## Implementation Areas

- `ProjectWizard` or a sibling import panel for the import UI.
- `MainUI` for import action wiring, status updates, registry update, and sidebar refresh.
- `VMCore` for reusable import helpers if the workflow needs more than UI orchestration.
- Tests in `OkrunVMTests` for size detection, generated config, staging cleanup, and registry update behavior.

## Test Plan

1. Unit-test ASIF virtual-size-to-`diskGB` conversion, including exact GiB and non-exact GiB sizes.
2. Unit-test generated `VMConfig` values for an imported ASIF.
3. Unit-test that the workflow rejects non-ASIF files.
4. Unit-test that failed imports do not update the registry.
5. Unit-test that failed staged imports clean up the staging directory.
6. E2E smoke-test importing a small ASIF fixture, then verify the project contains `okrun-vm.json`, `vm/linux.asif`, `vm/efi.variables`, and `vm/machine.identifier`.
7. Boot test with a known-good Linux ASIF that supports fallback EFI boot.

## Future Work

- Import an existing full Okrun project folder while preserving `efi.variables` and `machine.identifier`.
- Optional repair flow for disks that need EFI bootloader recovery.
- Optional settings screen during import for CPU, memory, private network, and shared directories.
- Optional RAW-to-ASIF conversion import.
