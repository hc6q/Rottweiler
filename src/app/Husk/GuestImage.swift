// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Compression
import Darwin

/// Manages the Android guest that lives in Documents.
///
/// The guest is LineageOS built to boot directly under QEMU
/// (github.com/jqssun/android-lineage-qemu), not Android inside a container
/// inside another Linux. That removes Debian, LXC, Waydroid, cage, dbus and
/// pipewire from underneath it -- along with every failure that only existed
/// because of them -- and the arm64only build is the one that project
/// recommends for iOS, where there is no hypervisor and QEMU is emulating.
///
/// Three files make up the guest. Only the system disk is downloaded; the other
/// two are a few hundred kilobytes each and ride in the IPA:
///
///   vda  system, 5 GiB virtual  -- downloaded, compressed clusters
///   vdb  userdata, 16 GiB virtual, empty -- seeded from the bundle
///   efi_vars  UEFI variable store (qcow2, 64 MiB virtual) -- seeded
@MainActor
final class GuestImage: ObservableObject {
    static let shared = GuestImage()

    enum State: Equatable {
        case missing
        case downloading(progress: Double, received: Int64, total: Int64)
        case installing
        case snapshotFailed(String)
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .missing

    /// Published alongside the IPA. Kept as a constant here so a rebuilt guest can
    /// be rolled out without shipping a new app binary.
    /// A qcow2 with compressed clusters (`qemu-img convert -c`). QEMU reads those
    /// transparently, so there is no decompression step in the app at all -- which
    /// matters because iOS's Compression framework offers LZFSE/LZ4/LZMA/zlib and
    /// neither zstd nor bzip2, so any external container would have meant shipping
    /// a decompressor.
    /// Bumped whenever the guest image itself changes. Without this the app keeps
    /// whatever it downloaded first: the disk exists, so nothing re-fetches it, and
    /// a guest missing a newly-added component fails in ways that look like app
    /// bugs rather than a stale image.
    /// The single "Dependencies" release that holds every downloadable asset.
    ///
    /// Fixed, so bumping a generation does not need a new GitHub release --
    /// the version lives in the asset name instead.
    static let dependenciesTag = "lineage-v2"
    /// Asset generation. Bumping this re-downloads the guest and its snapshot.
    ///
    /// v5 adds an init script that marks the device provisioned. Without it
    /// Android shows no launcher and adbd refuses every shell, because an
    /// unprovisioned device runs ADB in trade-in mode.
    ///
    /// v10 adds the command bridge -- an init service running a netcat listener
    /// on port 5599 whose child is a shell in `u:r:shell:s0`. That is what the
    /// library talks to, so an install carrying an older guest has no library at
    /// all and must re-fetch.
    /// v12 declares android.hardware.ethernet in /system/etc/permissions, so
    /// EthernetService starts and claims eth0. Without a registered network,
    /// netd's per-uid routing has no default to point at and the command bridge
    /// goes silent about a minute after every boot.
    static let imageVersion = "v12"

    /// Version shared by the blank userdata seed and downloaded snapshots.
    private static let userdataSeedVersion = "v10"

    /// Whether to fetch the pre-booted snapshot rather than boot from cold.
    static var wantsSnapshot: Bool {
        UserDefaults.standard.object(forKey: "husk.downloadSnapshot") as? Bool ?? true
    }

    /// A machine that has already finished booting, gzipped.
    ///
    /// Booting Android here takes five to twelve minutes and has to survive
    /// Android's own watchdog killing system_server partway through. The same
    /// boot was done once on a Mac and saved; restoring it took 8.8 seconds.
    /// Two gigabytes of download buys that.
    /// The snapshot arrives in pieces.
    ///
    /// GitHub refuses a release asset of 2 GiB or more -- "size must be less
    /// than 2147483648" -- and the pre-booted machine is 3 GiB of guest RAM
    /// that still compresses to just over the limit at maximum effort. So it is
    /// published split. The split is on plain byte offsets and not a container
    /// of any kind, so concatenating the pieces in order reproduces the gzip
    /// stream byte for byte and nothing downstream needs to know it happened.
    static let snapshotPartCount = 2
    static var snapshotPartURLs: [URL] {
        (0..<snapshotPartCount).map { i in
            URL(string: "https://github.com/Leviidev/Husk/releases/download/"
                      + "\(dependenciesTag)/vdb-snapshot-\(imageVersion).qcow2.gz."
                      + String(format: "%02d", i))!
        }
    }

    /// RAM and resolution the shipped snapshot was taken with.
    ///
    /// Not adjustable. QEMU refuses a restore whose RAM size differs by a byte
    /// -- "Size mismatch: huskram" -- so a device that probed its way to 5120
    /// could not load a snapshot saved at 4096. These are the numbers the
    /// snapshot on the release was built against.
    static let snapshotGuestMiB = 4096
    static let snapshotXres = 360
    static let snapshotYres = 800

    static var imageURL: URL {
        URL(string: "https://github.com/Leviidev/Husk/releases/download/"
                  + "\(dependenciesTag)/vda-\(imageVersion).qcow2")!
    }

    nonisolated private var versionStampPath: String {
        // Named for this guest, not the old one. It used to be
        // "husk-guest.version", which cleanUpPreviousGuest() deletes as Waydroid
        // leftovers -- so every launch wiped the stamp, decided the image was
        // unversioned, and downloaded 1.1 GB again.
        documents.appendingPathComponent("lineage-guest.version").path
    }

    // nonisolated: QEMU's own thread builds its command line from these, and they
    // are pure path arithmetic with no mutable state to protect.
    nonisolated private var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    nonisolated var diskPath: String { documents.appendingPathComponent("lineage-vda.qcow2").path }
    /// Present when userdata came from the shipped pre-booted snapshot.
    nonisolated var snapshotStampPath: String {
        documents.appendingPathComponent("husk-shipped-snapshot").path
    }
    /// Whether a valid pre-booted snapshot is present. Version freshness is
    /// checked separately against the remote manifest.
    ///
    /// Existence alone was not enough. The stamp survived an image version bump,
    /// so an install that already had the v1 snapshot skipped downloading the v5
    /// one -- while the userdata that snapshot lived in had just been re-seeded
    /// empty by the same bump. The app then pinned the machine for a restore
    /// that could not happen and cold-booted, which looks exactly like the
    /// snapshot feature silently not existing.
    nonisolated var hasShippedSnapshot: Bool {
        // The stamp files can outlive the disk they describe. A snapshot only
        // counts as installed while its qcow2 is present and valid.
        guard Self.validate(path: userdataPath).problem == nil else { return false }
        // A recorded digest is the modern answer. Comparing the stamp to
        // imageVersion, as this used to, quietly tied "do I have a snapshot" to
        // "is the app's generation string current" -- so publishing a new image
        // made every install believe its perfectly good snapshot had vanished,
        // and with it the pinned RAM and resolution a restore depends on.
        if installedSnapshotDigest != nil { return true }
        // Installs from before digests existed recorded a generation name here
        // instead. Their snapshot is still on disk and still restorable.
        return (try? String(contentsOfFile: snapshotStampPath, encoding: .utf8)) != nil
    }

    // MARK: digests

    /// SHA-256 of the system image this install actually wrote to disk, and of
    /// the snapshot archive it actually unpacked.
    ///
    /// Recorded at install time rather than computed on demand, because only the
    /// system image is still the bytes that were downloaded -- userdata is
    /// rewritten the instant Android runs, so hashing it later answers a
    /// different question than "is this the snapshot the release is offering".
    nonisolated var imageDigestPath: String {
        documents.appendingPathComponent("lineage-guest.sha256").path
    }
    nonisolated var snapshotDigestPath: String {
        documents.appendingPathComponent("husk-shipped-snapshot.sha256").path
    }
    /// The machine the installed snapshot was saved on, as JSON. Travels with
    /// the snapshot so a restore is never attempted at the wrong RAM size.
    nonisolated var snapshotPinsPath: String {
        documents.appendingPathComponent("husk-snapshot-pins.json").path
    }

    nonisolated private func recorded(at path: String) -> String? {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated var installedImageDigest: String?    { recorded(at: imageDigestPath) }
    nonisolated var installedSnapshotDigest: String? { recorded(at: snapshotDigestPath) }

    /// RAM and resolution the installed snapshot needs, falling back to the
    /// values this app was built against when nothing was recorded.
    nonisolated var snapshotPins: (mib: Int, xres: Int, yres: Int, smp: Int, cpu: String) {
        let fallback = (Self.snapshotGuestMiB, Self.snapshotXres, Self.snapshotYres,
                        Self.defaultSmp, Self.defaultCpu)
        guard let data = FileManager.default.contents(atPath: snapshotPinsPath),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mib = j["guestMiB"] as? Int,
              let x = j["xres"] as? Int, let y = j["yres"] as? Int
        else { return fallback }
        return (mib, x, y,
                j["smp"] as? Int ?? Self.defaultSmp,
                j["cpu"] as? String ?? Self.defaultCpu)
    }

    /// What this build uses when a snapshot does not say otherwise.
    static let defaultSmp = 4
    static let defaultCpu = "max,pauth-impdef=on,sve=off,sme=off"

    /// What the release is offering that this install does not have.
    @Published private(set) var update: GuestUpdate = .none
    @Published private(set) var manifest: GuestManifest?

    /// Compare what is installed against what the release publishes.
    ///
    /// Digests, not version names. The app used to decide this by writing the
    /// generation it believed it had installed into a stamp file and comparing
    /// strings, which cannot detect either of the two ways it has actually gone
    /// wrong: a stamp that outlived the files it described, and an asset
    /// published under a new name carrying the old bytes.
    func checkForUpdates() async {
        guard let m = await GuestManifest.fetch() else { return }
        manifest = m

        let haveImage = FileManager.default.fileExists(atPath: diskPath)

        // An install from before digests were recorded has the image but no
        // record of what it hashed to, which is indistinguishable from having
        // the wrong one. Hash it once instead of assuming the worst -- assuming
        // costs the person a three-gigabyte download of what they already have.
        if haveImage, installedImageDigest == nil {
            let path = diskPath
            let digest = await Task.detached(priority: .utility) {
                DigestWriter.ofFile(at: path)
            }.value
            if let digest {
                try? digest.write(toFile: imageDigestPath, atomically: true, encoding: .utf8)
                HuskLog.log("guest", "hashed the existing image: \(digest.prefix(12))…")
            }
        }

        guard haveImage, state == .ready else {
            update = .none
            return
        }
        if installedImageDigest != m.image.sha256 {
            HuskLog.log("guest", "image differs: have "
                      + "\(installedImageDigest?.prefix(12) ?? "nothing"), "
                      + "release has \(m.image.sha256.prefix(12))")
            offer(.image(bytes: m.image.size + m.snapshot.size), digest: m.image.sha256)
            return
        }
        if Self.wantsSnapshot,
           (!hasShippedSnapshot || installedSnapshotDigest != m.snapshot.sha256) {
            HuskLog.log("guest", "snapshot differs: have "
                      + "\(installedSnapshotDigest?.prefix(12) ?? "nothing"), "
                      + "release has \(m.snapshot.sha256.prefix(12))")
            offer(.snapshot(bytes: m.snapshot.size), digest: m.snapshot.sha256)
            return
        }
        HuskLog.log("guest", "guest is up to date with \(m.generation)")
        update = .none
    }

    /// Take whatever the update prompt offered.
    func applyUpdate() {
        switch update {
        case .image:    update = .none; download()
        case .snapshot: update = .none; downloadSnapshotNow()
        case .none:     break
        }
    }

    private static let declinedUpdateKey = "husk.guest.updateDeclined"
    private var offeredDigest: String?

    private func offer(_ candidate: GuestUpdate, digest: String) {
        guard !QemuRunner.shared.isRunning,
              UserDefaults.standard.string(forKey: Self.declinedUpdateKey) != digest else {
            update = .none
            return
        }
        offeredDigest = digest
        update = candidate
    }

    func dismissUpdate() {
        if update.isSomething, let offeredDigest {
            UserDefaults.standard.set(offeredDigest, forKey: Self.declinedUpdateKey)
        }
        update = .none
    }

    nonisolated var userdataPath: String { documents.appendingPathComponent("lineage-vdb.qcow2").path }
    nonisolated var varsPath: String { documents.appendingPathComponent("lineage-efi-vars.fd").path }
    nonisolated var firmwarePath: String { documents.appendingPathComponent("edk2-aarch64-code.fd").path }

    private var task: URLSessionDownloadTask?

    /// Bump whenever the set or order of virtio devices in the Phase 1 command
    /// line changes. Any change renumbers the PCI bus and invalidates recorded
    /// UEFI boot entries.
    nonisolated static let deviceLayoutSignature = "v4-lineage-gpu-xhci-2blk-net-serial-rng-balloon-vmstatenode"

    /// qcow2 magic: "QFI\xfb". Checked because a download that "succeeded" is not
    /// the same as a download that produced an image -- a 404 body lands on disk
    /// just as happily as 755 MB of guest would.
    private static let qcow2Magic: [UInt8] = [0x51, 0x46, 0x49, 0xFB]

    /// Anything smaller than this is definitionally not a guest image. The real
    /// one is ~755 MB; the failure that prompted this check was 9 bytes of
    /// "Not Found".
    private static let minimumPlausibleSize: Int64 = 64 * 1024 * 1024

    /// True if the file at `path` looks like a qcow2 of plausible size.
    nonisolated static func validate(path: String) -> (size: Int64?, problem: String?) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else {
            return (nil, "file is missing")
        }
        guard size >= minimumPlausibleSize else {
            // Show a little of it: when this fires the content is usually a short
            // error page, and quoting it names the real problem immediately.
            var hint = ""
            if size > 0, size < 512,
               let d = fm.contents(atPath: path),
               let text = String(data: d, encoding: .utf8) {
                hint = " — content was: \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            return (nil, "only \(size) bytes, expected at least "
                        + "\(minimumPlausibleSize / (1024 * 1024)) MB\(hint)")
        }
        guard let fh = FileHandle(forReadingAtPath: path),
              let head = try? fh.read(upToCount: 4), head.count == 4 else {
            return (nil, "could not read the file header")
        }
        try? fh.close()
        guard Array(head) == qcow2Magic else {
            let hex = head.map { String(format: "%02x", $0) }.joined(separator: " ")
            return (nil, "not a qcow2 image (header was \(hex), expected 51 46 49 fb)")
        }
        return (size, nil)
    }

    func refresh() {
        if case .downloading = state { return }
        if case .installing = state { return }
        if case .snapshotFailed = state { return }
        removeStaleDownloads()

        guard FileManager.default.fileExists(atPath: diskPath) else {
            state = .missing
            return
        }
        // Validate every time, not just after downloading: a previous run may have
        // installed a corrupt file before this check existed, and the symptom of
        // that ("Image is not in qcow2 format") points at QEMU rather than here.
        // A valid image of the wrong version is still the wrong image.
        let installed = try? String(contentsOfFile: versionStampPath, encoding: .utf8)
        if installed != Self.imageVersion {
            HuskLog.log("guest", "installed guest is \(installed ?? "unversioned"), "
                               + "need \(Self.imageVersion); re-downloading")
            try? FileManager.default.removeItem(atPath: diskPath)
            state = .missing
            return
        }

        let check = Self.validate(path: diskPath)
        if let why = check.problem {
            HuskLog.log("guest", "existing guest disk is INVALID (\(why)); removing it")
            try? FileManager.default.removeItem(atPath: diskPath)
            state = .failed("The runtime on disk is not a valid image (\(why)). Tap to retry.")
        } else {
            HuskLog.log("guest", "guest disk present and valid: \(check.size ?? 0) bytes")
            state = .ready
        }
    }

    /// Create the UEFI variable store beside the bundled firmware.
    ///
    /// The firmware itself ships raw in the app bundle. It is 64 MiB, but almost
    /// entirely zeros, so the IPA's own zip compresses it to about a megabyte --
    /// cheaper than carrying a decompressor for it.
    /// Remove what the previous guest architecture left in Documents.
    ///
    /// The Waydroid disk grew to over 4 GB once Android had been written into it
    /// and is now dead weight on the user's phone. Its diagnostics file is worse
    /// than dead: the bridge still folds it into the log every poll, replaying
    /// Debian and Waydroid text long after either existed, which reads exactly
    /// like a live guest saying the wrong thing.
    private func cleanUpPreviousGuest() {
        let fm = FileManager.default
        let stale = ["husk-guest.qcow2", "husk-guest.version",
                     "edk2-vars.fd", "edk2-vars.fd.layout",
                     "share/diagnostics.txt"]
        var freed: Int64 = 0
        for name in stale {
            let path = documents.appendingPathComponent(name).path
            guard fm.fileExists(atPath: path) else { continue }
            let size = ((try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
            try? fm.removeItem(atPath: path)
            freed += size
        }
        if freed > 0 {
            HuskLog.log("guest", "removed \(freed / (1024 * 1024)) MiB left by the previous "
                               + "guest (Debian/Waydroid)")
        }
    }

    func prepareFirmware() throws {
        cleanUpPreviousGuest()
        let fm = FileManager.default
        if !fm.fileExists(atPath: firmwarePath) {
            guard let src = Bundle.main.path(forResource: "edk2-aarch64-code", ofType: "fd") else {
                throw NSError(domain: "husk", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "edk2-aarch64-code.fd missing from the app bundle"])
            }
            // Copied rather than used in place: pflash wants a plain file and the
            // bundle is read-only, and keeping both volumes together in Documents
            // makes the pair easy to reason about.
            try fm.copyItem(atPath: src, toPath: firmwarePath)
            HuskLog.log("guest", "firmware staged to Documents")
        }
        // The UEFI variable store records boot entries as PCI device paths. Adding
        // or removing a virtio device renumbers the bus, so entries written under a
        // previous device layout stop resolving -- and the firmware then falls
        // through to PXE and drops to the EFI Shell instead of booting the disk.
        // The symptom looks nothing like its cause, so the store is stamped with a
        // signature of the layout and rebuilt whenever that changes.
        let stamp = URL(fileURLWithPath: varsPath + ".layout")
        let current = Self.deviceLayoutSignature
        let previous = try? String(contentsOf: stamp, encoding: .utf8)

        if !fm.fileExists(atPath: varsPath) || previous != current {
            if previous != nil, previous != current {
                HuskLog.log("guest", "device layout changed (\(previous ?? "?") -> \(current)); "
                                   + "resetting the UEFI variable store so it re-discovers the disk")
            } else {
                HuskLog.log("guest", "staging UEFI variable store")
            }
            // Seeded from the image's own variable store rather than created
            // blank. It already holds the boot entry for this Android build,
            // which saves the firmware a discovery pass -- and if our PCI layout
            // does not match the one it was recorded under, the entry simply
            // fails to resolve and the firmware falls back to scanning for
            // \EFI\BOOT\BOOTAA64.EFI, which is where it would have ended up
            // starting from empty anyway.
            guard let seed = Bundle.main.path(forResource: "lineage-efi-vars-seed", ofType: "fd") else {
                throw NSError(domain: "husk", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "lineage-efi-vars-seed.fd missing from the app bundle"])
            }
            try? fm.removeItem(atPath: varsPath)
            try fm.copyItem(atPath: seed, toPath: varsPath)
            try? current.write(to: stamp, atomically: true, encoding: .utf8)
        }

        // Userdata. Empty on arrival -- 16 GiB virtual, 192 KB on disk -- and
        // written by Android from its first boot onward, so it is copied out of
        // the read-only bundle once and then left alone. Deliberately NOT tied
        // to the device layout signature: that changes for reasons that have
        // nothing to do with /data, and resetting it factory-resets the guest.
        //
        // It has its own version instead, bumped only when userdata is known to
        // be unusable. It is at v2 because a kernel panic killed the guest
        // partway through building /data, and what it left behind made Android
        // reboot into recovery on every subsequent start
        // ("init_user0_failed"). Nothing short of a clean partition fixes that.
        let seedStamp = URL(fileURLWithPath: userdataPath + ".seed")
        // v3: the guest image changed, so userdata built against the old /system --
        // including a multi-gigabyte snapshot of it -- has to go.
        let seedVersion = Self.userdataSeedVersion
        let seededWith = try? String(contentsOf: seedStamp, encoding: .utf8)
        if fm.fileExists(atPath: userdataPath), seededWith != seedVersion {
            if hasShippedSnapshot {
                // Snapshot installs use the same userdata disk but historically
                // did not write this seed stamp. Repair the stamp instead of
                // replacing a valid, downloaded snapshot with an empty disk.
                try seedVersion.write(to: seedStamp, atomically: true, encoding: .utf8)
                HuskLog.log("guest", "preserving installed snapshot and repairing its "
                                   + "userdata seed stamp")
            } else {
                // Check for the replacement before deleting existing data. A
                // missing resource must not turn an upgrade into a missing disk.
                guard let seed = Bundle.main.path(forResource: "lineage-vdb-seed", ofType: "qcow2") else {
                    throw NSError(domain: "husk", code: 3, userInfo: [
                        NSLocalizedDescriptionKey: "lineage-vdb-seed.qcow2 missing from the app bundle"])
                }
                HuskLog.log("guest", "userdata seed \(seededWith ?? "unversioned") -> \(seedVersion); "
                                   + "starting from a clean partition")
                try? fm.removeItem(atPath: userdataPath)
                try fm.copyItem(atPath: seed, toPath: userdataPath)
                try seedVersion.write(to: seedStamp, atomically: true, encoding: .utf8)
                HuskLog.log("guest", "userdata disk staged to Documents")
            }
        }
        if !fm.fileExists(atPath: userdataPath) {
            guard let seed = Bundle.main.path(forResource: "lineage-vdb-seed", ofType: "qcow2") else {
                throw NSError(domain: "husk", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "lineage-vdb-seed.qcow2 missing from the app bundle"])
            }
            try fm.copyItem(atPath: seed, toPath: userdataPath)
            try seedVersion.write(to: seedStamp, atomically: true, encoding: .utf8)
            HuskLog.log("guest", "userdata disk staged to Documents")
        }
    }

    func download() {
        guard !QemuRunner.shared.isRunning, task == nil, fetcher == nil,
              state != .installing else { return }
        removeStaleDownloads()
        state = .downloading(progress: 0, received: 0, total: 0)
        let release = manifest
        let url = release?.imageURL ?? Self.imageURL
        HuskLog.log("guest", "downloading guest image from \(url.absoluteString)")

        let delegate = DownloadDelegate(owner: self, release: release)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        // The manifest names the file, so publishing a new image needs no new
        // app build. The constant is only the fallback for a first run that
        // could not reach the release.
        task = session.downloadTask(with: url)
        task?.resume()
    }

    /// Fetch the pre-booted machine on demand, reporting progress like any other
    /// download.
    ///
    /// This exists because the automatic fetch only ran as the tail of a fresh
    /// guest-image download. Anyone who already had the image -- which is most
    /// people, and was the case that reported this -- turned the setting on and
    /// watched nothing happen, because there was no download for it to follow.
    /// True while the current download is the snapshot rather than the image.
    @Published private(set) var isFetchingSnapshot = false

    func downloadSnapshotNow() {
        guard !QemuRunner.shared.isRunning, task == nil, fetcher == nil,
              state != .installing else { return }
        if hasShippedSnapshot {
            // A valid but older snapshot may be on disk when the manifest
            // offers a replacement. Do not let the presence check block that
            // update; only skip when the installed digest matches the release.
            guard let expected = manifest?.snapshot.sha256 else {
                HuskLog.log("guest", "snapshot already installed; release manifest unavailable")
                return
            }
            if installedSnapshotDigest == expected {
                HuskLog.log("guest", "snapshot already installed")
                return
            }
        }
        let release = manifest
        if let release, let installedImageDigest, installedImageDigest != release.image.sha256 {
            snapshotFailed("The published snapshot requires a newer Android system image.")
            return
        }
        downloadSnapshot(release: release)
    }

    private var fetcher: SnapshotFetcher?
    private var snapshotRequest: UUID?

    /// Both an initial install and a later update stage the entire disk before
    /// replacing userdata. A failed download or unpack leaves the old disk usable.
    private func downloadSnapshot(release: GuestManifest?) {
        if let short = snapshotSpaceShortfall(archiveSize: release?.snapshot.size) {
            snapshotFailed("Not enough free space for the pre-booted snapshot: \(short).")
            return
        }

        let request = UUID()
        snapshotRequest = request
        isFetchingSnapshot = true
        state = .downloading(progress: 0, received: 0, total: 0)
        HuskLog.log("guest", "downloading pre-booted snapshot (about 2 GB)")
        fetcher = SnapshotFetcher(
            request: request,
            urls: release?.partURLs ?? Self.snapshotPartURLs,
            progress: { [weak self] got, total in
                Task { @MainActor in
                    guard let self, self.snapshotRequest == request, case .downloading = self.state else { return }
                    self.progressed(received: got, total: total)
                }
            },
            completion: { [weak self] result in
                Task { @MainActor in
                    guard let self, self.snapshotRequest == request else {
                        if case .success(let joined) = result {
                            try? FileManager.default.removeItem(at: joined.url)
                        }
                        return
                    }
                    self.fetcher = nil
                    self.snapshotRequest = nil
                    switch result {
                    case .failure(let error):
                        self.snapshotFailed(error.localizedDescription)
                    case .success(let joined):
                        if let expected = release?.snapshot.sha256, expected != joined.digest {
                            try? FileManager.default.removeItem(at: joined.url)
                            self.snapshotFailed("The snapshot did not match the release.")
                            return
                        }
                        self.installSnapshot(joined, pins: release?.snapshot)
                    }
                }
            })
        fetcher?.start()
    }

    private func snapshotFailed(_ message: String) {
        HuskLog.log("guest", "snapshot failed: \(message)")
        isFetchingSnapshot = false
        #if HUSK_NO_JIT
        state = .snapshotFailed(message)
        #else
        state = .ready
        #endif
    }

    func useInstalledAndroid() {
        guard case .snapshotFailed = state else { return }
        state = .ready
    }

    private func installSnapshot(_ joined: SnapshotFetcher.Joined, pins: GuestManifest.Snapshot?) {
        state = .installing
        HuskLog.log("guest", "unpacking pre-booted snapshot")
        let destination = userdataPath
        let staged = destination + ".installing-" + UUID().uuidString
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            defer {
                try? fm.removeItem(at: joined.url)
                try? fm.removeItem(atPath: staged)
            }
            do {
                try Self.gunzip(from: joined.url, to: URL(fileURLWithPath: staged))
                if let problem = Self.validate(path: staged).problem {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: problem])
                }
                try await MainActor.run {
                    try Self.userdataSeedVersion.write(toFile: destination + ".seed",
                                                       atomically: true, encoding: .utf8)
                    // Same directory and filesystem. rename replaces the old disk
                    // atomically and leaves it intact if the operation fails.
                    guard rename(staged, destination) == 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    self.recordSnapshotPins(pins)
                    try? Self.imageVersion.write(toFile: self.snapshotStampPath, atomically: true, encoding: .utf8)
                    try? joined.digest.write(toFile: self.snapshotDigestPath, atomically: true, encoding: .utf8)
                    let runner = QemuRunner.shared
                    for path in [runner.snapshotSizePath, runner.snapshotDisplayPath, runner.memoryStrategyPath] {
                        try? fm.removeItem(atPath: path)
                    }
                    HuskLog.log("guest", "pre-booted snapshot installed")
                    self.isFetchingSnapshot = false
                    self.state = .ready
                }
            } catch {
                await self.snapshotFailed("Could not install the pre-booted snapshot: \(error.localizedDescription)")
            }
        }
    }

    /// What unpacking the snapshot takes on disk at its peak: the joined archive and the expanded disk side by side (#75, #128:
    /// a phone that ran out partway used to crash, because the old FileHandle.write raises instead of throwing, and the next
    /// launch offered the download again). nil when it fits.
    private func snapshotSpaceShortfall(archiveSize: Int64?) -> String? {
        let archive = max(0, archiveSize ?? 2_200_000_000)
        let expanded: Int64 = 5_000_000_000
        // A part can still occupy URLSession's temporary file while it is
        // copied into the joined archive. Keep room for the larger peak.
        let margin: Int64 = 500_000_000
        let (peak, peakOverflow) = archive.addingReportingOverflow(max(archive, expanded))
        let (required, marginOverflow) = peak.addingReportingOverflow(margin)
        let need = peakOverflow || marginOverflow ? Int64.max : required
        guard let free = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        else { return nil }
        guard free < need else { return nil }
        let gb = { (b: Int64) in String(format: "%.1f GB", Double(b) / 1e9) }
        return "it needs \(gb(need)) free and the device has \(gb(free))"
    }

    /// The staging files of a download or unpack that a previous run did not live to finish: gigabytes in tmp that iOS only
    /// clears when it decides to, and that left the next attempt even shorter of space.
    private func removeStaleDownloads() {
        guard fetcher == nil, task == nil else { return }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        let files = (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("husk-snapshot-download-")
            || file.lastPathComponent == "husk-snapshot-download.gz"
            || file.lastPathComponent.hasPrefix("husk-guest-download-")
            || file.lastPathComponent == "husk-guest-download.qcow2" {
            try? fm.removeItem(at: file)
        }
        let documentsFiles = (try? fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? []
        let prefix = URL(fileURLWithPath: userdataPath).lastPathComponent + ".installing-"
        for file in documentsFiles where file.lastPathComponent.hasPrefix(prefix) {
            try? fm.removeItem(at: file)
        }
    }

    /// Remember the machine the installed snapshot expects.
    ///
    /// QEMU refuses a restore whose RAM differs by a byte ("Size mismatch:
    /// huskram"), so these have to describe the snapshot on disk rather than
    /// whatever this build of the app happens to prefer.
    private func recordSnapshotPins(_ snap: GuestManifest.Snapshot?) {
        guard let snap else {
            try? FileManager.default.removeItem(atPath: snapshotPinsPath)
            return
        }
        var json: [String: Any] = ["guestMiB": snap.guestMiB,
                                   "xres": snap.xres, "yres": snap.yres]
        if let smp = snap.smp { json["smp"] = smp }
        if let cpu = snap.cpu { json["cpu"] = cpu }
        if let data = try? JSONSerialization.data(withJSONObject: json) {
            try? data.write(to: URL(fileURLWithPath: snapshotPinsPath), options: .atomic)
            HuskLog.log("guest", "snapshot needs \(snap.guestMiB) MiB at "
                               + "\(snap.xres)x\(snap.yres)")
        }
    }

    /// Streaming gunzip.
    ///
    /// Apple's Compression framework speaks raw DEFLATE, not the gzip
    /// container, so the header is parsed and skipped by hand. Streamed in
    /// chunks because the output is nearly four gigabytes and will not be held
    /// in memory on a phone.
    nonisolated static func gunzip(from src: URL, to dst: URL) throws {
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let output = try FileHandle(forWritingTo: dst)
        defer { try? output.close() }

        // Gzip header: magic, method, flags, mtime, xfl, os -- then optional
        // extra field, name, comment and header CRC, in that order.
        var head = try input.read(upToCount: 10) ?? Data()
        guard head.count == 10, head[0] == 0x1f, head[1] == 0x8b, head[2] == 8 else {
            throw NSError(domain: "husk", code: 1, userInfo:
                [NSLocalizedDescriptionKey: "not a gzip file"])
        }
        let flg = head[3]
        if flg & 0x04 != 0 {                                  // FEXTRA
            let n = try input.read(upToCount: 2) ?? Data()
            guard n.count == 2 else { throw CocoaError(.fileReadCorruptFile) }
            let len = Int(n[0]) | (Int(n[1]) << 8)
            _ = try input.read(upToCount: len)
        }
        for mask in [UInt8(0x08), UInt8(0x10)] where flg & mask != 0 {   // FNAME, FCOMMENT
            while let b = try input.read(upToCount: 1), b.count == 1, b[0] != 0 {}
        }
        if flg & 0x02 != 0 { _ = try input.read(upToCount: 2) }          // FHCRC
        head = Data()

        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
                                        dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
                                        src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE,
                                      COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw NSError(domain: "husk", code: 2, userInfo:
                [NSLocalizedDescriptionKey: "inflate init failed"])
        }
        defer { compression_stream_destroy(&stream) }

        let chunk = 1 << 20
        let outBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { outBuf.deallocate() }
        var finished = false

        while !finished {
            let data = try input.read(upToCount: chunk) ?? Data()
            let last = data.isEmpty
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                stream.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress
                    ?? UnsafePointer<UInt8>(bitPattern: 1)!
                stream.src_size = data.count
                repeat {
                    stream.dst_ptr = outBuf
                    stream.dst_size = chunk
                    let st = compression_stream_process(&stream, last ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                    let produced = chunk - stream.dst_size
                    if produced > 0 {
                        try output.write(contentsOf: Data(bytes: outBuf, count: produced))
                    }
                    if st == COMPRESSION_STATUS_END { finished = true; break }
                    if st == COMPRESSION_STATUS_ERROR {
                        throw NSError(domain: "husk", code: 3, userInfo:
                            [NSLocalizedDescriptionKey: "inflate failed"])
                    }
                } while stream.src_size > 0 || (last && !finished)
            }
            if last { finished = true }
        }
    }

    func cancel() {
        guard case .downloading = state else { return }
        task?.cancel()
        task = nil
        fetcher?.cancel()
        fetcher = nil
        snapshotRequest = nil
        isFetchingSnapshot = false
        state = Self.validate(path: diskPath).problem == nil ? .ready : .missing
        HuskLog.log("guest", "download cancelled")
    }

    fileprivate func finished(tempURL: URL, digest: String?, release: GuestManifest?) {
        state = .installing
        HuskLog.log("guest", "download complete; installing")
        // A download that arrived is not a download that arrived intact. When
        // the release says what the bytes should hash to, insist on it -- a
        // truncated image otherwise installs cleanly and fails much later,
        // inside QEMU, as something that looks nothing like a bad download.
        if let want = release?.image.sha256, digest != want {
            let got = digest.map { String($0.prefix(12)) } ?? "unavailable"
            let bytes = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? -1
            try? FileManager.default.removeItem(at: tempURL)
            HuskLog.log("guest", "image rejected: sha256 \(got) but the "
                               + "release says \(want.prefix(12)); \(bytes) bytes, "
                               + "release has \(release?.image.size ?? -1)")
            state = .failed("The downloaded image did not match the release. Tap to retry.")
            return
        }
        // Validate BEFORE installing, so a bad download never becomes the thing
        // QEMU is asked to boot.
        let check = Self.validate(path: tempURL.path)
        if let why = check.problem {
            try? FileManager.default.removeItem(at: tempURL)
            HuskLog.log("guest", "downloaded file rejected: \(why)")
            state = .failed("Download did not produce a disk image: \(why)")
            return
        }
        let size = check.size ?? 0
        do {
            let fm = FileManager.default
            guard rename(tempURL.path, diskPath) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try Self.imageVersion.write(toFile: versionStampPath, atomically: true, encoding: .utf8)
            if let digest {
                try digest.write(toFile: imageDigestPath, atomically: true, encoding: .utf8)
            } else {
                try? fm.removeItem(atPath: imageDigestPath)
            }

            // A snapshot can carry over only when the release specifically
            // publishes the same archive for the new system disk.
            if let published = release?.snapshot.sha256, installedSnapshotDigest == published {
                HuskLog.log("guest", "snapshot is unchanged in the manifest; keeping it")
            } else {
                let runner = QemuRunner.shared
                for path in [snapshotStampPath, snapshotDigestPath, snapshotPinsPath,
                             runner.snapshotSizePath, runner.snapshotDisplayPath, runner.memoryStrategyPath] {
                    try? fm.removeItem(atPath: path)
                }
            }

            HuskLog.log("guest", "guest image ready (\(size) bytes, \(Self.imageVersion))")
            if Self.wantsSnapshot, !hasShippedSnapshot {
                downloadSnapshot(release: release)
            } else {
                state = .ready
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            HuskLog.log("guest", "FAIL: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    fileprivate func progressed(received: Int64, total: Int64) {
        let p = total > 0 ? Double(received) / Double(total) : 0
        state = .downloading(progress: p, received: received, total: total)
    }

    fileprivate func failed(_ message: String) {
        HuskLog.log("guest", "download FAILED: \(message)")
        state = .failed(message)
    }

    fileprivate func completeImageDownload(_ completed: URLSessionTask, action: () -> Void) -> Bool {
        guard task === completed else { return false }
        task = nil
        action()
        return true
    }

    fileprivate func updateImageProgress(_ current: URLSessionTask, received: Int64, total: Int64) {
        guard task === current else { return }
        progressed(received: received, total: total)
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    weak var owner: GuestImage?
    private let release: GuestManifest?

    init(owner: GuestImage, release: GuestManifest?) {
        self.owner = owner
        self.release = release
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // A download task reports "finished" for any completed HTTP exchange,
        // including a 404 -- whose body then lands on disk as if it were the file
        // asked for. This is exactly how a 9-byte "Not Found" once became the
        // guest disk image. Check the status before treating it as the payload.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            let body = (try? String(contentsOf: location, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = body.isEmpty ? "" : " — server said: \(body.prefix(200))"
            let url = downloadTask.originalRequest?.url?.absoluteString ?? "?"
            Task { @MainActor in
                guard let owner = self.owner else { return }
                _ = owner.completeImageDownload(downloadTask) {
                    owner.failed("HTTP \(http.statusCode) from \(url)\(detail)")
                }
            }
            return
        }

        // The temp file is deleted when this returns, so move it somewhere stable
        // before handing it over.
        let stable = FileManager.default.temporaryDirectory
            .appendingPathComponent("husk-guest-download-\(UUID().uuidString).qcow2")
        do {
            try FileManager.default.moveItem(at: location, to: stable)
        } catch {
            Task { @MainActor in
                guard let owner = self.owner else { return }
                _ = owner.completeImageDownload(downloadTask) {
                    owner.failed("could not stage download: \(error.localizedDescription)")
                }
            }
            return
        }
        // Hashed here rather than on the main actor: this delegate callback is
        // already off the main thread, and a gigabyte is not something to digest
        // while the UI waits.
        let digest = DigestWriter.ofFile(at: stable.path)
        Task { @MainActor in
            let accepted = self.owner?.completeImageDownload(downloadTask) {
                self.owner?.finished(tempURL: stable, digest: digest, release: self.release)
            } ?? false
            if !accepted { try? FileManager.default.removeItem(at: stable) }
        }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            self.owner?.updateImageProgress(downloadTask, received: totalBytesWritten,
                                            total: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        s.finishTasksAndInvalidate()
        if let error {
            Task { @MainActor in
                guard let owner = self.owner else { return }
                _ = owner.completeImageDownload(task) { owner.failed(error.localizedDescription) }
            }
        }
    }
}

/// Downloads the snapshot's parts in order and joins them into one file.
///
/// One part at a time, deliberately. Two gigabytes arriving in parallel would
/// need both in flight at once, and this runs on a phone that is about to be
/// asked for another four gigabytes to unpack into.
private final class SnapshotFetcher: NSObject, URLSessionDownloadDelegate {
    private let urls: [URL]
    private let onProgress: (Int64, Int64) -> Void
    private let onDone: (Result<Joined, Error>) -> Void

    /// The joined archive and what it hashed to.
    struct Joined { let url: URL; let digest: String }

    /// Hashed as the parts are appended. The alternative is a second full pass
    /// over two gigabytes once the download finishes, for no extra information.
    private let hasher = DigestWriter()

    /// Where the joined archive is built up.
    private let staged: URL

    private var index = 0
    /// Bytes belonging to parts already appended, so progress does not restart
    /// at zero every time a part finishes.
    private var bytesDone: Int64 = 0
    private var session: URLSession!

    init(request: UUID, urls: [URL],
         progress: @escaping (Int64, Int64) -> Void,
         completion: @escaping (Result<Joined, Error>) -> Void) {
        self.urls = urls
        self.staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("husk-snapshot-download-\(request.uuidString).gz")
        self.onProgress = progress
        self.onDone = completion
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func start() {
        guard FileManager.default.createFile(atPath: staged.path, contents: nil) else {
            fail("could not create the snapshot download file")
            return
        }
        next()
    }

    func cancel() { session.invalidateAndCancel() }

    func urlSession(_ s: URLSession, didBecomeInvalidWithError error: Error?) {
        if index < urls.count { try? FileManager.default.removeItem(at: staged) }
    }

    private func next() {
        guard index < urls.count else {
            let size = (try? FileManager.default
                .attributesOfItem(atPath: staged.path)[.size] as? Int) ?? 0
            let digest = hasher.finish()
            HuskLog.log("guest", "snapshot download complete (\(size ?? 0) bytes, "
                               + "sha256 \(digest.prefix(12))…)")
            onDone(.success(Joined(url: staged, digest: digest)))
            session.finishTasksAndInvalidate()
            return
        }
        HuskLog.log("guest", "fetching snapshot part \(index + 1) of \(urls.count)")
        session.downloadTask(with: urls[index]).resume()
    }

    private func fail(_ message: String) {
        try? FileManager.default.removeItem(at: staged)
        session.invalidateAndCancel()
        onDone(.failure(NSError(domain: "husk", code: 10,
                                userInfo: [NSLocalizedDescriptionKey: message])))
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // A completed exchange is not a successful one: a 404 body lands on disk
        // looking exactly like the file that was asked for.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            fail("HTTP \(http.statusCode) fetching "
               + (downloadTask.originalRequest?.url?.lastPathComponent ?? "a snapshot part"))
            return
        }
        do {
            let input = try FileHandle(forReadingFrom: location)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: staged)
            defer { try? output.close() }
            try output.seekToEnd()
            while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
                hasher.update(chunk)
                bytesDone += Int64(chunk.count)
            }
        } catch {
            fail("could not join snapshot part \(index + 1): \(error.localizedDescription)")
            return
        }
        try? FileManager.default.removeItem(at: location)
        index += 1
        next()
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // The parts are near enough the same size that one of them stands in for
        // the rest; the alternative is a HEAD request per part before starting,
        // which buys a smoother bar and nothing else.
        let remaining = Int64(urls.count - index - 1)
        let estimate = totalBytesExpectedToWrite > 0
            ? bytesDone + totalBytesExpectedToWrite * (remaining + 1)
            : 0
        onProgress(bytesDone + totalBytesWritten, estimate)
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as NSError).code != NSURLErrorCancelled {
            fail(error.localizedDescription)
        }
    }
}
